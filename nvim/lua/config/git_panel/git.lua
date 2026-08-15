-- 非同期git操作レイヤー（vim.system + on_exitコールバック、UIをブロックしない）
-- コマンドの実選択は lazygit(pkg/commands/git_commands) を参照して合わせている

local M = {}

M.root = nil
M.command_log = {}
local MAX_LOG = 200
--- init.luaがrender_cmdlog相当を差し込むためのフック（コマンドログに変化があるたびに呼ぶ）
M.on_log_update = function() end

--- 左右2画面表示のオン/オフ
M.side_by_side = false

function M.toggle_side_by_side()
  M.side_by_side = not M.side_by_side
  return M.side_by_side
end

--- diff_text(生のunified diff)を描画データ(行+ハイライト)へ変換する。
--- 変換はプロセスを起こさない純Luaなので同期で返す
---@param diff_text string|nil
---@param width integer|nil 右ペインの表示幅
---@return table
function M.render_diff(diff_text, width)
  return require('config.panel.diff').render(diff_text, {
    width = width,
    side_by_side = M.side_by_side,
  })
end

--- lazygit(command_log_panel.go)と同じく、古い→新しいの順で末尾に追記する
--- （表示側でビューを一番下へスクロールすることで最新行を見せる。Autoscroll相当）
local function push_log(text)
  table.insert(M.command_log, text)
  if #M.command_log > MAX_LOG then
    table.remove(M.command_log, 1)
  end
  -- push_logはvim.system側のstdout/stderrコールバック(fast event context)からも
  -- 呼ばれるため、vim.api経由の再描画は必ずscheduleする
  vim.schedule(M.on_log_update)
end

local function log_command(args)
  push_log('git ' .. table.concat(args, ' '))
end

--- lazygitのStreamOutput()相当。標準出力/エラーを完了を待たず1行ずつコマンドログへ
--- 流し込む（lefthook/hk等のpre-commitフックの出力や、push/pullの進捗メッセージが
--- 見えるようにする）。vim.systemはstdout/stderrにコールバックを渡すと最終res.stdout/
--- res.stderrをnilにしてしまうため、ここで全文も別途累積して呼び出し元に渡せるようにする
local function make_streamer()
  local pending, full = '', {}
  local function feed(_, data)
    if not data then
      if pending ~= '' then push_log('  ' .. pending); table.insert(full, pending); pending = '' end
      return
    end
    table.insert(full, data)
    pending = pending .. data
    while true do
      local nl = pending:find('\n')
      if not nl then break end
      push_log('  ' .. pending:sub(1, nl - 1))
      pending = pending:sub(nl + 1)
    end
  end
  return feed, function() return table.concat(full) end
end

function M.find_root(cb)
  local args = { 'rev-parse', '--show-toplevel' }
  vim.system(vim.list_extend({ 'git' }, args), { cwd = vim.fn.getcwd(), text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        M.root = vim.trim(res.stdout or '')
        cb(M.root)
      else
        cb(nil)
      end
    end)
  end)
end

--- lazygit(pkg/commands/git_commands/git_command_builder.go OptionalLocksEnvVar)と
--- 同じ対応: gitは"読み取り専用"のstatus等でもstat-cache更新のためオプショナルに
--- .git/index.lockを取ることがある。これが自パネルの2秒おきバックグラウンド自動更新
--- (git status)と、discard等のインデックス変更コマンドの間で稀に競合し、
--- 後者が失敗する(実際に大量ファイルのdiscardをストレステストして再現した)。
--- 本体は全コマンドへ既定でGIT_OPTIONAL_LOCKS=0を付けてそもそもロックを取らせない
--- ようにしているので、それに合わせる
local GIT_ENV = { GIT_OPTIONAL_LOCKS = '0' }

--- lazygit(pkg/commands/git_cmd_obj_runner.go isRetryableError/retryOnLockError)と
--- 同じ判定・再試行ロジック: 上のGIT_OPTIONAL_LOCKS=0だけでは自分以外(ユーザーが
--- 別ターミナルで叩いたgit等)との競合は防げないため、"index.lock"/"cannot lock ref"
--- を含むエラーだけを対象に、指数バックオフで再試行する(初回20ms、最大7回で合計約1秒強)
local LOCK_RETRY_DELAYS_MS = { 20, 40, 80, 160, 320, 640, 1280 }

local function is_lock_error(stderr)
  return stderr ~= nil and (stderr:find('index.lock', 1, true) ~= nil or stderr:find('cannot lock ref', 1, true) ~= nil)
end

