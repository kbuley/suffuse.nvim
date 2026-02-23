-- lua/suffuse/init.lua
-- Public API and plugin wiring.

local M = {}

local _client  = nil ---@type SuffuseClient|nil
local _cfg     = nil ---@type table|nil
local _augroup = nil ---@type integer|nil

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param user_opts table|nil
function M.setup(user_opts)
  if _client then
    _client:disconnect()
    _client = nil
  end

  _cfg    = require('suffuse.config').resolve(user_opts)
  _client = require('suffuse.client').new(_cfg)

  _client:on_clipboard_update(function(text)
    M._apply_paste(text)
  end)

  -- Register vim.g.clipboard so plain Neovim unnamedplus works without the plugin
  local tier = require('suffuse.clipboard').register(_cfg, function() return _client end)
  if tier ~= 'off' then
    vim.notify(string.format('[suffuse] clipboard provider: %s', tier), vim.log.levels.DEBUG)
  end

  _augroup = vim.api.nvim_create_augroup('Suffuse', { clear = true })
  M._setup_autocmds()
  M._setup_commands()

  if _cfg.auto_connect then
    if vim.v.vim_did_enter == 1 then
      _client:connect()
    else
      vim.api.nvim_create_autocmd('VimEnter', {
        group    = _augroup,
        once     = true,
        callback = function() _client:connect() end,
      })
    end
  end
end

function M._is_setup() return _client ~= nil end

-- ── Autocmds ──────────────────────────────────────────────────────────────────

function M._setup_autocmds()
  if not _cfg.yank.enable then return end

  vim.api.nvim_create_autocmd('TextYankPost', {
    group    = _augroup,
    desc     = 'suffuse: send yank to clipboard server',
    callback = function()
      if not _client then return end
      local reg = _cfg.yank.register

      if reg == 'prompt' then
        vim.schedule(function() M._prompt_and_send() end)
        return
      end

      local text
      if reg == '"' then
        local event = vim.v.event
        if event and event.regcontents then
          text = table.concat(event.regcontents, '\n')
        end
      else
        text = vim.fn.getreg(reg)
      end

      if text and text ~= '' then
        _client:send_text(text)
      end
    end,
  })
end

-- ── Commands ──────────────────────────────────────────────────────────────────

function M._setup_commands()
  vim.api.nvim_create_user_command('SuffuseConnect', function()
    if not _client then
      vim.notify('[suffuse] not initialised — call require("suffuse").setup()',
        vim.log.levels.ERROR)
      return
    end
    _client:connect()
  end, { desc = 'Connect to the suffuse server' })

  vim.api.nvim_create_user_command('SuffuseDisconnect', function()
    if _client then _client:disconnect() end
  end, { desc = 'Disconnect from the suffuse server' })

  vim.api.nvim_create_user_command('SuffuseStatus', function()
    M.status()
  end, { desc = 'Show suffuse connection status and peer list' })

  vim.api.nvim_create_user_command('SuffuseCopy', function(args)
    M.copy(args.args ~= '' and args.args or nil)
  end, {
    nargs = '?',
    desc  = 'Send a register (default: yank.register) to the suffuse clipboard',
  })

  vim.api.nvim_create_user_command('SuffusePaste', function()
    M.paste()
  end, { desc = 'Pull the suffuse clipboard and insert at cursor' })
end

-- ── Public API ────────────────────────────────────────────────────────────────

---@param reg string|nil
function M.copy(reg)
  if not _client then return end
  reg = reg or _cfg.yank.register

  if reg == 'prompt' then
    M._prompt_and_send()
    return
  end

  local text = reg == '"'
    and table.concat(vim.fn.getreg('"', 1, true) --[[@as table]], '\n')
    or  vim.fn.getreg(reg)

  if not text or text == '' then
    vim.notify('[suffuse] register ' .. reg .. ' is empty', vim.log.levels.WARN)
    return
  end
  _client:send_text(text)
end

--- Pull the latest clipboard from the server, write to registers, insert at cursor.
function M.paste()
  if not _client then return end

  _client:fetch_paste(function(text, err)
    if err then
      vim.notify('[suffuse] paste: ' .. err, vim.log.levels.WARN)
      return
    end
    if not text then return end

    M._apply_paste(text)
    vim.schedule(function()
      local paste_reg = _cfg.paste.registers[1] or '+'
      local lines     = vim.split(vim.fn.getreg(paste_reg), '\n', { plain = true })
      local row, col  = unpack(vim.api.nvim_win_get_cursor(0))
      vim.api.nvim_buf_set_text(0, row-1, col, row-1, col, lines)
      local last_row = row - 1 + #lines - 1
      local last_col = #lines > 1 and #lines[#lines] or col + #lines[1]
      vim.api.nvim_win_set_cursor(0, { last_row+1, last_col })
    end)
  end)
end

--- Show connection status and peer list in a floating window.
function M.status()
  if not _client then
    vim.notify('[suffuse] not initialised', vim.log.levels.WARN)
    return
  end

  local state = _client:get_state()
  local host  = _client:get_host() or _cfg.host or '(probing)'

  if state ~= 'connected' then
    vim.notify(string.format('[suffuse] %s  (target: %s:%d)',
      state, host, _cfg.port), vim.log.levels.INFO)
    return
  end

  _client:fetch_status(function(msg, err)
    if err then
      vim.notify('[suffuse] status: ' .. err, vim.log.levels.WARN)
      return
    end
    vim.schedule(function() M._show_status_float(msg, host) end)
  end)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

function M._apply_paste(text)
  for _, reg in ipairs(_cfg.paste.registers) do
    vim.fn.setreg(reg, text)
  end
end

function M._prompt_and_send()
  local registers = { '"', '+', '*', 'a', 'b', 'c', '0' }
  vim.ui.select(registers, {
    prompt = 'suffuse: send which register?',
    format_item = function(r)
      local val     = vim.fn.getreg(r)
      local preview = val:sub(1, 40):gsub('\n', '↵')
      if #val > 40 then preview = preview .. '…' end
      return string.format('[%s] %s', r, preview)
    end,
  }, function(choice)
    if not choice then return end
    local text = vim.fn.getreg(choice)
    if text ~= '' then _client:send_text(text) end
  end)
end

function M._show_status_float(msg, host)
  local lines = {
    '',
    string.format('  Server:  %s:%d', host, _cfg.port),
    '',
  }

  local peers = msg.peers or {}
  if #peers == 0 then
    lines[#lines+1] = '  No other peers connected.'
  else
    lines[#lines+1] = string.format('  %-20s %-22s %-8s %s',
      'SOURCE', 'ADDR', 'ROLE', 'LAST SEEN')
    lines[#lines+1] = '  ' .. string.rep('─', 58)
    for _, p in ipairs(peers) do
      lines[#lines+1] = string.format('  %-20s %-22s %-8s %s',
        (p.source or '?'):sub(1,19),
        (p.addr   or '?'):sub(1,21),
        p.role    or '?',
        p.last_seen and p.last_seen:sub(1,19) or '?')
    end
  end

  lines[#lines+1] = ''
  lines[#lines+1] = '  Press q or <Esc> to close'
  lines[#lines+1] = ''

  local width  = 66
  local height = #lines
  local buf    = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'suffuse', { buf = buf })

  local ui  = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width  - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = 'editor',
    row       = row,
    col       = col,
    width     = width,
    height    = height,
    style     = 'minimal',
    border    = 'rounded',
    title     = ' suffuse ',
    title_pos = 'center',
  })

  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true, silent = true })
  end
end

return M
