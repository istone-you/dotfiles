-- .http / .rest ファイルで HTTP リクエストを管理・実行する
-- Requirements: curl
--
--   Space h r  カーソル位置のリクエストを実行
--   Space h e  環境を選択（http-client.env.json）
--   Space h j  ファイル内のリクエスト一覧からジャンプ
--   Space h c  カーソル位置のリクエストを curl コマンドとしてコピー
--   ]] / [[    次 / 前のリクエストへ
-- レスポンスパネル内: q 閉じる / R 再実行 / y ボディをコピー

local parser = require('config.http_client.parser')
local runner = require('config.http_client.runner')
local ui = require('config.http_client.ui')
local picker = require('config.http_client.picker')

local M = { parser = parser, runner = runner, ui = ui, picker = picker }

local state = {
  env_by_dir = {}, -- 環境ファイルのディレクトリ → 選択中の環境名
  last = nil,      -- { req = 展開済みリクエスト, dir = ..., env = ... }
}
M.state = state

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'HTTP' })
end

local function buf_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == '' then return vim.fn.getcwd() end
  return vim.fn.fnamemodify(name, ':p:h')
end

function M.doc(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return parser.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

--- 現在の環境名（未選択でも環境が1つだけなら自動で採用する）
function M.current_env(dir)
  local env_dir = parser.find_env_dir(dir)
  if not env_dir then return nil end
  local chosen = state.env_by_dir[env_dir]
  if chosen then return chosen end
  local names = parser.env_names(dir)
  if #names == 1 then return names[1] end
  return nil
end

--- カーソル位置のリクエストを変数展開まで済ませて返す。戻り値は req, エラー文字列
function M.prepare(buf, lnum)
  buf = buf or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]

  local doc = M.doc(buf)
  if #doc.requests == 0 then
    return nil, 'リクエストが見つかりません'
  end
  local raw = parser.request_at(doc, lnum)
  if not raw then return nil, 'リクエストが見つかりません' end

  local dir = buf_dir(buf)
  local env = M.current_env(dir)
  local env_vars, env_err = parser.env_vars(dir, env)
  if env_err then return nil, env_err end

  local req, unresolved = parser.build(raw, {
    vars = parser.vars_for(doc, raw),
    env = env_vars,
  })
  if #unresolved > 0 then
    local hint = ''
    if not env and #parser.env_names(dir) > 0 then
      hint = '（Space h e で環境を選ぶと解決するかもしれません）'
    end
    return nil, '未解決の変数: ' .. table.concat(unresolved, ', ') .. hint
  end
  if req.url == '' then return nil, 'URL がありません' end

  local body, body_err = runner.resolve_body(req.body, dir)
  if body_err then return nil, body_err end
  req.body = body

  return req, nil, { dir = dir, env = env }
end

function M.run(buf, lnum)
  buf = buf or vim.api.nvim_get_current_buf()
  local req, err, ctx = M.prepare(buf, lnum)
  if not req then
    notify(err, vim.log.levels.WARN)
    return
  end

  state.last = { req = req, dir = ctx.dir, env = ctx.env }
  ui.show_loading(req, { env = ctx.env })
  runner.run(req, { cwd = ctx.dir }, function(result)
    ui.show(result, { env = ctx.env })
    if not result.ok then
      notify(result.error or 'リクエストに失敗しました', vim.log.levels.ERROR)
    end
  end)
end

function M.rerun()
  local last = state.last
  if not last then
    notify('再実行できるリクエストがありません', vim.log.levels.WARN)
    return
  end
  ui.show_loading(last.req, { env = last.env })
  runner.run(last.req, { cwd = last.dir }, function(result)
    ui.show(result, { env = last.env })
  end)
end

function M.select_env(buf)
  local dir = buf_dir(buf)
  local names = parser.env_names(dir)
  if #names == 0 then
    notify('http-client.env.json が見つかりません', vim.log.levels.WARN)
    return
  end
  local env_dir = parser.find_env_dir(dir)
  local current = M.current_env(dir)
  picker.open({
    title = ' 環境を選択 ',
    items = names,
    format = function(name)
      return {
        tag = (name == current) and '●' or ' ',
        tag_hl = 'HttpPickerGet',
        text = name,
      }
    end,
    on_select = function(name)
      state.env_by_dir[env_dir] = name
      notify('環境: ' .. name)
    end,
  })
end

function M.select_request(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local doc = M.doc(buf)
  if #doc.requests == 0 then
    notify('リクエストが見つかりません', vim.log.levels.WARN)
    return
  end
  local win = vim.api.nvim_get_current_win()
  picker.open({
    title = ' リクエスト ',
    items = doc.requests,
    format = function(req)
      local name = (req.directives and req.directives.name) or req.name
      return {
        tag = string.format('%-6s', req.method or 'GET'),
        tag_hl = picker.method_hl(req.method),
        text = name or req.url or '',
        right = string.format('%4d', req.start_line),
      }
    end,
    on_select = function(req)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { req.start_line, 0 })
      end
    end,
  })
end

function M.copy_as_curl(buf, lnum)
  local req, err = M.prepare(buf, lnum)
  if not req then
    notify(err, vim.log.levels.WARN)
    return
  end
  local cmd = runner.curl_command(req)
  vim.fn.setreg('"', cmd)
  if vim.g.clipboard ~= nil then vim.fn.setreg('+', cmd) end
  notify('curl コマンドをコピーしました')
end

--- 次 / 前のリクエストの先頭行へカーソルを移す
function M.goto_request(dir_step, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local doc = M.doc(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local target = nil
  if dir_step > 0 then
    for _, req in ipairs(doc.requests) do
      if req.start_line > lnum then
        target = req.start_line
        break
      end
    end
  else
    for _, req in ipairs(doc.requests) do
      if req.start_line < lnum then target = req.start_line end
    end
  end
  if target then vim.api.nvim_win_set_cursor(0, { target, 0 }) end
end

-- ══════════════════════════════════════════════
-- セットアップ
-- ══════════════════════════════════════════════

-- .http は Neovim 本体が検出するが、.rest は自前で登録する
vim.filetype.add({ extension = { rest = 'http' } })

ui.set_rerun(function() M.rerun() end)

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('http_client', { clear = true }),
  pattern = 'http',
  callback = function(ev)
    local function map(lhs, fn, desc)
      vim.keymap.set('n', lhs, fn, { buffer = ev.buf, silent = true, desc = desc })
    end
    map('<leader>hr', function() M.run(ev.buf) end, 'HTTP: カーソル位置のリクエストを実行')
    map('<leader>he', function() M.select_env(ev.buf) end, 'HTTP: 環境を選択')
    map('<leader>hj', function() M.select_request(ev.buf) end, 'HTTP: リクエスト一覧へ')
    map('<leader>hc', function() M.copy_as_curl(ev.buf) end, 'HTTP: curl コマンドとしてコピー')
    map(']]', function() M.goto_request(1, ev.buf) end, 'HTTP: 次のリクエストへ')
    map('[[', function() M.goto_request(-1, ev.buf) end, 'HTTP: 前のリクエストへ')
    vim.bo[ev.buf].commentstring = '# %s'
  end,
})

vim.api.nvim_create_user_command('HttpRun', function() M.run() end, { desc = 'HTTP: カーソル位置のリクエストを実行' })
vim.api.nvim_create_user_command('HttpEnv', function() M.select_env() end, { desc = 'HTTP: 環境を選択' })
vim.api.nvim_create_user_command('HttpList', function() M.select_request() end, { desc = 'HTTP: リクエスト一覧へ' })

return M