--- lazygit(pkg/commands/oscommands/cmd_obj.go DontLog)と同じ方針:
--- git状態を変えないコマンド(status/diff/logなど)はコマンドログに出さない。
--- 状態を変えるコマンド(add/commit/checkoutなど)は出す。opts.dont_log=trueで前者を指定する。
--- opts.stream_output=trueなら、そのコマンドの標準出力/エラーもコマンドログへ流し込む
--- （lazygitがcommit/push/pull/merge/rebase等でStreamOutput()するのと同じ対象）
function M.run(args, cb, opts)
  local cmd = vim.list_extend({ 'git' }, args)
  if not (opts and opts.dont_log) then log_command(args) end

  local function attempt(retry_idx)
    local sys_opts = { cwd = M.root, text = true, env = GIT_ENV }
    local get_stdout, get_stderr
    if opts and opts.stream_output then
      local stdout_feed, stdout_get = make_streamer()
      local stderr_feed, stderr_get = make_streamer()
      sys_opts.stdout, sys_opts.stderr = stdout_feed, stderr_feed
      get_stdout, get_stderr = stdout_get, stderr_get
    end
    vim.system(cmd, sys_opts, function(res)
      if get_stdout then res.stdout = get_stdout() end
      if get_stderr then res.stderr = get_stderr() end
      local retry_delay = res.code ~= 0 and is_lock_error(res.stderr) and LOCK_RETRY_DELAYS_MS[retry_idx]
      if retry_delay then
        vim.defer_fn(function() attempt(retry_idx + 1) end, retry_delay)
        return
      end
      vim.schedule(function() cb(res) end)
    end)
  end
  attempt(1)
end

-- ══════════════════════════════════════════════
-- status / diff / stage（working_tree.goのStageFiles/UnStageFileに合わせる）
-- ══════════════════════════════════════════════

function M.status(cb)
  -- --untracked-files=all: 未追跡ディレクトリを1行にまとめず配下ファイルを個別に列挙する
  -- -z: NUL区切りの生バイト出力(lazygit file_loader.goのgitStatus()と同じ)。
  -- これが無いと空白/特殊文字を含むパスがダブルクォートで囲われてエスケープされ、
  -- リネームの旧パスも"old -> new"の human-readable表記に埋め込まれて分離できない
  M.run({ 'status', '--porcelain=v1', '--untracked-files=all', '-z' }, function(res) cb(res.stdout or '') end, { dont_log = true })
end

function M.branch_name(cb)
  M.run({ 'rev-parse', '--abbrev-ref', 'HEAD' }, function(res) cb(vim.trim(res.stdout or '')) end, { dont_log = true })
end

function M.diff_file(entry, cb)
  local args = (entry.section == 'staged')
    and { 'diff', '--cached', '--', entry.path }
    or { 'diff', '--', entry.path }
  M.run(args, function(res) cb(res.stdout or '') end, { dont_log = true })
end

local function status_untracked_paths(output)
  local records = vim.split(output or '', '\0', { plain = true })
  local paths = {}
  local i = 1
  while i <= #records do
    local rec = records[i]
    if rec ~= '' then
      local x, y, path = rec:sub(1, 1), rec:sub(2, 2), rec:sub(4):gsub('/$', '')
      if x == 'R' or x == 'C' then i = i + 1 end
      if x == '?' and y == '?' then table.insert(paths, path) end
    end
    i = i + 1
  end
  table.sort(paths)
  return paths
end

--- Filesパネルの拡大レビュー用: tracked/staged/unstaged は `git diff HEAD` で
--- 1本の変更ストリームにし、git diff が拾わない未追跡ファイルは no-index diff を後ろへ連結する。
function M.diff_worktree_all(cb)
  M.run({ 'diff', 'HEAD', '--' }, function(diff_res)
    local parts = {}
    if diff_res.stdout and diff_res.stdout ~= '' then table.insert(parts, diff_res.stdout) end
    M.status(function(status_out)
      local paths = status_untracked_paths(status_out)
      local idx = 1
      local function next_untracked()
        local path = paths[idx]
        idx = idx + 1
        if not path then
          cb(table.concat(parts, '\n'))
          return
        end
        if vim.fn.isdirectory(M.root .. '/' .. path) == 1 then
          next_untracked()
          return
        end
        M.diff_untracked_file(path, function(text)
          if text and text ~= '' then table.insert(parts, text) end
          next_untracked()
        end)
      end
      next_untracked()
    end)
  end, { dont_log = true })
end

--- lazygit(working_tree.go WorktreeFileDiffCmdObj、noIndex分岐)と同じ:
--- 未追跡ファイルは`git diff --no-index -- /dev/null <path>`で本物のunified diffを
--- 得る。exit code(--no-indexは差分がある時1を返す)はエラー扱いしない。
--- diff --git等のヘッダーが揃うので、描画側がファイル単位・hunk単位に分解できる
function M.diff_untracked_file(path, cb)
  M.run({ 'diff', '--no-index', '--', '/dev/null', path }, function(res) cb(res.stdout or '') end, { dont_log = true })
