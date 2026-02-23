-- lua/suffuse/config.lua
-- Default configuration and merging logic.

local M = {}

--- Hosts tried in order when config.host is nil.
--- First successful TCP connection wins and is remembered for the session.
--- localhost is first so that a local daemon is preferred over the remote host.
M.DEFAULT_HOSTS = {
  'localhost',                -- local suffuse daemon (preferred)
  'host.docker.internal',     -- Docker Desktop (macOS, Windows, Docker Desktop Linux)
  'host.containers.internal', -- Podman rootless
}

M.defaults = {
  host         = nil,    -- nil = auto-probe DEFAULT_HOSTS in order
  port         = 8752,
  token        = '',     -- empty = no auth (still TLS-encrypted with default passphrase)
  auto_connect = true,   -- connect on VimEnter

  -- Path to the suffuse binary. nil = find on PATH.
  -- Used by 'daemon' and 'binary' clipboard modes.
  bin = nil,

  -- Clipboard provider registration mode.
  -- 'auto'   detect in order: daemon → binary → plugin (default)
  -- 'daemon' shell out to local suffuse daemon via IPC socket
  -- 'binary' shell out to suffuse binary with explicit host/port
  -- 'plugin' direct TLS/HTTP from plugin only
  -- 'off'    do not register vim.g.clipboard
  clipboard_mode = 'auto',

  yank = {
    enable   = true,
    -- '"'      unnamed register — all yanks/deletes (default)
    -- '+'      system clipboard register
    -- '*'      primary selection
    -- 'prompt' ask via vim.ui.select() on every yank
    register = '"',
  },

  paste = {
    registers = { '+', '*' },
  },
}

---@param user table|nil
---@return table  resolved config (defaults + user overrides)
---@return table  explicit config (only keys the user actually provided)
function M.resolve(user)
  user = user or {}
  local cfg = vim.deepcopy(M.defaults)
  for k, v in pairs(user) do
    if type(v) == 'table' and type(cfg[k]) == 'table' then
      cfg[k] = vim.tbl_extend('force', cfg[k], v)
    else
      cfg[k] = v
    end
  end
  -- explicit tracks only what the user set; used by binary mode to avoid
  -- overwriting options that the binary would pick up from its own config file.
  local explicit = vim.deepcopy(user)
  return cfg, explicit
end

return M
