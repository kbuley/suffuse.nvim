-- lua/suffuse/client.lua
-- HTTP/1.1 + TLS transport for the suffuse grpc-gateway.
--
-- Two connections are maintained:
--   watch_conn  — persistent GET /v1/watch, chunked streaming response
--   rpc_conn    — short-lived connections for POST /v1/copy, GET /v1/status
--
-- TLS is handled by tls.lua (LuaJIT FFI → OpenSSL). If TLS is unavailable
-- the client refuses to connect rather than silently sending plaintext.
--
-- Connection lifecycle:
--   1. Probe DEFAULT_HOSTS in order (skipped if host is explicit)
--   2. TCP connect → TLS handshake → send Watch request
--   3. Stream chunked WatchResponse lines → dispatch to on_clipboard
--   4. On disconnect: exponential backoff reconnect (1s → 2s → … → 30s)

local proto = require('suffuse.protocol')
local tls   = require('suffuse.tls')
local M     = {}

local STATE = {
  DISCONNECTED = 'disconnected',
  PROBING      = 'probing',
  CONNECTING   = 'connecting',
  CONNECTED    = 'connected',
}

local BACKOFF_INIT = 1000
local BACKOFF_MAX  = 30000

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Open a TLS connection to host:port. Calls cb(conn, errmsg) when done.
--- The TCP connect is async; the TLS handshake runs in a uv work thread
--- so it doesn't block the Neovim event loop.
---@param host string
---@param port integer
---@param cb   fun(conn: table|nil, err: string|nil)
local function tls_connect(host, port, cb)
  if not tls.available then
    cb(nil, 'TLS not available (LuaJIT + OpenSSL required)')
    return
  end

  local tcp = vim.uv.new_tcp()
  tcp:connect(host, port, function(err)
    if err then
      tcp:close()
      cb(nil, 'TCP connect failed: ' .. err)
      return
    end

    -- TLS handshake in a thread so it doesn't block the loop.
    vim.uv.new_work(
      -- worker (runs in thread, no vim.* access)
      function(h, h_str)
        -- We can't pass cdata across threads, so we do the handshake
        -- back on the main loop via a timer trick instead.
        return h_str
      end,
      -- after_work (back on main loop)
      function()
        local conn, herr = tls.wrap(tcp, host)
        if not conn then
          tcp:close()
          cb(nil, herr)
          return
        end
        cb(conn, nil)
      end
    ):queue(host, host)
  end)
end

--- Simpler version: TLS handshake on main loop (brief block, acceptable for
--- connection setup). Replaces the thread approach which can't share cdata.
---@param host string
---@param port integer
---@param cb   fun(conn: table|nil, err: string|nil)
local function connect(host, port, cb)
  if not tls.available then
    cb(nil, 'TLS not available (LuaJIT + OpenSSL required)')
    return
  end

  local tcp = vim.uv.new_tcp()
  tcp:connect(host, port, function(err)
    if err then
      tcp:close()
      vim.schedule(function() cb(nil, 'TCP connect failed: ' .. err) end)
      return
    end
    -- Handshake on main loop — brief block during connection setup only.
    local conn, herr = tls.wrap(tcp, host)
    if not conn then
      tcp:close()
      vim.schedule(function() cb(nil, herr) end)
      return
    end
    vim.schedule(function() cb(conn, nil) end)
  end)
end

-- ── Client ───────────────────────────────────────────────────────────────────

---@class SuffuseClient
---@field cfg             table
---@field state           string
---@field resolved_host   string|nil
---@field watch_conn      table|nil     active TlsConn for the Watch stream
---@field backoff         integer
---@field reconnect_timer uv_timer_t|nil
---@field on_clipboard    fun(text:string)|nil
---@field _watch_buf      string        partial HTTP response buffer
---@field _watch_body_buf string        partial chunked body buffer
---@field _watch_headers  boolean       true once response headers consumed
---@field source          string
local Client = {}
Client.__index = Client

---@param cfg table
---@return SuffuseClient
function M.new(cfg)
  local source = vim.fn.hostname()
  return setmetatable({
    cfg              = cfg,
    state            = STATE.DISCONNECTED,
    resolved_host    = nil,
    watch_conn       = nil,
    backoff          = BACKOFF_INIT,
    reconnect_timer  = nil,
    on_clipboard     = nil,
    _watch_buf       = '',
    _watch_body_buf  = '',
    _watch_headers   = false,
    source           = source ~= '' and source or 'nvim',
  }, Client)
end

function Client:get_state() return self.state         end
function Client:get_host()  return self.resolved_host end

function Client:on_clipboard_update(fn) self.on_clipboard = fn end

