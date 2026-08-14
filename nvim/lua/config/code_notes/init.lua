-- Code Notes: コードリーディング用の場所付きメモをブラウザと API で共有する。

local M = {}
local server = require('config.code_notes.server')
local registry = require('config.util.session_registry').new('code-notes')

local state = { root = nil, port = nil }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'Code Notes' })
end

local function parse_port(input)
  input = vim.trim(tostring(input or ''))
  if not input:match('^%d+$') then return nil, 'port must be a number' end
  local port = tonumber(input)
  if not port or port < 1 or port > 65535 then return nil, 'port must be between 1 and 65535' end
  return port
end

local function resolve_root(cb)
  local name = vim.api.nvim_buf_get_name(0)
  local dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  vim.system({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or vim.trim(res.stdout) == '' then
        cb(vim.fs.normalize(vim.fn.getcwd()))
      else
        cb(vim.fs.normalize(vim.trim(res.stdout)))
      end
    end)
  end)
end

function M.open_on_port(port)
  resolve_root(function(root)
    state.root = root
    server.set_session({ repo_root = root })
    local ok, err = server.start(port)
    if not ok then
      notify(err or 'failed to start server', vim.log.levels.ERROR)
      return
    end
    state.port = port
    registry.register(root, port, { cwd = vim.fn.getcwd() })
    local url = server.server_url()
    require('config.browser.util').open_url(url, {
      fallback_message = 'Code Notes URL: ',
      namespace = 'code_notes',
      title = 'Code Notes',
    })
    notify('Code Notes: ' .. url)
  end)
end

function M.open()
  if server.is_running() then
    local url = server.server_url()
    if url then
      require('config.browser.util').open_url(url, {
        fallback_message = 'Code Notes URL: ',
        namespace = 'code_notes',
        title = 'Code Notes',
      })
      notify('Code Notes: ' .. url)
    end
    return
  end
  vim.ui.input({ prompt = 'Code Notes port: ' }, function(input)
    if input == nil then return end
    local port, err = parse_port(input)
    if not port then
      notify(err, vim.log.levels.ERROR)
      return
    end
    M.open_on_port(port)
  end)
end

--- いま待ち受けているポート。止まっていれば nil。
function M.serving_port()
  return state.port
end

function M.close(opts)
  opts = opts or {}
  local port = state.port
  local was_running = server.is_running()
  server.stop()
  if port then registry.unregister(port) end
  state.port = nil
  if was_running and not opts.silent then notify('Code Notes を停止しました') end
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('code_notes', { clear = true }),
  callback = function() M.close({ silent = true }) end,
})

vim.api.nvim_create_user_command('CodeNotes', function(cmd_opts)
  if cmd_opts.args ~= '' then
    local port, err = parse_port(cmd_opts.args)
    if not port then
      notify(err, vim.log.levels.ERROR)
      return
    end
    M.open_on_port(port)
  else
    M.open()
  end
end, { nargs = '?', desc = 'Code Notes をブラウザで開く' })

vim.api.nvim_create_user_command('CodeNotesClose', function() M.close() end, {
  desc = 'Code Notes のサーバを停止する',
})

vim.keymap.set('n', '<leader>B', M.open, { desc = 'Code Notes をブラウザで開く' })

M._private = {
  parse_port = parse_port,
  resolve_root = resolve_root,
  state = state,
}

return M
