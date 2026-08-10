-- 作業ツリーの変更を「構造化された diff モデル」に変換する層。
--
-- git_panel/git.lua の diff_worktree_all と同じ考え方で raw unified diff を集める
-- (tracked/staged/unstaged は `git diff HEAD`、未追跡は `--no-index`)。
-- git_panel は raw テキストを delta に流して色付け表示するのが目的なので「ファイル境界」しか
-- 見ないが、こちらはブラウザ(difit 風)で行単位に描画し、行番号を指定してコメントを付けたいので、
-- hunk と各行の old/new 行番号まで持つモデルへパースする。
--
-- パーサ(M.parse)は純粋関数で、collect(git 呼び出し)とは分離してテストしやすくしている。

local M = {}

local function clean_diff_path(raw)
  if not raw or raw == '/dev/null' then return nil end
  raw = vim.trim(raw)
  if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then
    raw = raw:sub(2, -2)
  end
  return (raw:gsub('^[ab]/', ''))
end

-- `@@ -l,s +l,s @@ heading` をパースする。s(行数)は省略時 1(git のルール)。
local function parse_hunk_header(line)
  local old_start, old_lines, new_start, new_lines =
    line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
  if not old_start then return nil end
  return {
    old_start = tonumber(old_start),
    old_lines = old_lines ~= '' and tonumber(old_lines) or 1,
    new_start = tonumber(new_start),
    new_lines = new_lines ~= '' and tonumber(new_lines) or 1,
    header = line,
  }
end

