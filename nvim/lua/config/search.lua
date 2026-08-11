-- プロジェクト検索（内容検索 / 置換）
-- 裏側で rg を使うが、rg/fzf は実装手段であって主役ではない。
-- （ファイル名検索は explorer の `/` に一本化したのでここでは扱わない）
-- Requirements: rg, fzf

local M = {}

local win_util = require('config.util.win_util')

local function has_cmd(name)
  return vim.fn.executable(name) == 1
end

local function ensure_deps()
  if not has_cmd('rg') then
    vim.notify('rg が見つかりません', vim.log.levels.ERROR)
    return false
  end
  if not has_cmd('fzf') then
    vim.notify('fzf が見つかりません', vim.log.levels.ERROR)
    return false
  end
  return true
end

--- 選択範囲のテキストを返す（visual mode 用）
local function visual_text()
  local mode = vim.fn.mode()
  if not mode:match('[vV\22]') then
    return ''
  end
  local start_pos = vim.fn.getpos('v')
  local end_pos = vim.fn.getpos('.')
  local lines = vim.fn.getregion(start_pos, end_pos, { type = mode })
  if #lines == 0 then return '' end
  -- 複数行は最初の行だけ（クエリとして扱いやすい）
  return lines[1] or ''
end

function M.open_match(line)
  line = line:gsub('\27%[[0-9;]*m', '')
  -- rg --column 形式: path:line:col:text
  local path, lnum, col = line:match('^([^:]+):(%d+):(%d+):')
  if not path then
    path, lnum = line:match('^([^:]+):(%d+):')
    col = 1
  end
  if not path or path == '' then return end

  lnum = tonumber(lnum) or 1
  col = tonumber(col) or 1

  win_util.focus_editor() -- explorer等にフォーカスがあっても必ず編集窓へ開く
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(col - 1, 0) })
  vim.cmd('normal! zz')
end

function M.parse_path(line)
  line = line:gsub('\27%[[0-9;]*m', '') -- rg --color の ANSI を除去
  local path = line:match('^([^:]+):%d+:%d+:')
  if not path then
    path = line:match('^([^:]+):%d+:')
  end
  return path
end

--- 固定文字列の置換（パターンではなくリテラル）
function M.replace_literal(text, old, new)
  if old == '' then
    return text, 0
  end
  local out = {}
  local i = 1
  local count = 0
  while true do
    local s, e = text:find(old, i, true)
    if not s then
      table.insert(out, text:sub(i))
      break
    end
    table.insert(out, text:sub(i, s - 1))
    table.insert(out, new)
    i = e + 1
    count = count + 1
  end
  return table.concat(out), count
end

function M.resolve_path(cwd, path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return cwd .. '/' .. path
end

--- 開いているバッファがあればバッファ上で置換、なければファイルを直接書き換え
function M.apply_replace_to_path(abs_path, search, replace)
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text = table.concat(lines, '\n')
    local new_text, count = M.replace_literal(text, search, replace)
    if count == 0 then
      return 0
    end
    local new_lines = vim.split(new_text, '\n', { plain = true })
    if text:sub(-1) ~= '\n' and new_text:sub(-1) == '\n' then
      table.remove(new_lines)
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd('silent write')
    end)
    return count
  end

  -- readfile()はNULバイトをNLへ置き換えて返すため(:h readfile()参照)、
  -- そこでNUL判定しても常にfalseになり検出できない。readblob()で生バイトを見る
  local blob_ok, blob = pcall(vim.fn.readblob, abs_path)
  if not blob_ok or type(blob) ~= 'string' or blob:find('\0', 1, true) then
    return 0
  end

  local ok, content = pcall(vim.fn.readfile, abs_path, 'b')
  if not ok or type(content) ~= 'table' then
    return 0
  end
  local text = table.concat(content, '\n')
  local new_text, count = M.replace_literal(text, search, replace)
  if count == 0 then
    return 0
  end
  local new_lines = vim.split(new_text, '\n', { plain = true })
  vim.fn.writefile(new_lines, abs_path, 'b')
  return count
