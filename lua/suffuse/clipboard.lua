-- lua/suffuse/clipboard.lua
-- Detects which clipboard tier is available and registers vim.g.clipboard.
--
-- Tiers (in auto-detect order):
--   daemon  — suffuse daemon running locally (IPC socket present);
--             copy/paste via `suffuse copy` / `suffuse paste` which use the
--             Unix socket automatically. Synchronous via vim.system.
--   binary  — `suffuse` binary on PATH but no local daemon;
--             shell out with explicit --upstream host:port flags.
--   plugin  — direct TLS/HTTP from this plugin (in-progress).
--   off     — do not touch vim.g.clipboard.

local M = {}

-- ── Tier detection ────────────────────────────────────────────────────────────

--- Check if the suffuse daemon is running by probing the IPC socket.
--- Mirrors ipc.IsRunning() from the Go package.
---@return boolean
local function daemon_running()
  local path = os.getenv('SUFFUSE_SOCKET')
  if not path or path == '' then
    path = (os.getenv('TMPDIR') or '/tmp') .. '/suffuse.sock'
  end
  if vim.fn.filereadable(path) == 0 then return false end
  local ok   = false
  local done = false
  local pipe = vim.uv.new_pipe(false)
  pipe:connect(path, function(err)
    ok   = not err
    done = true
    pcall(function() pipe:close() end)
  end)
  local deadline = vim.uv.now() + 200
  while not done and vim.uv.now() < deadline do
    vim.uv.run('nowait')
  end
  if not done then pcall(function() pipe:close() end) end
  return ok
end

--- Check if the suffuse binary exists on PATH.
---@return string|nil  full path or nil
local function binary_path()
  local path = vim.fn.exepath('suffuse')
  return path ~= '' and path or nil
end

--- Resolve which tier to use given the config.
---@param cfg table
---@return string  'daemon'|'binary'|'plugin'|'off'
function M.detect(cfg)
  local mode = cfg.clipboard_mode or 'auto'
  if mode == 'off' then return 'off' end

  if mode == 'daemon' then
    return daemon_running() and 'daemon' or 'off'
  end

  if mode == 'binary' then
    return binary_path() and 'binary' or 'off'
  end

  if mode == 'plugin' then
    return 'plugin'
  end

  -- auto: local daemon (IPC) → binary → plugin
  if daemon_running() then return 'daemon' end
  if binary_path()    then return 'binary' end
  return 'plugin'
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Run `suffuse paste` synchronously and return lines, regtype.
---@param bin string
---@return string[], string
local function run_paste(bin)
  local result = vim.system({ bin, 'paste' }, { text = true }):wait()
  if result.code ~= 0 or not result.stdout or result.stdout == '' then
    return { '' }, 'c'
  end
  local text = result.stdout:gsub('\n$', '')
  return vim.split(text, '\n', { plain = true }), 'V'
end

-- ── Provider builders ─────────────────────────────────────────────────────────

--- Build a g:clipboard table that uses the local IPC daemon via the binary.
--- No host/port needed — the binary finds the socket itself.
---@param get_client fun(): table|nil
---@return table
local function daemon_provider(get_client)
  local bin = binary_path()

  if bin and vim.system then
    return {
      name          = 'suffuse-daemon',
      copy  = {
        ['+'] = function(lines, _) vim.system({ bin, 'copy' }, { stdin = table.concat(lines, '\n') }) end,
        ['*'] = function(lines, _) vim.system({ bin, 'copy' }, { stdin = table.concat(lines, '\n') }) end,
      },
      paste = {
        ['+'] = function() return run_paste(bin) end,
        ['*'] = function() return run_paste(bin) end,
      },
      cache_enabled = 0,
    }
  end

  -- No binary or Neovim < 0.10: fall through to plugin provider
  return require('suffuse.clipboard')._plugin_provider(get_client)
end

--- Build a g:clipboard table that shells out to the suffuse binary with
--- explicit upstream flags (no local daemon).
---@param cfg table
---@return table
local function binary_provider(cfg)
  local bin   = binary_path() or 'suffuse'
  local flags = {}
  if cfg.host and cfg.host ~= '' then
    table.insert(flags, '--upstream=' .. cfg.host .. ':' .. cfg.port)
  end
  if cfg.token and cfg.token ~= '' then
    table.insert(flags, '--token=' .. cfg.token)
  end

  local function copy_cmd(lines)
    local args = { bin, 'copy' }
    for _, f in ipairs(flags) do table.insert(args, f) end
    vim.system(args, { stdin = table.concat(lines, '\n') })
  end

  local function paste_cmd()
    local args = { bin, 'paste' }
    for _, f in ipairs(flags) do table.insert(args, f) end
    if not vim.system then return { '' }, 'c' end
    local result = vim.system(args, { text = true }):wait()
    if result.code ~= 0 or not result.stdout or result.stdout == '' then
      return { '' }, 'c'
    end
    local text = result.stdout:gsub('\n$', '')
    return vim.split(text, '\n', { plain = true }), 'V'
  end

  return {
    name          = 'suffuse-binary',
    copy          = { ['+'] = function(lines, _) copy_cmd(lines) end,
                      ['*'] = function(lines, _) copy_cmd(lines) end },
    paste         = { ['+'] = paste_cmd, ['*'] = paste_cmd },
    cache_enabled = 0,
  }
end

--- Build a g:clipboard table backed by the Lua client.
--- Copy calls client:send_text(); paste reads whatever the watch stream
--- last deposited in '+'. Exposed as M._plugin_provider for fallback use.
---@param get_client fun(): table|nil
---@return table
local function plugin_provider(get_client)
  local _sending = false

  local function copy_fn(lines, _)
    if _sending then return end
    local client = get_client()
    if client and client:get_state() == 'connected' then
      client:send_text(table.concat(lines, '\n'))
    end
  end

  local function paste_fn()
    _sending = true
    local lines = vim.fn.getreg('+', 1, true)
    if type(lines) == 'string' then
      lines = vim.split(lines, '\n', { plain = true })
    end
    _sending = false
    return lines, 'V'
  end

  return {
    name          = 'suffuse-plugin',
    copy          = { ['+'] = copy_fn, ['*'] = copy_fn },
    paste         = { ['+'] = paste_fn, ['*'] = paste_fn },
    cache_enabled = 0,
  }
end

-- Expose for fallback use from daemon_provider
M._plugin_provider = plugin_provider

-- ── Public API ────────────────────────────────────────────────────────────────

--- Detect the best available tier and register vim.g.clipboard.
---@param cfg        table
---@param get_client fun(): table|nil
---@return string  the tier that was selected
function M.register(cfg, get_client)
  if cfg.clipboard_mode == 'off' then return 'off' end

  local tier = M.detect(cfg)

  local provider
  if tier == 'daemon' then
    provider = daemon_provider(get_client)
  elseif tier == 'binary' then
    provider = binary_provider(cfg)
  elseif tier == 'plugin' then
    provider = plugin_provider(get_client)
  else
    return 'off'
  end

  vim.g.clipboard = provider
  return tier
end

return M
