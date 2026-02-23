-- lua/suffuse/config.lua
-- Default configuration and merging logic.

local M = {}

--- Hosts tried in order when config.host is nil.
--- First successful TCP connection wins and is remembered for the session.
M.DEFAULT_HOSTS = {
  'host.docker.internal',     -- Docker Desktop (macOS, Windows, Docker Desktop Linux)
  'host.containers.internal', -- Podman rootless
  'localhost',                -- running directly on the host
}

M.defaults = {
  host         = nil,    -- nil = auto-probe DEFAULT_HOSTS in order
  port         = 8752,
  token        = '',     -- empty = no auth (still TLS-encrypted with default passphrase)
  auto_connect = true,   -- connect on VimEnter

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
---@return table
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
  return cfg
end

return M
