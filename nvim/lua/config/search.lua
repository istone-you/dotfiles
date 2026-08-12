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

--- rg のマッチ行から path と行番号を取り出す。
--- rg は1行に複数マッチがあっても1件しか出さない（--column は最初のマッチの桁）ので、
--- ピッカーに並ぶ粒度＝行。置換の選択もこの粒度で扱う。
function M.parse_match(line)
  line = line:gsub('\27%[[0-9;]*m', '') -- rg --color の ANSI を除去
  local path, lnum = line:match('^([^:]+):(%d+):%d+:')
  if not path then
    path, lnum = line:match('^([^:]+):(%d+):')
  end
  if not path or path == '' then return nil end
  return path, tonumber(lnum)
end

function M.parse_path(line)
  return (M.parse_match(line))
end

-- VSCode の検索欄トグル（Aa / ab / .*）。既定は VSCode と同じく3つとも OFF。
local TOGGLE_ORDER = { 'case', 'word', 'regex' }
local TOGGLE_LABEL = { case = 'Aa', word = 'ab', regex = '.*' }
-- VSCode 同様、Preserve Case（AB）だけは検索欄ではなく置換欄側のトグル。
-- rg の検索フラグにはならず、置換のときだけ効くのでここは別扱いにしてある。
local PRESERVE_LABEL = 'AB'

