-- lua/suffuse/protocol.lua
-- HTTP/1.1 request builders and response parsers for the suffuse grpc-gateway.
--
-- Endpoints:
--   POST /v1/copy     { clipboard, source, items:[{mime,data}] }
--   POST /v1/paste    { clipboard, accepts:[mime] }
--   GET  /v1/watch?clipboard=default&accepts=text%2Fplain  (chunked stream)
--   GET  /v1/status
--
-- The grpc-gateway encodes protobuf `bytes` fields as standard base64.
-- Authorization: Bearer <token> header is sent when token is non-empty.

local M = {}

-- ── Base64 ──────────────────────────────────────────────────────────────────

local function b64enc(s)
  if vim.base64 then return vim.base64.encode(s) end
  local alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local result, pad = {}, (3 - #s % 3) % 3
  s = s .. string.rep('\0', pad)
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i+2)
    local n = a*0x10000 + b*0x100 + c
    result[#result+1] = alpha:sub(math.floor(n/0x40000)+1, math.floor(n/0x40000)+1)
    result[#result+1] = alpha:sub(math.floor(n/0x1000)%64+1, math.floor(n/0x1000)%64+1)
    result[#result+1] = alpha:sub(math.floor(n/0x40)%64+1, math.floor(n/0x40)%64+1)
    result[#result+1] = alpha:sub(n%64+1, n%64+1)
  end
  local e = table.concat(result)
  return e:sub(1, #e-pad) .. string.rep('=', pad)
end

local function b64dec(s)
  if vim.base64 then return vim.base64.decode(s) end
  local alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local lut = {}
  for i = 1, #alpha do lut[alpha:sub(i,i)] = i-1 end
  s = s:gsub('[^'..alpha..'=]', '')
  local result = {}
  for i = 1, #s, 4 do
    local a = lut[s:sub(i,i)] or 0
    local b = lut[s:sub(i+1,i+1)] or 0
    local c = lut[s:sub(i+2,i+2)] or 0
    local d = lut[s:sub(i+3,i+3)] or 0
    local n = a*0x40000 + b*0x1000 + c*0x40 + d
    result[#result+1] = string.char(math.floor(n/0x10000))
    if s:sub(i+2,i+2) ~= '=' then result[#result+1] = string.char(math.floor(n/0x100)%256) end
    if s:sub(i+3,i+3) ~= '=' then result[#result+1] = string.char(n%256) end
  end
  return table.concat(result)
end

M.b64enc = b64enc
M.b64dec = b64dec

-- ── HTTP request builders ────────────────────────────────────────────────────

---@param method  string  'GET' or 'POST'
---@param path    string  e.g. '/v1/copy'
---@param host    string
---@param token   string  may be empty
---@param body    string|nil  JSON body for POST
---@return string  raw HTTP/1.1 request
local function build_request(method, path, host, token, body)
  local lines = {
    method .. ' ' .. path .. ' HTTP/1.1',
    'Host: ' .. host,
    'Connection: keep-alive',
    'Accept: application/json',
  }
  if token and token ~= '' then
    lines[#lines+1] = 'Authorization: Bearer ' .. token
  end
  if body then
    lines[#lines+1] = 'Content-Type: application/json'
    lines[#lines+1] = 'Content-Length: ' .. #body
  end
  lines[#lines+1] = ''
  lines[#lines+1] = body or ''
  return table.concat(lines, '\r\n')
end

--- HTTP request for POST /v1/copy
---@param host   string
---@param token  string
---@param text   string
---@param source string
---@return string
function M.copy_request(host, token, text, source)
  local body = vim.json.encode({
    clipboard = 'default',
    source    = source,
    items     = { { mime = 'text/plain', data = b64enc(text) } },
  })
  return build_request('POST', '/v1/copy', host, token, body)
end

--- HTTP request for POST /v1/paste
---@param host  string
---@param token string
---@return string
function M.paste_request(host, token)
  local body = vim.json.encode({ clipboard = 'default', accepts = { 'text/plain' } })
  return build_request('POST', '/v1/paste', host, token, body)
end

--- HTTP request for GET /v1/watch (opens a streaming response)
---@param host   string
---@param token  string
---@param source string
---@return string
function M.watch_request(host, token, source)
  local path = '/v1/watch?clipboard=default&accepts=text%2Fplain'
  local req  = build_request('GET', path, host, token, nil)
  -- inject x-suffuse-source before the terminal CRLF so the server can
  -- identify this peer separately from the copy/paste connections
  if source and source ~= '' then
    req = req:gsub('(\r\n\r\n)', '\r\nx-suffuse-source: ' .. source .. '%1', 1)
  end
  return req
end

--- HTTP request for GET /v1/status
---@param host  string
---@param token string
---@return string
function M.status_request(host, token)
  return build_request('GET', '/v1/status', host, token, nil)
end

-- ── Response parsing ─────────────────────────────────────────────────────────

--- Parse HTTP status line and headers from a response buffer.
--- Returns status code, headers table, and remaining body bytes.
---@param buf string
---@return integer|nil status, table headers, string rest
function M.parse_headers(buf)
  local header_end = buf:find('\r\n\r\n', 1, true)
  if not header_end then return nil, {}, buf end

  local header_block = buf:sub(1, header_end - 1)
  local rest         = buf:sub(header_end + 4)

  local status_line  = header_block:match('^(.-)\r\n')
  local status_code  = tonumber(status_line and status_line:match('HTTP/%S+ (%d+)'))

  local headers = {}
  for k, v in header_block:gmatch('\r\n([^:]+):%s*(.-)') do
    headers[k:lower()] = v
  end

  return status_code, headers, rest
end

--- Decode a chunked transfer-encoding body incrementally.
--- Returns complete JSON objects found in buf, and the remaining partial buffer.
---@param buf string  accumulated raw chunked data
---@return string[] lines, string remaining
function M.decode_chunks(buf)
  local lines = {}
  while true do
    -- Each chunk: <hex-size>\r\n<data>\r\n
    local size_end = buf:find('\r\n', 1, true)
    if not size_end then break end

    local size_hex = buf:sub(1, size_end - 1):gsub('%s', '')
    local size     = tonumber(size_hex, 16)
    if not size then break end
    if size == 0 then
      -- Terminal chunk
      buf = ''
      break
    end

    local data_start = size_end + 2
    local data_end   = data_start + size - 1
    if #buf < data_end + 2 then break end  -- incomplete chunk, wait for more

    local chunk = buf:sub(data_start, data_end)
    buf         = buf:sub(data_end + 3)    -- skip trailing \r\n

    -- A chunk may contain multiple newline-delimited JSON objects
    -- (grpc-gateway wraps each WatchResponse in {"result":{...}}\n)
    for line in (chunk .. '\n'):gmatch('(.-)\n') do
      line = line:gsub('^%s+', ''):gsub('%s+$', '')
      if line ~= '' then
        lines[#lines+1] = line
      end
    end
  end
  return lines, buf
end

--- Extract plain text from a WatchResponse or PasteResponse items list.
---@param items table[]
---@return string|nil
function M.text_from_items(items)
  if type(items) ~= 'table' then return nil end
  for _, item in ipairs(items) do
    if item.mime == 'text/plain' and type(item.data) == 'string' then
      return b64dec(item.data)
    end
  end
  return nil
end

--- Unwrap a grpc-gateway streaming envelope.
--- The gateway wraps each WatchResponse as {"result":{...}} or {"error":{...}}.
---@param line string  raw JSON line
---@return table|nil msg, string|nil err
function M.unwrap_watch(line)
  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= 'table' then
    return nil, 'json decode error: ' .. tostring(obj)
  end
  if obj.result then return obj.result, nil end
  if obj.error  then return nil, 'server error: ' .. vim.inspect(obj.error) end
  -- Some gateway versions send the object directly
  if obj.items  then return obj, nil end
  return nil, 'unexpected envelope: ' .. line
end

return M
