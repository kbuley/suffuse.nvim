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

if not jit then
  return { available = false }
end

local ffi = require('ffi')

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
  int      SSL_set_tlsext_host_name(SSL *ssl, const char *name);

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
  local code = libssl.ERR_get_error()
  if code == 0 then return 'unknown SSL error' end
  local buf = ffi.new('char[256]')
  libssl.ERR_error_string_n(code, buf, 256)
  return ffi.string(buf)
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

  -- fileno() is the correct luv method (not getfd)
  local fd, err = tcp:fileno()
  if not fd or fd < 0 then
    libssl.SSL_free(ssl)
    return nil, 'fileno() failed: ' .. tostring(err)
  end

  libssl.SSL_set_fd(ssl, fd)
  libssl.SSL_set_tlsext_host_name(ssl, host)

  local ret = libssl.SSL_connect(ssl)
  if ret ~= 1 then
    local errmsg = ssl_err_string()
    libssl.SSL_free(ssl)
    return nil, 'SSL_connect failed: ' .. errmsg
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
  local fd = self.tcp:fileno()
  return fd
end

function TlsConn:close()
  if self.ssl ~= nil then
    libssl.SSL_free(self.ssl)
    self.ssl = nil
  end
  pcall(function() self.tcp:close() end)
end

return M
