-- lua/suffuse/tls.lua
-- TLS via LuaJIT FFI → OpenSSL using memory BIOs.
--
-- Uses BIO pairs to decouple OpenSSL from the file descriptor entirely:
--   app_bio  ← we read plaintext from here after SSL_read
--   net_bio  ← we feed ciphertext into here from libuv, and drain it to send
--
-- This means all I/O goes through libuv's tcp:read_start() / tcp:write(),
-- which is the correct way to integrate with libuv's event loop.
-- We never touch the fd directly, so there's no conflict with libuv.
--
-- The TLS handshake runs asynchronously:
--   1. ssl:connect() is called; it generates ClientHello into net_bio
--   2. We drain net_bio → send via tcp:write()
--   3. libuv calls read_start callback with ServerHello data
--   4. We feed data into net_bio, call ssl:connect() again (loop)
--   5. Once ssl:connect() returns 1 the handshake is complete
--   6. We switch into data mode: ssl:write() / ssl:read() + drain/feed loop

if not jit then
  return { available = false }
end

local ffi = require('ffi')

ffi.cdef[[
  /* BIO */
  typedef struct bio_st BIO;
  typedef struct bio_method_st BIO_METHOD;
  const BIO_METHOD *BIO_s_mem(void);
  BIO  *BIO_new(const BIO_METHOD *type);
  int   BIO_new_bio_pair(BIO **bio1, size_t writebuf1, BIO **bio2, size_t writebuf2);
  int   BIO_read(BIO *b, void *data, int len);
  int   BIO_write(BIO *b, const void *data, int len);
  int   BIO_ctrl(BIO *bp, int cmd, long larg, void *parg);
  void  BIO_free(BIO *a);
  void  BIO_free_all(BIO *a);

  /* SSL */
  int      OPENSSL_init_ssl(uint64_t opts, const void *settings);
  typedef struct ssl_ctx_st SSL_CTX;
  SSL_CTX *SSL_CTX_new(const void *method);
  void     SSL_CTX_free(SSL_CTX *ctx);
  void     SSL_CTX_set_verify(SSL_CTX *ctx, int mode, void *cb);
  typedef struct ssl_st SSL;
  SSL     *SSL_new(SSL_CTX *ctx);
  void     SSL_free(SSL *ssl);
  void     SSL_set_bio(SSL *ssl, BIO *rbio, BIO *wbio);
  void     SSL_set_connect_state(SSL *ssl);
  int      SSL_do_handshake(SSL *ssl);
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

local SSL_ERROR_WANT_READ  = 2
local SSL_ERROR_WANT_WRITE = 3
local SSL_ERROR_ZERO_RETURN = 6
local SSL_VERIFY_NONE = 0
local BIO_CTRL_PENDING = 10  -- BIO_pending()

local function ssl_err_string()
  local msgs = {}
  while true do
    local code = libssl.ERR_get_error()
    if code == 0 then break end
    local buf = ffi.new('char[256]')
    libssl.ERR_error_string_n(code, buf, 256)
    table.insert(msgs, ffi.string(buf))
  end
  return #msgs > 0 and table.concat(msgs, '; ') or 'unknown SSL error'
end

local _ctx
local function get_ctx()
  if _ctx then return _ctx end
  libssl.OPENSSL_init_ssl(0, nil)
  local ctx = libssl.SSL_CTX_new(libssl.TLS_client_method())
  if ctx == nil then error('SSL_CTX_new: ' .. ssl_err_string()) end
  libssl.SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
  _ctx = ctx
  return ctx
end

-- Drain ciphertext from net_bio and send via tcp
local function flush_net_bio(ssl_conn)
  local pending = libssl.BIO_ctrl(ssl_conn.net_bio, BIO_CTRL_PENDING, 0, nil)
  while pending > 0 do
    local buf = ffi.new('char[?]', pending)
    local n   = libssl.BIO_read(ssl_conn.net_bio, buf, pending)
    if n <= 0 then break end
    ssl_conn.tcp:write(ffi.string(buf, n))
    pending = libssl.BIO_ctrl(ssl_conn.net_bio, BIO_CTRL_PENDING, 0, nil)
  end
end

-- ── TlsConn ───────────────────────────────────────────────────────────────────

---@class TlsConn
local TlsConn = {}
TlsConn.__index = TlsConn

--- Wrap a connected vim.uv TCP handle with TLS using memory BIOs.
--- The handshake is asynchronous — on_ready(conn, err) is called when done.
---@param tcp      uv_tcp_t
---@param host     string
---@param on_ready fun(conn: table|nil, err: string|nil)
function M.wrap(tcp, host, on_ready)
  vim.schedule(function() vim.notify('[suffuse] tls.wrap called host=' .. tostring(host), vim.log.levels.WARN) end)
  local ctx = get_ctx()
  local ssl = libssl.SSL_new(ctx)
  if ssl == nil then
    on_ready(nil, 'SSL_new: ' .. ssl_err_string())
    return
  end

  -- Create a BIO pair: ssl_bio ↔ net_bio
  -- OpenSSL reads/writes ssl_bio; we read/write net_bio
  local ssl_bio_p = ffi.new('BIO*[1]')
  local net_bio_p = ffi.new('BIO*[1]')
  local rc = libssl.BIO_new_bio_pair(ssl_bio_p, 0, net_bio_p, 0)
  if rc ~= 1 then
    libssl.SSL_free(ssl)
    on_ready(nil, 'BIO_new_bio_pair: ' .. ssl_err_string())
    return
  end

  local ssl_bio = ssl_bio_p[0]
  local net_bio = net_bio_p[0]

  -- SSL takes ownership of ssl_bio (both read and write sides)
  libssl.SSL_set_bio(ssl, ssl_bio, ssl_bio)
  libssl.SSL_set_connect_state(ssl)
  -- SNI: SSL_CTRL_SET_TLSEXT_HOSTNAME=55, TLSEXT_NAMETYPE_host_name=0
  libssl.SSL_ctrl(ssl, 55, 0, ffi.cast('void *', ffi.cast('const char *', host)))

  local conn = setmetatable({
    ssl     = ssl,
    net_bio = net_bio,
    tcp     = tcp,
    _ready  = false,
    _rbuf   = '',  -- plaintext read buffer
  }, TlsConn)

  -- Start the async handshake
  conn:_do_handshake(on_ready)
end

function TlsConn:_do_handshake(on_ready)
  local ret = libssl.SSL_do_handshake(self.ssl)
  flush_net_bio(self)
  vim.schedule(function() vim.notify(string.format('[suffuse] handshake ret=%d', ret), vim.log.levels.WARN) end)

  if ret == 1 then
    self._ready = true
    self.tcp:read_stop()
    vim.schedule(function() on_ready(self, nil) end)
    return
  end

  local ssl_err = libssl.SSL_get_error(self.ssl, ret)
  vim.schedule(function() vim.notify(string.format('[suffuse] handshake ssl_err=%d', ssl_err), vim.log.levels.WARN) end)
  if ssl_err == SSL_ERROR_WANT_READ or ssl_err == SSL_ERROR_WANT_WRITE then
    self.tcp:read_start(function(err, data)
      if err or not data then
        self.tcp:read_stop()
        vim.schedule(function() on_ready(nil, 'handshake: ' .. (err or 'EOF')) end)
        return
      end
      vim.schedule(function() vim.notify(string.format('[suffuse] handshake got %d bytes', #data), vim.log.levels.WARN) end)
      libssl.BIO_write(self.net_bio, data, #data)
      self:_do_handshake(on_ready)
    end)
    return
  end

  local errmsg = string.format('SSL_do_handshake: ssl_err=%d %s', ssl_err, ssl_err_string())
  vim.schedule(function() on_ready(nil, errmsg) end)
end

--- Start reading plaintext from the TLS stream.
--- Calls on_data(data) for each chunk, on_close(err) when connection ends.
---@param on_data  fun(data: string)
---@param on_close fun(err: string|nil)
function TlsConn:read_start(on_data, on_close)
  -- Drain any plaintext already buffered in SSL from the handshake
  vim.schedule(function() self:_drain_ssl(on_data) end)

  self.tcp:read_start(function(err, data)
    if err or not data then
      self.tcp:read_stop()
      vim.schedule(function() on_close(err) end)
      return
    end
    libssl.BIO_write(self.net_bio, data, #data)
    vim.schedule(function() self:_drain_ssl(on_data) end)
  end)
end

function TlsConn:_drain_ssl(on_data)
  local buf = ffi.new('char[16384]')
  while true do
    local n = libssl.SSL_read(self.ssl, buf, 16384)
    if n > 0 then
      on_data(ffi.string(buf, n))
    else
      local ssl_err = libssl.SSL_get_error(self.ssl, n)
      if ssl_err == SSL_ERROR_WANT_READ or ssl_err == SSL_ERROR_WANT_WRITE then
        break  -- no more data right now
      end
      if ssl_err == SSL_ERROR_ZERO_RETURN then
        break  -- clean EOF, on_close will fire from tcp read_start
      end
      break
    end
  end
end

function TlsConn:read_stop()
  self.tcp:read_stop()
end

---@param data string
---@return boolean ok, string|nil err
function TlsConn:write(data)
  local ret = libssl.SSL_write(self.ssl, data, #data)
  if ret <= 0 then
    return false, 'SSL_write: ' .. ssl_err_string()
  end
  flush_net_bio(self)
  return true, nil
end

--- Synchronous read for short-lived RPC connections (paste/status/copy response).
--- Only valid after handshake. Reads one SSL record worth of data.
---@param n integer
---@return string|nil data, string|nil err
function TlsConn:read_sync(n)
  local buf = ffi.new('char[?]', n)
  -- Try immediately first (data may already be buffered)
  local ret = libssl.SSL_read(self.ssl, buf, n)
  if ret > 0 then return ffi.string(buf, ret), nil end

  local ssl_err = libssl.SSL_get_error(self.ssl, ret)
  if ssl_err ~= SSL_ERROR_WANT_READ and ssl_err ~= SSL_ERROR_WANT_WRITE then
    return nil, 'SSL_read: ' .. ssl_err_string()
  end

  -- Need to do a synchronous (blocking) read from the tcp handle
  -- For RPC connections we can use a coroutine-style wait via uv
  local result, result_err
  local done = false
  self.tcp:read_start(function(err, data)
    if done then return end
    if err or not data then
      result_err = err or 'EOF'
      done = true
      self.tcp:read_stop()
      return
    end
    libssl.BIO_write(self.net_bio, data, #data)
    local r = libssl.SSL_read(self.ssl, buf, n)
    if r > 0 then
      result = ffi.string(buf, r)
      done   = true
      self.tcp:read_stop()
    end
  end)

  -- Spin the event loop until done
  -- This is safe because we're in a vim.schedule callback
  local deadline = vim.uv.now() + 5000
  while not done do
    vim.uv.run('nowait')
    if vim.uv.now() > deadline then
      self.tcp:read_stop()
      return nil, 'read_sync timeout'
    end
  end

  return result, result_err
end

function TlsConn:close()
  if self.ssl then
    libssl.SSL_free(self.ssl)  -- also frees ssl_bio
    self.ssl = nil
  end
  if self.net_bio then
    libssl.BIO_free(self.net_bio)
    self.net_bio = nil
  end
  pcall(function() self.tcp:close() end)
end

return M
