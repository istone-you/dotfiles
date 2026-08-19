-- プロジェクト検索（内容検索 / 置換）
-- 裏側で rg を使うが、rg は実装手段であって主役ではない。UI は fzf を使わず、
-- プロンプト / 結果リスト / プレビューを nvim のフロート窓で自作している（peek と同じ方針）。
-- （ファイル名検索は explorer の `/` に一本化したのでここでは扱わない）
-- Requirements: rg

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
--- 「リストに並んでいる場所」と「置換される場所」が構造的にズレない。
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

-- VSCode の files to include / exclude 相当。カンマ区切りのグロブを rg の --glob 引数へ変換する。
-- include はそのまま、exclude は先頭に '!' を付ける（rg の除外グロブ表記）。
-- ワイルドカード（* ?）もスラッシュも含まない「裸の名前」は、その名前のディレクトリ配下
-- すべて（**/名前/**）として解釈する。VSCode で 'src' や '.github' と入れた時と同じ直感で、
-- 裸のディレクトリ名だと rg が配下ファイルにマッチしない罠を避ける。.github も普通に効く。
-- 例: build_glob_args('*.lua, *.go', false) → "--glob '*.lua' --glob '*.go'"
--     build_glob_args('.github', false)     → "--glob '**/.github/**'"
--     build_glob_args('node_modules', true) → "--glob '!**/node_modules/**'"
function M.build_glob_args(text, is_exclude)
  local parts = {}
  for piece in (text or ''):gmatch('[^,]+') do
    local p = vim.trim(piece)
    if p ~= '' then
      if not p:find('[*?/]') then
        p = '**/' .. p .. '/**'
      end
      parts[#parts + 1] = '--glob'
      parts[#parts + 1] = vim.fn.shellescape((is_exclude and '!' or '') .. p)
    end
  end
  return table.concat(parts, ' ')
end

-- 全置換の対象ファイル一覧を出すコマンド。リストに並んでいるのと同じ条件
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
--- 選ばなかった行は触らない（何も選んでいなければカーソル行の1行だけ）。
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

-- 結果リストの下に積む入力欄（置換 / include / exclude）。既定は3つとも表示で、
-- Tab/Shift-Tab の循環で検索欄を含めて行き来する。表示トグルは VSCode 同様に
-- 「置換欄」と「include/exclude まとめて」の2つだけ持ち、隠した欄はその機能ごと無効になる。
local FIELD_ORDER = { 'replace', 'include', 'exclude' }
-- 色をそろえる方針:
--   見出しラベル(replace:/include:/exclude:)・検索欄タイトル・結果件数
--     = git パネルのアクティブタブと同色（GitPanelTabActive: ブルー太字）
--   キー説明(Ctrl-t:select ...) = プレースホルダと同じグレー（Comment）
vim.api.nvim_set_hl(0, 'SearchFieldLabel', { link = 'GitPanelTabActive', default = true })
-- 検索欄トグル（Aa / ab / .*）は ON をラベル色 + [] 囲み、OFF をグレーの素の字で出す。
-- 色だけだと端末では差が分かりにくいので、囲みの有無でも見分けられるようにしてある。
vim.api.nvim_set_hl(0, 'SearchToggleOn', { link = 'SearchFieldLabel', default = true })
vim.api.nvim_set_hl(0, 'SearchToggleOff', { link = 'Comment', default = true })
-- 結果リストの各行を パス / 行番号 / ヒット箇所 の3色に分ける（テーマの標準色に追従）。
vim.api.nvim_set_hl(0, 'SearchResultPath', { link = 'Directory', default = true })
vim.api.nvim_set_hl(0, 'SearchResultLine', { link = 'Number', default = true })
vim.api.nvim_set_hl(0, 'SearchResultMatch', { link = 'Search', default = true })

-- ON/OFF を [] の有無と色で見せるチャンク（色だけだと端末で差が分かりにくい）。
local function toggle_chunk(label, on)
  return {
    on and ('[' .. label .. ']') or (' ' .. label .. ' '),
    on and 'SearchToggleOn' or 'SearchToggleOff',
  }
end

-- キー説明の置き場所は「その窓の中央寄せフッタ」で統一する。ラベル(replace: など)と
-- トグル([Aa] [AB])は左のタイトル、キー説明はフッタ、という分け方。
-- プロンプト欄のフッタに出し、Alt-h で押した瞬間に消せる。
local HINTS = table.concat({
  'Ctrl-r:toggle replace', 'Ctrl-g:toggle filters',
  'Alt-c:case', 'Alt-w:word', 'Alt-r:regex', 'Alt-h:help',
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

-- 入力欄が空のときだけ薄く出すプレースホルダ（VSCode 風の e.g. 例示。例中のカンマで区切りも伝わる）。
local FIELD_PLACEHOLDERS = {
  include = 'e.g. *.ts,src/**/include',
  exclude = 'e.g. *.ts,src/**/exclude',
}
local ph_ns = vim.api.nvim_create_namespace('search_placeholder')