end

local function clean_diff_path(raw)
  if not raw or raw == '/dev/null' then return nil end
  raw = vim.trim(raw)
  if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then
    raw = raw:sub(2, -2)
  end
  return raw:gsub('^[ab]/', '')
end

--- raw unified diff をファイル単位へ分割し、review stream のサイドバー/ジャンプに必要な
--- ファイル境界と増減行数を返す。start_line/end_line は raw diff 上の 1-indexed 行。
function M.diff_files(diff_text)
  local lines = vim.split(diff_text or '', '\n', { plain = true })
  local files = {}
  local current = nil

  local function finish(end_line)
    if not current then return end
    current.end_line = end_line
    current.raw_text = table.concat(vim.list_slice(lines, current.start_line, end_line), '\n')
    current.path = current.path or current.new_path or current.old_path or current.fallback_path or '(unknown)'
    table.insert(files, current)
  end

  for i, line in ipairs(lines) do
    if line:match('^diff %-%-git ') then
      finish(i - 1)
      local fallback = line:match(' b/(.+)$')
      current = {
        start_line = i,
        path = nil,
        old_path = nil,
        new_path = nil,
        fallback_path = clean_diff_path(fallback),
        status = 'M',
        added = 0,
        deleted = 0,
      }
    elseif current then
      if line:match('^new file mode ') then current.status = 'A' end
      if line:match('^deleted file mode ') then current.status = 'D' end
      if line:match('^rename from ') then current.status = 'R' end
      local old = line:match('^%-%-%- (.+)$')
      local new = line:match('^%+%+%+ (.+)$')
      if old then
        current.old_path = clean_diff_path(old)
        if not current.old_path then current.status = 'A' end
      end
      if new then
        current.new_path = clean_diff_path(new)
        if not current.new_path then current.status = 'D' end
        current.path = current.new_path or current.old_path
      end
      if line:sub(1, 1) == '+' and not line:match('^%+%+%+') then current.added = current.added + 1 end
      if line:sub(1, 1) == '-' and not line:match('^%-%-%-') then current.deleted = current.deleted + 1 end
    end
  end
  finish(#lines)
  return files
end

function M.stage(path, cb) M.run({ 'add', '--', path }, cb) end
function M.unstage(path, cb) M.run({ 'reset', 'HEAD', '--', path }, cb) end
function M.stage_all(cb) M.run({ 'add', '-A' }, cb) end
function M.unstage_all(cb) M.run({ 'reset', 'HEAD' }, cb) end
function M.ignore_file(path, cb)
  local ok = pcall(function()
    vim.fn.writefile({ path }, M.root .. '/.gitignore', 'a')
  end)
  cb({ code = ok and 0 or 1 })
end

function M.commit(msg_lines, no_verify, cb)
  local tmp = vim.fn.tempname()
  vim.fn.writefile(msg_lines, tmp)
  local args = { 'commit', '-F', tmp }
  if no_verify then table.insert(args, '--no-verify') end
  M.run(args, function(res)
    vim.fn.delete(tmp)
    cb(res)
  end, { stream_output = true })
end

function M.amend(cb)
  M.run({ 'commit', '--amend', '--no-edit' }, cb, { stream_output = true })
end

-- ══════════════════════════════════════════════
-- hunk単位のステージ（pkg/commands/git_commands/patch.go ApplyPatchと同じフラグ運用）
-- stage: {cached=true}  unstage: {cached=true, reverse=true}  discard: {reverse=true}
-- ══════════════════════════════════════════════

function M.parse_hunks(diff_text)
  local lines = vim.split(diff_text, '\n', { plain = true })
  local header = {}
  local hunks = {}
  local current = nil
  for _, l in ipairs(lines) do
    if l:match('^@@') then
      current = { header = l, lines = {} }
      table.insert(hunks, current)
    elseif current then
      table.insert(current.lines, l)
    else
      table.insert(header, l)
    end
  end
  return header, hunks
end

local function build_patch(header, hunk)
  local parts = {}
  vim.list_extend(parts, header)
  table.insert(parts, hunk.header)
  vim.list_extend(parts, hunk.lines)
  return table.concat(parts, '\n') .. '\n'
end

--- opts = { cached = bool, reverse = bool }
function M.apply_hunk(header, hunk, opts, cb)
  local patch = build_patch(header, hunk)
  local tmp = vim.fn.tempname()
  vim.fn.writefile(vim.split(patch, '\n', { plain = true }), tmp)
  local args = { 'apply' }
  if opts.cached then table.insert(args, '--cached') end
  if opts.reverse then table.insert(args, '--reverse') end
  table.insert(args, tmp)
  M.run(args, function(res)
    vim.fn.delete(tmp)
    cb(res)
  end)
end

-- ══════════════════════════════════════════════
-- ブランチ
-- ══════════════════════════════════════════════

function M.branches(cb)
  M.run({
    'for-each-ref', 'refs/heads/',
    '--format=%(HEAD)%09%(refname:short)%09%(upstream:short)%09%(upstream:track)',
    '--sort=-committerdate',
  }, function(res)
    local list = {}
    local head_idx = nil
    for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
      if line ~= '' then
        local head, name, upstream, track = line:match('^(.-)\t(.-)\t(.-)\t(.*)$')
        if name then
          table.insert(list, { name = name, current = head == '*', upstream = upstream, track = track })
          if head == '*' then head_idx = #list end
        end
      end
    end
    -- branch_loader.go Load(): ソート順設定に関わらずHEADブランチを常に先頭へ移動する
    if head_idx and head_idx ~= 1 then
      table.insert(list, 1, table.remove(list, head_idx))
    end
    cb(list)
  end, { dont_log = true })
end

function M.checkout_branch(name, cb) M.run({ 'checkout', name }, cb) end
function M.checkout_by_name(name, cb) M.run({ 'checkout', name }, cb) end
function M.checkout_previous(cb) M.run({ 'checkout', '-' }, cb) end
function M.create_branch(name, cb) M.run({ 'checkout', '-b', name }, cb) end
function M.delete_branch(name, force, cb) M.run({ 'branch', force and '-D' or '-d', name }, cb) end
function M.force_checkout(name, cb) M.run({ 'checkout', '-f', name }, cb) end
function M.merge_branch(name, cb) M.run({ 'merge', name }, cb, { stream_output = true }) end
function M.rebase_branch(name, cb) M.run({ 'rebase', name }, cb, { stream_output = true }) end
function M.rename_branch(old, new, cb) M.run({ 'branch', '-m', old, new }, cb) end
-- lazygit(branches_controller.go fastForward)と同じ分岐: 現在チェックアウト中の
-- ブランチは`git fetch origin <name>:<name>`では更新できない(checkout中のrefへの
-- 直接fetchはgitに拒否される)ため、その場合だけ`git pull --ff-only`を使う
function M.fast_forward(name, cb)
  M.branch_name(function(current)
    if current == name then
      M.run({ 'pull', '--ff-only' }, cb, { stream_output = true })
    else
      M.run({ 'fetch', 'origin', name .. ':' .. name }, cb)
    end
  end)
end
-- lazygit(branch.go SetUpstream)と同じく、対象のブランチ名を明示する。
-- ブランチ名を省略すると現在チェックアウト中のブランチにしか効かず、
-- カーソル位置のブランチ(必ずしもcurrentではない)へ設定できないため
function M.set_upstream(remote, branch_name, cb)
  M.run({ 'branch', '--set-upstream-to=' .. remote .. '/' .. branch_name, branch_name }, cb)
end

-- ══════════════════════════════════════════════
-- ログ / コミット操作
-- ══════════════════════════════════════════════

local LOG_SEP = '\x1f'
local LOG_FMT = table.concat({ '%H', '%h', '%s', '%an', '%ar' }, LOG_SEP)

function M.log(cb)
  M.run({ 'log', '--pretty=format:' .. LOG_FMT, '-n', '300' }, function(res)
    local list = {}
    for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
      if line ~= '' then
        local parts = vim.split(line, LOG_SEP, { plain = true })
        table.insert(list, {
          hash = parts[1], short = parts[2], subject = parts[3],
          author = parts[4], rel = parts[5],
        })
      end
    end
    cb(list)
  end, { dont_log = true })
end

function M.show_commit(hash, cb) M.run({ 'show', hash }, function(res) cb(res.stdout or '') end, { dont_log = true }) end
function M.reset(hash, mode, cb) M.run({ 'reset', '--' .. mode, hash }, cb) end
function M.revert_commit(hash, cb) M.run({ 'revert', '--no-edit', hash }, cb, { stream_output = true }) end
function M.cherry_pick(hash, cb) M.run({ 'cherry-pick', hash }, cb, { stream_output = true }) end
function M.new_branch_from_commit(hash, name, cb) M.run({ 'checkout', '-b', name, hash }, cb) end

--- Undo(z): 直前のコミット1つだけをsoft resetで取り消す（lazygitのreflog Undoの
--- 「直前の操作がコミットだった」場合の挙動を再現。checkout/rebaseのUndoは対象外）
function M.undo_last_commit(cb) M.run({ 'reset', '--soft', 'HEAD@{1}' }, cb) end
function M.checkout_commit(hash, cb) M.run({ 'checkout', hash }, cb) end

--- lazygitのGit.MainBranches既定値("master","main")に合わせ、
--- pkg/commands/git_commands/main_branches.go の determineMainBranches と同じ優先順位で解決する:
--- 1. ローカルブランチのアップストリーム（<name>@{u}。例: main@{u} -> origin/main）
--- 2. アップストリーム未設定ならorigin配下のリモート追跡ブランチ（refs/remotes/origin/<name>）
--- 3. それも無ければローカルブランチ自体（refs/heads/<name>）
--- ※ 1を最優先するのが重要: mainブランチにチェックアウトしている状態でmain自身を使うと
---   git rev-list HEAD ^main が常に空になり、未pushコミットまで緑(Merged)になってしまう
function M.resolve_main_branches(cb)
  local candidates = { 'master', 'main' }
  local refs = {}
  local pending = #candidates
  local function done()
    pending = pending - 1
    if pending == 0 then cb(refs) end
  end
  for _, name in ipairs(candidates) do
    M.run({ 'rev-parse', '--symbolic-full-name', name .. '@{u}' }, function(res)
      if res.code == 0 then
        table.insert(refs, vim.trim(res.stdout or ''))
        done()
        return
      end
      M.run({ 'rev-parse', '--verify', '--quiet', 'refs/remotes/origin/' .. name }, function(res2)
        if res2.code == 0 then
          table.insert(refs, 'refs/remotes/origin/' .. name)
          done()
          return
        end
        M.run({ 'rev-parse', '--verify', '--quiet', 'refs/heads/' .. name }, function(res3)
          if res3.code == 0 then table.insert(refs, 'refs/heads/' .. name) end
          done()
        end, { dont_log = true })
      end, { dont_log = true })
    end, { dont_log = true })
  end
end

-- ══════════════════════════════════════════════
-- スタッシュ
-- ══════════════════════════════════════════════

local STASH_FMT = table.concat({ '%gd', '%s' }, LOG_SEP)

function M.stash_list(cb)
  M.run({ 'stash', 'list', '--pretty=format:' .. STASH_FMT }, function(res)
    local list = {}
    for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
      if line ~= '' then
        local parts = vim.split(line, LOG_SEP, { plain = true })
        table.insert(list, { ref = parts[1], message = parts[2] })
      end
    end
    cb(list)
  end, { dont_log = true })
end

function M.stash_show(ref, cb) M.run({ 'stash', 'show', '-p', ref }, function(res) cb(res.stdout or '') end, { dont_log = true }) end
function M.stash_apply(ref, cb) M.run({ 'stash', 'apply', ref }, cb, { stream_output = true }) end
function M.stash_pop(ref, cb) M.run({ 'stash', 'pop', ref }, cb, { stream_output = true }) end
function M.stash_drop(ref, cb) M.run({ 'stash', 'drop', ref }, cb) end
function M.stash_branch(ref, name, cb) M.run({ 'stash', 'branch', name, ref }, cb) end

--- opts = { include_untracked?, staged?, keep_index? }
--- lazygitのスタッシュオプション（Stash / StashIncludingUntracked / StashStaged / StashKeepIndex）に対応
function M.stash_save(msg, cb, opts)
  opts = opts or {}
  local args = { 'stash', 'push' }
  if opts.include_untracked then table.insert(args, '--include-untracked') end
  if opts.staged then table.insert(args, '--staged') end
  if opts.keep_index then table.insert(args, '--keep-index') end
  if msg and msg ~= '' then
    table.insert(args, '-m')
    table.insert(args, msg)
  end
  M.run(args, cb)
end

-- ══════════════════════════════════════════════
-- push / pull / fetch
-- ══════════════════════════════════════════════

function M.has_upstream(cb)
  M.run({ 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, function(res)
    cb(res.code == 0, vim.trim(res.stdout or ''))
  end, { dont_log = true })
end

function M.push(cb) M.run({ 'push' }, cb, { stream_output = true }) end
function M.push_force_with_lease(cb) M.run({ 'push', '--force-with-lease' }, cb, { stream_output = true }) end
function M.push_force(cb) M.run({ 'push', '--force' }, cb, { stream_output = true }) end
function M.push_set_upstream(remote, branch_name, cb) M.run({ 'push', '-u', remote, branch_name }, cb, { stream_output = true }) end
function M.pull(cb) M.run({ 'pull' }, cb, { stream_output = true }) end

-- ══════════════════════════════════════════════
-- マージ / コンフリクト
-- ══════════════════════════════════════════════

--- pull/merge の結果がコンフリクトで止まったかを判定する（git は終了コード1を返し、
--- 進捗は stdout、"Automatic merge failed" は stderr 側に出る）
function M.is_conflict_result(res)
  local text = (res.stdout or '') .. '\n' .. (res.stderr or '')
  return text:find('CONFLICT', 1, true) ~= nil
    or text:find('Automatic merge failed', 1, true) ~= nil
    or text:find('could not apply', 1, true) ~= nil
    or text:find('fix conflicts', 1, true) ~= nil
end

--- 中断中の作業を返す: 'merge' | 'rebase' | 'cherry-pick' | 'revert' | nil。
--- .git はワークツリーだとファイルになるので rev-parse --git-path で解決する
function M.merge_state(cb)
  M.run({ 'rev-parse', '--git-path', 'MERGE_HEAD' }, function(res)
    local git_dir = vim.trim(res.stdout or ''):gsub('/MERGE_HEAD$', '')
    if git_dir == '' then cb(nil); return end
    if not git_dir:match('^/') then git_dir = M.root .. '/' .. git_dir end
    local function exists(p) return vim.fn.filereadable(p) == 1 or vim.fn.isdirectory(p) == 1 end
    if exists(git_dir .. '/MERGE_HEAD') then cb('merge')
    elseif exists(git_dir .. '/rebase-merge') or exists(git_dir .. '/rebase-apply') then cb('rebase')
    elseif exists(git_dir .. '/CHERRY_PICK_HEAD') then cb('cherry-pick')
    elseif exists(git_dir .. '/REVERT_HEAD') then cb('revert')
    else cb(nil)
    end
  end, { dont_log = true })
end

--- 衝突ファイルの片側だけを採用する（VSCode の Accept Current/Incoming をファイル単位でやる版）。
--- checkout 後は add まで行って「解消済み」にする
function M.take_side(path, side, cb)
  M.run({ 'checkout', side == 'ours' and '--ours' or '--theirs', '--', path }, function(res)
    if res.code ~= 0 then cb(res); return end
    M.run({ 'add', '--', path }, cb)
  end)
end

function M.merge_abort(cb) M.run({ 'merge', '--abort' }, cb, { stream_output = true }) end
function M.rebase_abort(cb) M.run({ 'rebase', '--abort' }, cb, { stream_output = true }) end
function M.cherry_pick_abort(cb) M.run({ 'cherry-pick', '--abort' }, cb, { stream_output = true }) end
function M.revert_abort(cb) M.run({ 'revert', '--abort' }, cb, { stream_output = true }) end
-- どちらもエディタを開かせない形にする（merge --continue はコミットメッセージの
-- エディタを起動するため、等価な commit --no-edit を使う）
function M.merge_continue(cb) M.run({ 'commit', '--no-edit' }, cb, { stream_output = true }) end
function M.rebase_continue(cb)
  M.run({ '-c', 'core.editor=true', 'rebase', '--continue' }, cb, { stream_output = true })
end

--- 中断中の作業に応じた abort / continue を投げ分ける
function M.abort_in_progress(state, cb)
  if state == 'rebase' then return M.rebase_abort(cb) end
  if state == 'cherry-pick' then return M.cherry_pick_abort(cb) end
  if state == 'revert' then return M.revert_abort(cb) end
  return M.merge_abort(cb)
end

function M.continue_in_progress(state, cb)
  if state == 'rebase' then return M.rebase_continue(cb) end
  return M.merge_continue(cb)
end
function M.fetch(cb) M.run({ 'fetch' }, cb, { stream_output = true }) end
function M.remote_names(cb)
  M.run({ 'remote' }, function(res)
    cb(vim.tbl_filter(function(l) return l ~= '' end, vim.split(res.stdout or '', '\n', { plain = true })))
  end, { dont_log = true })
end

--- suggestions_helper.go GetRefsSuggestionsFuncと同じ材料を集める:
--- リモート追跡ブランチ("remote/branch"形式) + ローカルブランチ + タグ + HEAD系の特殊ref
function M.ref_candidates(cb)
  local function lines(res)
    local out = {}
    for l in (res.stdout or ''):gmatch('[^\r\n]+') do table.insert(out, l) end
    return out
  end
  M.run({ 'for-each-ref', 'refs/remotes/', '--format=%(refname:short)' }, function(r1)
    local remotes = vim.tbl_filter(function(l) return not l:match('/HEAD$') end, lines(r1))
    M.run({ 'for-each-ref', 'refs/heads/', '--format=%(refname:short)' }, function(r2)
      local locals = lines(r2)
      M.run({ 'for-each-ref', 'refs/tags/', '--format=%(refname:short)' }, function(r3)
        local tags = lines(r3)
        local all = {}
        vim.list_extend(all, remotes)
        vim.list_extend(all, locals)
        vim.list_extend(all, tags)
        vim.list_extend(all, { 'HEAD', 'FETCH_HEAD', 'MERGE_HEAD', 'ORIG_HEAD' })
        cb(all)
      end, { dont_log = true })
    end, { dont_log = true })
  end, { dont_log = true })
end

-- ══════════════════════════════════════════════
-- GitHub PR (pkg/commands/git_commands/github.go相当。GitHub以外のホスティングは未対応、
-- forkからのPR判定(headRepositoryOwnerの突き合わせ)も自分のリポジトリ運用を想定して省略)
-- ══════════════════════════════════════════════

--- originのURLからgithub.com上のowner/repoを判定する。github.com以外は非対応でnilを返す
function M.github_repo_info(cb)
  M.run({ 'remote', 'get-url', 'origin' }, function(res)
    if res.code ~= 0 then cb(nil); return end
    local url = vim.trim(res.stdout or '')
    local owner, repo = url:match('github%.com[:/]([^/]+)/([^/]+)')
    if not owner then cb(nil); return end
    cb({ owner = owner, repo = (repo:gsub('%.git$', '')) })
  end, { dont_log = true })
end

--- 自前でトークンを保存/管理せず、gh CLIが保持している認証情報をそのまま使う。
--- ghが未インストール/未認証なら黒く失敗してnilを返す（PR表示機能が黙って無効になる）
function M.gh_auth_token(cb)
  vim.system({ 'gh', 'auth', 'token' }, { text = true }, function(res)
    vim.schedule(function() cb(res.code == 0 and vim.trim(res.stdout or '') or nil) end)
  end)
end

--- pkg/commands/git_commands/github.go fetchPullRequestsQueryと同じ形
--- (ブランチ1つにつきheadRefNameで絞ったサブクエリを1本、まとめて1リクエストにする)
--- でGitHub GraphQL APIに問い合わせ、node一覧を返す。isDraftはsetCommitStatuses同様に
--- state側へ畳み込む(state=DRAFT)。取得失敗時は空配列を返すだけで、エラー通知はしない
--- （PR表示はlazygitでも失敗時にログだけでUIを止めない補助情報という位置づけ）
function M.fetch_prs(owner, repo, token, branch_names, cb)
  if #branch_names == 0 then cb({}); return end
  local var_decls = { '$owner: String!', '$repo: String!' }
  local variables = { owner = owner, repo = repo }
  local queries = {}
  for i, name in ipairs(branch_names) do
    local field, var = 'a' .. i, 'branch' .. i
    variables[var] = name
    table.insert(var_decls, '$' .. var .. ': String!')
    table.insert(queries, string.format(
      '%s: pullRequests(first: 5, headRefName: $%s, orderBy: {field: CREATED_AT, direction: DESC}) '
        .. '{ edges { node { title headRefName state number url isDraft headRepositoryOwner { login } } } }',
      field, var))
  end
  local query = string.format('query(%s) { repository(owner: $owner, name: $repo) { %s } }',
    table.concat(var_decls, ', '), table.concat(queries, ' '))

  local tmp = vim.fn.tempname()
  local hdr = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode({ query = query, variables = variables }) }, tmp)
  -- token を argv に載せると ps 等から見えるため、curl の -H @file で渡す
  vim.fn.writefile({ 'Authorization: token ' .. token }, hdr)
  vim.system({
    'curl', '-s', '-X', 'POST', 'https://api.github.com/graphql',
    '-H', '@' .. hdr,
    '-H', 'Content-Type: application/json',
    '--max-time', '10',
    '-d', '@' .. tmp,
  }, { text = true }, function(res)
    vim.schedule(function()
      vim.fn.delete(tmp)
      vim.fn.delete(hdr)
      if res.code ~= 0 or not res.stdout or res.stdout == '' then cb({}); return end
      local ok, decoded = pcall(vim.json.decode, res.stdout)
      local repository = ok and decoded and decoded.data and decoded.data.repository
      if not repository then cb({}); return end
      local prs = {}
      for i = 1, #branch_names do
        local pr_list = repository['a' .. i]
        for _, edge in ipairs((pr_list and pr_list.edges) or {}) do
          local node = edge.node
          node.state = (node.isDraft and node.state ~= 'CLOSED') and 'DRAFT' or node.state
          table.insert(prs, node)
        end
      end
      cb(prs)
    end)
  end)
