-- 構造化された diff を「バッファ行 + extmark ハイライト」へ組み立てる。
--
-- 出力は buf へ直接書かず、次の形のデータを返す（テストしやすく、複数ファイルぶんを
-- 連結してから一度に描けるようにするため）:
--   { lines = { 行文字列, ... },
--     marks = { { row0, 開始バイト, 終了バイト, グループ, 優先度 }, ... },
--     fills = { [row0] = グループ } }   fills は行末まで塗る背景（差分行の帯）
--
-- 桁の作り:
--   通常表示    "  12 ⋮  13 │ 本文"      （左が変更前の行番号、右が変更後）
--   side-by-side "  12 │-変更前  ‖  13 │+変更後"
-- 本文が桁に収まらない時は折り返し、WRAP_MAX 行を超えるぶんは末尾を … で打ち切る。

local parse = require('config.panel.diff.parse')
local words = require('config.panel.diff.words')
local syntax = require('config.panel.diff.syntax')

local M = {}

--- 1行の本文を最大何行に折り返すか
M.WRAP_MAX = 3

-- 優先度。背景（帯 → 語）→ 文字色（構文 → 記号）の順に重ねる。
-- 背景だけ・文字色だけを持つグループに分けてあるので、重なっても互いを消さない
local P_FILL, P_WORD, P_SYNTAX, P_MARK = 10, 20, 100, 110

M.HL = {
  file      = 'GitPanelDiffFile',
  tag       = 'GitPanelDiffTag',
  rule      = 'GitPanelDiffRule',
  hunk      = 'GitPanelDiffHunk',
  section   = 'GitPanelDiffSection',
  linenr    = 'GitPanelDiffLineNr',
  linenr_a  = 'GitPanelDiffLineNrAdd',
  linenr_d  = 'GitPanelDiffLineNrDel',
  add_bg    = 'GitPanelDiffAddBg',
  del_bg    = 'GitPanelDiffDelBg',
  add_word  = 'GitPanelDiffAddWord',
  del_word  = 'GitPanelDiffDelWord',
  add_mark  = 'GitPanelDiffAddMark',
  del_mark  = 'GitPanelDiffDelMark',
  meta      = 'GitPanelDiffMeta',
  commit    = 'GitPanelDiffCommit',
  count_a   = 'GitPanelDiffCountAdd',
  count_d   = 'GitPanelDiffCountDel',
}

--- パネルは背景透過なので、差分行の帯は「暗く色を乗せる」控えめな色にする。
--- 語単位の強調だけはっきり見えるように一段濃くする
function M.setup_hl()
  local hl = vim.api.nvim_set_hl
  hl(0, M.HL.file,     { fg = '#7aa2f7', bold = true })
  hl(0, M.HL.tag,      { fg = '#e0af68' })
  hl(0, M.HL.rule,     { fg = '#3b4261' })
  hl(0, M.HL.hunk,     { fg = '#565f89' })
  hl(0, M.HL.section,  { fg = '#7dcfff' })
  hl(0, M.HL.linenr,   { fg = '#3b4261' })
  hl(0, M.HL.linenr_a, { fg = '#5b8a4a' })
  hl(0, M.HL.linenr_d, { fg = '#9c5566' })
  hl(0, M.HL.add_bg,   { bg = '#1b2b22' })
  hl(0, M.HL.del_bg,   { bg = '#2e1d25' })
  hl(0, M.HL.add_word, { bg = '#2f5c3f' })
  hl(0, M.HL.del_word, { bg = '#6b2b3a' })
  hl(0, M.HL.add_mark, { fg = '#9ece6a', bold = true })
  hl(0, M.HL.del_mark, { fg = '#f7768e', bold = true })
  hl(0, M.HL.meta,     { fg = '#565f89' })
  hl(0, M.HL.commit,   { fg = '#e0af68' })
  hl(0, M.HL.count_a,  { fg = '#9ece6a' })
  hl(0, M.HL.count_d,  { fg = '#f7768e' })
end

-- ── 表示幅 ─────────────────────────────────────

local wcache = {}