--- raw unified diff を構造化モデルへ。
--- { files = { { path, old_path, new_path, status, added, deleted, binary,
---     hunks = { { header, old_start, old_lines, new_start, new_lines,
---       lines = { { type='context'|'add'|'del', content, old_line, new_line } } } } } } }
function M.parse(diff_text)
  local lines = vim.split(diff_text or '', '\n', { plain = true })
  local files = {}
  local current, hunk
  local old_no, new_no = 0, 0

  local function finish_file()
    if not current then return end
    current.path = current.new_path or current.old_path or current.fallback_path or '(unknown)'
    files[#files + 1] = current
    current, hunk = nil, nil
  end

  for _, line in ipairs(lines) do
    if line:match('^diff %-%-git ') then
      finish_file()
      current = {
        fallback_path = clean_diff_path(line:match(' b/(.+)$')),
        old_path = nil,
        new_path = nil,
        status = 'M',
        added = 0,
        deleted = 0,
        binary = false,
        hunks = {},
      }
      hunk = nil
    elseif current then
      local hh = parse_hunk_header(line)
      if hh then
        hunk = {
          header = hh.header,
          old_start = hh.old_start,
          old_lines = hh.old_lines,
          new_start = hh.new_start,
          new_lines = hh.new_lines,
          lines = {},
        }
        current.hunks[#current.hunks + 1] = hunk
        old_no, new_no = hh.old_start, hh.new_start
      elseif hunk then
        -- hunk 本体。ここでは `---`/`+++` はファイルヘッダではなく、`--`/`++` で
        -- 始まる中身の削除/追加行なので、先頭 1 文字だけで種別を判定する。
        local prefix = line:sub(1, 1)
        if prefix == '\\' then
          -- "\ No newline at end of file" はメタ行。行番号を進めない。
        elseif prefix == ' ' then
          hunk.lines[#hunk.lines + 1] =
            { type = 'context', content = line:sub(2), old_line = old_no, new_line = new_no }
          old_no, new_no = old_no + 1, new_no + 1
        elseif prefix == '-' then
          hunk.lines[#hunk.lines + 1] =
            { type = 'del', content = line:sub(2), old_line = old_no, new_line = vim.NIL }
          old_no = old_no + 1
          current.deleted = current.deleted + 1
        elseif prefix == '+' then
          hunk.lines[#hunk.lines + 1] =
            { type = 'add', content = line:sub(2), old_line = vim.NIL, new_line = new_no }
          new_no = new_no + 1
          current.added = current.added + 1
        end
      else
        -- 最初の @@ より前のヘッダ領域。ここだけで status とパスを確定する。
        if line:match('^new file mode ') then
          current.status = 'A'
        elseif line:match('^deleted file mode ') then
          current.status = 'D'
        elseif line:match('^rename from ') or line:match('^rename to ') then
          current.status = 'R'
        elseif line:match('^Binary files ') or line:match('^GIT binary patch') then
          current.binary = true
        end
        local old = line:match('^%-%-%- (.+)$')
        local new = line:match('^%+%+%+ (.+)$')
        if old then
          current.old_path = clean_diff_path(old)
          if not current.old_path then current.status = 'A' end
        elseif new then
          current.new_path = clean_diff_path(new)
          if not current.new_path then current.status = 'D' end
        end
      end
    end
  end

  finish_file()
  return { files = files }
end

-- git_panel/git.lua と同じく `git status --porcelain` から未追跡ファイルを拾う。
local function untracked_paths(status_out)
  local paths = {}
  for _, line in ipairs(vim.split(status_out or '', '\n', { plain = true })) do
    local path = line:match('^%?%? (.+)$')
    if path then
      if path:sub(1, 1) == '"' and path:sub(-1) == '"' then path = path:sub(2, -2) end
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

local function git(root, args, cb)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function() cb(res.stdout or '', res.code or 0) end)
  end)
end

-- origin の既定ブランチを `git symbolic-ref refs/remotes/origin/HEAD` の出力から解決する。
-- 例: "refs/remotes/origin/main\n" -> "origin/main"。取れなければ nil。純粋関数(テスト用)。
local function parse_default_branch(symref_out)
  local name = tostring(symref_out or ''):match('refs/remotes/origin/([^%s]+)')
  if not name or name == '' then return nil end
  return 'origin/' .. name
end

-- HEAD の比較元(デフォルトブランチ)を1つ解決する。difit の getOriginDefaultBranch/
-- getDefaultBranch 相当: origin/HEAD → origin/main → origin/master → ローカル main → master
-- の順に存在するものを採用する。どれも無ければ nil(= committed ビューは出せない)。
local function resolve_base_ref(root, cb)
  git(root, { 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD' }, function(out, code)
    local ref = code == 0 and parse_default_branch(out) or nil
    if ref then cb(ref); return end
    local candidates = { 'origin/main', 'origin/master', 'main', 'master' }
    local i = 1
    local function step()
      local c = candidates[i]
      i = i + 1
      if not c then cb(nil); return end
      git(root, { 'rev-parse', '--verify', '--quiet', c .. '^{commit}' }, function(_, rc)
        if rc == 0 then cb(c) else step() end
      end)
    end
    step()
  end)
end

-- base(ref) と HEAD の分岐点 SHA。difit の resolveBaseCommitish(merge-base) 相当。
local function resolve_merge_base(root, base_ref, cb)
  git(root, { 'merge-base', base_ref, 'HEAD' }, function(out, code)
    if code ~= 0 then cb(nil); return end
    local sha = vim.trim(out or '')
    cb(sha ~= '' and sha or nil)
  end)
end

--- committed ビュー: merge-base(<default>, HEAD) と HEAD の差分(= デフォルトブランチから
--- 分岐した後にこのブランチが積んだコミット。プッシュ済み・未マージのコミットも含む = PR 相当)。
--- difit と同じく `..`/`...` は使わず、merge-base を SHA へ解決してから 2 引数の
--- `git diff <mergeBaseSha> HEAD` を叩く。コミット間比較なので未追跡/未コミットは含めない
--- (未コミット分は uncommitted ビューの担当。両者は HEAD を境に重ならない)。
--- cb(diff_text, base_meta)。base_meta = { ref, merge_base } / デフォルトブランチが無ければ nil。
function M.collect_committed(root, cb)
  resolve_base_ref(root, function(base_ref)
    if not base_ref then
      cb('', nil)
      return
    end
    resolve_merge_base(root, base_ref, function(sha)
      if not sha then
        cb('', { ref = base_ref, merge_base = vim.NIL })
        return
      end
      git(root, { 'diff', sha, 'HEAD', '--' }, function(diff_out)
        cb(diff_out or '', { ref = base_ref, merge_base = sha })
      end)
    end)
  end)
end

-- 作業ツリー系のビューに対応する git diff コマンドと、未追跡ファイルを含めるか。
--   uncommitted … HEAD との差分(staged+unstaged 全部 = 未コミット変更)。未追跡も含める(既定・コメント面)
--   unstaged    … index との差分(まだステージしていない変更)。未追跡も含める(uncommitted の内訳・閲覧のみ)
--   staged      … index と HEAD の差分(ステージ済み)。未追跡はステージ対象外なので含めない(uncommitted の内訳・閲覧のみ)
-- ("all" は uncommitted の旧名。後方互換のためエイリアスとして残す。)
local VIEWS = {
  uncommitted = { args = { 'diff', 'HEAD', '--' },     untracked = true },
  unstaged    = { args = { 'diff', '--' },             untracked = true },
  staged      = { args = { 'diff', '--cached', '--' }, untracked = false },
}
VIEWS.all = VIEWS.uncommitted -- 旧名エイリアス

--- 指定ビューの raw unified diff を集める。git_panel/git.lua diff_worktree_all と同方針。
--- view 省略時は 'uncommitted'(後方互換: collect(root, cb) でも呼べる)。
function M.collect(root, view, cb)
  if type(view) == 'function' then cb = view; view = 'uncommitted' end
  local spec = VIEWS[view] or VIEWS.uncommitted
  git(root, spec.args, function(diff_out)
    local parts = {}
    if diff_out ~= '' then parts[#parts + 1] = diff_out end
    if not spec.untracked then
      cb(table.concat(parts, '\n'))
      return
    end
    git(root, { 'status', '--porcelain' }, function(status_out)
      local paths = untracked_paths(status_out)
      local i = 1
      local function step()
        local path = paths[i]
        i = i + 1
        if not path then
          cb(table.concat(parts, '\n'))
          return
        end
        if vim.fn.isdirectory(root .. '/' .. path) == 1 then
          step()
          return
        end
        git(root, { 'diff', '--no-index', '--', '/dev/null', path }, function(out)
          if out ~= '' then parts[#parts + 1] = out end
          step()
        end)
      end
      step()
    end)
  end)
end

--- collect + parse。cb(model)。view 省略時は 'uncommitted'。
function M.build(root, view, cb)
  if type(view) == 'function' then cb = view; view = 'uncommitted' end
  M.collect(root, view, function(diff_text)
    cb(M.parse(diff_text))
  end)
end

--- uncommitted / unstaged / staged / committed の 4 ビューをまとめてビルドして
--- cb({ uncommitted=, unstaged=, staged=, committed=, branch_base= }) を返す。
--- uncommitted は作業ツリー vs HEAD(未コミット変更)、committed はデフォルトブランチとの merge-base 差分(collect_committed)。
--- branch_base = 比較元 { ref, merge_base } / デフォルトブランチが無ければ nil。
function M.build_views(root, cb)
  M.build(root, 'uncommitted', function(uncommitted)
    M.build(root, 'unstaged', function(unstaged)
      M.build(root, 'staged', function(staged)
        M.collect_committed(root, function(committed_text, base_meta)
          cb({
            uncommitted = uncommitted,
            unstaged = unstaged,
            staged = staged,
            committed = M.parse(committed_text),
            branch_base = base_meta,
          })
        end)
      end)
    end)
  end)
end

M._private = {
  clean_diff_path = clean_diff_path,
  parse_hunk_header = parse_hunk_header,
  untracked_paths = untracked_paths,
  parse_default_branch = parse_default_branch,
}

return M
