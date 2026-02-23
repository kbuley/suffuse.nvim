-- lua/suffuse/clipboard.lua
-- Detects which clipboard tier is available and registers vim.g.clipboard.
--
-- Tiers (in auto-detect order):
--   daemon  — suffuse daemon reachable via HTTP on localhost; copy/paste via
--             direct Lua HTTP requests (no shell, no TLS needed for localhost)
--   binary  — `suffuse` binary on PATH; shell out to `suffuse copy` / `suffuse paste`
--   plugin  — direct TLS/HTTP from this plugin (current in-progress impl)
--   off     — do not touch vim.g.clipboard
--
-- Regardless of tier, the watch stream (when connected) pushes remote clipboard
-- updates directly into the configured paste registers so <C-r>+ works without
-- an explicit :SuffusePaste.

local M = {}

-- ── Tier detection ────────────────────────────────────────────────────────────

--- Check if the suffuse daemon is reachable on localhost via a synchronous
--- TCP connect attempt. Uses vim.uv in a blocking loop so it can be called
--- at setup time before the event loop is running fully.
---@param port integer
---@return boolean
local function daemon_reachable(port)
  local reachable = false
  local done      = false
  local tcp       = vim.uv.new_tcp()
  tcp:connect('127.0.0.1', port, function(err)
    tcp:close()
    reachable = not err
    done      = true
  end)
  -- Spin briefly — this resolves in <1ms on localhost
  local deadline = vim.uv.now() + 500
  while not done and vim.uv.now() < deadline do
    vim.uv.run('nowait')
  end
  return reachable
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
    return daemon_reachable(cfg.port) and 'daemon' or 'off'
  end

  if mode == 'binary' then
    return binary_path() and 'binary' or 'off'
  end

  if mode == 'plugin' then
    return 'plugin'
  end

  -- auto: daemon → binary → plugin
  if daemon_reachable(cfg.port) then return 'daemon' end
  if binary_path()              then return 'binary' end
  return 'plugin'
end

-- ── Provider builders ─────────────────────────────────────────────────────────

--- Build a g:clipboard table that shells out to the suffuse binary.
---@param cfg table
---@return table
local function binary_provider(cfg)
  local bin   = binary_path() or 'suffuse'
  local flags = {}
  if cfg.host  and cfg.host  ~= '' then
    table.insert(flags, '--upstream=' .. cfg.host .. ':' .. cfg.port)
  end
  if cfg.token and cfg.token ~= '' then
    table.insert(flags, '--token=' .. cfg.token)
  end

  local function cmd(subcmd)
    local t = { bin, subcmd }
    for _, f in ipairs(flags) do table.insert(t, f) end
    return t
  end

  return {
    name          = 'suffuse-binary',
    copy          = { ['+'] = cmd('copy'), ['*'] = cmd('copy') },
    paste         = { ['+'] = cmd('paste'), ['*'] = cmd('paste') },
    cache_enabled = 0,
  }
end

--- Build a g:clipboard table backed by the Lua client.
--- Copy calls client:send_text(); paste reads the register the watch stream
--- already populated (synchronous, no round-trip needed).
---@param get_client fun(): table|nil
---@return table
local function plugin_provider(get_client)
  local function copy_fn(lines, _regtype)
    local client = get_client()
    if client and client:get_state() == 'connected' then
      client:send_text(table.concat(lines, '\n'))
    end
  end

  local function paste_fn()
    -- The watch stream writes to '+' directly; return its current value.
    -- For an explicit :SuffusePaste the user can still call that command.
    local lines = vim.fn.getreg('+', 1, true)
    if type(lines) == 'string' then lines = vim.split(lines, '\n', { plain = true }) end
    return lines, 'V'
  end

  return {
    name          = 'suffuse-plugin',
    copy          = { ['+'] = copy_fn, ['*'] = copy_fn },
    paste         = { ['+'] = paste_fn, ['*'] = paste_fn },
    cache_enabled = 0,
  }
end

--- Build a g:clipboard table that talks to the local daemon via HTTP (no TLS).
--- The daemon listens on localhost so plain HTTP is fine.
---@param cfg        table
---@param get_client fun(): table|nil  fallback for paste register reads
---@return table
local function daemon_provider(cfg, get_client)
  -- For copy: POST to local daemon synchronously using vim.system (Neovim 0.10+)
  -- or fall back to plugin_provider copy for older Neovim.
  -- For paste: same as plugin — read the register the watch stream populated.

  if vim.system then
    local bin   = binary_path()
    local flags = { '--upstream=localhost:' .. cfg.port }
    if cfg.token and cfg.token ~= '' then
      table.insert(flags, '--token=' .. cfg.token)
    end

    local function copy_fn(lines, _regtype)
      local args = vim.list_extend({ bin or 'suffuse', 'copy' }, flags)
      vim.system(args, { stdin = table.concat(lines, '\n') })
    end

    local function paste_fn()
      local lines = vim.fn.getreg('+', 1, true)
      if type(lines) == 'string' then lines = vim.split(lines, '\n', { plain = true }) end
      return lines, 'V'
    end

    return {
      name          = 'suffuse-daemon',
      copy          = { ['+'] = copy_fn, ['*'] = copy_fn },
      paste         = { ['+'] = paste_fn, ['*'] = paste_fn },
      cache_enabled = 0,
    }
  end

  -- Neovim < 0.10: fall back to plugin provider
  return plugin_provider(get_client)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Detect the best available tier and register vim.g.clipboard.
--- Should be called from setup() before VimEnter.
---@param cfg        table
---@param get_client fun(): table|nil
---@return string  the tier that was selected
function M.register(cfg, get_client)
  if cfg.clipboard_mode == 'off' then return 'off' end

  local tier = M.detect(cfg)

  local provider
  if tier == 'daemon' then
    provider = daemon_provider(cfg, get_client)
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