local function char_width(ch)
  -- CRLF の \r など制御文字は ^M と2桁で描かれる（タブは読み込み時に空白へ展開済み）
  if #ch == 1 then return (ch:byte() < 0x20 or ch:byte() == 0x7f) and 2 or 1 end
  local w = wcache[ch]
  if not w then
    w = vim.api.nvim_strwidth(ch)
    wcache[ch] = w
  end
  return w
end

--- 表示幅。ASCIIの印字可能文字だけなら長さがそのまま幅になる
local function disp(s)
  if not s:find('[^\32-\126]') then return #s end
  local w, i, n = 0, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = (b < 0x80 and 1) or (b >= 0xf0 and 4) or (b >= 0xe0 and 3) or (b >= 0xc0 and 2) or 1
    local ch = s:sub(i, math.min(i + len - 1, n))
    w = w + char_width(ch)
    i = i + #ch
  end
  return w
end

--- s のバイト位置 from（0始まり）から表示幅 avail に収まる最長範囲の終端（0始まり半開）
local function cut_to_width(s, from, avail)
  local i, n = from + 1, #s
  local w = 0
  while i <= n do
    local b = s:byte(i)
    local len = (b < 0x80 and 1) or (b >= 0xf0 and 4) or (b >= 0xe0 and 3) or (b >= 0xc0 and 2) or 1
    local ch = s:sub(i, math.min(i + len - 1, n))
    local cw = char_width(ch)
    if w + cw > avail then break end
    w = w + cw
    i = i + #ch
  end
  return i - 1
end

