-- lua/suffuse/tls.lua
-- TLS via LuaJIT FFI → OpenSSL.
--
-- Wraps a connected vim.uv TCP handle with SSL. The rest of the client sees
-- the same read/write interface regardless of TLS.
--
-- The server uses a self-signed certificate derived from the shared token.
-- We skip certificate chain verification (SSL_CTX_set_verify NONE) because
-- we cannot reproduce the HKDF key derivation in Lua. Traffic is still
-- encrypted; the token in the Authorization header provides authentication.
--
-- libuv sets all TCP sockets to non-blocking mode. SSL_connect() requires the
-- fd to be blocking (or a poll loop). We temporarily set the fd to blocking
-- for the handshake via fcntl(F_SETFL), then restore it afterward.

if not jit then
  return { available = false }
end

local ffi = require('ffi')

-- ── libc (fcntl) ─────────────────────────────────────────────────────────────

ffi.cdef[[
  int fcntl(int fd, int cmd, ...);
]]

-- ffi.C gives access to symbols already in the process (libc is always loaded)
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048  -- 0x800 on Linux/aarch64 and x86_64

local function set_blocking(fd, blocking)
  local flags = ffi.C.fcntl(fd, F_GETFL, 0)
  if flags < 0 then return end
  if blocking then
    flags = bit.band(flags, bit.bnot(O_NONBLOCK))
  else
    flags = bit.bor(flags, O_NONBLOCK)
  end
  ffi.C.fcntl(fd, F_SETFL, ffi.cast('int', flags))
end

-- ── OpenSSL FFI declarations ─────────────────────────────────────────────────

ffi.cdef[[
  int      OPENSSL_init_ssl(uint64_t opts, const void *settings);

  typedef struct ssl_ctx_st SSL_CTX;
  SSL_CTX *SSL_CTX_new(const void *method);
  void     SSL_CTX_free(SSL_CTX *ctx);
  void     SSL_CTX_set_verify(SSL_CTX *ctx, int mode, void *cb);

  typedef struct ssl_st SSL;
  SSL     *SSL_new(SSL_CTX *ctx);
  void     SSL_free(SSL *ssl);
  int      SSL_set_fd(SSL *ssl, int fd);
  int      SSL_connect(SSL *ssl);
  int      SSL_read(SSL *ssl, void *buf, int num);
  int      SSL_write(SSL *ssl, const void *buf, int num);
  int      SSL_get_error(SSL *ssl, int ret);
  long     SSL_ctrl(SSL *ssl, int cmd, long larg, void *parg);

  const void *TLS_client_method(void);

  unsigned long ERR_get_error(void);
  void          ERR_error_string_n(unsigned long e, char *buf, size_t len);
]]

local ssl_loaded, libssl
for _, name in ipairs({ 'ssl', 'libssl.so.3', 'libssl.so.1.1', 'libssl.3.dylib', 'libssl.1.1.dylib' }) do
  ssl_loaded, libssl = pcall(ffi.load, name)
  if ssl_loaded then break end
end

if not ssl_loaded then
  return { available = false }
end

local M = { available = true }

local SSL_VERIFY_NONE = 0

local function ssl_err_string()
  local msgs = {}
  while true do
    local code = libssl.ERR_get_error()
    if code == 0 then break end
    local buf = ffi.new('char[256]')
    libssl.ERR_error_string_n(code, buf, 256)
    table.insert(msgs, ffi.string(buf))
  end
  if #msgs == 0 then return 'unknown SSL error (empty queue)' end
  return table.concat(msgs, '; ')
end

local _ctx
local function get_ctx()
  if _ctx then return _ctx end
  libssl.OPENSSL_init_ssl(0, nil)
  local ctx = libssl.SSL_CTX_new(libssl.TLS_client_method())
  if ctx == nil then error('SSL_CTX_new failed: ' .. ssl_err_string()) end
  libssl.SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
  _ctx = ctx
  return ctx
end

-- ── TLS connection ────────────────────────────────────────────────────────────

---@class TlsConn
---@field ssl  cdata  SSL*
---@field tcp  uv_tcp_t
local TlsConn = {}
TlsConn.__index = TlsConn

--- Wrap an already-connected vim.uv TCP handle with TLS.
--- The handshake is synchronous (brief block during connection setup only).
---@param tcp  uv_tcp_t
---@param host string   server hostname for SNI
---@return TlsConn|nil, string|nil
function M.wrap(tcp, host)
  local ctx = get_ctx()
  local ssl = libssl.SSL_new(ctx)
  if ssl == nil then
    return nil, 'SSL_new failed: ' .. ssl_err_string()
  end

  local fd, err = tcp:fileno()
  if not fd or fd < 0 then
    libssl.SSL_free(ssl)
    return nil, 'fileno() failed: ' .. tostring(err)
  end

  libssl.SSL_set_fd(ssl, fd)
  -- SSL_set_tlsext_host_name macro: SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME=55, TLSEXT_NAMETYPE_host_name=0, host)
  libssl.SSL_ctrl(ssl, 55, 0, ffi.cast('void *', ffi.cast('const char *', host)))

  -- libuv sets the fd non-blocking; SSL_connect needs blocking I/O.
  -- Set blocking for the handshake, restore non-blocking after.
  set_blocking(fd, true)
  local ret = libssl.SSL_connect(ssl)
  set_blocking(fd, false)

  if ret ~= 1 then
    local ssl_err = libssl.SSL_get_error(ssl, ret)
    local errmsg  = ssl_err_string()
    libssl.SSL_free(ssl)
    return nil, string.format('SSL_connect failed: ret=%d ssl_err=%d %s', ret, ssl_err, errmsg)
  end

  return setmetatable({ ssl = ssl, tcp = tcp }, TlsConn), nil
end

---@param data string
---@return boolean ok, string|nil errmsg
function TlsConn:write(data)
  local ret = libssl.SSL_write(self.ssl, data, #data)
  if ret <= 0 then
    return false, 'SSL_write failed: ' .. ssl_err_string()
  end
  return true, nil
end

---@param n integer
---@return string|nil data, string|nil errmsg
function TlsConn:read(n)
  local buf = ffi.new('char[?]', n)
  local ret = libssl.SSL_read(self.ssl, buf, n)
  if ret <= 0 then
    return nil, 'SSL_read failed: ' .. ssl_err_string()
  end
  return ffi.string(buf, ret), nil
end

--- Return the underlying fd for use with vim.uv.new_poll().
---@return integer|nil
function TlsConn:fd()
  return self.tcp:fileno()
end

function TlsConn:close()
  if self.ssl ~= nil then
    libssl.SSL_free(self.ssl)
    self.ssl = nil
  end
  pcall(function() self.tcp:close() end)
end

return M
