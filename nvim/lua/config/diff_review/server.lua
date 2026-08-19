-- 差分レビューの HTTP サーバ(libuv TCP)。
--
-- 既存の browser(html.lua/markdown.lua)は GET 専用の静的サーバだが、こちらは AI が
-- コメントを書き込むため POST + JSON ボディまで扱う。HTTP レスポンス生成・content-type・
-- open_url・config は browser.util をそのまま使い回す(= 「既存のブラウザ表示機能の使い回し」)。
--
-- ルーティング(response_for_request)は state と comments/web を参照するだけの関数に切り出し、
-- ソケット無しでテストできるようにしている。

local M = {}
local browser = require('config.browser.util')
local http = require('config.browser.server')
local comments = require('config.diff_review.comments')
local anchor = require('config.diff_review.anchor')
local web = require('config.diff_review.web')

local state = {
  server = nil,
  port = nil,
  host = nil,
  repo_root = nil,
  source = 'worktree',
  diff_models = {
    uncommitted = { files = {} },
    unstaged = { files = {} },
    staged = { files = {} },
    committed = { files = {} },
  },
  branch_base = nil, -- committed ビューの比較元 { ref, merge_base } / デフォルトブランチが無ければ nil
  diff_version = 0,
}

M.state = state

local EMPTY = { files = {} }

--- /__version 用。diff の再構築とコメント変更のどちらでも値が変わる。
function M.version()
  return state.diff_version + comments.version()
end

--- init 側が git から作り直した diff モデルを差し込む。
--- diffs は { uncommitted=, unstaged=, staged=, committed=, branch_base= } の 4 ビュー。
--- 後方互換で旧名 all= も uncommitted として受け、単一モデル({files=..})も受ける(uncommitted 扱い)。
function M.set_diff(diffs)
  if diffs and diffs.files and not diffs.uncommitted and not diffs.all then
    diffs = { uncommitted = diffs }
  end
  state.diff_models = {
    uncommitted = (diffs and (diffs.uncommitted or diffs.all)) or EMPTY,
    unstaged = (diffs and diffs.unstaged) or EMPTY,
    staged = (diffs and diffs.staged) or EMPTY,
    committed = (diffs and diffs.committed) or EMPTY,
  }
  state.branch_base = diffs and diffs.branch_base or nil
  -- 差分が変わったので、既存コメントをそれぞれのビューの新しい差分へ貼り直す
  -- (hunk 相当の追従/outdated)。コメントは view('uncommitted'|'committed')ごとに別の差分にアンカーする。
  for _, c in ipairs(comments.list()) do
    if c.parent_id == vim.NIL then
      anchor.reanchor(c, state.diff_models[c.view] or state.diff_models.uncommitted)
    end
  end
  state.diff_version = state.diff_version + 1
end

function M.set_session(opts)
  opts = opts or {}
  if opts.repo_root ~= nil then state.repo_root = opts.repo_root end
  if opts.source ~= nil then state.source = opts.source end
end

local function json_response(status, tbl)
  return browser.http_response(status, 'application/json', vim.json.encode(tbl))
end

-- クライアントへ返すコメント表現。内部用の anchor(fingerprint)は除く。
local function public_comment(c)
  local o = {}
  for k, v in pairs(c) do
    if k ~= 'anchor' then o[k] = v end
  end
  if o.replies then
    local reps = {}
    for i, r in ipairs(o.replies) do reps[i] = public_comment(r) end
    o.replies = reps
  end
  return o
end

local function public_list(list)
  local out = {}
  for i, c in ipairs(list) do out[i] = public_comment(c) end
  return out
end

-- "a=1&b=hi%20there" -> { a='1', b='hi there' }
local function parse_query(query)
  local out = {}
  for pair in tostring(query or ''):gmatch('[^&]+') do
    local k, v = pair:match('^([^=]+)=?(.*)$')
    if k then out[browser.url_decode(k)] = browser.url_decode(v) end
  end
  return out
end

local function decode_body(body)
  if not body or body == '' then return {} end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

local function real(path)
  local p = vim.fs.normalize(tostring(path or ''))
  if p == '' then return nil end
  p = vim.fn.fnamemodify(p, ':p')
  local resolved = vim.fn.resolve(p)
  if resolved and resolved ~= '' then p = resolved end
  return (p:gsub('(.)/$', '%1'))
end

