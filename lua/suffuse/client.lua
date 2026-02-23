-- lua/suffuse/client.lua
-- HTTP/1.1 + TLS transport for the suffuse grpc-gateway.
--
-- Two connection types:
--   watch_conn  — persistent, uses conn:read_start() for streaming
--   rpc         — short-lived, uses conn:read_sync() for copy/paste/status

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

---@param host string
---@param port integer
---@param cb   fun(conn: table|nil, err: string|nil)
local function connect(host, port, cb)
  if not tls.available then
    vim.schedule(function() cb(nil, 'TLS unavailable (LuaJIT + OpenSSL required)') end)
    return
  end

  vim.uv.getaddrinfo(host, tostring(port), { socktype = 'stream' }, function(err, res)
    if err or not res or not res[1] then
      vim.schedule(function()
        cb(nil, 'DNS failed for ' .. host .. ': ' .. tostring(err))
      end)
      return
    end

    local ip  = res[1].addr
    local tcp = vim.uv.new_tcp()
    tcp:connect(ip, port, function(cerr)
      if cerr then
        tcp:close()
        vim.schedule(function()
          cb(nil, 'TCP connect (' .. host .. '): ' .. cerr)
        end)
        return
      end

      -- Async TLS handshake via memory BIOs + tcp:read_start
      tls.wrap(tcp, host, function(conn, herr)
        vim.schedule(function()
          if not conn then
            tcp:close()
            vim.notify('[suffuse] tls.wrap failed: ' .. tostring(herr), vim.log.levels.WARN)
            cb(nil, herr)
          else
            vim.notify('[suffuse] tls.wrap ok', vim.log.levels.WARN)
            cb(conn, nil)
          end
        end)
      end)
    end)
  end)
end

---@param host string
---@param port integer
---@param cb   fun(reachable: boolean)
local function probe(host, port, cb)
  vim.uv.getaddrinfo(host, tostring(port), { socktype = 'stream' }, function(err, res)
    if err or not res or not res[1] then cb(false); return end
    local tcp = vim.uv.new_tcp()
    tcp:connect(res[1].addr, port, function(cerr)
      tcp:close()
      cb(not cerr)
    end)
  end)
end

-- ── Client ────────────────────────────────────────────────────────────────────

local Client = {}
Client.__index = Client

function M.new(cfg)
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
    source           = vim.fn.hostname() or 'nvim',
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
    conn:write(req)
    conn:read_sync(4096)  -- discard response
    conn:close()
  end)
end

function Client:fetch_paste(cb)
  if self.state ~= STATE.CONNECTED then cb(nil, 'not connected'); return end
  local host = self.resolved_host
  local req  = proto.paste_request(host, self.cfg.token)
  connect(host, self.cfg.port, function(conn, err)
    if err then cb(nil, err); return end
    conn:write(req)
    local raw, rerr = conn:read_sync(65536)
    conn:close()
    if not raw then cb(nil, rerr); return end
    local _, _, body = proto.parse_headers(raw)
    local ok, obj    = pcall(vim.json.decode, body)
    if not ok then cb(nil, 'json: ' .. tostring(obj)); return end
    local text = proto.text_from_items(obj.items)
    cb(text, text and nil or 'no text/plain in response')
  end)
end

function Client:fetch_status(cb)
  if self.state ~= STATE.CONNECTED then cb(nil, 'not connected'); return end
  local host = self.resolved_host
  local req  = proto.status_request(host, self.cfg.token)
  connect(host, self.cfg.port, function(conn, err)
    if err then cb(nil, err); return end
    conn:write(req)
    local raw, rerr = conn:read_sync(65536)
    conn:close()
    if not raw then cb(nil, rerr); return end
    local _, _, body = proto.parse_headers(raw)
    local ok, obj    = pcall(vim.json.decode, body)
    if not ok then cb(nil, 'json: ' .. tostring(obj)); return end
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
    probe(host, self.cfg.port, function(ok)
      if not ok then try_next(); return end
      self.resolved_host = host
      vim.schedule(function() self:_open_watch(host) end)
    end)
  end

  try_next()
end

function Client:_open_watch(host)
  self.state = STATE.CONNECTING
  connect(host, self.cfg.port, function(conn, err)
    if err then
      vim.notify('[suffuse] connect failed: ' .. err, vim.log.levels.WARN)
      self.state = STATE.DISCONNECTED
      self:_schedule_reconnect(function() self:_start() end)
      return
    end

    local req    = proto.watch_request(host, self.cfg.token)
    local ok, werr = conn:write(req)
    if not ok then
      conn:close()
      vim.notify('[suffuse] watch write: ' .. (werr or '?'), vim.log.levels.WARN)
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

    conn:read_start(
      function(data) self:_on_watch_data(data) end,
      function(e)    self:_watch_disconnected(e) end
    )
  end)
end

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
