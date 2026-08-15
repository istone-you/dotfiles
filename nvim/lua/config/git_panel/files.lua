-- Filesパネル: ディレクトリツリー表示（lazygit実機のデフォルト gui.showFileTree=true に合わせる）
-- t で VSCode の Source Control 風のフラット一覧（マージ/ステージ済み/変更のセクション別）へ切替
-- ステージ/アンステージ・hunk単位ステージ・破棄・コミット・amend・stash(オプション含む)・ignore

local git = require('config.git_panel.git')

local M = {}

local ctx
local branch = ''
local files = {}       -- { path, x, y }  x=staged状態, y=未ステージ状態（porcelainの生文字）
local root_node = nil
-- 表示モード: 'tree' = lazygit風のディレクトリツリー / 'list' = VSCode風のセクション別フラット一覧。
-- t で切替。explorer と同じくセッション中は維持する
local view_mode = 'tree'
local collapsed = {}    -- [node_id] = true
local line_entries = {}
local total_rows = 0
local cursor_mem = nil
local selection = {} -- [node_id] = true（Explorer と同じ複数選択。ルートは ''）
local hunk_state = nil
local hunk_hl_ns = vim.api.nvim_create_namespace('git_panel_hunk')

local function is_untracked(f) return f.x == '?' and f.y == '?' end
-- porcelain の未マージ状態（git status のドキュメントにある衝突の組み合わせ）。
-- どちらか片方でも 'U' なら衝突、DD と AA も両者が触った衝突扱い
local CONFLICT_CODES = {
  DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true,
}
local function is_conflicted(f) return CONFLICT_CODES[f.x .. f.y] == true end
M.is_conflicted = is_conflicted
local function has_staged(f) return f.x ~= ' ' and f.x ~= '?' end
local function has_unstaged(f) return f.y ~= ' ' or is_untracked(f) end
-- lazygit(models/file.go deriveStatusFields)のTrackedと同じ: 新規追加(A /AM)と未追跡(??)
-- 以外はtracked。アンステージ時にreset(tracked)かrm --cached(untracked)かを分けるのに使う
local function is_tracked(f)
  local code = f.x .. f.y
  return code ~= '??' and code ~= 'A ' and code ~= 'AM'
end

--- 行の同一性キー。tree表示はパスがそのままキーになるが、list表示では同じファイルが
--- 「ステージ済み」と「変更」の両セクションに並びうる（VSCode と同じ）ため、
--- セクション込みの id を別に持たせてカーソル記憶・選択・右ペインのキャッシュを分ける
local function nid(node) return node.id or node.path end

--- git.status()の`-z`出力(lazygit file_loader.goのgitStatus()と同形式)をパースする。
--- NUL区切りなのでスペース/特殊文字を含むパスもクォート無しの生バイトのまま渡ってくる。
--- Rename/Copy(先頭が'R'か'C')は次の要素が旧パス(単体、"old -> new"のような
--- human-readable表記ではない)になるので、そこだけ2要素消費してprevious_pathへ入れる
local function parse_status(output)
  local records = vim.split(output or '', '\0', { plain = true })
  local list = {}
  local i = 1
  while i <= #records do
    local rec = records[i]
    if rec ~= '' then
      local x, y, path = rec:sub(1, 1), rec:sub(2, 2), rec:sub(4)
      local previous_path = nil
      if x == 'R' or x == 'C' then
        previous_path = records[i + 1]
        i = i + 1
      end
      -- ネストしたgitリポジトリ(.gitを含む未追跡ディレクトリ)等、gitが展開せず
      -- "dir/"の形で1行にまとめて返すことがある。末尾の"/"が残るとbuild_treeで
      -- ファイル名抽出(name:match('([^/]+)$'))に失敗してnilになるため、ここで落とす
      path = path:gsub('/$', '')
      table.insert(list, { path = path, x = x, y = y, previous_path = previous_path })
    end
    i = i + 1
  end
  return list
end

-- ══════════════════════════════════════════════
-- ツリー構築
-- ══════════════════════════════════════════════

--- lazygit(pkg/gui/filetree/node.go compressAux)と同じ圧縮: ディレクトリの子が
--- ちょうど1つだけ、かつその子もディレクトリの場合にだけ連結する（子がファイル
--- 1つだけの場合は連結しない）。単一の子ディレクトリが連なる限り繰り返し辿って
--- 一番深いノードに差し替えることで、"hoge"→"fuga"の2行を"hoge/fuga"の1行にする
local function compress(node)
  if not node.is_dir then return end
  local children = node.children
  for i, child in ipairs(children) do
    local grandchildren = child.children
    while grandchildren and #grandchildren == 1 and grandchildren[1].is_dir do
      children[i] = grandchildren[1]
      grandchildren = children[i].children
    end
  end
  for _, child in ipairs(children) do
    compress(child)
  end
end

local function build_tree(list)
  local root = { name = '', path = '', is_dir = true, children = {} }
  local dir_index = { [''] = root }

  local function get_or_create_dir(path)
    if dir_index[path] then return dir_index[path] end
    local parent_path = path:match('^(.*)/[^/]+$') or ''
    local parent = get_or_create_dir(parent_path)
    local name = path:match('([^/]+)$')
    local node = { name = name, path = path, is_dir = true, children = {} }
    table.insert(parent.children, node)
    dir_index[path] = node
    return node
  end

  for _, f in ipairs(list) do
    local dir_path = f.path:match('^(.*)/[^/]+$') or ''
    local parent = get_or_create_dir(dir_path)
    local name = f.path:match('([^/]+)$')
    table.insert(parent.children, { name = name, path = f.path, is_dir = false, file = f })
  end

  local function sort_children(node)
    table.sort(node.children, function(a, b) return a.name:lower() < b.name:lower() end)
    for _, c in ipairs(node.children) do
      if c.is_dir then sort_children(c) end
    end
  end
  sort_children(root)
  compress(root)
  return root
