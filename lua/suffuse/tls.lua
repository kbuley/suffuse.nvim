-- lua/suffuse/tls.lua
-- TLS via LuaJIT FFI → OpenSSL.
--
-- Wraps a vim.uv TCP handle with SSL so the rest of the client code sees the
-- same read/write interface as a plain TCP handle.
--
-- The server uses a self-signed certificate derived from the shared token.
-- We skip certificate chain verification (SSL_CTX_set_verify NONE) because
-- we cannot reproduce the HKDF key derivation in Lua. Traffic is still
-- encrypted; the token in the Authorization header provides authentication.
--
-- Only available when Neovim is built with LuaJIT (jit ~= nil).
-- Falls back gracefully: if FFI is unavailable, returns nil from new() and
-- the client falls back to plain HTTP (unencrypted).

if not jit then
  return { available = false }
end

local ffi = require('ffi')

-- ── OpenSSL FFI declarations ────────────────────────────────────────────────

ffi.cdef[[
  /* Library init (OpenSSL 1.1+) */
  int OPENSSL_init_ssl(uint64_t opts, const void *settings);

  /* SSL_CTX */
  typedef struct ssl_ctx_st SSL_CTX;
  SSL_CTX *SSL_CTX_new(const void *method);
  void     SSL_CTX_free(SSL_CTX *ctx);
  void     SSL_CTX_set_verify(SSL_CTX *ctx, int mode, void *cb);

  /* SSL */
  typedef struct ssl_st SSL;
  SSL *SSL_new(SSL_CTX *ctx);
  void SSL_free(SSL *ssl);
  int  SSL_set_fd(SSL *ssl, int fd);
  int  SSL_connect(SSL *ssl);
  int  SSL_read(SSL *ssl, void *buf, int num);
  int  SSL_write(SSL *ssl, const void *buf, int num);
  int  SSL_get_error(SSL *ssl, int ret);
  void SSL_set_tlsext_host_name(SSL *ssl, const char *name);

  /* Methods */
  const void *TLS_client_method(void);

  /* ERR */
  unsigned long ERR_get_error(void);
  void ERR_error_string_n(unsigned long e, char *buf, size_t len);

  /* fd from libuv handle — platform-specific, done via uv_fileno */
  int uv_fileno(const void *handle, int *fd);
]]

local ssl_loaded, libssl = pcall(ffi.load, 'ssl')
if not ssl_loaded then
  ssl_loaded, libssl = pcall(ffi.load, 'libssl.so.3')
end
if not ssl_loaded then
  ssl_loaded, libssl = pcall(ffi.load, 'libssl.so.1.1')
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

-- Shared client SSL_CTX — created once, reused for all connections.
local _ctx

local function get_ctx()
  if _ctx then return _ctx end
  libssl.OPENSSL_init_ssl(0, nil)
  local ctx = libssl.SSL_CTX_new(libssl.TLS_client_method())
  if ctx == nil then
    error('SSL_CTX_new failed: ' .. ssl_err_string())
  end
  -- Skip cert chain verification — server uses a self-signed cert.
  -- The Bearer token in the Authorization header provides authentication.
  libssl.SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
  _ctx = ctx
  return ctx
end

-- ── TLS connection object ───────────────────────────────────────────────────

---@class TlsConn
---@field ssl   cdata   SSL*
---@field tcp   uv_tcp_t
local TlsConn = {}
TlsConn.__index = TlsConn

--- Perform the TLS handshake over an already-connected vim.uv TCP handle.
--- This is synchronous (blocking the event loop briefly) which is acceptable
--- for a one-time handshake during connection setup.
---@param tcp  uv_tcp_t  connected TCP handle
---@param host string    server hostname for SNI
---@return TlsConn|nil, string|nil  conn, errmsg
function M.wrap(tcp, host)
  local ctx = get_ctx()
  local ssl = libssl.SSL_new(ctx)
  if ssl == nil then
    return nil, 'SSL_new failed: ' .. ssl_err_string()
  end

  -- Get the raw fd from the libuv handle.
  -- vim.uv TCP handles expose :getfd() in recent Neovim versions.
  local fd = tcp:getfd()
  if not fd or fd < 0 then
    libssl.SSL_free(ssl)
    return nil, 'could not get fd from TCP handle'
  end

  libssl.SSL_set_fd(ssl, fd)
  libssl.SSL_set_tlsext_host_name(ssl, host)

  local ret = libssl.SSL_connect(ssl)
  if ret ~= 1 then
    local err = ssl_err_string()
    libssl.SSL_free(ssl)
    return nil, 'SSL_connect failed: ' .. err
  end

  return setmetatable({ ssl = ssl, tcp = tcp }, TlsConn), nil
end

--- Write data through the TLS layer.
---@param data string
---@return boolean ok, string|nil errmsg
function TlsConn:write(data)
  local ret = libssl.SSL_write(self.ssl, data, #data)
  if ret <= 0 then
    return false, 'SSL_write failed: ' .. ssl_err_string()
  end
  return true, nil
end

--- Read up to n bytes through the TLS layer (blocking).
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

function TlsConn:close()
  if self.ssl ~= nil then
    libssl.SSL_free(self.ssl)
    self.ssl = nil
  end
  pcall(function() self.tcp:close() end)
end

return M