end

local function preview_cmd()
  return [[sed -n '1,200p' -- {1}]]
end

-- VSCode の files to include / exclude 相当。カンマ区切りのグロブを rg の --glob 引数へ変換する。
-- include はそのまま、exclude は先頭に '!' を付ける（rg の除外グロブ表記）。
-- ワイルドカード（* ?）もスラッシュも含まない「裸の名前」は、その名前のディレクトリ配下
-- すべて（**/名前/**）として解釈する。VSCode で 'src' や '.github' と入れた時と同じ直感で、
-- 裸のディレクトリ名だと rg が配下ファイルにマッチしない罠を避ける。.github も普通に効く。
-- 例: build_glob_args('*.lua, *.go', false) → "--glob *.lua --glob *.go"
--     build_glob_args('.github', false)     → "--glob **/.github/**"
--     build_glob_args('node_modules', true) → "--glob !**/node_modules/**"
-- 注意: 空白を含むグロブは reload コマンド側の単語分割で壊れるため非対応（実用上ほぼ問題ない）。
function M.build_glob_args(text, is_exclude)
  local parts = {}
  for piece in (text or ''):gmatch('[^,]+') do
    local p = vim.trim(piece)
    if p ~= '' then
      if not p:find('[*?/]') then
        p = '**/' .. p .. '/**'
      end
      parts[#parts + 1] = '--glob'
      parts[#parts + 1] = (is_exclude and '!' or '') .. p
    end
  end
  return table.concat(parts, ' ')
end

-- include/exclude グロブを一時ファイルから読み込んで rg に渡す reload コマンド。
-- グロブは実行時に変わる（フィールド編集/トグル）ので、fzf 起動時に固定できない値を
-- $(cat) で都度読み込む。set -f でパス名展開を止め、'*.lua' 等がそのまま rg へ渡るようにする。
local function rg_reload_cmd(inc_file, exc_file)
  return string.format(
    [[set -f; test x{q} != x && rg --column --line-number --no-heading --color=always --smart-case --fixed-strings --hidden --glob '!.git/*' $(cat %s 2>/dev/null) $(cat %s 2>/dev/null) -- {q} || true]],
    inc_file, exc_file
  )
end

-- 全置換の対象ファイル一覧を出すコマンド。fzf に並んでいるのと同じ条件
-- （--fixed-strings / --smart-case / 表示中のグロブ）で rg を回す。
function M.rg_files_cmd(query, inc_args, exc_args)
  return string.format(
    [[set -f; rg --files-with-matches --smart-case --fixed-strings --hidden --glob '!.git/*' %s %s -- %s]],
    inc_args or '', exc_args or '', vim.fn.shellescape(query)
  )
end

--- クエリにマッチする全ファイルの絶対パス（全置換の対象）
function M.match_files(cwd, query, inc_args, exc_args)
  if not query or query == '' then return {} end
  local cmd = string.format('cd %s && %s', vim.fn.shellescape(cwd), M.rg_files_cmd(query, inc_args, exc_args))
  local paths = {}
  for _, line in ipairs(vim.fn.systemlist({ 'sh', '-c', cmd })) do
    if line ~= '' then
      paths[#paths + 1] = M.resolve_path(cwd, line)
    end
  end
  return paths
end

--- 与えられたファイル群に置換を適用する
---@return integer file_count
---@return integer replace_count
function M.replace_paths(paths, search, replace)
  local file_count = 0
  local replace_count = 0
  for _, abs_path in ipairs(paths) do
    local n = M.apply_replace_to_path(abs_path, search, replace)
    if n > 0 then
      file_count = file_count + 1
      replace_count = replace_count + n
    end
  end
  vim.cmd('checktime')
  return file_count, replace_count
end

--- 選択されたマッチ行のファイルに対して、検索文字列をすべて置換する
---@return integer file_count
---@return integer replace_count
function M.replace_selected(cwd, selected_lines, search, replace)
  local seen = {}
  local paths = {}
  for _, line in ipairs(selected_lines) do
    local path = M.parse_path(line)
    if path and path ~= '' then
      local abs = M.resolve_path(cwd, path)
      if not seen[abs] then
        seen[abs] = true
        paths[#paths + 1] = abs
      end
    end
  end
  return M.replace_paths(paths, search, replace)
end

-- fzf 窓の下に積む入力欄。既定は3つとも表示で、Tab/Shift-Tab の循環で行き来する。
-- 表示トグルは VSCode 同様に「置換欄」と「include/exclude まとめて」の2つだけ持ち、
-- 隠した欄はその機能ごと無効になる（＝隠す＝一時的に効かせない）。
local FIELD_ORDER = { 'replace', 'include', 'exclude' }
local FIELD_TITLES = {
  replace = ' 置換 (Ctrl-t:対象を選択  Ctrl-s:選択を置換  Ctrl-x:全置換): ',
  include = ' include (,区切り): ',
  exclude = ' exclude (,区切り): ',
}

local HEADER = table.concat({
  'Enter:開く', 'Tab:欄移動', 'Ctrl-r:置換欄', 'Ctrl-g:絞込欄', 'Esc:閉じる',
}, '  ')

-- 置換の実行はクエリと選択行の確定が要る（fzf は別プロセス）。fzf の --bind で
-- 「何をするか」の印を一時ファイルへ書いてから accept させ、Lua側(on_exit)がそれを見て置換する。
-- 置換欄が空（＝非表示のときも空を書く）なら transform が空アクションを返し、fzf は何もしない。
-- transform の中身に ) を含むので、括弧ではなく ~ を区切りに使う（fzf は任意の区切り文字を許す）。
-- transform(...) のままだと execute-silent(...) の閉じ括弧で切れて "unknown action" になる。
local function replace_bind(key, name, rep_file, action_file)
  local inner = string.format(
    [[test -s %s && echo 'execute-silent(printf %%s %s > %s)+accept']],
    rep_file, name, action_file
  )
  return '--bind ' .. vim.fn.shellescape(key .. ':transform~' .. inner .. '~')
end

--- 検索ピッカー（内容検索 + 置換）。fzf 窓の下に 置換 / include / exclude の欄を並べ、
--- Tab / Shift-Tab で fzf を含めて循環する。Enter はあくまでファイルを開く。
--- 置換は Ctrl-s（選択分）/ Ctrl-a（全件）。欄の表示は Ctrl-r / Ctrl-g でトグル。
---@param initial_query? string
---@param state? table  # { replace=string, include=string, exclude=string,
---                        shown={ replace=boolean, globs=boolean } }
function M.open(initial_query, state)
  if not ensure_deps() then return end

  initial_query = initial_query or ''
  state = state or {}
  local shown = vim.tbl_extend('force', { replace = true, globs = true }, state.shown or {})

  local out = vim.fn.tempname()
  local action_file = vim.fn.tempname()
  local rep_file = vim.fn.tempname()
  local inc_file = vim.fn.tempname()
  local exc_file = vim.fn.tempname()
  local cwd = vim.fn.getcwd()
  local closing = false
  local job_id

  local reload = rg_reload_cmd(inc_file, exc_file)
  local fzf_cmd = table.concat({
    'fzf',
    '--ansi',
    '--disabled',
    '--multi',
    '--print-query', -- 1行目に検索文字列。置換と開き直しで使う
    '--delimiter', ':',
    '--prompt', "'rg> '",
    '--header', vim.fn.shellescape(HEADER),
    '--preview-window', "'right,50%,+{2}+3/3,~1'",
    '--preview', vim.fn.shellescape(preview_cmd()),
    '--query', vim.fn.shellescape(initial_query),
    '--bind', vim.fn.shellescape('start:reload:' .. reload),
    '--bind', vim.fn.shellescape('change:reload:' .. reload),
    -- 欄の編集/トグル時に Lua 側から Ctrl-] を送って再検索させる
    '--bind', vim.fn.shellescape('ctrl-]:reload:' .. reload),
    '--bind', "'ctrl-u:clear-query'",
    -- Tab は欄移動に使うため、置換対象の複数選択は Ctrl-t
    '--bind', "'ctrl-t:toggle+down'",
    -- 全置換は Ctrl-x。Ctrl-a は fzf 既定の行頭移動なので潰さない
    replace_bind('ctrl-s', 'selected', rep_file, action_file),
    replace_bind('ctrl-x', 'all', rep_file, action_file),
  }, ' ')

  local shell = string.format(
    'cd %s && %s > %s',
    vim.fn.shellescape(cwd),
    fzf_cmd,
    vim.fn.shellescape(out)
  )

  -- レイアウト（fzf を上、表示中の欄を下に積む。欄の数だけ fzf を詰める）
  local width = math.floor(vim.o.columns * 0.9)
  local total_h = math.floor(vim.o.lines * 0.85)
  local base_col = math.floor((vim.o.columns - width) / 2)
  local base_top = math.floor((vim.o.lines - total_h) / 2)
  local fzf_title = ' search: ' .. cwd .. ' '

  local fzf_buf = vim.api.nvim_create_buf(false, true)
  local fzf_win = vim.api.nvim_open_win(fzf_buf, true, {
    relative = 'editor', width = width, height = total_h,
    col = base_col, row = base_top,
    style = 'minimal', border = 'single', title = fzf_title, title_pos = 'center',
  })
  vim.wo[fzf_win].number = false
  vim.wo[fzf_win].relativenumber = false
  vim.wo[fzf_win].signcolumn = 'no'

  -- 入力欄。buftype=prompt だと IME の未確定文字が出ないことがあるため通常の nofile バッファ
  local fields = {}
  for _, name in ipairs(FIELD_ORDER) do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { state[name] or '' })
    fields[name] = { buf = buf, win = nil }
  end

  local function visible(name)
    if name == 'replace' then return shown.replace end
    return shown.globs
  end

  local function field_line(name)
    local buf = fields[name].buf
    if not vim.api.nvim_buf_is_valid(buf) then return '' end
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
  end

  local function make_field_win(name)
    local w = vim.api.nvim_open_win(fields[name].buf, false, {
      relative = 'editor', width = width, height = 1, col = base_col, row = base_top,
      style = 'minimal', border = 'single', title = FIELD_TITLES[name], title_pos = 'left',
    })
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].signcolumn = 'no'
    vim.wo[w].wrap = false
    fields[name].win = w
    return w
  end

  -- 表示中の欄の並びに合わせて全ウィンドウを配置し直す
  local function relayout()
    local n = 0
    for _, name in ipairs(FIELD_ORDER) do
      if visible(name) then n = n + 1 end
    end
    local fzf_h = total_h - n * 3 -- 欄1つ = 内容1行 + ボーダー上下
    if fzf_h < 8 then fzf_h = 8 end
    vim.api.nvim_win_set_config(fzf_win, {
      relative = 'editor', width = width, height = fzf_h,
      col = base_col, row = base_top,
      style = 'minimal', border = 'single', title = fzf_title, title_pos = 'center',
    })
    local row = base_top + fzf_h + 2 -- fzf のボーダー下
    for _, name in ipairs(FIELD_ORDER) do
      local win = fields[name].win
      if visible(name) and win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, {
          relative = 'editor', width = width, height = 1, col = base_col, row = row,
          style = 'minimal', border = 'single', title = FIELD_TITLES[name], title_pos = 'left',
        })
        row = row + 3
      end
    end
  end

  -- 表示中の欄だけを一時ファイルへ書き出し、fzf に再検索を促す（隠した欄は効かせない）
  local function refresh_globs()
    local inc = shown.globs and field_line('include') or ''
    local exc = shown.globs and field_line('exclude') or ''
    vim.fn.writefile({ M.build_glob_args(inc, false) }, inc_file)
    vim.fn.writefile({ M.build_glob_args(exc, true) }, exc_file)
    if job_id then pcall(vim.fn.chansend, job_id, '\29') end -- Ctrl-] → reload
  end

  -- 置換文字列を fzf から見えるところへ置く。空なら 0 バイトにして、
  -- fzf 側の transform(test -s ...) が置換キーを握りつぶすようにする
  local function refresh_replace()
    local text = shown.replace and field_line('replace') or ''
    if text == '' then
      vim.fn.writefile({}, rep_file)
    else
      vim.fn.writefile({ text }, rep_file)
    end
  end

  local function focus_fzf()
    if vim.api.nvim_win_is_valid(fzf_win) then
      vim.api.nvim_set_current_win(fzf_win)
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(fzf_win) then vim.cmd('startinsert') end
      end)
    end
  end

  local function focus_field(name)
    local win = fields[name].win
    if not (win and vim.api.nvim_win_is_valid(win)) then return end
    vim.api.nvim_set_current_win(win)
    -- ターミナル離脱と同じティックだと startinsert が効かないことがある
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(win) then return end
      vim.api.nvim_win_set_cursor(win, { 1, #field_line(name) })
      vim.cmd('startinsert!')
    end)
  end

  local function focus(target)
    if target == 'fzf' then focus_fzf() else focus_field(target) end
  end

  -- Tab / Shift-Tab: fzf と表示中の欄を順に回る
  local function cycle(step)
    local targets = { 'fzf' }
    for _, name in ipairs(FIELD_ORDER) do
      if visible(name) then targets[#targets + 1] = name end
    end
    local cur_win = vim.api.nvim_get_current_win()
    local idx = 1
    for i, target in ipairs(targets) do
      local win = (target == 'fzf') and fzf_win or fields[target].win
      if win == cur_win then idx = i end
    end
    focus(targets[((idx - 1 + step) % #targets) + 1])
  end

  -- 欄の表示トグル（VSCode の置換欄トグル / 詳細検索トグル相当）。
  -- 隠した欄は無効化されるので、絞り込みや置換の一時的なオフとしても使える。
  local function apply_visibility(focus_first)
    for _, name in ipairs(FIELD_ORDER) do
      local f = fields[name]
      if visible(name) then
        if not (f.win and vim.api.nvim_win_is_valid(f.win)) then make_field_win(name) end
      elseif f.win and vim.api.nvim_win_is_valid(f.win) then
        vim.api.nvim_win_close(f.win, true)
        f.win = nil
      end
    end
    relayout()
    refresh_globs()
    refresh_replace()
    if focus_first and visible(focus_first) then
      focus_field(focus_first)
    else
      focus_fzf()
    end
  end

  local function toggle_replace()
    shown.replace = not shown.replace
    apply_visibility(shown.replace and 'replace' or nil)
  end

  local function toggle_globs()
    shown.globs = not shown.globs
    apply_visibility(shown.globs and 'include' or nil)
  end

  -- 欄からでも置換を実行できるよう、対応するキーを fzf へ送って --bind を発火させる
  local function send_key(byte)
    return function()
      if job_id then pcall(vim.fn.chansend, job_id, byte) end
    end
  end

  local function cleanup_wins()
    local wins = { fzf_win }
    local bufs = { fzf_buf }
    for _, name in ipairs(FIELD_ORDER) do
      wins[#wins + 1] = fields[name].win
      bufs[#bufs + 1] = fields[name].buf
    end
    for _, w in ipairs(wins) do
      if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
  end

  local function cleanup_files()
    for _, f in ipairs({ out, action_file, rep_file, inc_file, exc_file }) do
      pcall(vim.fn.delete, f)
    end
  end

  -- Esc は一段抜けるだけ（insert/terminal を抜けてクリックで欄を選べる状態にする）。
  -- ノーマルモードでもう一度 Esc を押したらピッカーごと閉じる。
  local function cancel()
    if closing then return end
    closing = true
    if job_id then pcall(vim.fn.jobstop, job_id) end
    cleanup_wins()
    cleanup_files()
  end

  -- 開き直しに引き継ぐ状態（バッファ破棄前に読む）
  local function snapshot()
    return {
      replace = field_line('replace'),
      include = field_line('include'),
      exclude = field_line('exclude'),
      shown = { replace = shown.replace, globs = shown.globs },
    }
  end

  for _, name in ipairs(FIELD_ORDER) do
    if visible(name) then make_field_win(name) end
  end
  relayout()
  refresh_globs()
  refresh_replace()

  vim.api.nvim_set_current_win(fzf_win)
  job_id = vim.fn.termopen({ 'sh', '-c', shell }, {
    on_exit = function()
      vim.schedule(function()
        if closing then return end
        closing = true

        local next_state = snapshot()
        cleanup_wins()
        pcall(vim.fn.delete, rep_file)
        pcall(vim.fn.delete, inc_file)
        pcall(vim.fn.delete, exc_file)

        local action
        if vim.fn.filereadable(action_file) == 1 then
          action = vim.trim((vim.fn.readfile(action_file))[1] or '')
          pcall(vim.fn.delete, action_file)
        end

        -- --print-query: 1行目が検索文字列、以降が選択行
        local query, selected = '', {}
        if vim.fn.filereadable(out) == 1 then
          local raw = vim.fn.readfile(out)
          query = raw[1] or ''
          for i = 2, #raw do
            if raw[i] ~= '' then selected[#selected + 1] = raw[i] end
          end
          pcall(vim.fn.delete, out)
        end

        -- Enter（開く）/ Esc（閉じる）
        if action ~= 'selected' and action ~= 'all' then
          if selected[1] then M.open_match(selected[1]) end
          return
        end

        -- 置換欄が空/非表示なら fzf 側で握りつぶされる想定だが、念のため何もしない
        if query == '' or not next_state.shown.replace or next_state.replace == '' then
          M.open(query, next_state)
          return
        end

        local file_count, replace_count
        if action == 'selected' then
          file_count, replace_count = M.replace_selected(cwd, selected, query, next_state.replace)
        else
          local inc_args = next_state.shown.globs
            and M.build_glob_args(next_state.include, false) or ''
          local exc_args = next_state.shown.globs
            and M.build_glob_args(next_state.exclude, true) or ''
          local paths = M.match_files(cwd, query, inc_args, exc_args)
          if #paths == 0 then
            M.open(query, next_state)
            return
          end
          file_count, replace_count = M.replace_paths(paths, query, next_state.replace)
        end

        vim.notify(
          string.format('置換完了: %d ファイル / %d 箇所', file_count, replace_count),
          vim.log.levels.INFO
        )
        -- 閉じずに同じ状態で開き直す（結果がすぐ見える）
        M.open(query, next_state)
      end)
    end,
  })

  -- グロブ欄の編集に追従して再検索、置換欄の編集は fzf 側の有効/無効に反映
  for _, name in ipairs({ 'include', 'exclude' }) do
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      buffer = fields[name].buf,
      callback = refresh_globs,
    })
  end
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = fields.replace.buf,
    callback = refresh_replace,
  })

  -- 各欄のキー: Tab で欄移動、Ctrl-r/Ctrl-g で表示トグル、
  -- Ctrl-s/Ctrl-a は fzf へ転送して置換を実行。
  -- Esc は insert を抜けるだけ（既定動作のまま）で、ノーマルモードの Esc が閉じる
  for _, name in ipairs(FIELD_ORDER) do
    local opts = { buffer = fields[name].buf, nowait = true }
    vim.keymap.set('n', '<Esc>', cancel, opts)
    vim.keymap.set({ 'i', 'n' }, '<CR>', focus_fzf, opts)
    vim.keymap.set({ 'i', 'n' }, '<Tab>', function() cycle(1) end, opts)
    vim.keymap.set({ 'i', 'n' }, '<S-Tab>', function() cycle(-1) end, opts)
    vim.keymap.set({ 'i', 'n' }, '<C-r>', toggle_replace, opts)
    vim.keymap.set({ 'i', 'n' }, '<C-g>', toggle_globs, opts)
    vim.keymap.set({ 'i', 'n' }, '<C-s>', send_key('\19'), opts)
    vim.keymap.set({ 'i', 'n' }, '<C-x>', send_key('\24'), opts)
  end

  -- fzf（ターミナル）側: 一旦ノーマルへ抜けてから欄を操作する
  -- （Ctrl-s / Ctrl-a はそのまま fzf へ渡して --bind に拾わせる）
  local function leave_term()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 'n', false)
  end
  local function from_term(fn)
    return function()
      leave_term()
      vim.schedule(fn)
    end
  end
  local term_opts = { buffer = fzf_buf, nowait = true }
  vim.keymap.set('t', '<Tab>', from_term(function() cycle(1) end), term_opts)
  vim.keymap.set('t', '<S-Tab>', from_term(function() cycle(-1) end), term_opts)
  vim.keymap.set('t', '<C-r>', from_term(toggle_replace), term_opts)
  vim.keymap.set('t', '<C-g>', from_term(toggle_globs), term_opts)
  -- 欄と同じ段階付け: Esc でターミナルを抜け（クリックで欄を選べる）、もう一度 Esc で閉じる
  vim.keymap.set('t', '<Esc>', leave_term, term_opts)
  vim.keymap.set('n', '<Esc>', cancel, term_opts)

  -- クリックやフォーカス移動で入り直したときは、その場で入力できる状態に戻す
  for _, buf in ipairs({ fzf_buf, fields.replace.buf, fields.include.buf, fields.exclude.buf }) do
    vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
      buffer = buf,
      callback = function()
        if closing then return end
        vim.schedule(function()
          if closing or vim.api.nvim_get_current_buf() ~= buf then return end
          vim.cmd(buf == fzf_buf and 'startinsert' or 'startinsert!')
        end)
      end,
    })
  end

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(fzf_win) then vim.cmd('startinsert') end
  end)
end

--- 置換文字列を入れた状態で検索ピッカーを開く（M.open の薄いラッパ）
---@param initial_query? string
---@param initial_replace? string
---@param state? table
function M.replace(initial_query, initial_replace, state)
  local next_state = vim.deepcopy(state or {})
  if initial_replace and initial_replace ~= '' then
    next_state.replace = initial_replace
  end
  next_state.shown = vim.tbl_extend('force', next_state.shown or {}, { replace = true })
  M.open(initial_query, next_state)
end

-- 入口は検索(内容)のみ。置換 / include / exclude の欄は最初から出ていて、
-- Tab で行き来する（ファイル名検索は explorer の `/`）。
vim.keymap.set('n', '<leader>/', function()
  M.open('')
end, { desc = 'search: 内容検索（Tab:欄移動 Ctrl-s/Ctrl-a:置換 Ctrl-r/Ctrl-g:欄の表示）' })

vim.keymap.set('n', '<leader>*', function()
  M.open(vim.fn.expand('<cword>'))
end, { desc = 'search: カーソル単語で内容検索（Tab:欄移動 Ctrl-s/Ctrl-a:置換）' })

vim.keymap.set('v', '<leader>/', function()
  local text = visual_text()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  vim.schedule(function()
    M.open(text)
  end)
end, { desc = 'search: 選択文字列で内容検索（Tab:欄移動 Ctrl-s/Ctrl-a:置換）' })

return M