end

--- VSCode の Source Control と同じセクション構成・同じ並び順。
--- 衝突中のファイルは Merge Changes 相当の専用セクションへ集め、それ以外は
--- ステージ済み側/未ステージ側の印がある方に入れる（両方あれば両方に出る）
local LIST_SECTIONS = {
  { section = 'merge',    label = 'Merge Changes' },
  { section = 'staged',   label = 'Staged Changes' },
  { section = 'unstaged', label = 'Changes' },
}

local function list_id(section, path) return section .. ':' .. path end

--- そのファイルがlist表示でどのセクションに並ぶか（両方に出る場合は未ステージ側を優先）。
--- 表示モードを切り替えた時にカーソルを同じファイルへ着地させるのに使う
local function primary_section(f)
  if is_conflicted(f) then return 'merge' end
  if has_unstaged(f) then return 'unstaged' end
  return 'staged'
end

local function in_section(f, section)
  if is_conflicted(f) then return section == 'merge' end
  if section == 'staged' then return has_staged(f) end
  if section == 'unstaged' then return has_unstaged(f) end
  return false
end

--- list表示のノード木。ルート(非表示)の下にセクション、その下にファイルを平らに並べる。
--- 空のセクションは行ごと出さない（VSCode も変更が無いセクションは畳んで消える）
local function build_list(list)
  local sorted = vim.list_extend({}, list)
  table.sort(sorted, function(a, b) return a.path:lower() < b.path:lower() end)

  local root = { name = '', path = '', is_dir = true, children = {} }
  for _, def in ipairs(LIST_SECTIONS) do
    local children = {}
    for _, f in ipairs(sorted) do
      if in_section(f, def.section) then
        table.insert(children, {
          name = f.path:match('([^/]+)$'),
          dir = f.path:match('^(.*)/[^/]+$'),
          path = f.path,
          id = list_id(def.section, f.path),
          is_dir = false,
          file = f,
          section = def.section,
        })
      end
    end
    if #children > 0 then
      table.insert(root.children, {
        name = def.label,
        label = def.label,
        id = '§' .. def.section,
        is_dir = true,
        is_section = true,
        section = def.section,
        children = children,
      })
    end
  end
  return root
end

local function build_root()
  if view_mode == 'list' then return build_list(files) end
  return build_tree(files)
end

--- list表示のファイル行は「並んでいるセクション側」しか操作対象にしない。
--- ステージ済みセクションの行は（未ステージの変更も残っていても）Space でアンステージ、
--- 変更セクションの行はステージ。名前の色分けも同じ考え方で決まる
local function node_flags(node)
  if not node.is_dir then
    local s, u = has_staged(node.file), has_unstaged(node.file)
    if node.section == 'staged' then return s, false end
    if node.section then return false, u end -- unstaged / merge
    return s, u
  end
  local any_s, any_u = false, false
  for _, c in ipairs(node.children) do
    local s, u = node_flags(c)
    any_s = any_s or s
    any_u = any_u or u
  end
  return any_s, any_u
end

--- 配下（ファイルなら自分自身）に衝突があるか。ディレクトリも赤で示すために使う
local function node_conflicted(node)
  if not node.is_dir then return is_conflicted(node.file) end
  for _, c in ipairs(node.children) do
    if node_conflicted(c) then return true end
  end
  return false
end

local function collect_files(node, out)
  out = out or {}
  if node.is_dir then
    for _, c in ipairs(node.children) do collect_files(c, out) end
  else
    table.insert(out, node.file)
  end
  return out
end

-- ══════════════════════════════════════════════
-- アイコン（拡張子ごと、tabline.lua/explorer.luaと同方式）
-- ══════════════════════════════════════════════

-- アイコン定義は config.util.file_icons に集約（explorer/git_panel/tabline で共有）
local file_icons = require('config.util.file_icons')
local function get_icon(name, is_dir, path) return file_icons.get(name, is_dir, path) end
local function icon_char(code) return file_icons.char(code) end
local FOLDER_OPEN_ICON = 0xe5fe -- explorer.lua / nvim-tree.lua default folder.open: ""
local TREE_ARROW_CLOSED = ''
local TREE_ARROW_OPEN = ''

-- ══════════════════════════════════════════════
-- 描画
-- ══════════════════════════════════════════════

local function current_entry()
  return ctx.current_entry(function() return line_entries end)
end

--- 明示的な操作を伴わないrefresh（自動更新・Rキー）の直前に呼ばれ、今カーソルが
--- 乗っている項目をcursor_memに反映する。個別の操作関数が意図的にcursor_mem
--- を設定/nil化した直後にrefresh()する場合はこれを経由しないので上書きされない
function M.remember_cursor()
  local node = current_entry()
  if node then cursor_mem = nid(node) end
end

local function current_id_is(id)
  local node = current_entry()
  return node and nid(node) == id
end

local function still_current(id)
  return ctx.current_panel_name() == 'files' and current_id_is(id)
end