end

-- ══════════════════════════════════════════════
-- PR（gh CLI）
-- ══════════════════════════════════════════════

--- オープンなPR一覧を gh CLI で取得。extra_args でフィルタ(--author/--search等)を足せる。
--- gh未インストール/未認証/GitHub以外なら空配列。
--- statusCheckRollup(個々のCheckRun/StatusContextの配列)を、GitHubのUIと同じ1つの
--- 状態へ畳む。優先度は「失敗 > 進行中 > 成功」。チェックが1つも無ければ nil。
---   CheckRun     : status が COMPLETED でなければ進行中。COMPLETEDなら conclusion で判定
---                  (SUCCESS/NEUTRAL/SKIPPED=成功、それ以外=失敗)
---   StatusContext: state で判定 (SUCCESS=成功、PENDING/EXPECTED=進行中、FAILURE/ERROR=失敗)
function M.pr_check_state(checks)
  if type(checks) ~= 'table' or #checks == 0 then return nil end
  local fail, pending = false, false
  for _, c in ipairs(checks) do
    if c.__typename == 'StatusContext' then
      if c.state == 'FAILURE' or c.state == 'ERROR' then fail = true
      elseif c.state == 'PENDING' or c.state == 'EXPECTED' then pending = true end
    else -- CheckRun（__typename欠落時もこちら扱い）
      if c.status ~= 'COMPLETED' then
        pending = true
      else
        local con = c.conclusion
        if con ~= 'SUCCESS' and con ~= 'NEUTRAL' and con ~= 'SKIPPED' then fail = true end
      end
    end
  end
  if fail then return 'failure' end
  if pending then return 'pending' end
  return 'success'