--- 本文を avail 幅で折り返す。max_lines 行を超えるぶんは打ち切り（truncated=true）
---@return table segs { { 開始バイト, 終了バイト, truncated=bool }, ... }
function M.split_width(s, avail, max_lines)
  if avail <= 0 then return { { 0, 0 } } end
  local segs, pos, n = {}, 0, #s
  while true do
    local e = cut_to_width(s, pos, avail)
    if e <= pos and pos < n then e = pos + 1 end -- 1文字も入らない異常時に止まらないように
    if e < n and #segs + 1 >= max_lines then
      segs[#segs + 1] = { pos, cut_to_width(s, pos, math.max(avail - 1, 0)), truncated = true }
      return segs
    end
    segs[#segs + 1] = { pos, e }
    pos = e
    if pos >= n then return segs end
  end
end

-- ── 出力バッファ ───────────────────────────────

local Out = {}
Out.__index = Out

function Out.new()
  return setmetatable({ lines = {}, marks = {}, fills = {} }, Out)
end

--- 1行足して、その行番号（0始まり）を返す
function Out:push(text)
  self.lines[#self.lines + 1] = text
  return #self.lines - 1
end

function Out:mark(row, s, e, group, prio)
  if e > s and group then
    self.marks[#self.marks + 1] = { row, s, e, group, prio }
  end
end

-- ── セルの組み立て ─────────────────────────────

--- cell:
---   width       … このセルが占める表示幅
---   gutter      … 行番号側の固定文字列   blank_gutter … 折り返し行で使う同じ幅の空白
---   marker      … '+' / '-' / ' '
---   content     … 本文   spans … 構文ハイライト   word … 語単位差分のバイト範囲
---   fill        … 行の帯   pad … 幅ぴったりまで空白で埋めるか（side-by-side用）
local function emit_spans(out, row, spans, seg, base, prio, forced)
  for _, sp in ipairs(spans or {}) do
    local s = math.max(sp[1], seg[1])
    local e = math.min(sp[2], seg[2])
    if e > s then out:mark(row, base + s - seg[1], base + e - seg[1], forced or sp[3], prio) end
  end
end

--- セル群を1行として流し込む（折り返しで複数のバッファ行になりうる）
local function emit_cells(out, cells, wrap_max)
  local segs_of, nseg = {}, 1
  for ci, cell in ipairs(cells) do
    local avail = cell.width - disp(cell.gutter) - disp(cell.marker)
    segs_of[ci] = M.split_width(cell.content, avail, wrap_max)
    if #segs_of[ci] > nseg then nseg = #segs_of[ci] end
  end

  for k = 1, nseg do
    local parts, meta, col = {}, {}, 0
    for ci, cell in ipairs(cells) do
      local seg = segs_of[ci][k]
      local gut = (k == 1) and cell.gutter or cell.blank_gutter
      local marker = (k == 1) and cell.marker or string.rep(' ', #cell.marker)
      local body = seg and cell.content:sub(seg[1] + 1, seg[2]) or ''
      if seg and seg.truncated then body = body .. '…' end
      local piece = gut .. marker .. body
      if cell.pad then
        local pad = cell.width - disp(piece)
        if pad > 0 then piece = piece .. string.rep(' ', pad) end
      end
      meta[ci] = { col = col, gut = #gut, marker = #marker, len = #piece, seg = seg }
      parts[#parts + 1] = piece
      col = col + #piece
    end

    local row = out:push(table.concat(parts))
    for ci, cell in ipairs(cells) do
      local m = meta[ci]
      if cell.fill then
        if cell.pad then
          out:mark(row, m.col, m.col + m.len, cell.fill, P_FILL)
        else
          out.fills[row] = cell.fill
        end
      end
      out:mark(row, m.col, m.col + m.gut, cell.num_hl, P_MARK)
      if k == 1 and cell.marker_hl then
        out:mark(row, m.col + m.gut, m.col + m.gut + m.marker, cell.marker_hl, P_MARK)
      end
      if m.seg then
        local base = m.col + m.gut + m.marker
        emit_spans(out, row, cell.spans, m.seg, base, P_SYNTAX)
        emit_spans(out, row, cell.word, m.seg, base, P_WORD, cell.word_hl)
      end
    end
  end
end

-- ── 行ごとの見た目 ─────────────────────────────

local STYLE = {
  ctx = { marker = ' ', num = M.HL.linenr },
  del = { marker = '-', num = M.HL.linenr_d, mark = M.HL.del_mark, fill = M.HL.del_bg, word = M.HL.del_word },
  add = { marker = '+', num = M.HL.linenr_a, mark = M.HL.add_mark, fill = M.HL.add_bg, word = M.HL.add_word },
}

local function num_str(n)
  return n and tostring(n) or ''
end

--- 通常表示のガター "  12 ⋮  13 │"
local function gutter_unified(old, new, numw)
  return string.format('%' .. numw .. 's ⋮ %' .. numw .. 's │', num_str(old), num_str(new))
end

--- side-by-side 片側のガター "  12 │"
local function gutter_side(no, numw)
  return string.format('%' .. numw .. 's │', num_str(no))
end

local function make_cell(line, gutter, width, pad)
  local st = STYLE[line and line.kind] or STYLE.ctx
  return {
    width = width,
    pad = pad,
    gutter = gutter,
    blank_gutter = string.rep(' ', disp(gutter)),
    marker = line and st.marker or ' ',
    marker_hl = line and st.mark or nil,
    num_hl = M.HL.linenr,
    fill = line and st.fill or nil,
    content = line and line.text or '',
    spans = line and line.spans or nil,
    word = line and line.word or nil,
    word_hl = st.word,
  }
end

-- ── hunk 本体 ──────────────────────────────────

--- 削除行の並びと追加行の並びを突き合わせ、語単位の差分を各行へ持たせる
local function annotate_words(file)
  for _, hunk in ipairs(file.hunks) do
    local lines = hunk.lines
    local i = 1
    while i <= #lines do
      if lines[i].kind == 'del' then
        local ds = i
        while lines[i] and lines[i].kind == 'del' do i = i + 1 end
        local de = i - 1
        if lines[i] and lines[i].kind == 'add' then
          local as = i
          while lines[i] and lines[i].kind == 'add' do i = i + 1 end
          local dtexts, atexts = {}, {}
          for k = ds, de do dtexts[#dtexts + 1] = lines[k].text end
          for k = as, i - 1 do atexts[#atexts + 1] = lines[k].text end
          for _, p in ipairs(words.align(dtexts, atexts)) do
            local dl, al = lines[ds + p[1] - 1], lines[as + p[2] - 1]
            dl.word, al.word = words.pair_diff(dl.text, al.text)
          end
        end
      else
        i = i + 1
      end
    end
  end
end

--- "\ No newline at end of file" の行。桁組みには乗せず、地の文として控えめに出す
local function render_nonl(out, text)
  local shown = '  ' .. text
  out:mark(out:push(shown), 0, #shown, M.HL.meta, P_MARK)
end

local function render_hunk_unified(out, hunk, numw, width, wrap_max)
  for _, line in ipairs(hunk.lines) do
    if line.kind == 'nonl' then
      render_nonl(out, line.text)
    else
      local cell = make_cell(line, gutter_unified(line.old_no, line.new_no, numw), width, false)
      cell.num_hl = STYLE[line.kind].num
      emit_cells(out, { cell }, wrap_max)
    end
  end
end

local function render_hunk_side(out, hunk, numw, width, wrap_max)
  -- 左右の間に1桁の仕切りを挟む。無いと左の本文と右の行番号がくっついて境目が読めない
  local left_w = math.floor((width - 1) / 2)
  local right_w = width - left_w - 1
  local lines = hunk.lines

  local function emit(l, r)
    local lc = make_cell(l, gutter_side(l and l.old_no, numw), left_w, true)
    local sep = { width = 1, pad = true, gutter = '', blank_gutter = '', marker = '', content = '' }
    local rc = make_cell(r, gutter_side(r and r.new_no, numw), right_w, true)
    if l then lc.num_hl = STYLE[l.kind].num end
    if r then rc.num_hl = STYLE[r.kind].num end
    emit_cells(out, { lc, sep, rc }, wrap_max)
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line.kind == 'nonl' then
      render_nonl(out, line.text)
      i = i + 1
    elseif line.kind == 'ctx' then
      emit(line, line)
      i = i + 1
    else
      local dels, adds = {}, {}
      while lines[i] and lines[i].kind == 'del' do
        dels[#dels + 1] = lines[i]
        i = i + 1
      end
      while lines[i] and lines[i].kind == 'add' do
        adds[#adds + 1] = lines[i]
        i = i + 1
      end
      for k = 1, math.max(#dels, #adds) do emit(dels[k], adds[k]) end
    end
  end
end

-- ── ファイル単位 ───────────────────────────────

local TAGS = { A = '[新規]', D = '[削除]', R = '[リネーム]' }

local function render_file_header(out, file, width)
  -- ファイルの区切りとして前に1行空ける。先頭や、既に空行が来ている時は足さない
  if #out.lines > 0 and out.lines[#out.lines] ~= '' then out:push('') end
  local name = file.path
  if file.status == 'R' and file.old_path and file.new_path then
    name = file.old_path .. ' → ' .. file.new_path
  end

  local segs = { { ' ' .. name, M.HL.file } }
  local tag = file.binary and '[バイナリ]' or TAGS[file.status]
  if tag then segs[#segs + 1] = { '  ' .. tag, M.HL.tag } end
  if not file.binary and (file.added > 0 or file.deleted > 0) then
    segs[#segs + 1] = { '  +' .. file.added, M.HL.count_a }
    segs[#segs + 1] = { ' -' .. file.deleted, M.HL.count_d }
  end

  local parts, marks, col = {}, {}, 0
  for _, s in ipairs(segs) do
    marks[#marks + 1] = { col, col + #s[1], s[2] }
    parts[#parts + 1] = s[1]
    col = col + #s[1]
  end
  local row = out:push(table.concat(parts))
  for _, m in ipairs(marks) do out:mark(row, m[1], m[2], m[3], P_MARK) end

  local rule = string.rep('─', width)
  out:mark(out:push(rule), 0, #rule, M.HL.rule, P_MARK)
end

--- hunk の見出し "@@ -12,7 +12,9 @@ 直前の関数名"。囲みの部分は控えめに、
--- 後ろに付く関数名などは目立つ色にする
local function render_hunk_header(out, hunk, width)
  local head = string.format('@@ -%d,%d +%d,%d @@', hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count)
  local section = hunk.section or ''
  local text = (section ~= '') and (head .. ' ' .. section) or head
  local seg = M.split_width(text, width, 1)[1]
  local shown = text:sub(seg[1] + 1, seg[2]) .. (seg.truncated and '…' or '')
  local row = out:push(shown)
  out:mark(row, 0, math.min(#head, #shown), M.HL.hunk, P_MARK)
  if #shown > #head then out:mark(row, #head, #shown, M.HL.section, P_MARK) end
end

--- 行番号の桁数。hunk の最終行番号から決める
local function number_width(file)
  local maxno = 1
  for _, h in ipairs(file.hunks) do
    maxno = math.max(maxno, h.old_start + h.old_count, h.new_start + h.new_count)
  end
  return math.max(2, math.min(6, #tostring(maxno)))
end

local function render_file(out, file, opts)
  render_file_header(out, file, opts.width)
  if file.binary then
    local text = '  ' .. (file.binary_message or 'Binary file')
    out:mark(out:push(text), 0, #text, M.HL.meta, P_MARK)
    return
  end

  local numw = number_width(file)
  for i, hunk in ipairs(file.hunks) do
    if i > 1 then out:push('') end
    render_hunk_header(out, hunk, opts.width)
    if opts.side_by_side then
      render_hunk_side(out, hunk, numw, opts.width, opts.wrap_max)
    else
      render_hunk_unified(out, hunk, numw, opts.width, opts.wrap_max)
    end
  end
end

--- git show のコミットヘッダなど、diff より前の地の文
local function render_preamble(out, preamble)
  for _, l in ipairs(preamble) do
    local row = out:push(parse.expand_tabs(l))
    if l:match('^commit ') then
      out:mark(row, 0, #l, M.HL.commit, P_MARK)
    elseif l:match('^%a[%w-]*:%s') then
      out:mark(row, 0, #l, M.HL.meta, P_MARK)
    end
  end
end

-- ── 公開API ────────────────────────────────────

--- 生の unified diff を描画データへ変換する。
---@param diff_text string|nil
---@param opts table|nil { width, side_by_side, wrap_max, syntax }
---@return table { lines, marks, fills }
function M.render(diff_text, opts)
  opts = opts or {}
  local o = {
    width = math.max(opts.width or 80, 20),
    side_by_side = opts.side_by_side and true or false,
    wrap_max = opts.wrap_max or M.WRAP_MAX,
  }
  local doc = parse.parse(diff_text)
  local out = Out.new()
  render_preamble(out, doc.preamble)
  for _, file in ipairs(doc.files) do
    if opts.syntax ~= false then syntax.annotate(file) end
    annotate_words(file)
    render_file(out, file, o)
  end
  return { lines = out.lines, marks = out.marks, fills = out.fills }
end

--- 複数の描画結果を縦に連結する（レビュー表示でファイルごとに描いたものを1枚にする）。
---@param results table[]
---@param gap integer|nil 間に挟む空行数（既定1）
---@return table result, integer[] offsets 各結果の先頭行（1始まり）
function M.concat(results, gap)
  gap = gap or 1
  local merged = { lines = {}, marks = {}, fills = {} }
  local offsets = {}
  for i, r in ipairs(results) do
    local base = #merged.lines
    offsets[i] = base + 1
    for _, l in ipairs(r.lines) do merged.lines[#merged.lines + 1] = l end
    for _, m in ipairs(r.marks) do
      merged.marks[#merged.marks + 1] = { m[1] + base, m[2], m[3], m[4], m[5] }
    end
    for row, group in pairs(r.fills) do merged.fills[row + base] = group end
    if i < #results then
      for _ = 1, gap do merged.lines[#merged.lines + 1] = '' end
    end
  end
  return merged, offsets
end

--- 描画結果をバッファへ反映する
---@param buf integer
---@param ns integer
---@param result table
function M.apply(buf, ns, result)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.bo[buf].modifiable = true
  -- vim 標準の diff syntax が残っていると自前のガターに勝手な色が乗るので外す
  if vim.bo[buf].filetype ~= '' then vim.bo[buf].filetype = '' end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for row, group in pairs(result.fills) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, { line_hl_group = group, priority = P_FILL })
  end
  for _, m in ipairs(result.marks) do
    local line = result.lines[m[1] + 1] or ''
    local e = math.min(m[3], #line)
    local s = math.min(m[2], #line)
    if e > s then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m[1], s, {
        end_row = m[1], end_col = e, hl_group = m[4], priority = m[5] or P_MARK,
      })
    end
  end
end

return M