local ts = require('config.treesitter')
local preview_ns = vim.api.nvim_create_namespace('search_preview')
local results_ns = vim.api.nvim_create_namespace('search_results')

-- 結果リスト用の rg コマンド。1行1マッチ・色なし（色付けはプレビュー側でネイティブに行う）。
-- glob（*.lua 等）をシェルに展開させないため set -f を付ける（rg_files_cmd と同じ理由）。
-- limit を渡すと `| head` で打ち切る。超過を検知したいので +1 行だけ多く取る。
function M.rg_search_cmd(query, flag_args, inc_args, exc_args, limit)
  local cmd = string.format(
    [[set -f; rg --column --line-number --no-heading --color=never --hidden --glob '!.git/*' %s %s %s -- %s]],
    flag_args or '', inc_args or '', exc_args or '', vim.fn.shellescape(query)
  )
  if limit and limit > 0 then
    cmd = cmd .. ' | head -n ' .. (limit + 1)
  end
  return cmd
end

-- プレビュー窓 win にファイル abs を、ヒット行 lnum を Visual で強調して出す（peek と同じ方針）。
-- 実バッファに読み込むので treesitter は可視域だけ遅延ハイライトされ、大きいファイルでも固まらない。
-- （旧実装は nvim 本体に HTTP 越しでファイル全体を毎回パースさせていて、大きい HTML 等で固まった）。
-- 色付けは本体と同じ切り分け: treesitter パーサがあればそれ（MAX_BYTES 超は諦める）、無ければ
-- vim の正規表現 syntax にフォールバック（html 等パーサ非同梱の ft でも色が出る＝explorer プレビューと同じ手）。
-- スクラッチ(buftype=nofile)は FileType 経由で treesitter が start されないので手動で呼ぶ。
-- 返り値は新しく作ったバッファ。前のバッファの破棄は呼び出し側の責任（差し替え時に消す）。
-- opts.no_highlight=true でヒット行の Visual 強調を付けない（意味のあるヒット行が無い一覧表示用）。
function M.render_preview(win, abs, lnum, opts)
  opts = opts or {}
  if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
  if vim.fn.filereadable(abs) ~= 1 then return nil end
  local buf = vim.api.nvim_create_buf(false, true)
  local ft
  local ok = pcall(function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(abs))
    ft = vim.filetype.match({ filename = abs, buf = buf }) or ''
    vim.bo[buf].filetype = ft
  end)
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil
  end
  local lang = ts.lang_for(ft)
  local bytes = vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf))
  local ts_ok = false
  if lang and bytes and bytes <= ts.MAX_BYTES then
    ts_ok = pcall(vim.treesitter.start, buf, lang)
  end
  if not ts_ok then
    -- パーサが無い/使えない ft は vim の正規表現 syntax で色付けする（本体と同じ挙動）
    pcall(function() vim.bo[buf].syntax = ft end)
  end
  vim.api.nvim_win_set_buf(win, buf)
  local target = math.max(1, math.min(lnum or 1, vim.api.nvim_buf_line_count(buf)))
  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  vim.fn.win_execute(win, 'normal! zz')
  -- ヒット行を全幅で強調（どこがヒットか一目で分かるように。peek と同じく Visual）。
  -- 意味のあるヒット行が無い場合（一覧表示など）は no_highlight で付けない。
  if not opts.no_highlight then
    pcall(vim.api.nvim_buf_set_extmark, buf, preview_ns, target - 1, 0, {
      end_row = target, hl_group = 'Visual', hl_eol = true,
    })
  end
  return buf
end