local function show_diff_for(node, prefer_staged)
  if not node then ctx.set_right_lines({}); return end
  local key = nid(node)
  -- list表示はセクションが「どちら側の差分か」を決める（ステージ済みセクションの
  -- 行にカーソルを置いたらステージ済み差分が出る）
  if node.section then prefer_staged = node.section == 'staged' end
  if node.is_dir then
    -- lazygit(files_controller.go GetOnRenderToMain -> renderWorkingTreeDiff)と同じ:
    -- ディレクトリでもファイル単体と全く同じgit diff -- <path>を使い、配下の
    -- 変更ファイルをまとめた差分をそのまま表示する(「N個のファイル」という
    -- 独自の要約表示はしない)。staged/unstagedの判定も配下のどこかにあれば
    -- 対象にする(node_flagsが再帰的に集計している)
    local any_staged, any_unstaged = node_flags(node)
    local section = (prefer_staged and any_staged) and 'staged' or (any_unstaged and 'unstaged' or 'staged')
    -- ルートノードとセクション行のpathは無いので、git diffの pathspecは"."(=全体)にする
    local path = (node.path and node.path ~= '') and node.path or '.'
    git.diff_file({ path = path, section = section }, function(diff_text)
      if not still_current(key) then return end
      ctx.set_right_diff(diff_text, key)
    end)
    return
  end
  local f = node.file
  if is_untracked(f) then
    local full = ctx.get_root() .. '/' .. f.path
    if vim.fn.isdirectory(full) == 1 then
      ctx.set_right_lines({ '(ディレクトリ: ' .. f.path .. ')' }, nil, nil, key)
      return
    end
    -- lazygitと同じくgit diff --no-index -- /dev/null <path>で本物のunified diffを
    -- 得る(diff --git等のヘッダーが揃うので描画側が構造を読める。バイナリ判定も
    -- gitが"Binary files ... differ"を出すのでこちらで個別に読む必要がない)
    git.diff_untracked_file(f.path, function(diff_text)
      if not still_current(key) then return end
      ctx.set_right_diff(diff_text, key)
    end)
    return
  end
  local section = (prefer_staged and has_staged(f)) and 'staged' or (has_unstaged(f) and 'unstaged' or 'staged')
  git.diff_file({ path = f.path, section = section }, function(diff_text)
    if not still_current(key) then return end
    ctx.set_right_diff(diff_text, key)
  end)
end

--- lazygit(pkg/gui/presentation/files.go formatFileStatus)と同じ配色:
--- 1文字目(index=staged側)は緑、ただし'?'(untracked)は赤、空白は無色。
--- 2文字目(worktree=unstaged側)は常に赤、空白は無色。
--- M/A/D等の文字の「意味」では色分けしない。あくまで列の位置だけで決まる
local function status_char_hl(ch, is_staged_col)
  if ch == ' ' then return nil end
  if is_staged_col and ch ~= '?' then return 'GitPanelStatusStaged' end
  return 'GitPanelStatusUnstaged'
end

