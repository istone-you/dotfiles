-- nvim API: 起動中の nvim が持っている情報(診断・LSP・バッファ)を、ローカル HTTP 経由で
-- AI から読めるようにする。
--
--   :NvimApi          … 状態と URL を表示
--   :NvimApiStart [port] … 起動(ポート省略で自動割り当て)
--   :NvimApiStop      … 停止
--
-- diff_review が「差分の上で人間と AI がコメントをやりとりする」ものだったのに対し、
-- こちらは常時起動の読み取り口。狙いは 2 つ:
--   * AI の探索精度 … grep は同名シンボルを区別できず import のエイリアスも追えない。
--     nvim に常駐している(インデックス済みの)LSP へ問い合わせれば一発で正しい答えが出る。
--   * 往復の削減 … 診断や「今開いているファイル」を、AI が tsc の再実行やコピペ無しに取れる。
--
-- 待ち受けは 127.0.0.1 のみ。画面を出さないので外から見せる必要がなく、diff_review(0.0.0.0)
-- とは既定を変えてある。

local M = {}
local server = require('config.nvim_api.server')
local registry = require('config.util.session_registry').new('nvim-api')

local augrp = vim.api.nvim_create_augroup('nvim_api', { clear = true })
local exiting = false

-- 自動割り当てで試すポート範囲。使用中なら次を試す。
M.PORT_RANGE = { first = 45001, last = 45100 }

local state = {
  port = nil,
  root = nil,
}

M.state = state

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'nvim API' })
end

--- カレントバッファのファイル(無ければ cwd)から git のトップレベルを解決する。
--- git 管理下でなければ cwd に倒す(API 自体は git を要求しない)。
local function resolve_root(cb)
  local name = vim.api.nvim_buf_get_name(0)
  local dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  vim.system({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or vim.trim(res.stdout) == '' then
        cb(vim.fs.normalize(vim.fn.getcwd()))
        return
      end
      cb(vim.fs.normalize(vim.trim(res.stdout)))
    end)
  end)
end

--- 空いているポートを見つけて listen する。見つからなければ false。
local function start_on_free_port()
  for port = M.PORT_RANGE.first, M.PORT_RANGE.last do
    local ok = server.start(port)
    if ok then return true, port end
  end
  return false, nil
end

function M.start(port, opts)
  opts = opts or {}
  if server.is_running() then return true end
  resolve_root(function(root)
    state.root = root
    server.set_session({ root = root })

    local ok, resolved_port
    if port then
      ok = server.start(port)
      resolved_port = port
    else
      ok, resolved_port = start_on_free_port()
    end
    if not ok then
      if not opts.silent then
        notify(port and ('port ' .. port .. ' is already in use') or 'no free port in range', vim.log.levels.ERROR)
      end
      return
    end

    state.port = resolved_port
    registry.register(root, resolved_port, { cwd = vim.fs.normalize(vim.fn.getcwd()) })
    if not opts.silent then
      notify('nvim API: ' .. (server.server_url() or ''))
    end
  end)
  return true
end

function M.stop(opts)
  opts = opts or {}
  local port = state.port
  local was_running = server.is_running()
  server.stop()
  if port then registry.unregister(port) end
  state.port = nil
  if was_running and not opts.silent and not exiting then
    notify('nvim API を停止しました')
  end
end

function M.status()
  if not server.is_running() then
    notify('nvim API は停止中です(:NvimApiStart で起動)')
    return
  end
  notify(table.concat({
    'nvim API: ' .. (server.server_url() or ''),
    'root: ' .. tostring(state.root),
    'registry: ' .. registry.path(),
  }, '\n'))
end

-- 起動直後は cwd や git の解決が済んでいないことがあるので VimEnter まで待つ。
-- vim.g.nvim_api_autostart = false で自動起動を切れる。
vim.api.nvim_create_autocmd('VimEnter', {
  group = augrp,
  once = true,
  callback = function()
    if vim.g.nvim_api_autostart == false then return end
    M.start(nil, { silent = true })
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = augrp,
  callback = function()
    exiting = true
    M.stop({ silent = true })
  end,
})

vim.api.nvim_create_user_command('NvimApi', function() M.status() end, {
  desc = 'nvim API サーバの状態を表示する',
})

vim.api.nvim_create_user_command('NvimApiStart', function(cmd_opts)
  local port = nil
  if cmd_opts.args ~= '' then
    port = tonumber(cmd_opts.args)
    if not port or port < 1 or port > 65535 then
      notify('port must be between 1 and 65535', vim.log.levels.ERROR)
      return
    end
  end
  M.start(port)
end, { nargs = '?', desc = 'nvim API サーバを起動する（AI が診断/LSP を叩ける）' })

vim.api.nvim_create_user_command('NvimApiStop', function() M.stop() end, {
  desc = 'nvim API サーバを停止する',
})

M._private = {
  resolve_root = resolve_root,
  start_on_free_port = start_on_free_port,
  registry = registry,
}

return M