--- 検索ピッカー（内容検索 + 置換）。fzf は使わず、左に プロンプト / 結果リスト /
--- 置換・include・exclude 欄、右にプレビュー（peek と同じく実バッファをそのまま載せ、
--- ヒット行を Visual で強調）を並べる。検索はプロンプト入力に追従して rg を非同期実行する。
--- 移動: Ctrl-n / Ctrl-p（or ↑↓）、開く: Enter、複数選択: Ctrl-t、
--- 置換: Ctrl-s（選択分）/ Ctrl-x（全件）。欄の表示: Ctrl-r / Ctrl-g。
--- 検索トグル（VSCode の Aa / ab / .*）: Alt-c / Alt-w / Alt-r、Preserve Case: Alt-p、説明: Alt-h。
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
  local hints = state.hints ~= false
  local cwd = vim.fn.getcwd()
  local closing = false

  -- 結果は rg を `| head` で打ち切る上限。超えたら結果タイトルに件数（N+）を出す。
  local MAX_RESULTS = 2000

  -- ── 検索状態 ──
  local items = {}       -- { { raw=, path=, lnum=, col=, text= }, ... }
  local sel = 1          -- フォーカス中の行（1-based）
  local marked = {}      -- [idx]=true（Ctrl-t の複数選択）
  local truncated = false
  local gen = 0          -- 検索世代。古い rg の結果を捨てるための番号
  local rg_handle        -- 実行中の vim.system ハンドル（新検索で kill する）
  local prev_preview_buf -- 直前のプレビューバッファ（差し替え時に破棄）

  -- ── レイアウト（左カラム=リスト系、右カラム=プレビュー） ──
  local outer_w = math.floor(vim.o.columns * 0.9)
  local total_h = math.floor(vim.o.lines * 0.85)
  local base_col = math.floor((vim.o.columns - outer_w) / 2)
  local base_top = math.floor((vim.o.lines - total_h) / 2)
  local gap = 2
  local list_w = math.floor(outer_w * 0.45)
  local preview_w = outer_w - list_w - gap
  local preview_col = base_col + list_w + gap

  -- ── バッファ ──
  local function make_input_buf(text)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text or '' })
    return buf
  end

  local query_buf = make_input_buf(initial_query)

  local results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[results_buf].buftype = 'nofile'
  vim.bo[results_buf].modifiable = false

  -- 入力欄。buftype=nofile の通常バッファ（prompt だと IME 未確定が出ないことがある）
  local fields = {}
  for _, name in ipairs(FIELD_ORDER) do
    fields[name] = { buf = make_input_buf(state[name]), win = nil }
  end

  local function valid(w) return w and vim.api.nvim_win_is_valid(w) end

  local function visible(name)
    if name == 'replace' then return shown.replace end
    return shown.globs
  end

  local function buf_line(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return '' end
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
  end

  local function query_line() return buf_line(query_buf) end
  local function field_line(name) return buf_line(fields[name].buf) end

  -- ── タイトル / フッタ ──
  local function query_title()
    local chunks = { { ' search: ' .. cwd .. ' ' } }
    for _, name in ipairs(TOGGLE_ORDER) do
      chunks[#chunks + 1] = toggle_chunk(TOGGLE_LABEL[name], toggles[name])
    end
    chunks[#chunks + 1] = { ' ' }
    return chunks
  end

  local function query_footer()
    return hints and { { ' ' .. HINTS .. ' ', 'Comment' } } or ''
  end

  local function results_title()
    local n = #items
    local label = truncated and (n .. '+') or tostring(n)
    return { { string.format(' results: %s ', label), 'SearchFieldLabel' } }
  end

  -- ── プレースホルダ（欄が空のときだけ薄く出す） ──
  local function update_placeholder(name)
    local f = fields[name]
    if not (f and vim.api.nvim_buf_is_valid(f.buf)) then return end
    vim.api.nvim_buf_clear_namespace(f.buf, ph_ns, 0, -1)
    local ph = hints and FIELD_PLACEHOLDERS[name] or nil
    if ph and field_line(name) == '' then
      vim.api.nvim_buf_set_extmark(f.buf, ph_ns, 0, 0, {
        virt_text = { { ph, 'Comment' } }, virt_text_pos = 'overlay', hl_mode = 'combine',
      })
    end
  end

  -- ── 窓 ──
  -- 縦の並びは 元の fzf レイアウトと同じ「結果リストが上、検索/置換/include/exclude の
  -- 入力欄はまとめて下」。位置は relayout() が確定させるので、ここの row は暫定でよい。
  local results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = 'editor', width = list_w, height = math.max(3, total_h - 12), col = base_col,
    row = base_top, style = 'minimal', border = 'single',
    title = results_title(), title_pos = 'left',
  })
  vim.wo[results_win].number = false
  vim.wo[results_win].relativenumber = false
  vim.wo[results_win].signcolumn = 'no'
  vim.wo[results_win].wrap = false
  vim.wo[results_win].cursorline = true

  local query_win = vim.api.nvim_open_win(query_buf, true, {
    relative = 'editor', width = list_w, height = 1, col = base_col, row = base_top + total_h - 9,
    style = 'minimal', border = 'single', title = query_title(), title_pos = 'left',
    footer = query_footer(), footer_pos = 'center',
  })
  vim.wo[query_win].number = false
  vim.wo[query_win].relativenumber = false
  vim.wo[query_win].signcolumn = 'no'
  vim.wo[query_win].wrap = false

  local preview_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = 'editor', width = preview_w, height = total_h, col = preview_col, row = base_top,
    style = 'minimal', border = 'single', title = ' preview ', title_pos = 'center',
    focusable = false,
  })
  vim.wo[preview_win].number = true
  vim.wo[preview_win].relativenumber = false
  vim.wo[preview_win].signcolumn = 'no'
  vim.wo[preview_win].wrap = false
  vim.wo[preview_win].cursorline = true

  local function make_field_win(name)
    local w = vim.api.nvim_open_win(fields[name].buf, false, {
      relative = 'editor', width = list_w, height = 1, col = base_col, row = base_top,
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

  -- 表示中の欄の数に合わせて左カラムを積み直す。並びは元の fzf と同じで、
  -- 結果リストが上、検索欄→置換→include→exclude の入力欄はまとめて下。
  local function relayout()
    if not valid(results_win) then return end
    local n = 0
    for _, name in ipairs(FIELD_ORDER) do
      if visible(name) then n = n + 1 end
    end
    -- 下に積む入力欄は「検索欄 + 表示中の欄」で (1 + n) 本。各 3 行分。
    local results_h = total_h - (1 + n) * 3
    if results_h < 3 then results_h = 3 end
    vim.api.nvim_win_set_config(results_win, {
      relative = 'editor', width = list_w, height = results_h, col = base_col, row = base_top,
      style = 'minimal', border = 'single', title = results_title(), title_pos = 'left',
    })
    local row = base_top + results_h + 2
    vim.api.nvim_win_set_config(query_win, {
      relative = 'editor', width = list_w, height = 1, col = base_col, row = row,
      style = 'minimal', border = 'single', title = query_title(), title_pos = 'left',
      footer = query_footer(), footer_pos = 'center',
    })
    row = row + 3
    for _, name in ipairs(FIELD_ORDER) do
      local win = fields[name].win
      if visible(name) and valid(win) then
        vim.api.nvim_win_set_config(win, {
          relative = 'editor', width = list_w, height = 1, col = base_col, row = row,
          style = 'minimal', border = 'single', title_pos = 'left',
          title = field_title_chunks(name, toggles.preserve),
          footer = field_footer_chunks(name, hints), footer_pos = 'center',
        })
        row = row + 3
      end
    end
  end

  -- ── プレビュー ──
  local function set_preview_buf(buf)
    if buf and prev_preview_buf and prev_preview_buf ~= buf
      and vim.api.nvim_buf_is_valid(prev_preview_buf) then
      pcall(vim.api.nvim_buf_delete, prev_preview_buf, { force = true })
    end
    prev_preview_buf = buf
  end

  local function clear_preview()
    if not valid(preview_win) then return end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(preview_win, buf)
    set_preview_buf(buf)
    if valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, {
        relative = 'editor', width = preview_w, height = total_h, col = preview_col, row = base_top,
        style = 'minimal', border = 'single', title = ' preview ', title_pos = 'center',
        focusable = false,
      })
    end
  end

  local function update_preview()
    if closing or not valid(preview_win) then return end
    local it = items[sel]
    if not it then clear_preview() return end
    local abs = vim.fs.normalize(M.resolve_path(cwd, it.path))
    local buf = M.render_preview(preview_win, abs, it.lnum)
    if not buf then clear_preview() return end
    set_preview_buf(buf)
    vim.api.nvim_win_set_config(preview_win, {
      relative = 'editor', width = preview_w, height = total_h, col = preview_col, row = base_top,
      style = 'minimal', border = 'single', title_pos = 'center', focusable = false,
      title = ' ' .. it.path .. ':' .. it.lnum .. ' ',
    })
  end

  -- ── 結果リスト描画 ──
  local function clamp_sel()
    if #items == 0 then sel = 1
    elseif sel < 1 then sel = 1
    elseif sel > #items then sel = #items end
  end

  -- 表示は旧 fzf の既定レイアウトに合わせ、最良マッチ(sel=1)をリストの一番下＝プロンプト直上に置き、
  -- 順位が下がるほど上へ積む。件数が窓の高さより少なければ上を空行で詰めて下寄せする。
  -- よって sel とバッファ行は上下反転＋pad ぶんずれる。
  local pad = 0
  local function row_of(s)
    return pad + (#items - s + 1)
  end

  local function update_cursor()
    clamp_sel()
    if valid(results_win) and #items > 0 then
      pcall(vim.api.nvim_win_set_cursor, results_win, { row_of(sel), 0 })
    end
  end

  -- 1行を「マーク + path : lnum : 本文」に組み、パス/行番号/ヒット箇所を色分けする位置も返す。
  local function result_line(it, marked_flag, query)
    local mark = marked_flag and '● ' or '  '
    local mb = #mark
    local lstr = tostring(it.lnum)
    local text_start = mb + #it.path + 1 + #lstr + 2 -- "path" ":" "lnum" ": "
    local display = mark .. it.path .. ':' .. lstr .. ': ' .. it.text
    local hls = {
      { mb, mb + #it.path, 'SearchResultPath' },
      { mb + #it.path + 1, mb + #it.path + 1 + #lstr, 'SearchResultLine' },
    }
    -- ヒット箇所。rg の col（本文内の 1-based バイト位置）を使う。正規表現時は長さが読めないので付けない。
    if query ~= '' and not toggles.regex and it.col then
      local ms = text_start + (it.col - 1)
      hls[#hls + 1] = { ms, ms + #query, 'SearchResultMatch' }
    end
    return display, hls
  end

  local function render_results()
    relayout() -- 先に窓の高さと件数タイトルを確定させる（pad 計算に高さが要る）
    local q = query_line()
    local n = #items
    local h = valid(results_win) and vim.api.nvim_win_get_height(results_win) or n
    pad = math.max(0, h - n) -- 下寄せ用に上を空行で詰める
    local lines, all_hls = {}, {}
    for k = 1, pad do lines[k] = '' end
    for i, it in ipairs(items) do
      local pos = pad + (n - i + 1) -- item i は下から i 番目に置く（最良が最下段）
      lines[pos], all_hls[pos] = result_line(it, marked[i], q)
    end
    vim.bo[results_buf].modifiable = true
    vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
    vim.bo[results_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(results_buf, results_ns, 0, -1)
    for pos, hls in pairs(all_hls) do
      local line_len = #lines[pos]
      for _, hh in ipairs(hls) do
        local e = math.min(hh[2], line_len)
        if hh[1] < e then
          pcall(vim.api.nvim_buf_set_extmark, results_buf, results_ns, pos - 1, hh[1], {
            end_col = e, hl_group = hh[3],
          })
        end
      end
    end
    if #items == 0 then clear_preview() else update_cursor(); update_preview() end
  end

  local function move(step)
    if #items == 0 then return end
    sel = sel + step
    update_cursor()
    update_preview()
  end

  -- ── 非同期 rg（デバウンス + 世代管理 + 前ジョブ kill） ──
  local uv = vim.uv or vim.loop
  local debounce = uv.new_timer()

  local function launch_rg()
    if closing then return end
    gen = gen + 1
    local my_gen = gen
    local q = query_line()
    if q == '' then
      items = {}; truncated = false; sel = 1; marked = {}
      render_results()
      return
    end
    local flag_args = M.build_flag_args(toggles)
    local inc = shown.globs and M.build_glob_args(field_line('include'), false) or ''
    local exc = shown.globs and M.build_glob_args(field_line('exclude'), true) or ''
    local sh = 'cd ' .. vim.fn.shellescape(cwd) .. ' && '
      .. M.rg_search_cmd(q, flag_args, inc, exc, MAX_RESULTS)
    if rg_handle then pcall(function() rg_handle:kill('sigterm') end); rg_handle = nil end
    rg_handle = vim.system({ 'sh', '-c', sh }, { text = true }, function(res)
      vim.schedule(function()
        if closing or my_gen ~= gen then return end
        rg_handle = nil
        local parsed = {}
        for line in (res.stdout or ''):gmatch('[^\n]+') do
          local path, lnum, col, text = line:match('^(.-):(%d+):(%d+):(.*)$')
          if path then
            parsed[#parsed + 1] =
              { raw = line, path = path, lnum = tonumber(lnum), col = tonumber(col), text = text }
          end
        end
        truncated = #parsed > MAX_RESULTS
        if truncated then parsed[#parsed] = nil end -- head で余分に取った +1 行を落とす
        items = parsed
        sel = 1; marked = {}
        render_results()
      end)
    end)
  end

  local function run_search(immediate)
    debounce:stop()
    if immediate then
      vim.schedule(launch_rg)
    else
      debounce:start(80, 0, vim.schedule_wrap(launch_rg))
    end
  end

  -- ── 選択・置換・開く ──
  local function toggle_mark()
    if #items == 0 then return end
    marked[sel] = (not marked[sel]) or nil
    render_results()
    move(1)
  end

  local function close_picker()
    if closing then return end
    closing = true
    pcall(function() debounce:stop() end)
    pcall(function() debounce:close() end)
    if rg_handle then pcall(function() rg_handle:kill('sigterm') end) end
    for _, w in ipairs({ query_win, results_win, preview_win,
      fields.replace.win, fields.include.win, fields.exclude.win }) do
      if valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
    for _, b in ipairs({ query_buf, results_buf, prev_preview_buf,
      fields.replace.buf, fields.include.buf, fields.exclude.buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    -- 入力欄は insert で開いていたので、閉じた後にエディタが insert のまま残らないよう抜ける
    vim.schedule(function() vim.cmd('stopinsert') end)
  end

  local function open_selected()
    local it = items[sel]
    if not it then return end
    close_picker()
    M.open_match(it.raw) -- focus_editor → edit → カーソル移動（ANSI 無しでもそのまま通る）
  end

  local function do_replace(scope)
    local q = query_line()
    local rep = field_line('replace')
    if q == '' or not shown.replace or rep == '' then return end
    local flag_args = M.build_flag_args(toggles)
    local opts = { flags = flag_args, preserve = toggles.preserve }
    local file_count, replace_count = 0, 0
    if scope == 'selected' then
      local selected = {}
      for i, it in ipairs(items) do
        if marked[i] then selected[#selected + 1] = it.raw end
      end
      if #selected == 0 and items[sel] then selected = { items[sel].raw } end -- 未選択ならフォーカス行
      if #selected == 0 then return end
      file_count, replace_count = M.replace_selected(cwd, selected, q, rep, opts)
    else
      local inc = shown.globs and M.build_glob_args(field_line('include'), false) or ''
      local exc = shown.globs and M.build_glob_args(field_line('exclude'), true) or ''
      local paths = M.match_files(cwd, q, inc, exc, flag_args)
      if #paths == 0 then return end
      file_count, replace_count = M.replace_paths(paths, q, rep, opts)
    end
    vim.notify(
      string.format('置換完了: %d ファイル / %d 箇所', file_count, replace_count), vim.log.levels.INFO)
    marked = {}
    run_search(true) -- 置換結果をすぐ反映
  end

  -- ── フォーカス移動 ──
  local function enter_input(win)
    if not valid(win) then return end
    vim.api.nvim_set_current_win(win)
    vim.schedule(function()
      if valid(win) and vim.api.nvim_get_current_win() == win then vim.cmd('startinsert!') end
    end)
  end

  local function cycle(step)
    local targets = { query_win }
    for _, name in ipairs(FIELD_ORDER) do
      if visible(name) and valid(fields[name].win) then targets[#targets + 1] = fields[name].win end
    end
    local cur = vim.api.nvim_get_current_win()
    local idx = 1
    for i, w in ipairs(targets) do
      if w == cur then idx = i end
    end
    enter_input(targets[((idx - 1 + step) % #targets) + 1])
  end

  -- ── 欄・トグルの操作 ──
  local function apply_visibility(focus_name)
    for _, name in ipairs(FIELD_ORDER) do
      local f = fields[name]
      if visible(name) then
        if not valid(f.win) then make_field_win(name) end
      elseif valid(f.win) then
        vim.api.nvim_win_close(f.win, true)
        f.win = nil
      end
    end
    relayout()
    run_search() -- グロブの有効/無効が結果に効く
    if focus_name and visible(focus_name) and valid(fields[focus_name].win) then
      enter_input(fields[focus_name].win)
    else
      enter_input(query_win)
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

  local function toggle_flag(name)
    return function()
      toggles[name] = not toggles[name]
      relayout() -- タイトルの [Aa] 等を描き替える
      run_search()
    end
  end

  local function toggle_preserve()
    toggles.preserve = not toggles.preserve
    relayout() -- 置換欄タイトルの [AB] を描き替えるだけ（rg は不要）
  end

  local function toggle_hints()
    hints = not hints
    relayout()
    for _, name in ipairs(FIELD_ORDER) do
      update_placeholder(name)
    end
  end

  -- ── キーマップ ──
  local function set_input_keymaps(buf)
    local opts = { buffer = buf, nowait = true }
    local both = { 'i', 'n' }
    -- 最良マッチが一番下なので、↓ は最良側（下）へ、↑ は次候補（上）へ。旧 fzf 既定と同じ向き。
    vim.keymap.set(both, '<Down>', function() move(-1) end, opts)
    vim.keymap.set(both, '<Up>', function() move(1) end, opts)
    vim.keymap.set(both, '<CR>', open_selected, opts)
    vim.keymap.set(both, '<C-t>', toggle_mark, opts)
    vim.keymap.set(both, '<C-s>', function() do_replace('selected') end, opts)
    vim.keymap.set(both, '<C-x>', function() do_replace('all') end, opts)
    vim.keymap.set(both, '<C-r>', toggle_replace, opts)
    vim.keymap.set(both, '<C-g>', toggle_globs, opts)
    vim.keymap.set(both, '<M-c>', toggle_flag('case'), opts)
    vim.keymap.set(both, '<M-w>', toggle_flag('word'), opts)
    vim.keymap.set(both, '<M-r>', toggle_flag('regex'), opts)
    vim.keymap.set(both, '<M-p>', toggle_preserve, opts)
    vim.keymap.set(both, '<M-h>', toggle_hints, opts)
    vim.keymap.set(both, '<Tab>', function() cycle(1) end, opts)
    vim.keymap.set(both, '<S-Tab>', function() cycle(-1) end, opts)
    vim.keymap.set(both, '<Esc>', close_picker, opts)
  end

  set_input_keymaps(query_buf)
  for _, name in ipairs(FIELD_ORDER) do
    set_input_keymaps(fields[name].buf)
  end

  -- ── autocmd（入力に追従して再検索、フォーカスで再インサート） ──
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = query_buf,
    callback = function() if not closing then run_search() end end,
  })
  for _, name in ipairs({ 'include', 'exclude' }) do
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      buffer = fields[name].buf,
      callback = function()
        if closing then return end
        run_search()
        update_placeholder(name)
      end,
    })
  end
  for _, buf in ipairs({ query_buf, fields.replace.buf, fields.include.buf, fields.exclude.buf }) do
    vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
      buffer = buf,
      callback = function()
        if closing then return end
        vim.schedule(function()
          if closing or vim.api.nvim_get_current_buf() ~= buf then return end
          vim.cmd('startinsert!')
        end)
      end,
    })
  end

  -- ── 起動 ──
  for _, name in ipairs(FIELD_ORDER) do
    if visible(name) then make_field_win(name) end
  end
  relayout()
  render_results()
  run_search(true) -- 初期クエリがあればすぐ検索
  enter_input(query_win)
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
-- Tab で行き来する（ファイル/パス検索は explorer の `/`）。
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

M._private = { rg_search_cmd = M.rg_search_cmd, render_preview = M.render_preview }

return M