local function render()
  local lines, hl_queue = {}, {}
  line_entries = {}

  local function push(text, entry, hlgroup, col_start, col_end)
    table.insert(lines, text)
    line_entries[#lines] = entry
    if hlgroup then table.insert(hl_queue, { #lines - 1, hlgroup, col_start, col_end }) end
  end

  push('  ' .. (branch ~= '' and branch or '(no branch)'), nil, 'GitPanelHeader')
  push('', nil)

  -- lazygitのShowRootItemInFileTree(デフォルトtrue)に合わせ、ルートを"/"として
  -- 選択可能な1行にする。ここでSpaceを押すと全ファイルがステージ/アンステージされる
  local remembered_row = nil
  -- 記憶しているキーの行が消えていても（ステージしてセクションを移った、表示モードを
  -- 切り替えた等）、同じファイルの行があればそこへ着地させるための保険
  local fallback_row = nil
  local mem_path = cursor_mem and (cursor_mem:match('^%a+:(.+)$') or cursor_mem)
  local function walk(node, depth, parent_path)
    local id = nid(node)
    local is_root = not node.is_section and node.path == ''
    -- 圧縮(compress)で"hoge"の子スロットに"fuga"が直接差し込まれている場合、
    -- node.pathは元々のフルパス("hoge/fuga")のまま変わっていないので、
    -- 呼び出し元(parent_path)からの相対部分を取り出せば"hoge/fuga"と表示できる
    local display_name
    if node.is_section then
      display_name = node.label .. '  (' .. #node.children .. ')'
    elseif is_root then
      display_name = '/'
    elseif view_mode == 'list' then
      display_name = node.name -- list表示はファイル名だけ。ディレクトリは後ろへ薄く添える
    elseif parent_path == nil or parent_path == '' then
      display_name = node.path
    else
      display_name = node.path:sub(#parent_path + 2)
    end
    local s, u = node_flags(node)
    -- ファイル名(+アイコン/ディレクトリの矢印)の色: 実物のnameColorと同じ
    -- staged onlyなら緑、staged+unstagedなら黄、それ以外は無色
    local conflicted = node_conflicted(node)
    local name_color
    if node.is_section then name_color = 'GitPanelSection'
    elseif conflicted then name_color = 'GitPanelConflict' -- 衝突は VSCode と同じく赤で目立たせる
    elseif s and not u then name_color = 'GitPanelAdded'
    elseif s then name_color = 'GitPanelModified'
    end
    local indent = string.rep('  ', depth)
    -- ステータス欄: ディレクトリ/セクションは開閉の矢印、ファイルはporcelainの2文字。
    -- list表示のファイルは並んでいるセクション側の1文字だけを出す（ステージ済み
    -- セクションで"MM"と出ても片方は意味を持たないため）
    local status_str
    if node.is_dir then
      status_str = collapsed[id] and TREE_ARROW_CLOSED or TREE_ARROW_OPEN
    elseif view_mode == 'list' and node.section == 'staged' then
      status_str = node.file.x .. ' '
    elseif view_mode == 'list' and node.section == 'unstaged' then
      status_str = (is_untracked(node.file) and '?' or node.file.y) .. ' '
    else
      status_str = node.file.x .. node.file.y
    end
    local icon = node.is_dir and not collapsed[id]
      and icon_char(FOLDER_OPEN_ICON) or get_icon(display_name, node.is_dir, node.path)
    -- yazi の marker_symbol("│") 相当: 選択行は左端に色付きバー、文字色は変えない
    local marker = selection[id] and '│' or ' '
    local status_prefix = marker .. ' ' .. indent
    local before_name = status_prefix .. status_str .. ' '
    -- セクション行はラベルだけ（ファイルアイコンは付けない）
    local line = before_name .. (node.is_section and display_name or (icon .. ' ' .. display_name))
    -- name_colorはアイコン+ファイル名部分だけに適用する（ステータス文字は別配色）
    local name_end = #line
    local dir_start
    if view_mode == 'list' and not node.is_dir and node.dir then
      dir_start = #line
      line = line .. '  ' .. node.dir
    end
    push(line, node, name_color, #before_name, name_end)
    if dir_start then
      table.insert(hl_queue, { #lines - 1, 'GitPanelDim', dir_start, -1 })
    end
    if cursor_mem == id then
      remembered_row = #lines
    elseif not fallback_row and mem_path and node.path == mem_path then
      fallback_row = #lines
    end

    local status_base = #status_prefix
    if node.is_dir then
      table.insert(hl_queue, { #lines - 1, 'GitPanelTreeArrow', status_base, status_base + #status_str })
    elseif conflicted then
      table.insert(hl_queue, { #lines - 1, 'GitPanelConflict', status_base, status_base + #status_str })
    elseif view_mode == 'list' then
      -- 1文字しか出していないので、そのセクション側の色だけを当てる
      local c = status_char_hl(status_str:sub(1, 1), node.section == 'staged')
      if c then table.insert(hl_queue, { #lines - 1, c, status_base, status_base + 1 }) end
    else
      local c1 = status_char_hl(node.file.x, true)
      local c2 = status_char_hl(node.file.y, false)
      if c1 then table.insert(hl_queue, { #lines - 1, c1, status_base, status_base + 1 }) end
      if c2 then table.insert(hl_queue, { #lines - 1, c2, status_base + 1, status_base + 2 }) end
    end
    if selection[id] then
      table.insert(hl_queue, { #lines - 1, 'GitPanelSelected', 0, #marker })
    end

    if node.is_dir and not collapsed[id] then
      for _, c in ipairs(node.children) do
        walk(c, depth + 1, node.path)
      end
    end
  end
  if view_mode == 'list' then
    -- list表示のルートは器なので描画しない（セクション行がその役目を果たす）
    for _, section in ipairs(root_node.children) do walk(section, 0, nil) end
    if #root_node.children == 0 then push('  (変更はありません)', nil, 'GitPanelDim') end
  else
    walk(root_node, 0, nil)
  end

  -- 消えた行の選択を刈り取る（自動更新で残骸を残さない）
  local alive = {}
  for _, e in pairs(line_entries) do
    if e then alive[nid(e)] = true end
  end
  for p in pairs(selection) do
    if not alive[p] then selection[p] = nil end
  end

  total_rows = #lines
  ctx.set_left_lines(lines, hl_queue)

  local target = remembered_row or fallback_row
  if not target then
    for i = 1, total_rows do
      if line_entries[i] then target = i; break end
    end
  end
  if target then
    ctx.set_left_cursor(target)
    show_diff_for(line_entries[target])
  else
    show_diff_for(nil)
  end
end

--- auto_captureはinit.luaの自動更新/Rキーから汎用refresh扱いの時だけtrueで渡される。
--- render()の直前で今のカーソル位置を捕捉することで、非同期処理中にユーザーがj/kで
--- 動かした分を取りこぼさないようにする
function M.refresh(auto_capture)
  local pending = 2
  local function done()
    pending = pending - 1
    if pending == 0 then
      root_node = build_root()
      if auto_capture then M.remember_cursor() end
      render()
    end
  end
  git.branch_name(function(name) branch = name; done() end)
  git.status(function(out) files = parse_status(out); done() end)
end

function M.review_diff(cb)
  git.diff_worktree_all(cb)
end

-- ══════════════════════════════════════════════
-- hunk単位ステージング
-- ══════════════════════════════════════════════

local function leave_staging_mode()
  hunk_state = nil
  ctx.refocus_left()
  show_diff_for(current_entry())
end

local function render_hunk_view()
  local lines = {}
  vim.list_extend(lines, hunk_state.header)
  local ranges = {}
  for i, hunk in ipairs(hunk_state.hunks) do
    local start = #lines
    table.insert(lines, hunk.header)
    vim.list_extend(lines, hunk.lines)
    ranges[i] = { start, #lines - 1 }
  end
  hunk_state.ranges = ranges
  ctx.set_right_lines(lines, 'diff')

  local rbuf = ctx.get_right_buf()
  if rbuf and vim.api.nvim_buf_is_valid(rbuf) then
    vim.api.nvim_buf_clear_namespace(rbuf, hunk_hl_ns, 0, -1)
    local r = ranges[hunk_state.idx]
    if r then
      for ln = r[1], r[2] do
        vim.api.nvim_buf_add_highlight(rbuf, hunk_hl_ns, 'GitPanelHunkSelected', ln, 0, -1)
      end
    end
  end
end

local function move_hunk(delta)
  hunk_state.idx = math.max(1, math.min(#hunk_state.hunks, hunk_state.idx + delta))
  render_hunk_view()
end

local function stage_current_hunk()
  local hunk = hunk_state.hunks[hunk_state.idx]
  local opts = hunk_state.staged and { cached = true, reverse = true } or { cached = true }
  git.apply_hunk(hunk_state.header, hunk, opts, function(res)
    ctx.render_cmdlog()
    if res.code ~= 0 then
      vim.notify('hunk適用に失敗しました: ' .. (res.stderr or ''), vim.log.levels.ERROR)
      return
    end
    leave_staging_mode()
    M.refresh()
  end)
end

local function discard_current_hunk()
  if hunk_state.staged then
    stage_current_hunk()
    return
  end
  local hunk = hunk_state.hunks[hunk_state.idx]
  local header = hunk_state.header
  ctx.confirm('このhunkを破棄しますか？', function(ok)
    if not ok then return end
    git.apply_hunk(header, hunk, { reverse = true }, function(res)
      ctx.render_cmdlog()
      if res.code ~= 0 then
        vim.notify('破棄に失敗しました: ' .. (res.stderr or ''), vim.log.levels.ERROR)
        return
      end
      leave_staging_mode()
      M.refresh()
    end)
  end)
end

local function toggle_hunk_view_side()
  local node = hunk_state.node
  local f = node.file
  if not (has_staged(f) and has_unstaged(f)) then return end
  hunk_state.staged = not hunk_state.staged
  git.diff_file({ path = f.path, section = hunk_state.staged and 'staged' or 'unstaged' }, function(diff_text)
    local header, hunks = git.parse_hunks(diff_text)
    hunk_state.header, hunk_state.hunks, hunk_state.idx = header, hunks, 1
    render_hunk_view()
  end)
end

local function setup_hunk_keymaps()
  local rbuf = ctx.get_right_buf()
  local function map(key, fn) vim.keymap.set('n', key, fn, { buffer = rbuf, nowait = true, silent = true }) end
  map('h', function() move_hunk(-1) end)
  map('<Left>', function() move_hunk(-1) end)
  map('l', function() move_hunk(1) end)
  map('<Right>', function() move_hunk(1) end)
  map('<Space>', stage_current_hunk)
  map('d', discard_current_hunk)
  map('<Tab>', toggle_hunk_view_side)
  map('<Esc>', leave_staging_mode)
  map('q', leave_staging_mode)
end

local function enter_staging_mode()
  local node = current_entry()
  if not node or node.is_dir then return end
  local f = node.file
  if is_untracked(f) then
    vim.notify('新規ファイルはhunk単位のステージに未対応です。Spaceでファイル単位でステージしてください', vim.log.levels.WARN)
    return
  end
  -- list表示では「今どちらのセクションに並んでいる行から入ったか」でどちら側の
  -- hunkを触るかが決まる（ステージ済みセクション→ステージ済み差分のhunk）
  local staged_first
  if node.section then
    staged_first = node.section == 'staged'
  else
    staged_first = has_staged(f) and not has_unstaged(f)
  end
  git.diff_file({ path = f.path, section = staged_first and 'staged' or 'unstaged' }, function(diff_text)
    if not still_current(nid(node)) then return end
    local header, hunks = git.parse_hunks(diff_text)
    if #hunks == 0 then return end
    hunk_state = { node = node, header = header, hunks = hunks, idx = 1, staged = staged_first }
    render_hunk_view()
    local rwin = ctx.get_right_win()
    if rwin and vim.api.nvim_win_is_valid(rwin) then
      vim.api.nvim_set_current_win(rwin)
    end
    setup_hunk_keymaps()
  end)
end

-- ══════════════════════════════════════════════
-- 複数選択（Explorer と同じキー: Tab / S-Tab / Ctrl-a / Ctrl-r / Esc）
-- ══════════════════════════════════════════════

local function selected_nodes()
  if vim.tbl_count(selection) > 0 then
    local list = {}
    for i = 1, total_rows do
      local n = line_entries[i]
      if n and selection[nid(n)] then table.insert(list, n) end
    end
    return list
  end
  local n = current_entry()
  return n and { n } or {}
end

local function pathspec_of(node)
  return node.path ~= '' and node.path or '.'
end

--- セクション行は自分のパスを持たない「中身の集合」なので、実際に git へ渡す前に
--- 配下のファイル行へ展開する
local function expand_sections(nodes)
  local out = {}
  for _, node in ipairs(nodes) do
    if node.is_section then
      for _, c in ipairs(node.children) do table.insert(out, c) end
    else
      table.insert(out, node)
    end
  end
  return out
end

local function toggle_select_at_cursor(step)
  step = step or 1
  local node = current_entry()
  if not node then return end
  local id = nid(node)
  if selection[id] then
    selection[id] = nil
  else
    selection[id] = true
  end
  cursor_mem = id
  render()
  local lwin = ctx.get_left_win()
  if lwin and vim.api.nvim_win_is_valid(lwin) then
    local row = vim.api.nvim_win_get_cursor(lwin)[1]
    local target = row + step
    while target >= 1 and target <= total_rows do
      if line_entries[target] then
        pcall(vim.api.nvim_win_set_cursor, lwin, { target, 0 })
        show_diff_for(line_entries[target])
        break
      end
      target = target + (step > 0 and 1 or -1)
    end
  end
end

local function select_all()
  for i = 1, total_rows do
    local n = line_entries[i]
    if n then selection[nid(n)] = true end
  end
  render()
end

local function invert_selection()
  for i = 1, total_rows do
    local n = line_entries[i]
    if n then
      local id = nid(n)
      if selection[id] then
        selection[id] = nil
      else
        selection[id] = true
      end
    end
  end
  render()
end

local function clear_selection_or_close()
  if vim.tbl_count(selection) > 0 then
    selection = {}
    local node = current_entry()
    if node then cursor_mem = nid(node) end
    render()
  else
    require('config.git_panel').close()
  end
end

-- ══════════════════════════════════════════════
-- 操作（ファイル or ディレクトリ配下すべてに適用）
-- ══════════════════════════════════════════════

local function toggle_collapse()
  local node = current_entry()
  if not node or not node.is_dir then return end
  local id = nid(node)
  collapsed[id] = not collapsed[id]
  cursor_mem = id
  render()
end

--- t: ツリー表示 ⇄ セクション別のフラット一覧。tree の行キーはパス、list は
--- "section:パス" と別物なので、カーソルは今いるファイルの新しいキーへ寄せ直す
local function toggle_view_mode()
  local node = current_entry()
  view_mode = view_mode == 'tree' and 'list' or 'tree'
  selection = {}
  cursor_mem = nil
  if node and not node.is_dir then
    cursor_mem = view_mode == 'list'
      and list_id(primary_section(node.file), node.file.path)
      or node.file.path
  end
  root_node = build_root()
  render()
end

local function enter_or_toggle()
  local node = current_entry()
  if not node then return end
  if node.is_dir then toggle_collapse() else enter_staging_mode() end
end

local batched -- 前方宣言（stage_toggle から参照）

local function stage_toggle()
  local nodes = expand_sections(selected_nodes())
  if #nodes == 0 then return end
  local cur = current_entry()
  if cur then cursor_mem = nid(cur) end
  local function done()
    selection = {}
    ctx.render_cmdlog()
    M.refresh()
  end

  -- lazygit(files_controller.go pressWithLock)と同じ「パス単位」方式。表示されている
  -- ファイル行を個別に列挙するのではなく、選択ノードのパス(ディレクトリならそのディレクトリ、
  -- ルートなら".")をそのままgitに渡し、配下の再帰はgitに任せる。
  -- こうすると「木に出ていないステージ済み削除」なども確実に対象へ含められる。
  -- 個別列挙だと表示に無いエントリを拾えず「Dだけアンステージされない」不具合になっていた。
  --
  -- 複数選択時: 配下(自分含む)に未ステージが1つでもあれば一括ステージ、無ければ一括アンステージ
  local any_unstaged = false
  for _, node in ipairs(nodes) do
    local _, u = node_flags(node)
    if u then any_unstaged = true; break end
  end

  local pathspecs = {}
  for _, node in ipairs(nodes) do
    table.insert(pathspecs, pathspec_of(node))
  end

  if any_unstaged then
    -- git add -- <path>: git2.0以降はディレクトリ指定でも配下の削除を拾う(git add -A相当)。
    -- 未ステージ削除の単体ファイルにもマッチする。ステージ済みのみの削除は
    -- any_unstaged=falseでここへ来ないので pathspec エラーにもならない
    git.run(vim.list_extend({ 'add', '--' }, pathspecs), done)
    return
  end

  -- 全部ステージ済み → アンステージ。lazygitはディレクトリを常にtracked扱いにして
  -- git reset HEAD -- <dir> 一発で配下全部(削除・新規追加含む)をindexから戻す。
  -- 単体の新規追加ファイル(A 等、HEADに無い)だけは git rm --cached でないと外せない
  local to_reset, to_rm = {}, {}
  for _, node in ipairs(nodes) do
    local ps = pathspec_of(node)
    if node.is_dir or is_tracked(node.file) then
      table.insert(to_reset, ps)
    else
      table.insert(to_rm, ps)
    end
  end
  batched({ 'reset', 'HEAD', '--' }, to_reset, function()
    batched({ 'rm', '--cached', '--force', '--' }, to_rm, done)
  end)
end

local function stage_all_toggle()
  local any_unstaged = false
  for _, f in ipairs(files) do
    if has_unstaged(f) then any_unstaged = true; break end
  end
  cursor_mem = nil
  local function done() ctx.render_cmdlog(); M.refresh() end
  if any_unstaged then git.stage_all(done) else git.unstage_all(done) end
end

--- files_controller.go remove()相当の並列実行ヘルパー。per_file(f, done)が各対象への
--- 実処理、doneを呼んだ回数が対象数に達したらon_all_doneを呼ぶ
--- ファイルごとに個別のgitプロセスを並行実行すると、複数プロセスが同時に
--- .git/index.lockを取り合って一部だけ失敗することがある(実際に対象ファイルが
--- 複数ある時に再現した)。lazygit本体のDiscardAllDirChanges/DiscardUnstagedDirChanges
--- も同じ理由でパスを種別ごとに集めてバッチで1回のgitコマンドにまとめているので、
--- それに合わせる(removeFilesはgitを介さない直接のファイル削除なのでロック競合が無い)
local function remove_from_disk(paths)
  for _, p in ipairs(paths) do
    -- 'rf'必須: 未追跡ディレクトリ(nested git repo等、--untracked-files=allでも
    -- 展開されず1行になるものがある)は非再帰のdeleteだと空でない限り削除できない
    vim.fn.delete(git.root .. '/' .. p, 'rf')
  end
end

batched = function(args_prefix, paths, cb)
  if #paths == 0 then cb(); return end
  git.run(vim.list_extend(vim.deepcopy(args_prefix), paths), cb)
end

--- DiscardAllDirChanges相当: ステージ済みのパスはまとめてreset(unstage)してから、
--- 元々untracked/新規追加(A)だったパスはディスクから直接削除、それ以外はまとめてcheckout
--- lazygit(working_tree.go DiscardAllFileChanges)と同じく、renameは
--- 「旧パスの削除」+「新パスの追加」の2つに分解して扱う: 旧パスはindexを戻して
--- checkoutで復元、新パスはindexから外してディスクから削除する(=リネームを完全に取り消す)
local function discard_all_targets(targets)
  cursor_mem = nil
  selection = {}
  local to_reset, to_remove, to_checkout = {}, {}, {}
  for _, f in ipairs(targets) do
    if f.previous_path then
      table.insert(to_reset, f.previous_path)
      table.insert(to_reset, f.path)
      table.insert(to_checkout, f.previous_path)
      table.insert(to_remove, f.path)
    else
      local was_added = f.x == 'A' or is_untracked(f)
      if has_staged(f) then table.insert(to_reset, f.path) end
      table.insert(was_added and to_remove or to_checkout, f.path)
    end
  end
  batched({ 'reset', '--' }, to_reset, function()
    remove_from_disk(to_remove)
    batched({ 'checkout', '--' }, to_checkout, function()
      ctx.render_cmdlog()
      M.refresh()
    end)
  end)
end

--- DiscardUnstagedDirChanges相当: indexには触れず、まとめて作業ツリーの差分だけを戻す。
--- ステージ済みの内容はそのまま残る
local function discard_unstaged_targets(targets)
  cursor_mem = nil
  selection = {}
  local to_remove, to_checkout = {}, {}
  for _, f in ipairs(targets) do
    table.insert(is_untracked(f) and to_remove or to_checkout, f.path)
  end
  remove_from_disk(to_remove)
  batched({ 'checkout', '--' }, to_checkout, function()
    ctx.render_cmdlog()
    M.refresh()
  end)
end

--- files_controller.go remove()相当: すべての変更を破棄 / ステージされていない変更を破棄
--- の2択メニュー。後者はステージ済み+未ステージが両方ある対象を含む時だけ意味があるため、
--- そうでなければ選択肢自体を出さない(lazygitはグレーアウト、こちらは項目自体を省く簡略化)
local function discard()
  local nodes = selected_nodes()
  if #nodes == 0 then return end
  local targets, seen = {}, {}
  for _, node in ipairs(nodes) do
    for _, f in ipairs(collect_files(node)) do
      if not seen[f.path] then
        seen[f.path] = true
        table.insert(targets, f)
      end
    end
  end
  if #targets == 0 then return end
  local label
  if vim.tbl_count(selection) > 0 then
    label = '選択 ' .. #targets .. '件'
  elseif nodes[1].is_section then
    label = nodes[1].label .. ' ' .. #targets .. '件'
  elseif nodes[1].is_dir then
    local p = nodes[1].path
    label = (p ~= '' and p or '/') .. '/ 配下 ' .. #targets .. '件'
  else
    label = nodes[1].file.path
  end
  local any_staged, any_unstaged = false, false
  for _, f in ipairs(targets) do
    if has_staged(f) then any_staged = true end
    if has_unstaged(f) then any_unstaged = true end
  end
  local items = { { key = 'x', label = 'すべての変更を破棄', value = 'all' } }
  if any_staged and any_unstaged then
    table.insert(items, { key = 'u', label = 'ステージされていない変更を破棄', value = 'unstaged' })
  end
  ctx.menu('破棄: ' .. label, items, function(choice)
    if choice == 'all' then discard_all_targets(targets)
    elseif choice == 'unstaged' then discard_unstaged_targets(targets)
    end
  end)
end

local function ignore_file()
  local node = current_entry()
  if not node or node.is_dir then return end
  git.ignore_file(node.file.path, function() ctx.render_cmdlog(); M.refresh() end)
end

local function copy_path()
  local node = current_entry()
  if not node or not node.path then return end -- セクション行はパスを持たない
  vim.fn.setreg('"', node.path)
  pcall(vim.fn.setreg, '+', node.path)
  vim.notify('コピーしました: ' .. node.path, vim.log.levels.INFO)
end

local function open_file()
  local node = current_entry()
  if not node or node.is_dir then return end
  ctx.open_file_in_origin(ctx.get_root() .. '/' .. node.file.path)
end

local function commit(no_verify)
  ctx.multiline_input('コミットメッセージ', function(msg_lines)
    if not msg_lines then return end
    local msg = table.concat(msg_lines, '\n')
    if vim.trim(msg) == '' then
      vim.notify('コミットメッセージが空です', vim.log.levels.WARN)
      return
    end
    git.commit(msg_lines, no_verify, ctx.done_refresh(function() cursor_mem = nil; M.refresh() end, 'コミット'))
  end)
end

local function amend()
  ctx.confirm('ステージ済みの変更でHEADをamendしますか？', function(ok)
    if not ok then return end
    git.amend(ctx.done_refresh(function() cursor_mem = nil; M.refresh() end, 'amend'))
  end)
end

--- files_controller.go fetch()相当（KeybindingFilesConfig.Fetch既定"f"）。
--- 成功時は無通知（push/pullと同じくパネル再描画自体が結果を表す）。
--- lazygitのPostFetchRefreshと同じく、fetch完了時にBranchesパネルのPR状態も更新する
local function fetch()
  ctx.set_loading('Fetching')
  git.fetch(function(res)
    ctx.clear_loading()
    ctx.render_cmdlog()
    if res.code ~= 0 then
      vim.notify('fetch失敗: ' .. (res.stderr or ''), vim.log.levels.ERROR)
      return
    end
    M.refresh()
    require('config.git_panel.branches').refresh_prs()
  end)
end

--- files_controller.go handleStashSave相当。AllowEmptyInput=trueと同じく、
--- 空メッセージのままEnterしてもキャンセルにはせずスタッシュを実行する
local function stash_with(opts)
  ctx.input('スタッシュメッセージ', '', function(msg)
    if msg == nil then return end
    git.stash_save(msg, ctx.done_refresh(function() cursor_mem = nil; M.refresh() end, 'スタッシュ'), opts)
  end)
end

local function stash_all()
  stash_with(nil)
end

--- lazygit KeybindingFilesConfig.ViewStashOptions(既定"S")相当
local function stash_options()
  ctx.menu('スタッシュ', {
    { key = 'a', label = 'すべての変更をスタッシュ', value = 'all' },
    { key = 'u', label = '未追跡ファイルも含めてスタッシュ', value = 'untracked' },
    { key = 't', label = 'ステージ済みのみスタッシュ', value = 'staged' },
    { key = 'k', label = 'インデックスを保持してスタッシュ', value = 'keep_index' },
  }, function(choice)
    if choice == 'all' then stash_with(nil)
    elseif choice == 'untracked' then stash_with({ include_untracked = true })
    elseif choice == 'staged' then stash_with({ staged = true })
    elseif choice == 'keep_index' then stash_with({ keep_index = true })
    end
  end)
end

--- コンフリクト解消メニュー（m）。
--- ファイル単位の一括採用（VSCode の Accept Current/Incoming に相当）と、
--- マージ/リベースの続行・中断をまとめる。行単位の採用はファイルを開いて
--- config.git_conflict（Space x 系）で行う
local function conflict_menu()
  local node = current_entry()
  local target = (node and not node.is_dir and is_conflicted(node.file)) and node.file or nil

  git.merge_state(function(state)
    local items = {}
    if target then
      table.insert(items, { key = 'c', label = '現在の変更を採用（ours）: ' .. target.path, value = 'ours' })
      table.insert(items, { key = 'i', label = '入力側の変更を採用（theirs）: ' .. target.path, value = 'theirs' })
      table.insert(items, { key = 'e', label = 'エディタで開いて1つずつ解消する', value = 'edit' })
    end
    if state then
      table.insert(items, { key = 'n', label = state .. ' を続行する', value = 'continue' })
      table.insert(items, { key = 'a', label = state .. ' を中断する', value = 'abort' })
    end
    if #items == 0 then
      vim.notify('解消が必要な衝突はありません', vim.log.levels.INFO)
      return
    end

    ctx.menu('コンフリクト', items, function(choice)
      if choice == 'ours' or choice == 'theirs' then
        git.take_side(target.path, choice, ctx.done_refresh(function() M.refresh() end, '衝突の解消'))
      elseif choice == 'edit' then
        open_file()
      elseif choice == 'continue' then
        git.continue_in_progress(state, ctx.done_refresh(function() cursor_mem = nil; M.refresh() end, state .. 'の続行'))
      elseif choice == 'abort' then
        ctx.confirm(state .. ' を中断して元の状態に戻しますか？', function(ok)
          if not ok then return end
          git.abort_in_progress(state, ctx.done_refresh(function() cursor_mem = nil; M.refresh() end, state .. 'の中断'))
        end)
      end
    end)
  end)
end

function M.keymaps()
  return {
    ['<Space>'] = stage_toggle,
    m = conflict_menu,
    a = stage_all_toggle,
    d = discard,
    c = function() commit(false) end,
    w = function() commit(true) end,
    A = amend,
    e = open_file,
    o = open_file,
    i = ignore_file,
    y = copy_path,
    s = stash_all,
    S = stash_options,
    f = fetch,
    t = toggle_view_mode,
    ['<CR>'] = enter_or_toggle,
    ['<Tab>'] = function() toggle_select_at_cursor(1) end,
    ['<S-Tab>'] = function() toggle_select_at_cursor(-1) end,
    ['<C-a>'] = select_all,
    ['<C-r>'] = invert_selection,
    ['<Esc>'] = clear_selection_or_close,
  }
end

function M.activate(c)
  ctx = c
  selection = {}
  ctx.setup_cursor_clamp(
    function() return line_entries end,
    function() return total_rows end,
    function(node)
      cursor_mem = nid(node)
      show_diff_for(node)
    end
  )
  M.refresh()
end

return M