end

function M.gh_pr_list(extra_args, cb)
  local cmd = {
    'gh', 'pr', 'list', '--limit', '50',
    '--json', 'number,title,state,author,headRefName,url,isDraft,updatedAt,statusCheckRollup',
  }
  for _, a in ipairs(extra_args or {}) do table.insert(cmd, a) end
  vim.system(cmd, { cwd = M.root, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or res.stdout == '' then cb({}); return end
      local ok, list = pcall(vim.json.decode, res.stdout)
      if not ok or type(list) ~= 'table' then cb({}); return end
      for _, pr in ipairs(list) do
        if pr.isDraft and pr.state == 'OPEN' then pr.state = 'DRAFT' end
        pr.checks = M.pr_check_state(pr.statusCheckRollup)
      end
      cb(list)
    end)
  end)
end

--- gh pr view の出力を「端末で見るのと同じ形（本文＋コメント＋色）」で取得する。
--- 非TTY(vim.system)だとコメントが落ちるため GH_FORCE_TTY で端末表示を強制し、ansiのまま返す。
function M.gh_pr_view(number, width, cb)
  vim.system(
    { 'gh', 'pr', 'view', tostring(number) },
    { cwd = M.root, text = true, env = { GH_FORCE_TTY = tostring(width or 80), GH_PAGER = 'cat' } },
    function(res)
      vim.schedule(function()
        cb(res.code == 0 and (res.stdout or '') or ('PR詳細の取得に失敗:\n' .. (res.stderr or '')))
      end)
    end
  )