--- トグルの状態を rg のフラグ列へ。検索・ファイル列挙・置換のすべてがこの1本を使うので、
--- 「fzf に並んでいる場所」と「置換される場所」が構造的にズレない。
--- match case OFF は VSCode に合わせて --ignore-case（--smart-case ではない）。
function M.build_flag_args(toggles)
  toggles = toggles or {}
  local parts = { toggles.case and '--case-sensitive' or '--ignore-case' }
  if toggles.word then
    parts[#parts + 1] = '--word-regexp'
  end
  if not toggles.regex then
    parts[#parts + 1] = '--fixed-strings'
  end
  return table.concat(parts, ' ')
end

--- マッチ数を数えるだけの rg。stdin を1ファイルとして扱うので合計が1行で返る。
function M.rg_count_cmd(query, flag_args)
  return string.format(
    'rg --count-matches --no-filename %s -- %s',
    flag_args or '', vim.fn.shellescape(query)
  )
end

--- 置換後の本文を丸ごと吐く rg（--passthru なので非マッチ行もそのまま出る）。
--- 注意: rg の --replace は --fixed-strings のときでも $1 / ${name} を後方参照として
--- 解釈する。regex OFF では VSCode と同じく置換文字列をそのまま入れたいので $ を $$ へ逃がす。
function M.rg_replace_cmd(query, replace, flag_args)
  flag_args = flag_args or ''
  if flag_args:find('--fixed-strings', 1, true) then
    replace = (replace:gsub('%$', '$$'))
  end
  return string.format(
    'rg --passthru --no-line-number --no-filename --color=never %s --replace %s -- %s',
    flag_args, vim.fn.shellescape(replace), vim.fn.shellescape(query)
  )
end

--- マッチした文字列だけを出現順に1行1件で吐く rg。Preserve Case で
--- 「何にマッチしたか」を知るために使う。
function M.rg_matches_cmd(query, flag_args)
  return string.format(
    'rg --only-matching --no-line-number --no-filename --color=never %s -- %s',
    flag_args or '', vim.fn.shellescape(query)
  )
end

-- Preserve Case のとき、rg に入れさせた置換文字列の範囲を後から見つけるための番兵。
-- 制御文字なのでソースコードにはまず出てこない（万一入力に含まれていたら諦めて素の置換に倒す）。
local PC_OPEN, PC_CLOSE = '\1', '\2'

--- VSCode の Preserve Case（AB）相当。マッチした文字列の見た目に合わせて置換文字列の
--- 大小を寄せる。全小文字→小文字、全大文字→大文字、先頭だけ大文字→先頭だけ大文字。
--- どれにも当てはまらない（camelCase など）ときは置換文字列をそのまま使う。
--- 注意: Lua の :lower()/:upper() は ASCII のみなので、非 ASCII はそのまま残る。
function M.preserve_case(matched, replacement)
  if matched == '' or replacement == '' then
    return replacement
  end
  if matched == matched:lower() then
    return replacement:lower()
  end
  if matched == matched:upper() then
    return replacement:upper()
  end
  local head, tail = matched:sub(1, 1), matched:sub(2)
  if head == head:upper() and tail == tail:lower() then
    return replacement:sub(1, 1):upper() .. replacement:sub(2):lower()
  end
  return replacement
end

--- 番兵で囲まれた挿入部分を、対応するマッチ文字列の大小に寄せて置き換える。
--- rg は --only-matching も --passthru も同じ順で処理するので、k 番目の番兵は
--- k 番目のマッチに対応する。数が合わなければ寄せずに番兵だけ外す（安全側）。
local function apply_preserved(out_lines, matched)
  local idx = 0
  for i, line in ipairs(out_lines) do
    out_lines[i] = line:gsub(PC_OPEN .. '(.-)' .. PC_CLOSE, function(inner)
      idx = idx + 1
      local m = matched[idx]
      return m and M.preserve_case(m, inner) or inner
    end)
  end
  return idx == #matched
end

--- 置換そのものを rg に任せる（自前のリテラル検索だと大小無視・単語単位・正規表現の
--- どれもトグルと食い違うため）。本文は stdin で渡すので、開いているバッファでも
--- ディスク上のファイルでも同じ経路を通る。
---@param opts? table # { flags=string(rg の検索フラグ), preserve=boolean(Preserve Case) }
---@return string[] new_lines
---@return integer count
function M.rg_replace_lines(lines, query, replace, opts)
  -- rg のフラグ文字列だけを渡されても効くようにする。テーブル前提で string を
  -- 素通しすると opts.flags が nil になり、条件が黙って消えたまま置換してしまう
  if type(opts) == 'string' then opts = { flags = opts } end
  opts = opts or {}
  local flags = opts.flags or ''
  if not query or query == '' then
    return lines, 0
  end

  -- Preserve Case は rg の --replace では表現できないので、置換文字列を番兵で囲んで
  -- 入れさせ、あとから Lua 側で大小を寄せる。$1 の展開は rg に任せたままにできる。
  local preserve = opts.preserve or false
  if preserve then
    for _, line in ipairs(lines) do
      if line:find(PC_OPEN, 1, true) or line:find(PC_CLOSE, 1, true) then
        preserve = false -- 番兵が本文に居るので対応が取れない
        break
      end
    end
  end

  local count, matched
  if preserve then
    matched = vim.fn.systemlist({ 'sh', '-c', M.rg_matches_cmd(query, flags) }, lines)
    if vim.v.shell_error ~= 0 then
      return lines, 0
    end
    count = #matched
  else
    -- 先に数える。マッチ0(exit 1)も正規表現エラー(exit 2)もここで弾けるので、
    -- 置換の出力が壊れているのに書き込む事故が起きない
    local counted = vim.fn.systemlist({ 'sh', '-c', M.rg_count_cmd(query, flags) }, lines)
    if vim.v.shell_error ~= 0 then
      return lines, 0
    end
    count = tonumber(vim.trim(counted[1] or '')) or 0
  end
  if count == 0 then
    return lines, 0
  end

  local body = preserve and (PC_OPEN .. replace .. PC_CLOSE) or replace
  local out = vim.fn.systemlist({ 'sh', '-c', M.rg_replace_cmd(query, body, flags) }, lines)
  if vim.v.shell_error ~= 0 or #out == 0 then
    return lines, 0
  end
  if preserve then
    apply_preserved(out, matched) -- 数が合わなくても番兵は外れる
  end
  return out, count
end

--- 指定した行番号の行だけを置換する（選んでいない行は同じファイル内でも触らない）。
--- 対象行だけを抜き出して1本の rg に流すので、選択が何行あっても rg の起動は
--- ファイルごとに一定。--passthru は入力1行につき必ず1行返し、置換欄は1行入力で
--- 改行が混ざらないため、返ってきた並びはそのまま元の行番号に対応する。
---@return string[] new_lines
---@return integer count
function M.rg_replace_at_lnums(lines, lnums, query, replace, opts)
  local targets, subset = {}, {}
  for _, lnum in ipairs(lnums) do
    if lines[lnum] then
      targets[#targets + 1] = lnum
      subset[#subset + 1] = lines[lnum]
    end
  end
  if #subset == 0 then
    return lines, 0
  end

  local new_subset, count = M.rg_replace_lines(subset, query, replace, opts)
  -- 行数が変わったら対応が取れないので、安全側に倒して何もしない
  if count == 0 or #new_subset ~= #subset then
    return lines, 0
  end

  local out = vim.list_slice(lines, 1, #lines)
  for i, lnum in ipairs(targets) do
    out[lnum] = new_subset[i]
  end
  return out, count
end

function M.resolve_path(cwd, path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return cwd .. '/' .. path
end

--- 本文を読んで transform(lines) の結果を書き戻す。開いているバッファがあれば
--- バッファ上で（＝undo が効く形で）、なければファイルを直接書き換える。
--- transform は new_lines, count を返し、count が 0 なら何も書かない。
local function rewrite_path(abs_path, transform)
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_lines, count = transform(lines)
    if count == 0 then
      return 0
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
  -- readfile('b') は末尾改行を空要素で表す。systemlist は渡した各要素の後ろに改行を足すので、
  -- この空要素を付けたまま流すと空行が1つ増える。剥がして通し、書き戻す直前に足し直す
  local final_nl = content[#content] == ''
  if final_nl then
    table.remove(content)
  end
  local new_lines, count = transform(content)
  if count == 0 then
    return 0
  end
  if final_nl then
    new_lines[#new_lines + 1] = ''
  end
  vim.fn.writefile(new_lines, abs_path, 'b')
  return count
end

--- ファイル内の全マッチを置換（Ctrl-x の全置換用）
function M.apply_replace_to_path(abs_path, search, replace, opts)
  return rewrite_path(abs_path, function(lines)
    return M.rg_replace_lines(lines, search, replace, opts)
  end)
end

--- 指定した行だけを置換（Ctrl-s の選択置換用）
function M.apply_replace_to_lnums(abs_path, lnums, search, replace, opts)
  return rewrite_path(abs_path, function(lines)
    return M.rg_replace_at_lnums(lines, lnums, search, replace, opts)
  end)
end

-- fzf の外部プレビュー。nvim_api が動いていれば curl で「エディタと同じ色」の ANSI を
-- 取り、失敗（サーバ停止・描画不可）時は素の sed に倒す。curl かサーバが無ければ最初から
-- sed のまま。{1} は選択行のパス（cwd 相対のことがあるので $PWD で絶対化する）。行位置
-- 合わせ（--preview-window +{2}）は 1..200 行を返す点が sed と同じなのでそのまま効く。
-- 端末プロセスなので nvim の highlight は貼れず、色付けは nvim_api 側で ANSI に落として届く。
local function preview_cmd()
  local sed = [[sed -n '1,200p' -- {1}]]
  local port = require('config.nvim_api').state.port
  if not port or not has_cmd('curl') then return sed end
  return string.format(
    [[f={1}; case "$f" in /*) ;; *) f="$PWD/$f";; esac; ]]
    .. [[curl -sf --get 'http://127.0.0.1:%d/api/preview' --data-urlencode "path=$f" || %s]],
    port, sed)
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

-- トグルのフラグと include/exclude グロブを一時ファイルから読み込んで rg に渡す reload コマンド。
-- どちらも実行時に変わる（フィールド編集 / Alt-c,w,r のトグル）ので、fzf 起動時に固定できない値を
-- $(cat) で都度読み込む。set -f でパス名展開を止め、'*.lua' 等がそのまま rg へ渡るようにする。
local function rg_reload_cmd(flag_file, inc_file, exc_file)
  return string.format(
    [[set -f; test x{q} != x && rg --column --line-number --no-heading --color=always --hidden --glob '!.git/*' $(cat %s 2>/dev/null) $(cat %s 2>/dev/null) $(cat %s 2>/dev/null) -- {q} || true]],
    flag_file, inc_file, exc_file
  )
end

-- 全置換の対象ファイル一覧を出すコマンド。fzf に並んでいるのと同じ条件
-- （トグル由来のフラグ / 表示中のグロブ）で rg を回す。
function M.rg_files_cmd(query, inc_args, exc_args, flag_args)
  return string.format(
    [[set -f; rg --files-with-matches %s --hidden --glob '!.git/*' %s %s -- %s]],
    flag_args or '', inc_args or '', exc_args or '', vim.fn.shellescape(query)
  )
end

--- クエリにマッチする全ファイルの絶対パス（全置換の対象）
function M.match_files(cwd, query, inc_args, exc_args, flag_args)
  if not query or query == '' then return {} end
  local cmd = string.format(
    'cd %s && %s',
    vim.fn.shellescape(cwd), M.rg_files_cmd(query, inc_args, exc_args, flag_args))
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
function M.replace_paths(paths, search, replace, opts)
  local file_count = 0
  local replace_count = 0
  for _, abs_path in ipairs(paths) do
    local n = M.apply_replace_to_path(abs_path, search, replace, opts)
    if n > 0 then
      file_count = file_count + 1
      replace_count = replace_count + n
    end
  end
  vim.cmd('checktime')
  return file_count, replace_count
end

--- 選択されたマッチ行だけを置換する。粒度は行なので、同じファイルでも
--- 選ばなかった行は触らない（fzf で何も選んでいなければカーソル行の1行だけ）。
---@return integer file_count
---@return integer replace_count
function M.replace_selected(cwd, selected_lines, search, replace, opts)
  -- ファイルごとに行番号を集める（選択順のまま、重複は落とす）
  local order, by_path = {}, {}
  for _, line in ipairs(selected_lines) do
    local path, lnum = M.parse_match(line)
    if path and lnum then
      local abs = M.resolve_path(cwd, path)
      local entry = by_path[abs]
      if not entry then
        entry = { lnums = {}, seen = {} }
        by_path[abs] = entry
        order[#order + 1] = abs
      end
      if not entry.seen[lnum] then
        entry.seen[lnum] = true
        entry.lnums[#entry.lnums + 1] = lnum
      end
    end
  end

  local file_count, replace_count = 0, 0
  for _, abs in ipairs(order) do
    local entry = by_path[abs]
    table.sort(entry.lnums)
    local n = M.apply_replace_to_lnums(abs, entry.lnums, search, replace, opts)
    if n > 0 then
      file_count = file_count + 1
      replace_count = replace_count + n
    end
  end
  vim.cmd('checktime')
  return file_count, replace_count
end

-- fzf 窓の下に積む入力欄。既定は3つとも表示で、Tab/Shift-Tab の循環で行き来する。
-- 表示トグルは VSCode 同様に「置換欄」と「include/exclude まとめて」の2つだけ持ち、
-- 隠した欄はその機能ごと無効になる（＝隠す＝一時的に効かせない）。
local FIELD_ORDER = { 'replace', 'include', 'exclude' }
-- 色をそろえる方針:
--   見出しラベル(replace:/include:/exclude:) と fzf の search> プロンプト
--     = git パネルのアクティブタブと同色（GitPanelTabActive: ブルー太字）
--   キー説明(Ctrl-t:select ...) とヘッダー(Ctrl-r/Ctrl-g) = プレースホルダと同じグレー（Comment）
-- nvim タイトルの色と fzf の --color を同じ highlight から作ることで一致させる。
vim.api.nvim_set_hl(0, 'SearchFieldLabel', { link = 'GitPanelTabActive', default = true })
-- 検索欄トグル（Aa / ab / .*）は ON をラベル色 + [] 囲み、OFF をグレーの素の字で出す。
-- 色だけだと端末では差が分かりにくいので、囲みの有無でも見分けられるようにしてある。
vim.api.nvim_set_hl(0, 'SearchToggleOn', { link = 'SearchFieldLabel', default = true })
vim.api.nvim_set_hl(0, 'SearchToggleOff', { link = 'Comment', default = true })

-- ON/OFF を [] の有無と色で見せるチャンク（色だけだと端末で差が分かりにくい）。
local function toggle_chunk(label, on)
  return {
    on and ('[' .. label .. ']') or (' ' .. label .. ' '),
    on and 'SearchToggleOn' or 'SearchToggleOff',
  }
end

-- キー説明の置き場所は「その窓の中央寄せフッタ」で統一する。ラベル(replace: など)と
-- トグル([Aa] [AB])は左のタイトル、キー説明はフッタ、という分け方。
-- fzf の --header は起動時に固定されてしまうのでこちらも nvim 側のフッタに出す
-- （Alt-h で押した瞬間に消せるし、fzf を作り直さずに済む）。
local HINTS = table.concat({
  'Ctrl-r:replace欄', 'Ctrl-g:絞り込み欄',
  'Alt-c:大小', 'Alt-w:単語', 'Alt-r:正規表現', 'Alt-h:この説明',
}, '  ')

-- 欄ごとのキー説明。置換のキーは置換欄のフッタに出す（Alt-p も置換側のトグルなのでここ）。
local FIELD_HINTS = {
  replace = table.concat({
    'Ctrl-t:select', 'Ctrl-s:replace selected', 'Ctrl-x:replace all', 'Alt-p:PreserveCase',
  }, '  '),
}

-- フロート境界タイトル（左寄せ）。ラベルと、置換欄なら Preserve Case のトグルだけ。
local function field_title_chunks(name, preserve)
  if name == 'replace' then
    return {
      { ' replace: ', 'SearchFieldLabel' },
      toggle_chunk(PRESERVE_LABEL, preserve),
      { ' ' },
    }
  end
  return { { ' ' .. name .. ': ', 'SearchFieldLabel' } } -- include / exclude
end

-- 欄のフッタ（中央寄せ）。隠すときは '' を渡す（nil だと「変更なし」になって消えない）。
local function field_footer_chunks(name, hints)
  local text = hints and FIELD_HINTS[name] or nil
  return text and { { ' ' .. text .. ' ', 'Comment' } } or ''
end

-- highlight の前景色を fzf に渡せる #RRGGBB で得る（link は解決する）。無ければ nil。
local function hl_hex(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if ok and hl and hl.fg then
    return string.format('#%06x', hl.fg)
  end
  return nil
end

-- 入力欄が空のときだけ薄く出すプレースホルダ（VSCode 風の e.g. 例示。例中のカンマで区切りも伝わる）。
local FIELD_PLACEHOLDERS = {
  include = 'e.g. *.ts,src/**/include',
  exclude = 'e.g. *.ts,src/**/exclude',
}
local ph_ns = vim.api.nvim_create_namespace('search_placeholder')


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
--- 置換は Ctrl-s（選択分）/ Ctrl-x（全件）。欄の表示は Ctrl-r / Ctrl-g でトグル。
--- 検索条件のトグル（VSCode の Aa / ab / .*）は Alt-c / Alt-w / Alt-r、
--- 置換欄の Preserve Case（AB）は Alt-p。キー説明とプレースホルダは Alt-h で出し入れ。
---@param initial_query? string
---@param state? table  # { replace=string, include=string, exclude=string,
---                        shown={ replace=boolean, globs=boolean },
---                        toggles={ case=boolean, word=boolean, regex=boolean, preserve=boolean },
---                        hints=boolean }
function M.open(initial_query, state)
  if not ensure_deps() then return end

  initial_query = initial_query or ''
  state = state or {}
  local shown = vim.tbl_extend('force', { replace = true, globs = true }, state.shown or {})
  -- case/word/regex は検索欄、preserve は置換欄のトグル（VSCode の置き場所に合わせている）
  local toggles = vim.tbl_extend(
    'force', { case = false, word = false, regex = false, preserve = false }, state.toggles or {})
  -- キー説明とプレースホルダの表示（Alt-h でまとめて出し入れ）
  local hints = state.hints ~= false

  local out = vim.fn.tempname()
  local action_file = vim.fn.tempname()
  local rep_file = vim.fn.tempname()
  local flag_file = vim.fn.tempname()
  local inc_file = vim.fn.tempname()
  local exc_file = vim.fn.tempname()
  local cwd = vim.fn.getcwd()
  local closing = false
  local job_id

  local reload = rg_reload_cmd(flag_file, inc_file, exc_file)

  -- search> プロンプトはタイトルのラベルと同じ highlight 由来の色にそろえる
  local label_hex = vim.o.termguicolors and hl_hex('SearchFieldLabel') or nil
  local color_arg = label_hex
    and ('--color ' .. vim.fn.shellescape('prompt:' .. label_hex .. ':bold'))
    or ''

  local fzf_cmd = table.concat({
    'fzf',
    '--ansi',
    '--disabled',
    '--multi',
    '--print-query', -- 1行目に検索文字列。置換と開き直しで使う
    '--delimiter', ':',
    '--prompt', "'> '",
    -- キー説明は nvim 側のフッタに出すので fzf の --header は使わない
    color_arg,
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

  -- fzf 窓のタイトルに VSCode の検索欄トグルを並べる。fzf の --header は起動時に固定されて
  -- しまうが、ここは nvim 側なので押した瞬間に描き替えられる
  local function fzf_title_chunks()
    local chunks = { { ' search: ' .. cwd .. ' ' } }
    for _, name in ipairs(TOGGLE_ORDER) do
      chunks[#chunks + 1] = toggle_chunk(TOGGLE_LABEL[name], toggles[name])
    end
    chunks[#chunks + 1] = { ' ' }
    return chunks
  end

  -- キー説明はフッタ。隠すときは '' を渡す（nil だと「変更なし」の意味になって消えない）
  local function fzf_footer()
    return hints and { { ' ' .. HINTS .. ' ', 'Comment' } } or ''
  end

  local fzf_buf = vim.api.nvim_create_buf(false, true)
  local fzf_win = vim.api.nvim_open_win(fzf_buf, true, {
    relative = 'editor', width = width, height = total_h,
    col = base_col, row = base_top,
    style = 'minimal', border = 'single', title = fzf_title_chunks(), title_pos = 'center',
    footer = fzf_footer(), footer_pos = 'center',
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

  -- 欄が空のときだけプレースホルダを overlay で薄く出す。入力があれば消す。
  local function update_placeholder(name)
    local f = fields[name]
    if not (f and vim.api.nvim_buf_is_valid(f.buf)) then return end
    vim.api.nvim_buf_clear_namespace(f.buf, ph_ns, 0, -1)
    local ph = hints and FIELD_PLACEHOLDERS[name] or nil
    if ph and field_line(name) == '' then
      vim.api.nvim_buf_set_extmark(f.buf, ph_ns, 0, 0, {
        virt_text = { { ph, 'Comment' } },
        virt_text_pos = 'overlay',
        hl_mode = 'combine',
      })
    end
  end

  local function make_field_win(name)
    local w = vim.api.nvim_open_win(fields[name].buf, false, {
      relative = 'editor', width = width, height = 1, col = base_col, row = base_top,
      style = 'minimal', border = 'single', title_pos = 'left',
      title = field_title_chunks(name, toggles.preserve),
      footer = field_footer_chunks(name, hints), footer_pos = 'center',
    })
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].signcolumn = 'no'
    vim.wo[w].wrap = false
    fields[name].win = w
    update_placeholder(name)
    return w
  end

  -- 表示中の欄の並びに合わせて全ウィンドウを配置し直す。
  -- 欄と同じく fzf 窓も有効性を見る（閉じた後に取り残されたキーマップから呼ばれても落ちない）
  local function relayout()
    if not vim.api.nvim_win_is_valid(fzf_win) then return end
    local n = 0
    for _, name in ipairs(FIELD_ORDER) do
      if visible(name) then n = n + 1 end
    end
    local fzf_h = total_h - n * 3 -- 欄1つ = 内容1行 + ボーダー上下
    if fzf_h < 8 then fzf_h = 8 end
    vim.api.nvim_win_set_config(fzf_win, {
      relative = 'editor', width = width, height = fzf_h,
      col = base_col, row = base_top,
      style = 'minimal', border = 'single', title = fzf_title_chunks(), title_pos = 'center',
      footer = fzf_footer(), footer_pos = 'center',
    })
    local row = base_top + fzf_h + 2 -- fzf のボーダー下
    for _, name in ipairs(FIELD_ORDER) do
      local win = fields[name].win
      if visible(name) and win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, {
          relative = 'editor', width = width, height = 1, col = base_col, row = row,
          style = 'minimal', border = 'single', title_pos = 'left',
          title = field_title_chunks(name, toggles.preserve),
          footer = field_footer_chunks(name, hints), footer_pos = 'center',
        })
        row = row + 3
      end
    end
  end

  -- トグルの状態を rg のフラグとして書き出し、fzf に再検索を促す。
  -- fzf は起動したままなのでクエリも選択も保たれる（VSCode でトグルを押した時と同じ体感）
  local function refresh_flags()
    vim.fn.writefile({ M.build_flag_args(toggles) }, flag_file)
    if job_id then pcall(vim.fn.chansend, job_id, '\29') end -- Ctrl-] → reload
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

  -- 検索欄トグル（VSCode の Alt-c / Alt-w / Alt-r）。欄は増えないのでレイアウトは変わらず、
  -- タイトルの表示更新（relayout）と rg フラグの書き出しだけ。フォーカスも動かさない
  local function toggle_flag(name)
    return function()
      toggles[name] = not toggles[name]
      relayout()
      refresh_flags()
    end
  end

  -- Preserve Case（VSCode の Alt-p）。置換のときにしか効かないので rg の再検索は要らず、
  -- 置換欄タイトルの [AB] を描き直すだけ
  local function toggle_preserve()
    toggles.preserve = not toggles.preserve
    relayout()
  end

  -- キー説明（フッタ・置換欄のキー説明）とプレースホルダをまとめて出し入れする
  local function toggle_hints()
    hints = not hints
    relayout()
    for _, name in ipairs(FIELD_ORDER) do
      update_placeholder(name)
    end
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
    for _, f in ipairs({ out, action_file, rep_file, flag_file, inc_file, exc_file }) do
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
      toggles = {
        case = toggles.case, word = toggles.word,
        regex = toggles.regex, preserve = toggles.preserve,
      },
      hints = hints,
    }
  end

  for _, name in ipairs(FIELD_ORDER) do
    if visible(name) then make_field_win(name) end
  end
  relayout()
  refresh_flags() -- fzf の start:reload より先にフラグを置いておく
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
        pcall(vim.fn.delete, flag_file)
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

        -- 置換にも検索と同じフラグを渡す。トグルを効かせたまま置換しても
        -- 「fzf に並んでいた場所」と食い違わない
        local flag_args = M.build_flag_args(next_state.toggles)
        local replace_opts = { flags = flag_args, preserve = next_state.toggles.preserve }

        local file_count, replace_count
        if action == 'selected' then
          file_count, replace_count =
            M.replace_selected(cwd, selected, query, next_state.replace, replace_opts)
        else
          local inc_args = next_state.shown.globs
            and M.build_glob_args(next_state.include, false) or ''
          local exc_args = next_state.shown.globs
            and M.build_glob_args(next_state.exclude, true) or ''
          local paths = M.match_files(cwd, query, inc_args, exc_args, flag_args)
          if #paths == 0 then
            M.open(query, next_state)
            return
          end
          file_count, replace_count =
            M.replace_paths(paths, query, next_state.replace, replace_opts)
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
      callback = function()
        refresh_globs()
        update_placeholder(name) -- 空にしたら薄い (,区切り) を戻す
      end,
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
    vim.keymap.set({ 'i', 'n' }, '<M-c>', toggle_flag('case'), opts)
    vim.keymap.set({ 'i', 'n' }, '<M-w>', toggle_flag('word'), opts)
    vim.keymap.set({ 'i', 'n' }, '<M-r>', toggle_flag('regex'), opts)
    vim.keymap.set({ 'i', 'n' }, '<M-p>', toggle_preserve, opts)
    vim.keymap.set({ 'i', 'n' }, '<M-h>', toggle_hints, opts)
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
  -- 検索欄トグルは欄の出し入れが無いのでターミナルモードのまま処理する（入力を切らさない）
  vim.keymap.set('t', '<M-c>', toggle_flag('case'), term_opts)
  vim.keymap.set('t', '<M-w>', toggle_flag('word'), term_opts)
  vim.keymap.set('t', '<M-r>', toggle_flag('regex'), term_opts)
  vim.keymap.set('t', '<M-p>', toggle_preserve, term_opts)
  vim.keymap.set('t', '<M-h>', toggle_hints, term_opts)
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
end, { desc = 'search: 内容検索（Tab:欄移動 Ctrl-s/Ctrl-x:置換 Alt-c/w/r:大小/単語/正規表現）' })

vim.keymap.set('n', '<leader>*', function()
  M.open(vim.fn.expand('<cword>'))
end, { desc = 'search: カーソル単語で内容検索（Tab:欄移動 Ctrl-s/Ctrl-x:置換）' })

vim.keymap.set('v', '<leader>/', function()
  local text = visual_text()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  vim.schedule(function()
    M.open(text)
  end)
end, { desc = 'search: 選択文字列で内容検索（Tab:欄移動 Ctrl-s/Ctrl-x:置換）' })

M._private = { preview_cmd = preview_cmd }

return M