-- ── Public API ────────────────────────────────────────────────────────────────

function Client:connect()
  if self.state ~= STATE.DISCONNECTED then return end
  self:_cancel_reconnect()
  self:_start()
end

function Client:disconnect()
  self:_cancel_reconnect()
  self:_close_watch()
  self.state         = STATE.DISCONNECTED
  self.resolved_host = nil
  self.backoff       = BACKOFF_INIT
end

--- Send text to the server via POST /v1/copy.
--- Opens a fresh TLS connection, sends the request, closes it.
---@param text string
function Client:send_text(text)
  if self.state ~= STATE.CONNECTED then
    vim.notify('[suffuse] not connected', vim.log.levels.WARN)
    return
  end
  local host = self.resolved_host
  local req  = proto.copy_request(host, self.cfg.token, text, self.source)
  connect(host, self.cfg.port, function(conn, err)
    if err then
      vim.notify('[suffuse] copy: ' .. err, vim.log.levels.WARN)
      return
    end
    local ok, werr = conn:write(req)
    if not ok then
      vim.notify('[suffuse] copy write: ' .. (werr or '?'), vim.log.levels.WARN)
    end
    -- Read and discard the response, then close.
    conn:read(4096)
    conn:close()
  end)
end

--- Fetch the current clipboard via POST /v1/paste.
--- Calls cb(text) with the plain-text content, or cb(nil, err) on failure.
---@param cb fun(text: string|nil, err: string|nil)
function Client:fetch_paste(cb)
  if self.state ~= STATE.CONNECTED then
    cb(nil, 'not connected')
    return
  end
  local host = self.resolved_host
  local req  = proto.paste_request(host, self.cfg.token)
  connect(host, self.cfg.port, function(conn, err)
    if err then cb(nil, err); return end

    local ok, werr = conn:write(req)
    if not ok then conn:close(); cb(nil, werr); return end

    -- Read full response (paste response is small, 4096 is plenty)
    local raw, rerr = conn:read(65536)
    conn:close()
    if not raw then cb(nil, rerr); return end

    local _, _, body = proto.parse_headers(raw)
    local ok2, obj = pcall(vim.json.decode, body)
    if not ok2 then cb(nil, 'json decode: ' .. tostring(obj)); return end

    local text = proto.text_from_items(obj.items)
    cb(text, text and nil or 'no text/plain in response')
  end)
end

--- Fetch peer status via GET /v1/status.
--- Calls cb(msg) with the decoded StatusResponse, or cb(nil, err).
---@param cb fun(msg: table|nil, err: string|nil)
function Client:fetch_status(cb)
  if self.state ~= STATE.CONNECTED then
    cb(nil, 'not connected')
    return
  end
  local host = self.resolved_host
  local req  = proto.status_request(host, self.cfg.token)
  connect(host, self.cfg.port, function(conn, err)
    if err then cb(nil, err); return end

    local ok, werr = conn:write(req)
    if not ok then conn:close(); cb(nil, werr); return end

    local raw, rerr = conn:read(65536)
    conn:close()
    if not raw then cb(nil, rerr); return end

    local _, _, body = proto.parse_headers(raw)
    local ok2, obj = pcall(vim.json.decode, body)
    if not ok2 then cb(nil, 'json decode: ' .. tostring(obj)); return end
    cb(obj, nil)
  end)
end

-- ── Watch stream ──────────────────────────────────────────────────────────────

function Client:_start()
  if self.cfg.host then
    self.resolved_host = self.cfg.host
    self:_open_watch(self.cfg.host)
    return
  end
  if self.resolved_host then
    self:_open_watch(self.resolved_host)
    return
  end
  self:_probe()
end

function Client:_probe()
  self.state  = STATE.PROBING
  local hosts = require('suffuse.config').DEFAULT_HOSTS
  local idx   = 0

  local function try_next()
    idx = idx + 1
    if idx > #hosts then
      vim.schedule(function()
        vim.notify(string.format('[suffuse] no host reachable, retrying in %ds',
          math.floor(self.backoff / 1000)), vim.log.levels.WARN)
        self.state = STATE.DISCONNECTED
        self:_schedule_reconnect(function() self:_probe() end)
      end)
      return
    end
    local host = hosts[idx]
    local tcp  = vim.uv.new_tcp()
    tcp:connect(host, self.cfg.port, function(err)
      tcp:close()
      if err then try_next(); return end
      self.resolved_host = host
      vim.schedule(function() self:_open_watch(host) end)
    end)
  end

  try_next()
end

