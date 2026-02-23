-- lua/suffuse/client.lua
-- HTTP/1.1 + TLS transport for the suffuse grpc-gateway.
--
-- Two connections are maintained:
--   watch_conn  — persistent GET /v1/watch, chunked streaming response
--   (rpc)       — short-lived connections for POST /v1/copy, GET /v1/status
--
-- Hostnames are resolved via vim.uv.getaddrinfo() before each TCP connect
-- since vim.uv TCP handles require a resolved IP address.

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

-- ── DNS + TCP + TLS connect ───────────────────────────────────────────────────

--- Resolve hostname to IP, open TCP connection, perform TLS handshake.
--- Calls cb(conn, errmsg) on completion. conn is a TlsConn on success.
---@param host string
---@param port integer
---@param cb   fun(conn: table|nil, err: string|nil)
local function connect(host, port, cb)
  if not tls.available then
    vim.schedule(function() cb(nil, 'TLS unavailable (LuaJIT + OpenSSL required)') end)
    return
  end

  -- Resolve hostname → IP (required; vim.uv.tcp:connect() needs a numeric IP)
  vim.uv.getaddrinfo(host, tostring(port), { socktype = 'stream' }, function(err, res)
    if err or not res or not res[1] then
      vim.schedule(function()
        cb(nil, 'DNS resolution failed for ' .. host .. ': ' .. tostring(err))
      end)
      return
    end

    local ip = res[1].addr

    local tcp = vim.uv.new_tcp()
    tcp:connect(ip, port, function(cerr)
      if cerr then
        tcp:close()
        vim.schedule(function()
          cb(nil, 'TCP connect failed (' .. host .. '): ' .. cerr)
        end)
        return
      end

      -- TLS handshake on main loop (brief block during connection setup only)
      vim.schedule(function()
        local conn, herr = tls.wrap(tcp, host)
        if not conn then
          tcp:close()
          cb(nil, herr)
          return
        end
        cb(conn, nil)
      end)
    end)
  end)
end

--- Probe a host by attempting a TCP connection (no TLS, just reachability).
--- Calls cb(ip) on success, cb(nil) on failure.
---@param host string
---@param port integer
---@param cb   fun(ip: string|nil)
local function probe(host, port, cb)
  vim.uv.getaddrinfo(host, tostring(port), { socktype = 'stream' }, function(err, res)
    if err or not res or not res[1] then cb(nil); return end
    local ip  = res[1].addr
    local tcp = vim.uv.new_tcp()
    tcp:connect(ip, port, function(cerr)
      tcp:close()
      cb(cerr and nil or ip)
    end)
  end)
end

-- ── Client ────────────────────────────────────────────────────────────────────

---@class SuffuseClient
---@field cfg             table
---@field state           string
---@field resolved_host   string|nil
---@field watch_conn      table|nil
---@field backoff         integer
---@field reconnect_timer uv_timer_t|nil
---@field on_clipboard    fun(text:string)|nil
---@field _watch_buf      string
---@field _watch_body_buf string
---@field _watch_headers  boolean
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
    conn:read(4096)  -- discard response
    conn:close()
  end)
end

---@param cb fun(text: string|nil, err: string|nil)
function Client:fetch_paste(cb)
  if self.state ~= STATE.CONNECTED then cb(nil, 'not connected'); return end
  local host = self.resolved_host
  local req  = proto.paste_request(host, self.cfg.token)
  connect(host, self.cfg.port, function(conn, err)
    if err then cb(nil, err); return end
    local ok, werr = conn:write(req)
    if not ok then conn:close(); cb(nil, werr); return end
    local raw, rerr = conn:read(65536)
    conn:close()
    if not raw then cb(nil, rerr); return end
    local _, _, body = proto.parse_headers(raw)
    local ok2, obj  = pcall(vim.json.decode, body)
    if not ok2 then cb(nil, 'json: ' .. tostring(obj)); return end
    local text = proto.text_from_items(obj.items)
    cb(text, text and nil or 'no text/plain in response')
  end)
end

---@param cb fun(msg: table|nil, err: string|nil)
function Client:fetch_status(cb)
  if self.state ~= STATE.CONNECTED then cb(nil, 'not connected'); return end
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
    local ok2, obj  = pcall(vim.json.decode, body)
    if not ok2 then cb(nil, 'json: ' .. tostring(obj)); return end
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
    probe(host, self.cfg.port, function(ip)
      if not ip then try_next(); return end
      self.resolved_host = host
      vim.schedule(function() self:_open_watch(host) end)
    end)
  end

  try_next()
end

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

    self:_start_watch_read(conn)
  end)
end

---@param conn table  TlsConn
function Client:_start_watch_read(conn)
  local fd = conn:fd()
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

    local chunk, rerr, retry = conn:read(16384)
    if retry then return end  -- WANT_READ: no data yet, wait for next poll event
    if not chunk then
      poll:stop(); poll:close()
      self:_watch_disconnected(rerr or 'read error')
      return
    end

    self:_on_watch_data(chunk)
  end)
end

---@param data string
function Client:_on_watch_data(data)
  if not self._watch_headers then
    self._watch_buf = self._watch_buf .. data
    local status, _, rest = proto.parse_headers(self._watch_buf)
    if not status then return end

    self._watch_headers = true
    self._watch_buf     = ''

    if status ~= 200 then
      vim.notify(string.format('[suffuse] watch HTTP %d', status), vim.log.levels.WARN)
      self:_close_watch()
      self.state = STATE.DISCONNECTED
      self:_schedule_reconnect(function() self:_start() end)
      return
    end

    self._watch_body_buf = rest
    self:_process_watch_body()
  else
    self._watch_body_buf = self._watch_body_buf .. data
    self:_process_watch_body()
  end
end

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
