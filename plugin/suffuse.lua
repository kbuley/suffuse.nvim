-- plugin/suffuse.lua
-- Auto-setup entry point.
--
-- This file is sourced automatically by Neovim on startup.
-- It calls setup() with defaults so the plugin works out of the box with:
--
--   { 'kbuley/suffuse.nvim' }
--
-- lazy.nvim users who pass opts={...} get setup() called by lazy with their
-- opts after this file runs — the user's call wins because setup() is
-- idempotent and reinitialises with the new config.
--
-- To disable auto-setup entirely:
--
--   vim.g.suffuse_no_autosetup = true

if vim.g.suffuse_no_autosetup then return end

vim.api.nvim_create_autocmd('VimEnter', {
  once  = true,
  group = vim.api.nvim_create_augroup('SuffuseAutoSetup', { clear = true }),
  callback = function()
    if not require('suffuse')._is_setup() then
      require('suffuse').setup()
    end
  end,
})
