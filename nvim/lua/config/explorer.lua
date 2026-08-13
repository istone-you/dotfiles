-- explorer（右パネル・単一カラムのファイラ）

local M = {}

local win, buf
local origin_win
local cwd
local initialized = false
local rows = {}
local cursor_mem = {}
local tree_cursor_mem = {}
local selection = {}
local clipboard = nil
local show_hidden = true
-- git 管理外（.gitignore された node_modules / dist 等）を一覧に出すか。i で切替
local show_ignored = true
local filter = ''
-- 再帰ファイル/パス検索(/)。fd で cwd 相対パスを絞り込み、結果を explorer バッファ内へ
-- view_mode に従ってインクリメンタル表示する。検索中は専用の入力欄(live_prompt)へ
-- フォーカスがあり、C-j/C-k で結果内を移動、<CR> で確定、<Esc> で解除する。
local search_active = false
local search_query = ''
local search_paths = {} -- fd が返した絶対パス（ファイル）
local search_sel = 1    -- 選択中の行（rows 内 1 始まり）
local search_job = nil  -- 実行中の fd ジョブ id
local search_gen = 0    -- 検索世代。速い連続入力で古いジョブの結果が後勝ちするのを防ぐ
local view_mode = 'list' -- 'list': 単一カラムのリスト / 'tree': 折りたたみツリー
local tree_expanded = {} -- [path] = true
-- 圧縮表示（VSCode の Compact Folders 相当）。子がディレクトリ1つだけの連鎖を
-- "a/b/c" のように1行へ畳む。ツリー表示専用。c で切替
local compact_dirs = false

-- 全画面表示(:Explorer!)の時だけ有効になるプレビューパネル。通常のサイドパネル表示は
-- 幅が狭く単一カラムのままにする（トップのコメント通り）
local preview_win, preview_buf
local last_preview_path = nil
local is_fullscreen = false
local sidebar_side = 'left' -- サイドバー表示位置（'left' / 'right'）。< / > で切替、以降も維持

local git_status = {}      -- [リポジトリルート相対path] = GIT_CODES（git statusは常にルート相対で返るため）
local git_status_cwd = nil -- git_statusがどのcwdのものか
local git_repo_root = nil  -- git_statusに対応するリポジトリルート（絶対path）
local git_status_dirty = false
-- node_modules 等が別マウント（FS境界）だと、その中から git を叩くと境界で
-- 探索が止まり上位の .git を見つけられない。境界を越えて探索させる。
local GIT_ENV = { GIT_DISCOVERY_ACROSS_FILESYSTEM = '1' }
local render -- 前方宣言（gitステータス取得の非同期コールバックから参照するため）
local render_preview -- 前方宣言（render()の末尾から参照するため）
local teardown_ui -- 前方宣言（open_selectedから参照するため）
local refresh -- 前方宣言（fs watcher から参照するため）
local start_watch -- 前方宣言（render 末尾から参照するため）
local stop_watch -- 前方宣言
local start_git_watch -- 前方宣言（git status 取得後に .git を監視するため）
local stop_git_watch -- 前方宣言

-- yazi の yazi-watcher 相当: 表示中ディレクトリを fs_event で監視し、外部変更を一覧へ反映する
local fs_event = nil
local watched_path = nil
local watch_debounce = nil
local watch_poll = nil
local watch_stamp = nil
local WATCH_DEBOUNCE_MS = 150

-- nvim-tree 方式: リポジトリの .git ディレクトリも監視する。表示中ディレクトリの監視だけだと、
-- 別ペインや git パネルでの add / commit / checkout など「作業ツリーは変わらず .git だけ変わる操作」を
-- 取りこぼし、ディレクトリ移動するまで git 表示が古いままになるため。
local git_fs_event = nil
local git_watched_dir = nil
local git_watch_debounce = nil
local git_watch_poll = nil
local git_watch_stamp = nil
-- .git 配下でこれらが変わったときだけ再取得する(nvim-tree の WATCHED_FILES 相当)。
-- watchman 等が頻繁に書く他ファイルでの無駄な再取得を避ける。
local GIT_WATCHED_FILES = {
  ['HEAD'] = true,       -- チェックアウト等
  ['HEAD.lock'] = true,  -- revert 等で HEAD が更新されないケースの検知
  ['index'] = true,      -- ステージ(add/reset)・commit
  ['config'] = true,     -- 設定変更
  ['FETCH_HEAD'] = true, -- fetch
}
local hl_ns = vim.api.nvim_create_namespace('explorer_hl')
local augrp = vim.api.nvim_create_augroup('explorer', { clear = true })

local ENTRY_OFFSET = 2
local PANEL_WIDTH = 48