end

function M.gh_pr_diff(number, cb)
  vim.system({ 'gh', 'pr', 'diff', tostring(number) }, { cwd = M.root, text = true }, function(res)
    vim.schedule(function() cb(res.code == 0 and (res.stdout or '') or '') end)
  end)
end

function M.gh_pr_web(number, cb)
  vim.system({ 'gh', 'pr', 'view', tostring(number), '--web' }, { cwd = M.root, text = true }, function(res)
    vim.schedule(function() if cb then cb(res) end end)
  end)
end

function M.gh_pr_checkout(number, cb)
  vim.system({ 'gh', 'pr', 'checkout', tostring(number) }, { cwd = M.root, text = true }, function(res)
    vim.schedule(function() cb(res) end)
  end)
end

-- ══════════════════════════════════════════════
-- ワークツリー
-- ══════════════════════════════════════════════

function M.worktrees(cb)
  M.run({ 'worktree', 'list', '--porcelain' }, function(res)
    local list = {}
    local current = nil
    for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
      if line == '' then
        current = nil
      else
        local key, val = line:match('^(%S+)%s*(.*)$')
        if key == 'worktree' then
          current = { path = val }
          table.insert(list, current)
        elseif current then
          if key == 'branch' then
            current.branch = val:gsub('^refs/heads/', '')
          elseif key == 'bare' then
            current.bare = true
          elseif key == 'detached' then
            current.detached = true
          elseif key == 'HEAD' then
            current.head = val:sub(1, 7)
          end
        end
      end
    end
    cb(list)
  end, { dont_log = true })
end

function M.worktree_add(path, branch_name, as_new_branch, cb)
  local args = { 'worktree', 'add' }
  if as_new_branch then
    table.insert(args, '-b')
    table.insert(args, branch_name)
    table.insert(args, path)
  else
    table.insert(args, path)
    if branch_name and branch_name ~= '' then table.insert(args, branch_name) end
  end
  M.run(args, cb)
end

function M.worktree_remove(path, force, cb)
  local args = { 'worktree', 'remove' }
  if force then table.insert(args, '--force') end
  table.insert(args, path)
  M.run(args, cb)
end

return M