local function abs_path(file)
  local p = vim.fs.normalize(tostring(file or ''))
  if p == '' then return nil, 'file is required' end
  if p:sub(1, 1) ~= '/' then p = vim.fs.normalize((state.repo_root or vim.fn.getcwd()) .. '/' .. p) end
  local abs = real(p)
  local root = real(state.repo_root or vim.fn.getcwd())
  if abs ~= root and abs:sub(1, #root + 1) ~= root .. '/' then
    return nil, 'path is outside the repository root: ' .. abs
  end
  return abs
end

local function jump(body)
  local abs, err = abs_path(body.file)
  if not abs then return nil, err end
  if vim.fn.filereadable(abs) ~= 1 then return nil, 'file not readable: ' .. abs end
  local ok = pcall(function()
    local win_util = require('config.util.win_util')
    local bufnr = vim.fn.bufnr(abs)
    local target
    if bufnr > 0 then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win_util.is_editor(win) and vim.api.nvim_win_get_buf(win) == bufnr then
          target = win
          break
        end
      end
    else
      bufnr = nil
    end
    if target then
      vim.api.nvim_set_current_win(target)
    else
      win_util.focus_editor()
      vim.cmd('edit ' .. vim.fn.fnameescape(abs))
      bufnr = vim.api.nvim_get_current_buf()
    end
    vim.bo[bufnr].buflisted = true
    vim.api.nvim_win_set_cursor(0, {
      math.max(tonumber(body.line) or 1, 1),
      math.max((tonumber(body.col) or 1) - 1, 0),
    })
    vim.cmd('normal! zz')
  end)
  if not ok then return nil, 'failed to jump' end
  return true
end

-- /__vendor で配信を許可する同梱アセット(シンタックスハイライト用)。パストラバーサル防止。
local VENDOR_FILES = {
  ['highlight.min.js'] = true,
  ['highlight-theme.css'] = true,
}

local function handle_get(req)
  local path = req.path
  if path == '/' or path == '/index.html' then
    return browser.http_response('200 OK', 'text/html', web.render({ repo_root = state.repo_root }))
  end
  local vf = path:match('^/__vendor/([%w._-]+)$')
  if vf and VENDOR_FILES[vf] then
    return browser.vendor_response(vf)
  end
  if path == '/__version' then
    return browser.http_response('200 OK', 'text/plain', tostring(M.version()))
  end
  if path == '/api/session' then
    return json_response('200 OK', {
      repoRoot = state.repo_root,
      source = state.source,
      port = state.port,
      views = { 'uncommitted', 'committed', 'unstaged', 'staged' },
      -- committed ビューの比較元(= 比較する既定ブランチ)。無ければ nil(UI は Committed を無効化する)。
      branchBase = state.branch_base or vim.NIL,
      version = M.version(),
    })
  end
  if path == '/api/diff' then
    local view = parse_query(req.query).view or 'uncommitted'
    return json_response('200 OK', state.diff_models[view] or state.diff_models.uncommitted)
  end
  if path == '/api/comments' then
    local q = parse_query(req.query)
    local filter = {}
    if q.file and q.file ~= '' then filter.file = q.file end
    if q.author and q.author ~= '' then filter.author = q.author end
    if q.view and q.view ~= '' then filter.view = q.view end
    return json_response('200 OK', {
      comments = public_list(comments.list(filter)),
      threads = public_list(comments.threads(filter)),
      version = M.version(),
    })
  end
  return browser.http_response('404 Not Found', 'application/json', vim.json.encode({ error = 'not found' }))
end

local function jump_response(body)
  local ok, err = jump(body)
  if not ok then return json_response('400 Bad Request', { error = err }) end
  return json_response('200 OK', { ok = true })
end

local function handle_post(req, respond)
  local path = req.path
  local body = decode_body(req.body)
  if body == nil then
    return json_response('400 Bad Request', { error = 'invalid JSON body' })
  end

  if path == '/api/comments' then
    local comment, err = comments.add(body)
    if not comment then return json_response('400 Bad Request', { error = err }) end
    -- 作成時にそのコメントのビューの差分から fingerprint(本文＋前後行)を控える → 以後の更新で追従できる
    local model = state.diff_models[comment.view] or state.diff_models.uncommitted
    comment.anchor = anchor.capture(model, comment.file, comment.side, comment.line) or vim.NIL
    return json_response('200 OK', { comment = public_comment(comment) })
  end
  if path == '/api/comments/reply' then
    local comment, err = comments.reply(body)
    if not comment then return json_response('400 Bad Request', { error = err }) end
    return json_response('200 OK', { comment = public_comment(comment) })
  end
  if path == '/api/comments/delete' then
    local ok = comments.remove(body.id)
    if not ok then return json_response('404 Not Found', { error = 'comment not found' }) end
    return json_response('200 OK', { ok = true })
  end
  if path == '/api/comments/clear' then
    local filter = {}
    if body.file and body.file ~= '' then filter.file = body.file end
    if body.author and body.author ~= '' then filter.author = body.author end
    if body.view and body.view ~= '' then filter.view = body.view end
    comments.clear(next(filter) and filter or nil)
    return json_response('200 OK', { ok = true })
  end
  if path == '/api/jump' then
    if respond then
      vim.schedule(function() respond(jump_response(body)) end)
      return nil
    end
    return jump_response(body)
  end
  return json_response('404 Not Found', { error = 'not found' })
end

--- ソケット非依存のルーティング本体。req = {method, path, query, body}
function M.response_for_request(req, respond)
  if req.method == 'GET' then return handle_get(req) end
  if req.method == 'POST' then return handle_post(req, respond) end
  if req.method == 'OPTIONS' then
    return browser.http_response('204 No Content', 'text/plain', '')
  end
  return json_response('405 Method Not Allowed', { error = 'method not allowed' })
end

function M.is_running()
  return state.server ~= nil
end

function M.server_url()
  if not state.port then return nil end
  return 'http://localhost:' .. tostring(state.port) .. '/'
end

function M.stop()
  http.stop(state)
end

--- port で listen 開始。成功で true、失敗で false, err。共通サーバ(browser/server.lua)を使う。
function M.start(port)
  if state.server and state.port == port then return true end
  if state.server then M.stop() end
  return http.start(state, port, {
    namespace = 'diff_review',
    default_host = '127.0.0.1',
    handler = function(req, respond) return M.response_for_request(req, respond) end,
  })
end

M._private = {
  parse_request = http.parse_request,
  parse_query = parse_query,
  decode_body = decode_body,
  json_response = json_response,
}

return M
