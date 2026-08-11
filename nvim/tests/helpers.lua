-- 最小のテストハーネス。busted風にdescribe/itで書けるが、
-- 実装はassert+pcallだけの薄いラッパー。各specファイルは`nvim -l`で個別プロセスとして
-- 実行され、最後にsummary()がos.exit()でpass/failを終了コードに反映する。
-- run.shが`--cmd "lua TESTS_DIR=...`"を渡している前提(直接nvim -lする場合は自分で設定する)
--
-- ハマりやすい点（実際にテストを書いていて踏んだもの）:
-- 1. キー入力は`vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)`
--    を使う。`vim.cmd('normal ...')`はEx引数がスペース1文字だけの時にE471になったり
--    <Space>等の表記変換をしないため不向き。`vim.cmd('normal! ...')`はbang付きで
--    マッピングそのものを無効化してしまうので使わない。
-- 2. `vim.cmd('startinsert')`はheadless(-l)実行では実際には持続しない
--    (`vim.wait()`を挟むとNormalモードに戻ってしまう)。インサートモード専用の
--    キーマップ(<CR>で確定、等)を押させたい時は、'i'で明示的にインサートへ入る
--    キーと本体のキーを**同じ1回のfeedkeys呼び出し**にまとめて送ること
--    (`feed('itext<CR>')`のように)。別々のfeedkeys呼び出しに分けると、その間に
--    モードがNormalへ戻ってしまい、インサート専用マッピングが発火しない。
-- 3. `CursorMoved`/`TextChangedI`等の一部autocmdイベントは、合成feedkeysだけでは
--    確実に発火しない。必要なら`vim.api.nvim_exec_autocmds(イベント名, {buffer=...})`
--    で明示的に発火させる。
-- 4. `nvim_win_get_config(win).title`はプレーン文字列ではなく`{{text,hl},...}`形式の
--    chunkリストで返る（`M.win_title_text`参照）。

local M = {}

local total, passed, failed = 0, 0, 0
local current_describe = nil

function M.describe(name, fn)
  local prev = current_describe
  current_describe = prev and (prev .. ' > ' .. name) or name
  fn()
  current_describe = prev
end

function M.it(name, fn)
  total = total + 1
  local label = current_describe and (current_describe .. ' > ' .. name) or name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('  ok   - ' .. label)
  else
    failed = failed + 1
    print('  FAIL - ' .. label)
    print('         ' .. tostring(err):gsub('\n', '\n         '))
  end
end

function M.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(string.format('%s\n  expected: %s\n  actual:   %s',
      msg or 'values differ', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.ok(cond, msg)
  if not cond then
    error(msg or 'expected a truthy value', 2)
  end
end

function M.contains(haystack, needle, msg)
  if type(haystack) == 'string' then
    if not haystack:find(needle, 1, true) then
      error(string.format('%s\n  string does not contain: %s\n  actual: %s',
        msg or 'contains check failed', needle, haystack), 2)
    end
    return
  end
  for _, v in ipairs(haystack) do
    if v == needle then return end
  end
  error(string.format('%s\n  list does not contain: %s\n  actual: %s',
    msg or 'contains check failed', vim.inspect(needle), vim.inspect(haystack)), 2)
end

function M.summary()
  print(string.format('\n%d total, %d passed, %d failed', total, passed, failed))
  os.exit(failed > 0 and 1 or 0)
end

-- ══════════════════════════════════════════════
-- テスト用の一時git repo・ディレクトリヘルパー
-- ══════════════════════════════════════════════

--- 同期でgitコマンドを実行する(テスト用途なので待つだけの単純な実装で十分)。
--- GIT_AUTHOR_* 環境変数は `git -c user.name=` より優先されるため、args 内の
--- `-c user.name=` / `-c user.email=` を拾って env にも同じ値を載せ、ホスト環境の
--- 作者名がテスト結果に混ざらないようにする
function M.git(dir, args)
  local name, email = 'test', 'test@test'
  local i = 1
  while i <= #args do
    if args[i] == '-c' and args[i + 1] then
      local n = args[i + 1]:match('^user%.name=(.+)$')
      local e = args[i + 1]:match('^user%.email=(.+)$')
      if n then name = n end
      if e then email = e end
    end
    i = i + 1
  end
  local env = vim.fn.environ()
  env.GIT_AUTHOR_NAME = name
  env.GIT_AUTHOR_EMAIL = email
  env.GIT_COMMITTER_NAME = name
  env.GIT_COMMITTER_EMAIL = email
  return vim.system(vim.list_extend({ 'git' }, args), { cwd = dir, text = true, env = env }):wait()
end

--- 空リポジトリ(1個の空コミット済み)を作って dir を返す。setup_fn(dir)で追加のセットアップができる
function M.tmp_git_repo(setup_fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  M.git(dir, { 'init', '-q', '-b', 'main' })
  M.git(dir, { '-c', 'user.email=test@test', '-c', 'user.name=test', 'commit', '-qm', 'init', '--allow-empty' })
  if setup_fn then setup_fn(dir) end
  return dir
end

function M.write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  vim.fn.writefile(lines, path)
end

function M.rmrf(dir)
  vim.fn.delete(dir, 'rf')
end

--- vim.wait を使い、cond()がtrueになるまで(またはtimeout)待つ。非同期の
--- vim.system/コールバック完了を待つのに使う
function M.wait_until(cond, timeout_ms)
  vim.wait(timeout_ms or 3000, cond, 20)
end

-- floatウィンドウのtitleは{{text,hl},...}形式のchunkリストで返るためテキストだけ取り出す
function M.win_title_text(win)
  local cfg = vim.api.nvim_win_get_config(win)
  if not cfg.title then return '' end
  local out = {}
  for _, chunk in ipairs(cfg.title) do
    table.insert(out, chunk[1])
  end
  return table.concat(out)
end

--- テスト用の極小 HTTP サーバを 127.0.0.1 の空きポートに立てる。
--- handler(受信したリクエスト全文) が返した文字列をそのままレスポンスとして書き戻す。
--- 戻り値は server, port（テスト側で server:close() すること）
function M.http_server(handler)
  local uv = vim.uv or vim.loop
  local server, port
  for p = 20000, 26000 do
    local candidate = uv.new_tcp()
    local ok = pcall(function() candidate:bind('127.0.0.1', p) end)
    local name = ok and candidate:getsockname() or nil
    if name and name.port == p then
      server = candidate
      port = p
      break
    end
    pcall(function() candidate:close() end)
  end
  assert(server and port, 'failed to bind a test HTTP server port')
  server:listen(16, function(err)
    if err then return end
    local client = uv.new_tcp()
    server:accept(client)
    local buf = ''
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        pcall(function() client:close() end)
        return
      end
      buf = buf .. chunk
      -- ヘッダを受け切り、Content-Length 分のボディが揃ってから返す
      local head, body = buf:match('^(.-\r\n\r\n)(.*)$')
      if not head then return end
      local len = tonumber(head:match('[Cc]ontent%-[Ll]ength:%s*(%d+)') or '0') or 0
      if #body < len then return end
      client:write(handler(buf))
      client:shutdown(function()
        pcall(function() client:close() end)
      end)
    end)
  end)
  return server, port
end

function M.floating_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then table.insert(out, w) end
  end
  return out
end

return M