local function fs_stamp(path)
  local st = path and vim.uv.fs_stat(path) or nil
  if not st then return nil end
  local mtime = st.mtime or {}
  return table.concat({
    tostring(st.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
  }, ':')
end

local function user_facing_path(path)
  local normalized = tostring(path or ''):gsub('^/private/var/', '/var/')
  return normalized
end

-- ヘッダー行（パス表示・空行）には行番号を出さない
_G.__explorer_statuscolumn = function()
  if vim.v.lnum <= ENTRY_OFFSET then
    return ''
  end
  -- カーソル行はヘッダー分を引いた「一覧内での番号」を表示（他行は相対距離のまま）
  local num = vim.v.relnum == 0 and (vim.v.lnum - ENTRY_OFFSET) or vim.v.relnum
  return string.format('%3d ', num)
end

-- ══════════════════════════════════════════════
-- アイコン（拡張子ごと・Nerd Fonts）
-- 定義は config.util.file_icons に集約（explorer/git_panel/tabline で共有）
-- ══════════════════════════════════════════════

local file_icons = require('config.util.file_icons')

local FOLDER_ICON = file_icons.FOLDER
local FOLDER_OPEN_ICON = 0xe5fe -- nvim-tree.lua default folder.open: ""
local TREE_ARROW_CLOSED = '' -- nvim-tree.lua default folder.arrow_closed
local TREE_ARROW_OPEN = ''   -- nvim-tree.lua default folder.arrow_open
local function icon_char(code) return file_icons.char(code) end
local function get_icon(name, isdir, path) return file_icons.get(name, isdir, path) end

-- ══════════════════════════════════════════════
-- gitステータス（yazi/plugins/git.yazi と同じ判定・表示ロジック）
-- ══════════════════════════════════════════════

local GIT_CODES = {
  ignored = 6, untracked = 5, modified = 4, added = 3, deleted = 2, updated = 1, clean = 0,
}
local GIT_PATTERNS = {
  { '!$', GIT_CODES.ignored },
  { '?$', GIT_CODES.untracked },
  { '[MT]', GIT_CODES.modified },
  { '[AC]', GIT_CODES.added },
  { 'D', GIT_CODES.deleted },
  { 'U', GIT_CODES.updated },
  { '[AD][AD]', GIT_CODES.updated },
}
local GIT_SIGNS = {
  [GIT_CODES.ignored] = '  ', [GIT_CODES.untracked] = '? ', [GIT_CODES.modified] = 'M ',
  [GIT_CODES.added] = 'A ', [GIT_CODES.deleted] = 'D ', [GIT_CODES.updated] = 'U ',
}
local GIT_HL = {
  [GIT_CODES.ignored] = 'ExplorerGitIgnored', [GIT_CODES.untracked] = 'ExplorerGitUntracked',
  [GIT_CODES.modified] = 'ExplorerGitModified', [GIT_CODES.added] = 'ExplorerGitAdded',
  [GIT_CODES.deleted] = 'ExplorerGitDeleted', [GIT_CODES.updated] = 'ExplorerGitUpdated',
}

local function match_status_line(line)
  local signs = line:sub(1, 2)
  for _, p in ipairs(GIT_PATTERNS) do
    if signs:find(p[1]) then
      local path = line:sub(4, 4) == '"' and line:sub(5, -2) or line:sub(4)
      return p[2], path
    end
  end
  return nil, nil
end

--- git statusは常にリポジトリルート相対パスで返るため、entry.pathをルート相対に
--- 変換してから比較する。ファイルは完全一致、ディレクトリは配下(prefix一致)の
--- 最悪ステータスを継承する
-- そのエントリのgitステータス。ディレクトリは中身を集約しない（自身のコードのみ）。
-- ただし未追跡/ignoreのディレクトリは git status が "dir/" 一つに畳むため、
-- その配下の個々のエントリは git_status に現れない。祖先が畳まれていれば継承する。
local function entry_git_code(entry)
  if not git_repo_root then return nil end
  local rel = entry.path:sub(#git_repo_root + 2)
  local own = entry.isdir and git_status[rel .. '/'] or git_status[rel]
  if own then return own end
  local parent = rel
  while true do
    local slash = parent:match('^(.*)/[^/]*$')
    if not slash then break end
    parent = slash
    local code = git_status[parent .. '/']
    if code then return code end
  end
  return nil
end

--- show_ignored=false のとき、git 管理外（ignore）エントリを一覧から隠すか。
--- gitステータス未取得（別cwd/非gitリポジトリ）の間は隠さない（取得完了後に再render
--- されるのでそこで反映される）。
--- また cwd 自体が ignore 配下（node_modules の中へ入った等）だと配下が全部 ignore に
--- なって一覧が空になるため、その場合は絞り込まない。
local function git_hidden_active()
  if show_ignored then return false end
  if not git_repo_root or git_status_cwd ~= cwd then return false end
  return entry_git_code({ path = cwd, isdir = true }) ~= GIT_CODES.ignored
end

--- git 管理外として隠す対象か。.git 自体は ignore ではなく「ワークツリー外」なので
--- git status には一切現れない。ユーザから見れば同じ「git 管理しないディレクトリ」なので
--- ここで明示的に含める。
local function is_git_unmanaged(entry)
  if entry.name == '.git' then return true end
  return entry_git_code(entry) == GIT_CODES.ignored
end

local function refresh_git_status(target_cwd)
  vim.system(
    { 'git', 'rev-parse', '--show-toplevel', '--absolute-git-dir' },
    { cwd = target_cwd, text = true, env = GIT_ENV },
    function(root_res)
    vim.schedule(function()
      if root_res.code ~= 0 then
        git_status, git_status_cwd, git_repo_root = {}, target_cwd, nil
        if cwd == target_cwd then
          stop_git_watch()
          render()
        end
        return
      end
      -- 1行目: リポジトリルート、2行目: 実 .git ディレクトリ(worktree/submodule では .git 実体は別)
      local parts = vim.split(vim.trim(root_res.stdout or ''), '\n', { plain = true })
      local repo_root = parts[1]
      local git_dir = parts[2]
      vim.system({
        'git', '--no-optional-locks', '-c', 'core.quotePath=', 'status',
        '--porcelain', '-unormal', '--no-renames', '--ignored=matching', '.',
      }, { cwd = target_cwd, text = true, env = GIT_ENV }, function(res)
        vim.schedule(function()
          local map = {}
          for line in (res.stdout or ''):gmatch('[^\r\n]+') do
            local code, path = match_status_line(line)
            if code and path then map[path] = code end
          end
          git_status, git_status_cwd, git_repo_root = map, target_cwd, repo_root
          if cwd == target_cwd then
            start_git_watch(git_dir)
            render()
          end
        end)
      end)
    end)
  end)
end

-- ══════════════════════════════════════════════
-- 一覧取得・表示
-- ══════════════════════════════════════════════

-- パス連結。cwd が '/'（ルート）のときに '//app' のような重複スラッシュを
-- 作らないようにする（重複すると :h での親移動時に累積していく）。
local function join_path(dir, name)
  if dir == '/' then return '/' .. name end
  return dir .. '/' .. name
end

local function build_display_path(path)
  local home = vim.fn.expand('~')
  if path == home then return '~' end
  if path:sub(1, #home + 1) == home .. '/' then
    return '~' .. path:sub(#home + 1)
  end
  return path
end

local function list_dir(path)
  local names = vim.fn.readdir(path) or {}
  local list = {}
  local hide_ignored = git_hidden_active()
  for _, name in ipairs(names) do
    if show_hidden or name:sub(1, 1) ~= '.' then
      if filter == '' or name:lower():find(filter:lower(), 1, true) then
        local full = join_path(path, name)
        local entry = { name = name, path = full, isdir = vim.fn.isdirectory(full) == 1 }
        local st = vim.uv.fs_lstat(full)
        if st and st.type == 'link' then
          entry.link = vim.uv.fs_readlink(full)
        end
        if not (hide_ignored and is_git_unmanaged(entry)) then
          table.insert(list, entry)
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.isdir ~= b.isdir then return a.isdir end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

local function build_tree_rows(path)
  local list = {}

  local function walk(dir, depth)
    for _, entry in ipairs(list_dir(dir)) do
      -- 圧縮表示: 子がディレクトリ1つだけのディレクトリは、その連鎖を "a/b/c" のように
      -- 1行へ畳む（VSCode の Compact Folders 相当）。畳んだ末端 tail を実体として扱い、
      -- 展開状態やgit判定は tail.path をキーにする。
      if compact_dirs and entry.isdir and not entry.link then
        local names = { entry.name }
        local tail = entry
        while true do
          local children = list_dir(tail.path)
          if #children == 1 and children[1].isdir and not children[1].link then
            tail = children[1]
            table.insert(names, tail.name)
          else
            break
          end
        end
        if #names > 1 then
          entry = { name = tail.name, path = tail.path, isdir = true, display_name = table.concat(names, '/') }
        end
      end
      entry.depth = depth
      entry.expandable = entry.isdir and not entry.link
      table.insert(list, entry)
      if entry.expandable and tree_expanded[entry.path] then
        walk(entry.path, depth + 1)
      end
    end
  end

  walk(path, 0)
  return list
end

-- 再帰検索結果を list 表示用の行へ変換する（cwd 相対パスのフラット一覧）。
local function build_search_list_rows()
  local out = {}
  local prefix = cwd == '/' and '/' or (cwd .. '/')
  for _, abs in ipairs(search_paths) do
    local rel = (abs:sub(1, #prefix) == prefix) and abs:sub(#prefix + 1) or abs
    table.insert(out, {
      name = vim.fn.fnamemodify(abs, ':t'),
      path = abs,
      isdir = false,
      display_name = rel,
    })
  end
  return out
end

-- 再帰検索結果を tree 表示用の行へ変換する。一致ファイルの祖先ディレクトリだけを残し、
-- すべて展開済みの状態で列挙する（build_tree_rows と同じ「ディレクトリ先・名前順」）。
local function build_search_tree_rows()
  local prefix = cwd == '/' and '/' or (cwd .. '/')
  local children = {} -- [dir abs] = { [child abs] = true }
  local isdir = {}    -- [abs] = bool
  local function ensure(d) children[d] = children[d] or {} end
  ensure(cwd)
  for _, abs in ipairs(search_paths) do
    if abs:sub(1, #prefix) == prefix then
      local parts = vim.split(abs:sub(#prefix + 1), '/', { plain = true })
      local cur = cwd
      for i = 1, #parts do
        local child = (cur == '/') and ('/' .. parts[i]) or (cur .. '/' .. parts[i])
        ensure(cur)
        children[cur][child] = true
        if i < #parts then
          isdir[child] = true
          ensure(child)
        elseif isdir[child] == nil then
          isdir[child] = false
        end
        cur = child
      end
    end
  end
  local out = {}
  local function emit(dir, depth)
    local keys = {}
    for k in pairs(children[dir] or {}) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      if isdir[a] ~= isdir[b] then return isdir[a] end
      return a:lower() < b:lower()
    end)
    for _, k in ipairs(keys) do
      table.insert(out, {
        name = vim.fn.fnamemodify(k, ':t'),
        path = k,
        isdir = isdir[k],
        depth = depth,
        expandable = isdir[k],
        display_name = vim.fn.fnamemodify(k, ':t'),
      })
      if isdir[k] then emit(k, depth + 1) end
    end
  end
  emit(cwd, 0)
  return out
end

local function remember_entry(entry)
  if not entry then return end
  if view_mode == 'tree' then
    tree_cursor_mem[cwd] = entry.path
  else
    cursor_mem[cwd] = entry.name
  end
end

local function top_child_name(path)
  if not path or not cwd then return nil end
  local prefix = cwd == '/' and '/' or (cwd .. '/')
  if path:sub(1, #prefix) ~= prefix then return nil end
  local rest = path:sub(#prefix + 1)
  return rest:match('^[^/]+')
end

local function is_under_cwd(path)
  if not path or not cwd then return false end
  if cwd == '/' then return path:sub(1, 1) == '/' and path ~= '/' end
  return path:sub(1, #cwd + 1) == cwd .. '/'
end

local function is_under_dir(path, dir)
  if not path or not dir then return false end
  if dir == '/' then return path:sub(1, 1) == '/' and path ~= '/' end
  return path:sub(1, #dir + 1) == dir .. '/'
end

local function status_text()
  local parts = {}
  local sel_count = vim.tbl_count(selection)
  if sel_count > 0 then table.insert(parts, sel_count .. '選択') end
  if clipboard then
    table.insert(parts, (clipboard.mode == 'copy' and 'コピー' or 'カット') .. ':' .. #clipboard.paths)
  end
  if not show_hidden then table.insert(parts, 'hidden: off') end
  if not show_ignored then table.insert(parts, 'ignored: off') end
  if filter ~= '' then table.insert(parts, 'filter:' .. filter) end
  if search_active then table.insert(parts, 'search:' .. search_query) end
  if #parts == 0 then return '' end
  return '  [' .. table.concat(parts, ' | ') .. ']'
end

function render()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  if search_active then
    rows = view_mode == 'tree' and build_search_tree_rows() or build_search_list_rows()
  else
    rows = view_mode == 'tree' and build_tree_rows(cwd) or list_dir(cwd)
  end

  if git_status_cwd ~= cwd or git_status_dirty then
    git_status_dirty = false
    refresh_git_status(cwd)
  end
  local git_ready = git_status_cwd == cwd

  local lines = {}
  local hl_queue = {}
  local function hl(lnum, group, cs, ce)
    table.insert(hl_queue, { lnum, group, cs or 0, ce or -1 })
  end

  local mode_label = view_mode == 'tree' and (compact_dirs and 'tree/compact' or 'tree') or 'list'
  table.insert(lines, ' ' .. icon_char(FOLDER_ICON) .. ' ' .. build_display_path(cwd) .. '  [' .. mode_label .. ']' .. status_text())
  hl(0, 'ExplorerHeader')
  table.insert(lines, '')

  for _, entry in ipairs(rows) do
    -- 検索中はツリーを全展開状態で見せる（開いた矢印・開いたフォルダアイコン）
    local node_open = tree_expanded[entry.path] or search_active
    local icon = view_mode == 'tree' and entry.expandable and node_open
      and icon_char(FOLDER_OPEN_ICON) or get_icon(entry.name, entry.isdir, entry.path)
    -- yazi の marker_symbol("│") 相当: 選択行は左端に色付きバー、文字色は変えない
    local marker = selection[entry.path] and '│' or ' '
    local prefix
    local arrow_cs, arrow_ce
    if view_mode == 'tree' then
      local indent = string.rep('  ', entry.depth or 0)
      local arrow = entry.expandable and (node_open and TREE_ARROW_OPEN or TREE_ARROW_CLOSED) or ' '
      local tree_marker = selection[entry.path] and marker or ''
      prefix = tree_marker .. indent .. arrow .. ' '
      if entry.expandable then
        arrow_cs = #tree_marker + #indent
        arrow_ce = arrow_cs + #arrow
      end
    else
      prefix = marker .. ' '
    end
    local line = prefix .. icon .. '  ' .. (entry.display_name or entry.name)
    -- シンボリックリンクは yazi 風に「名前 -> ターゲット」を表示する
    local link_cs, link_ce
    if entry.link then
      link_cs = #line
      line = line .. ' -> ' .. entry.link
      link_ce = #line
    end
    local git_code = git_ready and entry_git_code(entry) or nil
    local sign = git_code and GIT_SIGNS[git_code]
    if sign and sign ~= '' then
      line = line .. '  ' .. sign
    end
    table.insert(lines, line)
    local lnum = #lines - 1
    -- 薄字化するのは git 管理外＝ignore のみ（新規/未追跡ファイルは薄くしない）
    local unmanaged = git_code == GIT_CODES.ignored
    if entry.isdir then
      hl(lnum, 'ExplorerDir')
    else
      hl(lnum, 'ExplorerFile')
    end
    -- git 管理外（ignore）は行全体を薄く表示する（VSCode風。未追跡は薄くしない）
    -- 選択バー自体は薄くせず残す
    if unmanaged then
      hl(lnum, 'ExplorerDimmed', #prefix, -1)
    end
    if selection[entry.path] then
      hl(lnum, 'ExplorerSelected', 0, #marker)
    end
    if arrow_cs then
      hl(lnum, 'ExplorerTreeArrow', arrow_cs, arrow_ce)
    end
    if clipboard and clipboard.mode == 'cut' then
      for _, p in ipairs(clipboard.paths) do
        if p == entry.path then hl(lnum, 'ExplorerCut', #prefix, -1) end
      end
    end
    if sign and sign ~= '' and GIT_HL[git_code] then
      hl(lnum, GIT_HL[git_code], #line - #sign, #line)
    end
    -- 薄字化した行はアイコンのブランド色を付けない（全体を薄く保つ）
    if not unmanaged then
      local icon_group = file_icons.icon_hl(entry.name, entry.isdir, entry.path)
      if icon_group then
        hl(lnum, icon_group, #prefix, #prefix + #icon)
      end
    end
    if link_cs then
      hl(lnum, 'ExplorerSymlink', link_cs, link_ce)
    end
  end

  if #rows == 0 then
    table.insert(lines, '  (空)')
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for _, h in ipairs(hl_queue) do
    vim.api.nvim_buf_add_highlight(buf, hl_ns, h[2], h[1], h[3], h[4])
  end

  -- 検索中は入力欄側にフォーカスがあるので panel_focus が explorer の cursorline を落とす。
  -- だが検索は C-j/C-k で選ぶ操作なので、選択行が見えないと何が開くのか分からない。
  -- ここで戻しておく（入力欄を閉じたときの復元は panel_focus 側が面倒を見る）。
  -- 候補が無いときは消しておく（選べる行が無いのに帯だけ残ると紛らわしい）。
  if search_active and win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].cursorline = #rows > 0
  end

  if win and vim.api.nvim_win_is_valid(win) and #rows > 0 then
    local target_row
    if search_active then
      -- 検索中は入力欄側にフォーカスがあるため、選択行(search_sel)へカーソルだけ移す
      search_sel = math.max(1, math.min(search_sel, #rows))
      target_row = ENTRY_OFFSET + search_sel
    else
      target_row = ENTRY_OFFSET + 1
      if view_mode == 'tree' then
        local remembered = tree_cursor_mem[cwd]
        for i, entry in ipairs(rows) do
          if entry.path == remembered then
            target_row = ENTRY_OFFSET + i
            break
          end
        end
      else
        local remembered = cursor_mem[cwd]
        if remembered then
          for i, entry in ipairs(rows) do
            if entry.name == remembered then
              target_row = ENTRY_OFFSET + i
              break
            end
          end
        end
      end
      target_row = math.min(target_row, ENTRY_OFFSET + #rows)
    end
    pcall(vim.api.nvim_win_set_cursor, win, { target_row, 0 })
  end

  start_watch(cwd)
  render_preview()
end

local function entry_at_cursor()
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return rows[row - ENTRY_OFFSET]
end

-- ══════════════════════════════════════════════
-- プレビュー（全画面表示のみ）
-- ══════════════════════════════════════════════

local function recreate_preview_buf()
  local old = preview_buf
  preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[preview_buf].buftype = 'nofile'
  vim.bo[preview_buf].buflisted = false
  -- nvim_win_set_bufは対象ウィンドウがフォーカスされていなくてもBufEnterを発火し、
  -- その一瞬だけ「カレントバッファ」がこのバッファとして扱われる。hidden_cursorの
  -- 判定(vim.b.hide_cursor)がその瞬間に走るため、差し込む前に必ずマークしておく
  -- （後からmark_bufferすると一瞬フラグが立っていない状態でBufEnterが飛び、
  -- 実際にフォーカスしている一覧側のカーソルが復活して見えるちらつきが起きていた）
  require('config.hidden_cursor').mark_buffer(preview_buf)
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_set_buf(preview_win, preview_buf)
  end
  if old and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
end

local function set_preview_title(text)
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_set_config(preview_win, { title = ' ' .. text .. ' ', title_pos = 'center' })
  end
end

local preview_hl_ns = vim.api.nvim_create_namespace('explorer_preview_hl')

-- highlights: { {lnum0, group, col_start, col_end}, ... }（任意）
local function set_preview_lines(lines, filetype, highlights, syntax)
  if not (preview_buf and vim.api.nvim_buf_is_valid(preview_buf)) then return end
  if vim.bo[preview_buf].buftype ~= 'nofile' then recreate_preview_buf() end
  vim.bo[preview_buf].modifiable = true
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
  vim.bo[preview_buf].filetype = filetype or ''
  vim.bo[preview_buf].syntax = syntax or filetype or ''
  vim.bo[preview_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(preview_buf, preview_hl_ns, 0, -1)
  for _, h in ipairs(highlights or {}) do
    vim.api.nvim_buf_add_highlight(preview_buf, preview_hl_ns, h[2], h[1], h[3], h[4])
  end
end

-- ディレクトリプレビュー。本体一覧(list_dir)と同じ並び・色で lines と highlights を返す。
local function preview_dir_lines(path)
  local names = vim.fn.readdir(path) or {}
  local entries = {}
  local hide_ignored = git_hidden_active()
  for _, name in ipairs(names) do
    if show_hidden or name:sub(1, 1) ~= '.' then
      local full = join_path(path, name)
      local e = { name = name, path = full, isdir = vim.fn.isdirectory(full) == 1 }
      local st = vim.uv.fs_lstat(full)
      if st and st.type == 'link' then e.link = vim.uv.fs_readlink(full) end
      if not (hide_ignored and is_git_unmanaged(e)) then
        entries[#entries + 1] = e
      end
    end
  end
  -- list_dir と同じ: ディレクトリが先、その後は名前順
  table.sort(entries, function(a, b)
    if a.isdir ~= b.isdir then return a.isdir end
    return a.name:lower() < b.name:lower()
  end)
  if #entries == 0 then return { '  (空)' }, {} end

  local git_ready = git_status_cwd == cwd
  local lines, hls = {}, {}
  for _, e in ipairs(entries) do
    local icon = get_icon(e.name, e.isdir, e.path)
    local line = '  ' .. icon .. '  ' .. e.name
    local link_cs, link_ce
    if e.link then
      link_cs = #line
      line = line .. ' -> ' .. e.link
      link_ce = #line
    end
    lines[#lines + 1] = line
    local lnum = #lines - 1
    local unmanaged = git_ready and entry_git_code(e) == GIT_CODES.ignored or false
    hls[#hls + 1] = { lnum, e.isdir and 'ExplorerDir' or 'ExplorerFile', 0, -1 }
    if unmanaged then
      hls[#hls + 1] = { lnum, 'ExplorerDimmed', 0, -1 }
    else
      local ig = file_icons.icon_hl(e.name, e.isdir, e.path)
      if ig then hls[#hls + 1] = { lnum, ig, 2, 2 + #icon } end
    end
    if link_cs then hls[#hls + 1] = { lnum, 'ExplorerSymlink', link_cs, link_ce } end
  end
  return lines, hls
end

local function preview_filetype(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if ok then return ft end
  return nil
end

local function preview_syntax(filetype)
  if not filetype or filetype == '' then return '' end
  return filetype:match('^[^%.%-]+') or filetype
end

local BINARY_PREVIEW_EXT = {
  avif = true, bmp = true, gif = true, heic = true, ico = true, jpeg = true, jpg = true,
  pdf = true, png = true, tiff = true, webp = true, zip = true,
}

local function is_probably_binary(path)
  local ext = vim.fn.fnamemodify(path, ':e'):lower()
  if BINARY_PREVIEW_EXT[ext] then return true end

  local fd = vim.uv.fs_open(path, 'r', 438)
  if not fd then return false end
  local chunk = vim.uv.fs_read(fd, 8192, 0) or ''
  pcall(vim.uv.fs_close, fd)
  if chunk == '' then return false end
  if chunk:find('\0', 1, true) then return true end

  local suspicious = 0
  for i = 1, #chunk do
    local b = chunk:byte(i)
    if b < 9 or (b > 13 and b < 32) then suspicious = suspicious + 1 end
  end
  return suspicious > (#chunk * 0.3)
end

local function sanitize_preview_lines(lines)
  local out = {}
  for _, line in ipairs(lines) do
    line = tostring(line):gsub('[\r\n]', '')
    out[#out + 1] = line
  end
  return out
end

--- Neovimの通常バッファに読み込み、filetype/syntaxを設定してハイライトさせる。
--- 先頭だけで十分なので、巨大ファイルでも固まらないよう読み込み行数を制限する。
local function preview_file(path)
  if is_probably_binary(path) then
    set_preview_lines({ '  (バイナリファイルのためプレビューできません)' })
    return
  end
  local ok, content = pcall(vim.fn.readfile, path, '', 2000)
  if not ok then
    set_preview_lines({ '  (読み込み不可)' })
    return
  end
  local ft = preview_filetype(path)
  set_preview_lines(sanitize_preview_lines(content), ft or '', nil, preview_syntax(ft))
end

--- 一覧のCursorMoved、render()末尾、ディレクトリ移動後などから呼ばれる。
--- 同じ対象への連続呼び出しは無視して再描画/再実行を省く
function render_preview()
  if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then return end
  local entry = entry_at_cursor()
  local path = entry and entry.path or nil
  if path == last_preview_path then return end
  last_preview_path = path
  if not entry then
    set_preview_title('プレビュー')
    set_preview_lines({})
    return
  end
  set_preview_title(entry.name)
  if entry.isdir then
    local lines, hls = preview_dir_lines(entry.path)
    set_preview_lines(lines, '', hls)
  else
    preview_file(entry.path)
  end
end

-- ══════════════════════════════════════════════
-- ナビゲーション
-- ══════════════════════════════════════════════

-- サイドバー表示時のプレビュー窓（エディタ領域の上に浮かべる。全画面時は常時右に
-- 出るため無効）。トグルで表示/非表示。表示中はCursorMovedでrender_previewが追従する。
local function close_sidebar_preview()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_close(preview_win, true)
  end
  if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
    vim.api.nvim_buf_delete(preview_buf, { force = true })
  end
  preview_win, preview_buf = nil, nil
  last_preview_path = nil
end

local function toggle_sidebar_preview()
  if is_fullscreen then return end
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    close_sidebar_preview()
    return
  end
  local height = vim.o.lines - 3
  local width = vim.o.columns - PANEL_WIDTH - 3 -- サイドバー幅+区切り+ボーダーを避ける
  if width < 20 or height < 5 then return end
  -- サイドバーが左なら、その右側（エディタ上）に出す
  local col = sidebar_side == 'left' and (PANEL_WIDTH + 1) or 0
  preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[preview_buf].buftype = 'nofile'
  vim.bo[preview_buf].buflisted = false
  require('config.hidden_cursor').mark_buffer(preview_buf)
  preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = 'editor',
    width = width,
    height = height,
    col = col,
    row = 1,
    style = 'minimal',
    border = 'single',
    title = ' プレビュー ',
    title_pos = 'center',
    zindex = 40,
  })
  vim.wo[preview_win].wrap = false
  vim.wo[preview_win].signcolumn = 'no'
  vim.wo[preview_win].winhighlight = 'Normal:ExplorerBg'
  last_preview_path = nil
  render_preview()
end

-- サイドバーを左右へ移動する（'left' / 'right'）。プレビュー表示中は位置が変わるので
-- 一旦閉じて移動後に開き直す。全画面モードでは無効。
local function move_sidebar(side)
  if is_fullscreen then return end
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if sidebar_side == side then return end
  local had_preview = preview_win and vim.api.nvim_win_is_valid(preview_win)
  if had_preview then close_sidebar_preview() end
  vim.api.nvim_set_current_win(win)
  vim.cmd(side == 'left' and 'wincmd H' or 'wincmd L')
  sidebar_side = side
  vim.api.nvim_win_set_width(win, PANEL_WIDTH)
  vim.wo[win].winfixwidth = true
  if had_preview then toggle_sidebar_preview() end
  vim.cmd('redrawtabline')
end

local function toggle_view_mode()
  local entry = entry_at_cursor()
  if view_mode == 'list' then
    if entry then tree_cursor_mem[cwd] = entry.path end
    view_mode = 'tree'
  else
    if entry then cursor_mem[cwd] = top_child_name(entry.path) or entry.name end
    view_mode = 'list'
  end
  render()
end

-- 圧縮表示（Compact Folders）のトグル。ツリー表示専用の機能なので、リスト表示中に
-- 有効化したらツリー表示へ切り替えて効果がすぐ見えるようにする。
local function toggle_compact_dirs()
  compact_dirs = not compact_dirs
  if compact_dirs and view_mode == 'list' then
    local entry = entry_at_cursor()
    if entry then tree_cursor_mem[cwd] = entry.path end
    view_mode = 'tree'
  end
  render()
end

local function toggle_tree_node()
  local entry = entry_at_cursor()
  if not entry or not entry.expandable then return end
  if tree_expanded[entry.path] then
    tree_expanded[entry.path] = nil
  else
    tree_expanded[entry.path] = true
  end
  tree_cursor_mem[cwd] = entry.path
  render()
end

local function collapse_all_tree_nodes()
  tree_expanded = {}
  local entry = entry_at_cursor()
  remember_entry(entry)
  render()
end

local function expand_all_tree_nodes()
  if view_mode ~= 'tree' then view_mode = 'tree' end
  local count = 0
  local capped = false
  local max_dirs = 10000

  local function walk(dir)
    if capped then return end
    for _, entry in ipairs(list_dir(dir)) do
      if entry.isdir and not entry.link then
        tree_expanded[entry.path] = true
        count = count + 1
        if count >= max_dirs then
          capped = true
          return
        end
        walk(entry.path)
      end
    end
  end

  local entry = entry_at_cursor()
  remember_entry(entry)
  walk(cwd)
  if capped then
    vim.notify('展開数が多すぎるため途中で止めました', vim.log.levels.WARN)
  end
  render()
end

local function editor_file_path()
  local win_util = require('config.util.win_util')
  local function from_win(w)
    if not (w and vim.api.nvim_win_is_valid(w) and win_util.is_editor(w)) then return nil end
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype ~= '' then return nil end
    local name = vim.api.nvim_buf_get_name(b)
    if name == '' then return nil end
    return vim.fn.fnamemodify(name, ':p'):gsub('/$', '')
  end

  return from_win(vim.api.nvim_get_current_win())
    or from_win(origin_win)
    or (function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local path = from_win(w)
        if path then return path end
      end
    end)()
end

local function expand_tree_to_path(path)
  local dir = vim.fn.fnamemodify(path, ':h')
  while dir and dir ~= '' and dir ~= cwd and is_under_dir(dir, cwd) do
    tree_expanded[dir] = true
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then break end
    dir = parent
  end
end

local function reveal_current_file()
  local path = editor_file_path()
  if not path or vim.fn.filereadable(path) == 0 then
    vim.notify('現在の編集ファイルが見つかりません', vim.log.levels.WARN)
    return
  end

  local parent = vim.fn.fnamemodify(path, ':h')
  local name = vim.fn.fnamemodify(path, ':t')
  if view_mode == 'tree' then
    if not (path == cwd or is_under_dir(path, cwd)) then
      cwd = parent
    end
    expand_tree_to_path(path)
    tree_cursor_mem[cwd] = path
  else
    cwd = parent
    cursor_mem[cwd] = name
  end
  selection = {}
  render()
end

local function enter_dir()
  local entry = entry_at_cursor()
  if not entry or not entry.isdir then return end
  if view_mode == 'tree' then
    toggle_tree_node()
    return
  end
  cwd = entry.path
  selection = {}
  render()
end

-- 一覧UIを畳んでorigin_winへ実バッファとしてファイルを開く。
-- 全画面時はlist/previewの2枚のfloatが画面全体を覆っているため、それらを
-- 閉じずにorigin_winへeditしても裏に隠れて何も変わって見えない
-- (teardown_uiはqallを伴わないので、この場合はnvim自体は終了しない)
local function open_file_in_origin(path)
  if is_fullscreen then
    teardown_ui()
  else
    -- サイドバー時: 開いたファイルがプレビュー窓に隠れないよう閉じる
    close_sidebar_preview()
  end
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

local function open_selected()
  local entry = entry_at_cursor()
  if not entry then return end
  if entry.isdir then
    if view_mode == 'tree' then
      toggle_tree_node()
      return
    end
    cwd = entry.path
    selection = {}
    render()
  else
    open_file_in_origin(entry.path)
  end
end

-- カーソル上の HTML/Markdown をブラウザプレビューで開く(<leader>o と同じ挙動)。
-- 一旦 origin_win へ実バッファとして開き、そのバッファを対象に preview を起動する。
local function preview_selected()
  local entry = entry_at_cursor()
  if not entry or entry.isdir then return end
  local ext = vim.fn.fnamemodify(entry.path, ':e'):lower()
  if not (ext == 'html' or ext == 'htm' or ext == 'md' or ext == 'markdown') then
    vim.notify('HTML / Markdown ファイルではありません', vim.log.levels.WARN, { title = 'Browser Preview' })
    return
  end
  open_file_in_origin(entry.path)
  require('config.browser').open()
end

local function go_parent()
  if view_mode == 'tree' then
    local entry = entry_at_cursor()
    if entry then
      if entry.expandable and tree_expanded[entry.path] then
        tree_expanded[entry.path] = nil
        tree_cursor_mem[cwd] = entry.path
        render()
        return
      end
      local parent = vim.fn.fnamemodify(entry.path, ':h')
      if parent ~= cwd and is_under_cwd(parent) then
        tree_cursor_mem[cwd] = parent
        render()
        return
      end
    end
  end
  local parent = vim.fn.fnamemodify(cwd, ':h')
  if parent == cwd then return end
  cursor_mem[parent] = vim.fn.fnamemodify(cwd, ':t')
  cwd = parent
  selection = {}
  render()
end

local function toggle_hidden()
  show_hidden = not show_hidden
  render()
end

-- git 管理外（ignore）エントリの表示/非表示。node_modules や dist を一時的に畳んで
-- 見通しを良くするためのもの
local function toggle_ignored()
  show_ignored = not show_ignored
  render()
end

--- is_auto=true のときはカーソル位置を覚えてから再描画する（外部変更の自動更新用）。
--- しないと render() が cursor_mem の古い名前へ戻してしまい、j/k 中の位置が飛ぶ。
refresh = function(is_auto)
  if is_auto then
    local e = entry_at_cursor()
    remember_entry(e)
  end
  git_status_dirty = true
  render()
end

stop_watch = function()
  if watch_debounce then
    watch_debounce:stop()
    watch_debounce:close()
    watch_debounce = nil
  end
  if watch_poll then
    pcall(function() watch_poll:stop() end)
    pcall(function() watch_poll:close() end)
    watch_poll = nil
  end
  watch_stamp = nil
  if fs_event then
    pcall(function() fs_event:stop() end)
    pcall(function() fs_event:close() end)
    fs_event = nil
  end
  watched_path = nil
end

start_watch = function(path)
  if watched_path == path and fs_event then return end
  stop_watch()
  if not path or path == '' then return end
  local handle = vim.uv.new_fs_event()
  if not handle then return end
  local ok = handle:start(path, {}, function(err)
    if err then return end
    vim.schedule(function()
      if not (win and vim.api.nvim_win_is_valid(win)) then return end
      if cwd ~= path then return end
      if watch_debounce then
        watch_debounce:stop()
        watch_debounce:close()
      end
      watch_debounce = vim.uv.new_timer()
      watch_debounce:start(WATCH_DEBOUNCE_MS, 0, function()
        if watch_debounce then
          watch_debounce:stop()
          watch_debounce:close()
          watch_debounce = nil
        end
        vim.schedule(function()
          if not (win and vim.api.nvim_win_is_valid(win)) then return end
          if cwd ~= path then return end
          refresh(true)
        end)
      end)
    end)
  end)
  if not ok then
    pcall(function() handle:close() end)
    return
  end
  fs_event = handle
  watched_path = path
  watch_stamp = fs_stamp(path)
  watch_poll = vim.uv.new_timer()
  if watch_poll then
    watch_poll:start(WATCH_DEBOUNCE_MS, WATCH_DEBOUNCE_MS, function()
      local stamp = fs_stamp(path)
      if stamp and stamp ~= watch_stamp then
        watch_stamp = stamp
        vim.schedule(function()
          if not (win and vim.api.nvim_win_is_valid(win)) then return end
          if cwd ~= path then return end
          refresh(true)
        end)
      end
    end)
  end
end

stop_git_watch = function()
  if git_watch_debounce then
    git_watch_debounce:stop()
    git_watch_debounce:close()
    git_watch_debounce = nil
  end
  if git_watch_poll then
    pcall(function() git_watch_poll:stop() end)
    pcall(function() git_watch_poll:close() end)
    git_watch_poll = nil
  end
  git_watch_stamp = nil
  if git_fs_event then
    pcall(function() git_fs_event:stop() end)
    pcall(function() git_fs_event:close() end)
    git_fs_event = nil
  end
  git_watched_dir = nil
end

-- リポジトリの .git ディレクトリを監視する(非再帰。libuv の再帰監視は nvim では機能しないため、
-- HEAD/index/config 等は .git 直下にあるのでこれで拾える)。start_watch と同様に atomic rename
-- 対策でファイルではなくディレクトリを監視し、debounce してから git status を取り直す。
start_git_watch = function(git_dir)
  if not git_dir or git_dir == '' then
    stop_git_watch()
    return
  end
  if git_watched_dir == git_dir and git_fs_event then return end
  stop_git_watch()
  local handle = vim.uv.new_fs_event()
  if not handle then return end
  local ok = handle:start(git_dir, {}, function(err, filename)
    if err then return end
    -- filename が取れるプラットフォームでは、対象ファイル以外の .git 変更は無視する
    if filename and not GIT_WATCHED_FILES[filename] then return end
    vim.schedule(function()
      if not (win and vim.api.nvim_win_is_valid(win)) then return end
      if git_watch_debounce then
        git_watch_debounce:stop()
        git_watch_debounce:close()
      end
      git_watch_debounce = vim.uv.new_timer()
      git_watch_debounce:start(WATCH_DEBOUNCE_MS, 0, function()
        if git_watch_debounce then
          git_watch_debounce:stop()
          git_watch_debounce:close()
          git_watch_debounce = nil
        end
        vim.schedule(function()
          if not (win and vim.api.nvim_win_is_valid(win)) then return end
          git_status_dirty = true
          render()
        end)
      end)
    end)
  end)
  if not ok then
    pcall(function() handle:close() end)
    return
  end
  git_fs_event = handle
  git_watched_dir = git_dir
  local index_path = git_dir .. '/index'
  git_watch_stamp = fs_stamp(index_path)
  git_watch_poll = vim.uv.new_timer()
  if git_watch_poll then
    git_watch_poll:start(WATCH_DEBOUNCE_MS, WATCH_DEBOUNCE_MS, function()
      local stamp = fs_stamp(index_path)
      if stamp and stamp ~= git_watch_stamp then
        git_watch_stamp = stamp
        vim.schedule(function()
          if not (win and vim.api.nvim_win_is_valid(win)) then return end
          git_status_dirty = true
          render()
        end)
      end
    end)
  end
end

local function refocus_panel()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

local function input_modal(title, default, on_submit)
  default = default or ''
  local width = math.max(30, math.min(60, math.floor(vim.o.columns * 0.5)))
  local height = 1
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2) - 1

  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].buftype = 'nofile'
  vim.bo[ibuf].bufhidden = 'wipe'
  vim.bo[ibuf].swapfile = false
  vim.bo[ibuf].modifiable = true
  vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { default })

  local iwin = vim.api.nvim_open_win(ibuf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = col,
    row = row,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  })
  vim.wo[iwin].winhighlight = 'Normal:ExplorerInputBg,FloatBorder:ExplorerInputBorder'

  local done = false
  local function finish(value)
    if done then return end
    done = true
    -- インサートモードのまま閉じるとフォーカス移動後もインサートモードが引き継がれるため先に抜ける
    vim.cmd('stopinsert')
    if vim.api.nvim_win_is_valid(iwin) then vim.api.nvim_win_close(iwin, true) end
    refocus_panel()
    on_submit(value)
  end

  vim.keymap.set({ 'i', 'n' }, '<CR>', function()
    local line = vim.api.nvim_buf_get_lines(ibuf, 0, 1, false)[1] or ''
    finish(line)
  end, { buffer = ibuf, nowait = true, silent = true })

  vim.keymap.set({ 'i', 'n' }, '<Esc>', function()
    finish(nil)
  end, { buffer = ibuf, nowait = true, silent = true })

  vim.keymap.set({ 'i', 'n' }, '<C-u>', function()
    vim.api.nvim_buf_set_lines(ibuf, 0, 1, false, { '' })
    if vim.api.nvim_win_is_valid(iwin) then
      vim.api.nvim_win_set_cursor(iwin, { 1, 0 })
    end
  end, { buffer = ibuf, nowait = true, silent = true })

  vim.api.nvim_win_set_cursor(iwin, { 1, #default })
  vim.cmd('startinsert!')
end

-- ══════════════════════════════════════════════
-- 選択
-- ══════════════════════════════════════════════

local function toggle_select_at_cursor(step)
  step = step or 1
  local entry = entry_at_cursor()
  if not entry then return end
  if selection[entry.path] then
    selection[entry.path] = nil
  else
    selection[entry.path] = true
  end
  remember_entry(entry)
  render()
  if win and vim.api.nvim_win_is_valid(win) then
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local target = row + step
    if target >= ENTRY_OFFSET + 1 and target <= ENTRY_OFFSET + #rows then
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end
  end
end

local function select_all()
  for _, entry in ipairs(rows) do selection[entry.path] = true end
  render()
end

local function invert_selection()
  for _, entry in ipairs(rows) do
    if selection[entry.path] then
      selection[entry.path] = nil
    else
      selection[entry.path] = true
    end
  end
  render()
end

local function clear_selection_or_close()
  if vim.tbl_count(selection) > 0 then
    selection = {}
    render()
  elseif filter ~= '' then
    filter = ''
    render()
  else
    M.close()
  end
end

local function targets()
  if vim.tbl_count(selection) > 0 then
    local list = {}
    for _, entry in ipairs(rows) do
      if selection[entry.path] then table.insert(list, entry) end
    end
    return list
  end
  local entry = entry_at_cursor()
  return entry and { entry } or {}
end

-- ══════════════════════════════════════════════
-- ファイル操作
-- ══════════════════════════════════════════════

local function create()
  input_modal('作成 (末尾/でディレクトリ)', '', function(input)
    if not input or input == '' then return end
    local is_dir = input:sub(-1) == '/'
    local name = is_dir and input:sub(1, -2) or input
    if name == '' then return end
    local full = join_path(cwd, name)
    if is_dir then
      vim.fn.mkdir(full, 'p')
    else
      vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
      if vim.fn.filereadable(full) == 0 then
        vim.fn.writefile({}, full)
      end
    end
    cursor_mem[cwd] = name:match('^([^/]+)') or name
    tree_cursor_mem[cwd] = join_path(cwd, name)
    git_status_dirty = true
    render()
    refocus_panel()
  end)
end

local function rename()
  local list = targets()
  if #list == 0 then return end
  if #list > 1 then
    vim.notify('複数選択時はリネームできません', vim.log.levels.WARN)
    return
  end
  local entry = list[1]
  input_modal('リネーム', entry.name, function(input)
    if not input or input == '' or input == entry.name then return end
    local parent_dir = vim.fn.fnamemodify(entry.path, ':h')
    local new_path = join_path(parent_dir, input)
    if vim.fn.filereadable(new_path) == 1 or vim.fn.isdirectory(new_path) == 1 then
      vim.notify('既に存在します: ' .. input, vim.log.levels.ERROR)
      return
    end
    local ok = vim.uv.fs_rename(entry.path, new_path)
    if not ok then
      vim.notify('リネームに失敗しました', vim.log.levels.ERROR)
      return
    end
    selection[entry.path] = nil
    local bufnr = vim.fn.bufnr(entry.path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_name(bufnr, new_path)
      vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent! write!') end)
    end
    cursor_mem[cwd] = parent_dir == cwd and input or (top_child_name(new_path) or input)
    tree_cursor_mem[cwd] = new_path
    if entry.isdir and tree_expanded[entry.path] then
      tree_expanded[entry.path] = nil
      tree_expanded[new_path] = true
    end
    git_status_dirty = true
    render()
    refocus_panel()
  end)
end

local function confirm(message, on_result, opts)
  opts = opts or {}
  local lines = vim.split(message, '\n', { plain = true })
  local width = 10
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, opts.max_height or #lines)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2) - 1

  local cbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[cbuf].buftype = 'nofile'
  vim.bo[cbuf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, lines)
  vim.bo[cbuf].modifiable = false
  require('config.hidden_cursor').mark_buffer(cbuf)

  local cwin = vim.api.nvim_open_win(cbuf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = col,
    row = row,
    style = 'minimal',
    border = 'rounded',
    title = ' 確認 (y/N) ',
    title_pos = 'center',
  })
  vim.wo[cwin].winhighlight = 'Normal:ExplorerConfirmBg,FloatBorder:ExplorerConfirmBorder'
  vim.wo[cwin].wrap = false
  local scrollable = #lines > height
  local function update_confirm_title()
    if not vim.api.nvim_win_is_valid(cwin) then return end
    if not scrollable then
      vim.api.nvim_win_set_config(cwin, { title = ' 確認 (y/N) ', title_pos = 'center' })
      return
    end
    local top = vim.fn.line('w0', cwin)
    local bottom = math.min(top + height - 1, #lines)
    local marker
    if top > 1 and bottom < #lines then
      marker = string.format(' ↑↓ %d-%d/%d ', top, bottom, #lines)
    elseif bottom < #lines then
      marker = string.format(' ↓ %d-%d/%d ', top, bottom, #lines)
    else
      marker = string.format(' ↑ %d-%d/%d ', top, bottom, #lines)
    end
    vim.api.nvim_win_set_config(cwin, {
      title = ' 確認 (y/N) ',
      title_pos = 'center',
      footer = marker,
      footer_pos = 'right',
    })
  end
  if scrollable then
    vim.wo[cwin].cursorline = true
  end
  update_confirm_title()

  local done = false
  local function finish(result)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(cwin) then vim.api.nvim_win_close(cwin, true) end
    refocus_panel()
    on_result(result)
  end

  local function map(key, result)
    vim.keymap.set('n', key, function() finish(result) end, { buffer = cbuf, nowait = true, silent = true })
  end
  local function scroll(key, normal)
    vim.keymap.set('n', key, function()
      vim.cmd('normal! ' .. normal)
      update_confirm_title()
    end, { buffer = cbuf, nowait = true, silent = true })
  end
  map('y', true)
  map('Y', true)
  map('<CR>', true)
  map('n', false)
  map('N', false)
  map('q', false)
  map('<Esc>', false)
  if scrollable then
    scroll('j', 'j')
    scroll('k', 'k')
    scroll('<C-d>', '\004')
    scroll('<C-u>', '\021')
    scroll('G', 'G')
    scroll('gg', 'gg')
  end
end

--- FreeDesktop Trash仕様（XDG）に従ってゴミ箱へ移す。外部CLI不要。
--- Pathは仕様どおりパーセントエンコードする。
local function trash_encode_path(abs)
  return (abs:gsub('([^A-Za-z0-9_.!*/-])', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

local function move_to_trash(path)
  local data_home = vim.env.XDG_DATA_HOME
  if not data_home or data_home == '' then
    data_home = vim.fn.expand('~/.local/share')
  end
  local files_dir = data_home .. '/Trash/files'
  local info_dir = data_home .. '/Trash/info'
  vim.fn.mkdir(files_dir, 'p')
  vim.fn.mkdir(info_dir, 'p')

  local base = vim.fn.fnamemodify(path, ':t')
  local dest = files_dir .. '/' .. base
  local info = info_dir .. '/' .. base .. '.trashinfo'
  local n = 1
  while vim.fn.filereadable(dest) == 1 or vim.fn.isdirectory(dest) == 1
    or vim.fn.filereadable(info) == 1 do
    dest = string.format('%s/%s.%d', files_dir, base, n)
    info = string.format('%s/%s.%d.trashinfo', info_dir, base, n)
    n = n + 1
  end

  local abs = vim.fn.fnamemodify(path, ':p'):gsub('/$', '')
  local ok = vim.uv.fs_rename(path, dest)
  if not ok then
    local cp = vim.system({ 'cp', '-a', path, dest }):wait()
    if cp.code ~= 0 then
      return false, 'ゴミ箱への移動に失敗しました'
    end
    vim.fn.delete(path, 'rf')
  end
  vim.fn.writefile({
    '[Trash Info]',
    'Path=' .. trash_encode_path(abs),
    'DeletionDate=' .. os.date('%Y-%m-%dT%H:%M:%S'),
  }, info)
  return true
end

local function delete_targets(permanent)
  local list = targets()
  if #list == 0 then return end
  local names = {}
  for i, e in ipairs(list) do
    if i > 5 then break end
    table.insert(names, e.name)
  end
  local label = table.concat(names, ', ')
  if #list > 5 then label = label .. ' 他' .. (#list - 5) .. '件' end

  local msg = permanent
    and string.format('%d件を完全削除しますか？\n%s', #list, label)
    or string.format('%d件をゴミ箱へ移しますか？\n%s', #list, label)

  confirm(msg, function(ok)
    if not ok then return end
    for _, e in ipairs(list) do
      if permanent then
        vim.fn.delete(e.path, 'rf')
      else
        local moved, err = move_to_trash(e.path)
        if not moved then
          vim.notify(err or 'ゴミ箱への移動に失敗しました', vim.log.levels.ERROR)
        end
      end
      selection[e.path] = nil
      local bufnr = vim.fn.bufnr(e.path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        -- 窓ごと閉じると最後の編集窓が消えて auto_quit が nvim を終了させるので、
        -- バッファだけ消して窓は別バッファへ退避する。
        require('config.util.buf_cycle').delete_keep_windows(bufnr)
      end
    end
    git_status_dirty = true
    render()
    refocus_panel()
  end)
end

local function trash()
  delete_targets(false)
end

local function delete_permanent()
  delete_targets(true)
end

local empty_dir_scan_running = false

local function start_empty_dir_scan(root, on_done)
  vim.system({
    'fd', '--hidden', '--exclude', '.git', '--absolute-path', '--print0',
    '--type', 'directory', '--type', 'empty', '.', root,
  }, { text = false }, function(res)
    vim.schedule(function()
      empty_dir_scan_running = false
      if res.code ~= 0 then
        vim.notify('fdによる空ディレクトリ検索に失敗しました', vim.log.levels.ERROR)
        return
      end

      local delete_set = {}
      local dirs = {}
      for raw in (res.stdout or ''):gmatch('[^%z]+') do
        local path = vim.fn.fnamemodify(raw, ':p'):gsub('/$', '')
        if path ~= root and is_under_dir(path, root) and not delete_set[path] then
          delete_set[path] = true
          table.insert(dirs, path)
        end
      end

      local function effectively_empty(dir)
        local ok, names = pcall(vim.fn.readdir, dir)
        if not ok then return false end
        for _, name in ipairs(names) do
          local child = join_path(dir, name)
          local st = vim.uv.fs_lstat(child)
          if not (st and st.type == 'directory' and delete_set[child]) then
            return false
          end
        end
        return true
      end

      table.sort(dirs, function(a, b) return #a > #b end)
      local i = 1
      while i <= #dirs do
        local parent = vim.fn.fnamemodify(dirs[i], ':h')
        while parent ~= root and is_under_dir(parent, root) and not delete_set[parent] and effectively_empty(parent) do
          delete_set[parent] = true
          table.insert(dirs, parent)
          parent = vim.fn.fnamemodify(parent, ':h')
        end
        i = i + 1
      end

      table.sort(dirs, function(a, b)
        if #a ~= #b then return #a > #b end
        return a < b
      end)
      on_done(dirs)
    end)
  end)
end

local function relative_to_dir(path, dir)
  if dir == '/' then return path:sub(2) end
  if path:sub(1, #dir + 1) == dir .. '/' then return path:sub(#dir + 2) end
  return path
end

local function confirm_delete_empty_dirs(root, dirs)
  table.sort(dirs, function(a, b)
    if #a ~= #b then return #a > #b end
    return a < b
  end)

  local labels = {}
  for _, path in ipairs(dirs) do
    table.insert(labels, relative_to_dir(path, root))
  end
  local message = string.format('空ディレクトリ%d件を完全削除しますか？\n%s', #dirs, table.concat(labels, '\n'))

  confirm(message, function(ok)
    if not ok then return end
    local failed = 0
    for _, path in ipairs(dirs) do
      if vim.fn.isdirectory(path) == 1 then
        local removed = vim.uv.fs_rmdir(path)
        if not removed and vim.fn.isdirectory(path) == 1 then
          failed = failed + 1
        end
      end
      selection[path] = nil
      tree_expanded[path] = nil
    end
    git_status_dirty = true
    render()
    refocus_panel()
    if failed > 0 then
      vim.notify(string.format('%d件の空ディレクトリ削除に失敗しました', failed), vim.log.levels.WARN)
    end
  end, { max_height = math.max(8, vim.o.lines - 8) })
end

local function delete_empty_dirs()
  if vim.fn.executable('fd') == 0 then
    vim.notify('fd が見つかりません', vim.log.levels.ERROR)
    return
  end
  if empty_dir_scan_running then
    vim.notify('空ディレクトリを検索中です', vim.log.levels.INFO)
    return
  end
  empty_dir_scan_running = true
  local scan_root = cwd

  start_empty_dir_scan(scan_root, function(dirs)
    if not (win and vim.api.nvim_win_is_valid(win)) then return end
    if cwd ~= scan_root then
      vim.notify('検索中にフォルダが変わったため中止しました', vim.log.levels.WARN)
      return
    end
    if #dirs == 0 then
      vim.notify('空ディレクトリはありません', vim.log.levels.INFO)
      return
    end

    confirm_delete_empty_dirs(scan_root, dirs)
  end)
end

local function copy_selection()
  local list = targets()
  if #list == 0 then return end
  local paths = {}
  for _, e in ipairs(list) do table.insert(paths, e.path) end
  clipboard = { mode = 'copy', paths = paths }
  render()
end

local function cut_selection()
  local list = targets()
  if #list == 0 then return end
  local paths = {}
  for _, e in ipairs(list) do table.insert(paths, e.path) end
  clipboard = { mode = 'cut', paths = paths }
  render()
end

local function copy_path_text(kind)
  local list = targets()
  if #list == 0 then return end
  local parts = {}
  for _, e in ipairs(list) do
    if kind == 'name' then
      table.insert(parts, e.name)
    else
      table.insert(parts, user_facing_path(e.path))
    end
  end
  local text = table.concat(parts, '\n')
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, '+', text)
  vim.notify('コピーしました: ' .. (#parts > 1 and (#parts .. '件') or text), vim.log.levels.INFO)
end

local function copy_name()
  copy_path_text('name')
end

local function copy_abs_path()
  copy_path_text('path')
end

local function unique_dest(dest_dir, name)
  local base, ext = name:match('^(.*)(%.[^%.]+)$')
  if not base then
    base, ext = name, ''
  end
  local candidate = join_path(dest_dir, name)
  local n = 1
  while vim.fn.filereadable(candidate) == 1 or vim.fn.isdirectory(candidate) == 1 do
    candidate = string.format('%s/%s_copy%d%s', dest_dir, base, n, ext)
    n = n + 1
  end
  return candidate
end

local function paste(overwrite)
  if not clipboard or #clipboard.paths == 0 then
    vim.notify('クリップボードが空です', vim.log.levels.WARN)
    return
  end
  for _, src in ipairs(clipboard.paths) do
    local name = vim.fn.fnamemodify(src, ':t')
    local dest = join_path(cwd, name)
    if not overwrite and (vim.fn.filereadable(dest) == 1 or vim.fn.isdirectory(dest) == 1) then
      dest = unique_dest(cwd, name)
    end
    if clipboard.mode == 'copy' then
      vim.system({ 'cp', '-r', src, dest }):wait()
    else
      local ok = vim.uv.fs_rename(src, dest)
      if not ok then
        vim.system({ 'cp', '-r', src, dest }):wait()
        vim.fn.delete(src, 'rf')
      end
    end
  end
  if clipboard.mode == 'cut' then clipboard = nil end
  selection = {}
  git_status_dirty = true
  render()
end

-- explorer バッファへ重ねる1行のライブ入力欄。打鍵ごとに handlers.change(text) を呼び、
-- <CR> で handlers.accept(text)、<Esc> で handlers.cancel() を呼ぶ（いずれもフォーカスを
-- explorer へ戻してから）。handlers.move(delta) があれば C-j/C-k・↑↓ を割り当てる。
-- 入力中も裏の explorer 一覧が見えているので、フィルタ/検索の結果をその場で確認できる。
local function live_prompt(title, initial, handlers)
  initial = initial or ''
  local width = math.max(30, math.min(60, math.floor(vim.o.columns * 0.5)))
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - 1) / 2) - 1

  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].buftype = 'nofile'
  vim.bo[pbuf].bufhidden = 'wipe'
  vim.bo[pbuf].swapfile = false
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { initial })

  local pwin = vim.api.nvim_open_win(pbuf, true, {
    relative = 'editor',
    width = width,
    height = 1,
    col = col,
    row = row,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  })
  vim.wo[pwin].winhighlight = 'Normal:ExplorerInputBg,FloatBorder:ExplorerInputBorder'

  local function current_text()
    return vim.api.nvim_buf_get_lines(pbuf, 0, 1, false)[1] or ''
  end

  local done = false
  local function finish(cb, arg)
    if done then return end
    done = true
    -- インサートのまま閉じるとフォーカス移動後もインサートが引き継がれるため先に抜ける
    vim.cmd('stopinsert')
    if vim.api.nvim_win_is_valid(pwin) then vim.api.nvim_win_close(pwin, true) end
    refocus_panel()
    if cb then cb(arg) end
  end

  -- bufhidden=wipe なのでバッファ破棄時に buffer-local な autocmd/keymap も自動で消える
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = pbuf,
    callback = function() handlers.change(current_text()) end,
  })

  local opts = { buffer = pbuf, nowait = true, silent = true }
  vim.keymap.set({ 'i', 'n' }, '<CR>', function() finish(handlers.accept, current_text()) end, opts)
  vim.keymap.set({ 'i', 'n' }, '<Esc>', function() finish(handlers.cancel) end, opts)
  vim.keymap.set({ 'i', 'n' }, '<C-u>', function()
    vim.api.nvim_buf_set_lines(pbuf, 0, 1, false, { '' })
    if vim.api.nvim_win_is_valid(pwin) then vim.api.nvim_win_set_cursor(pwin, { 1, 0 }) end
    handlers.change('')
  end, opts)
  if handlers.move then
    vim.keymap.set({ 'i', 'n' }, '<C-j>', function() handlers.move(1) end, opts)
    vim.keymap.set({ 'i', 'n' }, '<C-k>', function() handlers.move(-1) end, opts)
    vim.keymap.set({ 'i', 'n' }, '<Down>', function() handlers.move(1) end, opts)
    vim.keymap.set({ 'i', 'n' }, '<Up>', function() handlers.move(-1) end, opts)
  end

  vim.api.nvim_win_set_cursor(pwin, { 1, #initial })
  vim.cmd('startinsert!')
end

-- 直下フィルタ（yazi 風インクリメンタル）。打鍵ごとに現在フォルダの一覧を名前で絞り込む。
-- <CR> で確定（絞り込みを維持）、<Esc> でクリア。
local function set_filter()
  live_prompt('フィルタ (Esc でクリア)', filter, {
    change = function(text) filter = text; render() end,
    accept = function(text) filter = text or ''; render() end,
    cancel = function() filter = ''; render() end,
  })
end

-- ══════════════════════════════════════════════
-- 再帰パス検索（fd・fzf 不使用）
-- ══════════════════════════════════════════════

-- fd は既定で .gitignore を尊重するため node_modules などは自動的に除外され、大きな
-- リポジトリでも速い。--fixed-strings でクエリはリテラル。--full-path でファイル名だけ
-- でなくパスにも当てる（"config/explorer" のようなクエリを効かせるため）。
local function fd_command(query)
  return {
    'fd', '--type', 'f', '--hidden', '--color', 'never',
    '--exclude', '.git', '--fixed-strings', '--full-path', query, cwd,
  }
end

-- fd の --full-path は cwd 側の絶対パス部分にも当たってしまう（cwd が /app/.config なら
-- クエリ "config" が配下の全ファイルに一致する）ため、cwd 相対パスで当て直して余分を落とす。
-- 大文字を含むときだけ大小を区別する fd の smart-case に挙動を合わせる。
local function filter_paths_by_query(paths, query)
  if not query or query == '' then return {} end
  local cased = query:match('%u') ~= nil -- smart-case
  local needle = cased and query or query:lower()
  local prefix = cwd == '/' and '/' or (cwd .. '/')
  local out = {}
  for _, abs in ipairs(paths) do
    local rel = (abs:sub(1, #prefix) == prefix) and abs:sub(#prefix + 1) or abs
    if (cased and rel or rel:lower()):find(needle, 1, true) then
      table.insert(out, abs)
    end
  end
  return out
end

-- fd を非同期実行してファイル名で候補を集める（打鍵ごとのライブ更新用）。結果は
-- search_paths に入れ、検索中なら再描画する。
local function run_fd_search(query)
  if search_job then
    pcall(vim.fn.jobstop, search_job)
    search_job = nil
  end
  query = query or ''
  search_query = query
  search_gen = search_gen + 1
  local gen = search_gen
  if query == '' then
    search_paths = {}
    search_sel = 1
    if search_active then render() end
    return
  end
  local out = {}
  search_job = vim.fn.jobstart(fd_command(query), {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= '' then table.insert(out, line) end
      end
    end,
    on_exit = function()
      vim.schedule(function()
        if gen ~= search_gen then return end -- 後続の入力で世代が進んでいたら破棄
        search_job = nil
        search_paths = filter_paths_by_query(out, query)
        search_sel = 1
        if search_active then render() end
      end)
    end,
  })
end

-- 確定時の保険。ライブ更新(TextChangedI)がまだ届いておらず結果が空のときだけ、最新の
-- クエリで同期的に fd を回して search_paths を埋める。既に結果があれば触らない（C-j/C-k で
-- 動かした選択位置を保つため）。
local function ensure_fd_results(query)
  query = query or ''
  if query == '' or #search_paths > 0 then return end
  search_query = query
  search_gen = search_gen + 1 -- 以降に届く非同期ジョブの結果で上書きされないように
  local result = vim.fn.systemlist(fd_command(query))
  if vim.v.shell_error ~= 0 then result = {} end
  search_paths = filter_paths_by_query(vim.tbl_filter(function(l) return l ~= '' end, result), query)
  search_sel = 1
end

-- 検索状態を解除する。restore=true なら通常表示へ戻すため再描画する。
local function stop_search(restore)
  search_active = false
  search_query = ''
  search_paths = {}
  search_sel = 1
  search_gen = search_gen + 1 -- 実行中ジョブの結果を無効化
  if search_job then
    pcall(vim.fn.jobstop, search_job)
    search_job = nil
  end
  -- 候補ゼロで抜けた場合に render() が消した cursorline を通常状態へ戻す
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].cursorline = true
  end
  if restore then render() end
end

-- 選択中の検索結果（rows[search_sel]）を確定する。ファイルなら開き、ディレクトリなら cd する。
local function resolve_search_selection(text)
  ensure_fd_results(text) -- ライブ更新が届いていなければ確定テキストで検索し直す
  render()                -- 最新の search_paths で rows を組み直す
  local entry = rows[search_sel]
  stop_search(false)
  if not entry then
    render()
    return
  end
  if entry.isdir then
    cwd = entry.path
    selection = {}
    render()
  else
    render() -- 検索表示を通常表示へ戻してからファイルを開く
    open_file_in_origin(entry.path)
  end
end

-- 再帰パス検索を開始する。ライブ入力欄で打鍵ごとに fd を回し、結果を explorer
-- バッファ内へ view_mode に従って表示する。C-j/C-k で移動、<CR> で確定、<Esc> で解除。
local function start_search()
  if vim.fn.executable('fd') == 0 then
    vim.notify('fd が見つかりません', vim.log.levels.ERROR)
    return
  end
  search_active = true
  search_query = ''
  search_paths = {}
  search_sel = 1
  render()
  live_prompt('検索 (再帰・パス)', '', {
    change = function(text) run_fd_search(text) end,
    accept = function(text) resolve_search_selection(text) end,
    cancel = function() stop_search(true) end,
    move = function(delta)
      if #rows == 0 then return end
      search_sel = math.max(1, math.min(#rows, search_sel + delta))
      render()
    end,
  })
end

-- ══════════════════════════════════════════════
-- 開閉
-- ══════════════════════════════════════════════

--- ウィンドウ/バッファの後始末だけを行う(qallは含まない)。close()本体と、
--- 全画面中にファイルを開く場合(open_selected、qallされては困る)の両方から使う
teardown_ui = function()
  stop_watch()
  stop_git_watch()
  vim.api.nvim_clear_autocmds({ group = augrp })
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_close(preview_win, true)
  end
  if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
    vim.api.nvim_buf_delete(preview_buf, { force = true })
  end
  win, buf, preview_win, preview_buf = nil, nil, nil, nil
  last_preview_path = nil
  is_fullscreen = false
  if search_job then pcall(vim.fn.jobstop, search_job); search_job = nil end
  search_active = false
  search_query = ''
  search_paths = {}
  search_sel = 1
  pcall(vim.cmd, 'redrawtabline')
end

--- 全画面表示は「これがこのnvimプロセスの用件そのもの」という前提(例: nvim +Explorer!
--- で直接立ち上げる運用等)なので、閉じる操作(q/Esc/:q
--- どれでも最終的にここを通る)がそのまま裏側の元バッファへ戻るのではなく、
--- nvim自体を終了させる。通常のサイドパネル表示ではこれまで通り単に閉じるだけ
local function close()
  local was_fullscreen = is_fullscreen
  teardown_ui()
  if was_fullscreen then
    vim.cmd('qall')
  end
end

local function open(fullscreen)
  is_fullscreen = fullscreen or false
  origin_win = vim.api.nvim_get_current_win()
  if not initialized then
    cwd = vim.fn.getcwd()
    initialized = true
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = 'nofile'
  vim.bo[buf].buflisted  = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype   = 'explorer'

  if fullscreen then
    local total_w = vim.o.columns
    local total_h = vim.o.lines - 2
    -- 一覧は幅32%程度、残りをプレビューに割く。ボーダー分(左右1桁ずつ)を差し引いて
    -- 隙間無く並べる
    local list_w = math.max(24, math.floor(total_w * 0.32) - 2)
    local list_screen_w = list_w + 2
    local preview_w = total_w - list_screen_w - 2

    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width    = list_w,
      height   = total_h,
      col      = 0,
      row      = 0,
      style    = 'minimal',
      border   = 'single',
    })

    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[preview_buf].buftype   = 'nofile'
    vim.bo[preview_buf].buflisted = false
    -- ウィンドウへ差し込む前に必ずマークする（recreate_preview_bufと同じ理由:
    -- nvim_open_win/nvim_win_set_bufはフォーカスしていなくてもBufEnterを発火するため）
    require('config.hidden_cursor').mark_buffer(preview_buf)
    preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = 'editor',
      width    = preview_w,
      height   = total_h,
      col      = list_screen_w,
      row      = 0,
      style    = 'minimal',
      border   = 'single',
      title    = ' プレビュー ',
      title_pos = 'center',
    })
    vim.wo[preview_win].wrap         = false
    vim.wo[preview_win].signcolumn   = 'no'
    vim.wo[preview_win].winhighlight = 'Normal:ExplorerBg'
  else
    local pos = sidebar_side == 'left' and 'topleft' or 'botright'
    vim.cmd(pos .. ' ' .. PANEL_WIDTH .. 'vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].winfixwidth = true
  end

  require('config.hidden_cursor').mark_buffer(buf)
  -- 全画面(float)時は is_float で非エディタ扱い。スプリット時は mark でガードする
  if not is_fullscreen then
    require('config.util.win_util').mark_sidebar(win, buf)
  end

  vim.wo[win].wrap           = false
  vim.wo[win].number         = true
  vim.wo[win].relativenumber = true
  vim.wo[win].statuscolumn   = '%!v:lua.__explorer_statuscolumn()'
  vim.wo[win].signcolumn     = 'no'
  vim.wo[win].cursorline     = true
  vim.wo[win].winhighlight   = 'Normal:ExplorerBg,CursorLine:ExplorerCursorLine'
  vim.wo[win].statusline     = '%#ExplorerBg#' -- ステータスラインを空＋透明にして隠す

  render()

  -- ヘッダー行（パス表示・空行）にはカーソルを乗せない
  vim.api.nvim_create_autocmd('CursorMoved', {
    group    = augrp,
    buffer   = buf,
    callback = function()
      if not (win and vim.api.nvim_win_is_valid(win)) then return end
      local pos = vim.api.nvim_win_get_cursor(win)
      local min_row = ENTRY_OFFSET + 1
      if pos[1] < min_row then
        pcall(vim.api.nvim_win_set_cursor, win, { min_row, pos[2] })
      end
      local entry = entry_at_cursor()
      remember_entry(entry)
      render_preview()
    end,
  })

  vim.api.nvim_create_autocmd('WinEnter', {
    group = augrp,
    callback = function()
      local current = vim.api.nvim_get_current_win()
      if require('config.util.win_util').is_editor(current) then
        origin_win = current
      end
    end,
  })

  local function map(key, fn)
    vim.keymap.set('n', key, fn, { buffer = buf, nowait = true, silent = true })
  end

  map('l',       enter_dir)
  map('<Right>', enter_dir)
  map('<CR>',    open_selected)
  map('o',       preview_selected)
  map('h',       go_parent)
  map('<Left>',  go_parent)
  map('.',       toggle_hidden)
  map('i',       toggle_ignored)
  map('t',       toggle_view_mode)
  map('c',       toggle_compact_dirs)
  map('F',       reveal_current_file)
  map('E',       expand_all_tree_nodes)
  map('W',       collapse_all_tree_nodes)
  map('R',       function() refresh() end)
  map('<Tab>',   function() toggle_select_at_cursor(1) end)
  map('<S-Tab>', function() toggle_select_at_cursor(-1) end)
  map('<C-a>',   select_all)
  map('<C-r>',   invert_selection)
  map('<Esc>',   clear_selection_or_close)
  map('q',       close)
  map('a',       create)
  map('r',       rename)
  map('d',       trash)
  map('D',       delete_permanent)
  map('X',       delete_empty_dirs)
  map('<C-y>',   copy_selection)
  map('<C-x>',   cut_selection)
  map('<C-p>',   function() paste(false) end)
  map('<C-S-p>', function() paste(true) end)
  map('y',       copy_name)
  map('Y',       copy_abs_path)
  map('f',       set_filter)
  map('/',       start_search)
  map('v',       toggle_sidebar_preview)
  map('<',       function() move_sidebar('left') end)
  map('>',       function() move_sidebar('right') end)

  local watched = tostring(win)
  if preview_win then watched = watched .. ',' .. tostring(preview_win) end
  -- :q等でウィンドウが閉じられた時もclose()と同じ後始末(+全画面ならqall)を通す
  vim.api.nvim_create_autocmd('WinClosed', {
    group    = augrp,
    pattern  = watched,
    once     = true,
    callback = close,
  })

  vim.cmd('redrawtabline')
end

function M.open(fullscreen)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    open(fullscreen)
  end
end

-- タブラインが explorer の上に被らないよう、左サイドバー表示時に必要な左パディング桁数。
-- （右サイドバー/全画面/非表示なら0）
function M.sidebar_pad()
  if is_fullscreen then return 0 end
  if not (win and vim.api.nvim_win_is_valid(win)) then return 0 end
  if sidebar_side ~= 'left' then return 0 end
  return vim.api.nvim_win_get_width(win) + 1 -- サイドバー幅 + 区切り1桁
end

function M.close()
  close()
end

function M.toggle(fullscreen)
  if win and vim.api.nvim_win_is_valid(win) then
    close()
  else
    open(fullscreen)
  end
end

-- ══════════════════════════════════════════════
-- ハイライト
-- ══════════════════════════════════════════════

local function setup_hl()
  vim.api.nvim_set_hl(0, 'ExplorerBg',         { bg = 'NONE' })
  vim.api.nvim_set_hl(0, 'ExplorerCursorLine', { bg = '#2d3250' })
  vim.api.nvim_set_hl(0, 'ExplorerHeader',     { fg = '#7aa2f7', bold = true })
  vim.api.nvim_set_hl(0, 'ExplorerDir',        { fg = '#7aa2f7' })
  vim.api.nvim_set_hl(0, 'ExplorerFile',       { fg = '#c0caf5' })
  vim.api.nvim_set_hl(0, 'ExplorerTreeArrow',  { fg = '#626262' })
  vim.api.nvim_set_hl(0, 'ExplorerSelected',   { fg = '#e0af68', bg = '#e0af68' })
  vim.api.nvim_set_hl(0, 'ExplorerCut',        { fg = '#565f89', italic = true })
  vim.api.nvim_set_hl(0, 'ExplorerConfirmBg',     { bg = 'NONE', fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'ExplorerConfirmBorder', { bg = 'NONE', fg = '#f7768e' })
  vim.api.nvim_set_hl(0, 'ExplorerInputBg',       { bg = 'NONE', fg = '#c0caf5' })
  vim.api.nvim_set_hl(0, 'ExplorerInputBorder',   { bg = 'NONE', fg = '#7aa2f7' })
  vim.api.nvim_set_hl(0, 'ExplorerDimmed',        { fg = '#6b7394' })
  vim.api.nvim_set_hl(0, 'ExplorerSymlink',       { fg = '#73daca' })
  vim.api.nvim_set_hl(0, 'ExplorerGitIgnored',    { fg = '#565f89' })
  vim.api.nvim_set_hl(0, 'ExplorerGitUntracked',  { fg = '#bb9af7' })
  vim.api.nvim_set_hl(0, 'ExplorerGitModified',   { fg = '#e0af68' })
  vim.api.nvim_set_hl(0, 'ExplorerGitAdded',      { fg = '#9ece6a' })
  vim.api.nvim_set_hl(0, 'ExplorerGitDeleted',    { fg = '#f7768e' })
  vim.api.nvim_set_hl(0, 'ExplorerGitUpdated',    { fg = '#e0af68' })
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

vim.keymap.set('n', '<leader>e', function() M.toggle() end, { desc = 'explorerを開閉' })

vim.api.nvim_create_user_command('Explorer', function(cmd_opts)
  M.toggle(cmd_opts.bang)
end, { bang = true, desc = 'explorerを開閉（!で全画面表示）' })

--- 起動時に -c/--cmd/+cmd で明示的なコマンドが指定されていた場合は、
--- そちらを優先してexplorerの自動起動をしない（例: nvim +Git でGitパネルを
--- 開いたのに、VimEnterの自動起動が後からフォーカスを奪ってしまうのを防ぐ）
local function has_explicit_startup_command()
  for _, arg in ipairs(vim.v.argv) do
    if arg == '-c' or arg == '--cmd' or arg:sub(1, 1) == '+' then
      return true
    end
  end
  return false
end

vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    if has_explicit_startup_command() then return end
    M.open()
  end,
})

-- テスト用の内部フック（プロダクション動作には影響しない）。テストハーネスは insert-mode の
-- ライブ入力(TextChangedI)を再現できず検索行ビルダを実キー経由で駆動できないため、直接
-- 検証できるよう純粋関数と最小限のステート注入だけを公開する。
M._debug = {
  build_search_list_rows = build_search_list_rows,
  build_search_tree_rows = build_search_tree_rows,
  filter_paths_by_query = filter_paths_by_query,
  set_cwd = function(p) cwd = p end,
  set_search_paths = function(p) search_paths = p end,
}

return M