--- Open the Watch stream connection to host.
---@param host string
function Client:_open_watch(host)
  self.state = STATE.CONNECTING
  connect(host, self.cfg.port, function(conn, err)
    if err then
      vim.notify('[suffuse] connect failed: ' .. err, vim.log.levels.WARN)
      self.state = STATE.DISCONNECTED
      self:_schedule_reconnect(function() self:_start() end)
      return
    end

    local req = proto.watch_request(host, self.cfg.token)
    local ok, werr = conn:write(req)
    if not ok then
      conn:close()
      vim.notify('[suffuse] watch write failed: ' .. (werr or '?'), vim.log.levels.WARN)
      self.state = STATE.DISCONNECTED
      self:_schedule_reconnect(function() self:_start() end)
      return
    end

    self.watch_conn      = conn
    self._watch_buf      = ''
    self._watch_body_buf = ''
    self._watch_headers  = false
    self.state           = STATE.CONNECTED
    self.backoff         = BACKOFF_INIT

    vim.notify(string.format('[suffuse] connected to %s:%d', host, self.cfg.port),
      vim.log.levels.INFO)

    -- Start async read loop via uv poll on the underlying TCP fd.
    self:_start_watch_read(conn)
  end)
end

--- Drive the Watch stream read loop using uv.new_poll on the TCP fd.
--- Reads are non-blocking; we poll for readability then call SSL_read.
---@param conn table  TlsConn
function Client:_start_watch_read(conn)
  local fd = conn.tcp:getfd()
  if not fd or fd < 0 then
    self:_watch_disconnected('could not get watch fd')
    return
  end

  local poll = vim.uv.new_poll(fd)
  poll:start('r', function(err, events)
    if err or not events then
      poll:stop(); poll:close()
      self:_watch_disconnected(err or 'poll error')
      return
    end

    local chunk, rerr = conn:read(16384)
    if not chunk then
      poll:stop(); poll:close()
      self:_watch_disconnected(rerr or 'read error')
      return
    end

    self:_on_watch_data(chunk)
  end)
end

--- Process raw bytes from the Watch stream.
---@param data string
function Client:_on_watch_data(data)
  if not self._watch_headers then
    -- Accumulate until we have the full header block.
    self._watch_buf = self._watch_buf .. data
    local status, headers, rest = proto.parse_headers(self._watch_buf)
    if not status then return end  -- headers not complete yet

    self._watch_headers = true
    self._watch_buf     = ''

    if status ~= 200 then
      vim.notify(string.format('[suffuse] watch HTTP %d', status), vim.log.levels.WARN)
      self:_close_watch()
      self.state = STATE.DISCONNECTED
      self:_schedule_reconnect(function() self:_start() end)
      return
    end

    -- Start processing body chunks.
    self._watch_body_buf = rest
    self:_process_watch_body()
  else
    self._watch_body_buf = self._watch_body_buf .. data
    self:_process_watch_body()
  end
end

--- Decode chunked body and dispatch complete WatchResponse objects.
function Client:_process_watch_body()
  local lines, remaining = proto.decode_chunks(self._watch_body_buf)
  self._watch_body_buf   = remaining

  for _, line in ipairs(lines) do
    local msg, err = proto.unwrap_watch(line)
    if err then
      vim.notify('[suffuse] watch: ' .. err, vim.log.levels.DEBUG)
    elseif msg and msg.items then
      local text = proto.text_from_items(msg.items)
      if text and self.on_clipboard then
        vim.schedule(function() self.on_clipboard(text) end)
      end
    end
  end
end

function Client:_watch_disconnected(reason)
  vim.schedule(function()
    if self.state == STATE.CONNECTED then
      vim.notify('[suffuse] disconnected: ' .. (reason or '?'), vim.log.levels.WARN)
    end
    self:_close_watch()
    self.state = STATE.DISCONNECTED
    self:_schedule_reconnect(function() self:_start() end)
  end)
end

function Client:_close_watch()
  if self.watch_conn then
    pcall(function() self.watch_conn:close() end)
    self.watch_conn = nil
  end
end

-- ── Reconnect ─────────────────────────────────────────────────────────────────

function Client:_schedule_reconnect(fn)
  self:_cancel_reconnect()
  local delay  = self.backoff
  self.backoff = math.min(self.backoff * 2, BACKOFF_MAX)
  local timer  = vim.uv.new_timer()
  self.reconnect_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    timer:close()
    self.reconnect_timer = nil
    if self.state == STATE.DISCONNECTED then fn() end
  end))
end

function Client:_cancel_reconnect()
  if self.reconnect_timer then
    pcall(function() self.reconnect_timer:stop() end)
    pcall(function() self.reconnect_timer:close() end)
    self.reconnect_timer = nil
  end
end

return M
