-- lua/suffuse/clipboard.lua
-- Detects which clipboard tier is available and registers vim.g.clipboard.
--
-- Tiers (in auto-detect order):
--   daemon  — suffuse IPC socket present; binary uses it automatically, no flags needed
--   binary  — `suffuse` on PATH, no local daemon; probe host order in the binary
--   plugin  — direct TLS/HTTP from this plugin (in-progress)
--   off     — do not touch vim.g.clipboard

local M = {}

-- ── Tier detection ────────────────────────────────────────────────────────────

local function daemon_running()
  local path = os.getenv('SUFFUSE_SOCKET')
  if not path or path == '' then
    path = (os.getenv('TMPDIR') or '/tmp') .. '/suffuse.sock'
  end
  if vim.fn.filereadable(path) == 0 then return false end
  local ok, done = false, false
  local pipe = vim.uv.new_pipe(false)
  pipe:connect(path, function(err)
    ok, done = not err, true
    pcall(function() pipe:close() end)
  end)
  local deadline = vim.uv.now() + 200
  while not done and vim.uv.now() < deadline do vim.uv.run('nowait') end
  if not done then pcall(function() pipe:close() end) end
  return ok
end

local function binary_path(cfg)
  if cfg and cfg.bin and cfg.bin ~= '' then
    return cfg.bin
  end
  local p = vim.fn.exepath('suffuse')
  return p ~= '' and p or nil
end

function M.detect(cfg)
  local mode = cfg.clipboard_mode or 'auto'
  if mode == 'off'    then return 'off' end
  if mode == 'daemon' then return daemon_running() and 'daemon' or 'off' end
  if mode == 'binary' then return binary_path(cfg) and 'binary' or 'off' end
  if mode == 'plugin' then return 'plugin' end
  -- auto
  if daemon_running()    then return 'daemon' end
  if binary_path(cfg)    then return 'binary' end
  return 'plugin'
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build argv for `suffuse copy|paste`.
-- explicit contains only the keys the user explicitly set in their plugin config.
-- Only those keys are forwarded as CLI flags; everything else the binary resolves
-- itself from its own config file, env vars, and built-in defaults.
local function build_args(bin, sub, cfg, explicit)
  local args = { bin, sub }
  explicit = explicit or {}
  if explicit.host then
    args[#args+1] = '--host=' .. cfg.host
  end
  if explicit.port then
    args[#args+1] = '--port=' .. cfg.port
  end
  if explicit.token then
    args[#args+1] = '--token=' .. (cfg.token or '')
  end
  return args
end

local function run_paste_cmd(bin, cfg, explicit)
  if not vim.system then return { '' }, 'c' end
  local result = vim.system(build_args(bin, 'paste', cfg, explicit), { text = true }):wait()
  if result.code ~= 0 or not result.stdout or result.stdout == '' then
    return { '' }, 'c'
  end
  local text = result.stdout
  if text:sub(-1) == '\n' then text = text:sub(1, -2) end
  return vim.split(text, '\n', { plain = true }), 'V'
end

local function run_copy_cmd(bin, cfg, explicit, lines)
  if not vim.system then return end
  vim.system(build_args(bin, 'copy', cfg, explicit), { stdin = table.concat(lines, '\n') })
end

-- ── Provider builders ─────────────────────────────────────────────────────────

-- Daemon tier: IPC socket is live; binary finds it automatically.
-- No CLI args forwarded — the binary uses the IPC socket unconditionally.
local function daemon_provider(cfg, get_client)
  local bin = binary_path(cfg)

  if bin and vim.system then
    return {
      name  = 'suffuse-daemon',
      copy  = {
        ['+'] = function(lines, _) run_copy_cmd(bin, cfg, {}, lines) end,
        ['*'] = function(lines, _) run_copy_cmd(bin, cfg, {}, lines) end,
      },
      paste = {
        ['+'] = function() return run_paste_cmd(bin, cfg, {}) end,
        ['*'] = function() return run_paste_cmd(bin, cfg, {}) end,
      },
      cache_enabled = 0,
    }
  end

  return M._plugin_provider(get_client)
end

-- Binary tier: no local daemon. Only explicitly-configured plugin options are
-- forwarded as CLI flags; everything else the binary resolves itself.
local function binary_provider(cfg, explicit)
  local bin = binary_path(cfg) or 'suffuse'

  return {
    name  = 'suffuse-binary',
    copy  = {
      ['+'] = function(lines, _) run_copy_cmd(bin, cfg, explicit, lines) end,
      ['*'] = function(lines, _) run_copy_cmd(bin, cfg, explicit, lines) end,
    },
    paste = {
      ['+'] = function() return run_paste_cmd(bin, cfg, explicit) end,
      ['*'] = function() return run_paste_cmd(bin, cfg, explicit) end,
    },
    cache_enabled = 0,
  }
end

-- Plugin tier: pure Lua via the watch-stream client.
local function plugin_provider(get_client)
  local function copy_fn(lines, _)
    local client = get_client()
    if client and client:get_state() == 'connected' then
      client:send_text(table.concat(lines, '\n'))
    end
  end

  -- Paste does a synchronous fetch so it returns current server state
  -- regardless of whether the watch stream has delivered an update yet.
  -- vim.g.clipboard paste functions may be called from a blocking context
  -- so we use read_sync via fetch_paste_sync on the client.
  local function paste_fn()
    local client = get_client()
    if not client or client:get_state() ~= 'connected' then
      return { '' }, 'c'
    end
    local text = client:fetch_paste_sync()
    if not text or text == '' then
      return { '' }, 'c'
    end
    return vim.split(text, '\n', { plain = true }), 'V'
  end

  return {
    name  = 'suffuse-plugin',
    copy  = { ['+'] = copy_fn, ['*'] = copy_fn },
    paste = { ['+'] = paste_fn, ['*'] = paste_fn },
    cache_enabled = 0,
  }
end

M._plugin_provider = plugin_provider

-- ── Public API ────────────────────────────────────────────────────────────────

function M.register(cfg, explicit, get_client)
  if cfg.clipboard_mode == 'off' then return 'off' end

  local tier = M.detect(cfg)
  local provider

  if tier == 'daemon' then
    -- Daemon: binary uses IPC socket, no CLI args needed
    provider = daemon_provider(cfg, get_client)

  elseif tier == 'binary' then
    -- Binary: only forward flags the user explicitly set in plugin config
    provider = binary_provider(cfg, explicit)

  elseif tier == 'plugin' then
    -- Plugin: pure Lua, uses cfg directly (including defaults for host probing)
    provider = plugin_provider(get_client)

  else
    return 'off'
  end

  vim.g.clipboard = provider
  return tier
end

return M
