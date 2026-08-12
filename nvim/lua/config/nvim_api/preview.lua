-- バッファのシンタックスハイライトを ANSI(truecolor)付きテキストへ書き出す。
--
-- ansi_view.lua の「逆向き」。あちらは delta 等の ANSI をバッファ＋extmark へ写すが、
-- こちらはバッファのハイライトを ANSI(SGR)へ落とす。用途は fzf の外部プレビュー枠で、
-- 端末なので nvim の highlight group をそのまま貼ることはできない。そこで
-- 「同じ入力（バッファ＋colorscheme＋treesitter クエリ）から同じ色を再計算する」ことで
-- nvim で開いたときと同じ見た目を再現する（= 画面のコピーではなく“再現”）。
--
-- 色は起動中の nvim の現在の colorscheme から引くので、bat のような別テーマとは違い
-- エディタの色と一致する。treesitter の injection（markdown のコードフェンス内など）も
-- パーサを辿るので言語ごとに色が付く。treesitter パーサが無い filetype では色を付けず
-- 素のテキストを返す（sed でのプレビューと同じ＝退化しても悪化はしない）。

local M = {}
local ts = require('config.treesitter')

local ESC = '\27'
local RESET = ESC .. '[0m'

-- プレビューは頭から一定行だけ出す（sed -n '1,200p' と揃える）。
M.DEFAULT_MAX_LINES = 200

-- ── ハイライト → SGR ─────────────────────────────
-- highlight group の前景色＋装飾を SGR パラメータ列（"38;2;r;g;b;1" 等）にする。
-- link は解決し、色も装飾も無ければ nil（= 既定の端末色のまま出す）。
-- 同じ group は何度も引くので、バッファ 1 枚のあいだキャッシュする。
local function build_sgr(group, cache)
  local cached = cache[group]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or type(hl) ~= 'table' then
    cache[group] = false
    return nil
  end
  local parts = {}
  if hl.fg then
    local fg = hl.fg
    parts[#parts + 1] = string.format('38;2;%d;%d;%d',
      math.floor(fg / 65536) % 256, math.floor(fg / 256) % 256, fg % 256)
  end
  if hl.bold then parts[#parts + 1] = '1' end
  if hl.italic then parts[#parts + 1] = '3' end
  if hl.underline or hl.undercurl then parts[#parts + 1] = '4' end
  if hl.strikethrough then parts[#parts + 1] = '9' end
  if #parts == 0 then
    cache[group] = false
    return nil
  end
  local sgr = table.concat(parts, ';')
  cache[group] = sgr
  return sgr
end

-- treesitter の capture 名（"function.builtin" 等）と言語から、実際に色を持つ
-- highlight group を優先順に探す。nvim の highlighter と同じく `@capture.lang` を
-- まず見て、無ければ `@capture`、さらにドット付きは末尾を段階的に落とす
-- （@a.b.c → @a.b → @a）。最初に色/装飾が引けたものを採用する。
local function sgr_for_capture(capture, lang, cache)
  local bases = { capture }
  local base = capture
  while true do
    local dropped = base:match('^(.*)%.[^.]+$')
    if not dropped then break end
    base = dropped
    bases[#bases + 1] = base
  end
  for _, b in ipairs(bases) do
    if lang then
      local sgr = build_sgr('@' .. b .. '.' .. lang, cache)
      if sgr then return sgr end
    end
    local sgr = build_sgr('@' .. b, cache)
    if sgr then return sgr end
  end
  return nil
end

-- ── セルごとの色を集める ─────────────────────────
-- 行 row（0-based）の byte 桁 [scol, ecol) を sgr で塗る。erow まで跨ぐ span も扱う。
-- priority が同じか高いものだけ上書きする（injection や後勝ちの capture を活かす）。
local function paint(cells, prio, srow, scol, erow, ecol, sgr, p, line_len)
  for row = srow, math.min(erow, #line_len - 1) do
    local from = (row == srow) and scol or 0
    local to = (row == erow) and ecol or line_len[row + 1]
    local c = cells[row]
    local pr = prio[row]
    if not c then
      c = {}
      pr = {}
      cells[row] = c
      prio[row] = pr
    end
    for col = from, to - 1 do
      if pr[col] == nil or p >= pr[col] then
        c[col] = sgr
        pr[col] = p
      end
    end
  end
end

-- UTF-8 の先頭バイトから、その文字のバイト長を返す。
local function utf8_len(b)
  if b < 0x80 then return 1 end
  if b < 0xE0 then return 2 end
  if b < 0xF0 then return 3 end
  return 4
end

-- ── 本体 ─────────────────────────────────────────
-- buf の先頭 max_lines 行を ANSI 付きテキストにして返す。
-- treesitter パーサが引ければ色を付け、無ければ素のテキストを返す。
function M.render_buf(buf, opts)
  opts = opts or {}
  local max_lines = opts.max_lines or M.DEFAULT_MAX_LINES
  local total = vim.api.nvim_buf_line_count(buf)
  local nlines = math.min(total, max_lines)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, nlines, false)
  local line_len = {}
  for i, l in ipairs(lines) do line_len[i] = #l end

  local cells, prio = {}, {}
  local lang = ts.lang_for(vim.bo[buf].filetype)
  if lang then
    local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, lang)
    if ok_parser and parser then
      -- true で全体＋injection まで確実にパースする（描画に依存しない）。
      -- 古い nvim で true 引数が無い場合に備えて素の parse に倒す。
      if not pcall(function() parser:parse(true) end) then
        pcall(function() parser:parse() end)
      end
      local cache = {}
      parser:for_each_tree(function(tstree, ltree)
        local llang = ltree:lang()
        local query = vim.treesitter.query.get(llang, 'highlights')
        if not query then return end
        for id, node, metadata in query:iter_captures(tstree:root(), buf, 0, nlines) do
          local cap = query.captures[id]
          -- `@_foo` のような内部 capture は描画対象外
          if cap:sub(1, 1) ~= '_' then
            local sgr = sgr_for_capture(cap, llang, cache)
            if sgr then
              local srow, scol, erow, ecol = node:range()
              local mp = metadata[id] and metadata[id].priority
              local p = tonumber(mp or metadata.priority) or 100
              paint(cells, prio, srow, scol, erow, ecol, sgr, p, line_len)
            end
          end
        end
      end)
    end
  end

  -- 各行を走査し、色が変わる境目にだけ SGR を挿む。行末は必ずリセット。
  local out = {}
  for i, line in ipairs(lines) do
    local row = i - 1
    local rcells = cells[row]
    if not rcells then
      out[i] = line
    else
      local pieces = {}
      local cur = nil
      local j = 1
      local n = #line
      while j <= n do
        local col = j - 1
        local sgr = rcells[col]
        if sgr ~= cur then
          if sgr then
            pieces[#pieces + 1] = RESET .. ESC .. '[' .. sgr .. 'm'
          else
            pieces[#pieces + 1] = RESET
          end
          cur = sgr
        end
        local clen = utf8_len(line:byte(j))
        pieces[#pieces + 1] = line:sub(j, j + clen - 1)
        j = j + clen
      end
      if cur then pieces[#pieces + 1] = RESET end
      out[i] = table.concat(pieces)
    end
  end
  return table.concat(out, '\n')
end

-- パスのファイルを先頭 max_lines 行だけ読み、filetype を判定してから render_buf する。
-- 読めない／描画できない場合は nil（呼び出し側でフォールバックさせる）。
function M.render_file(abs_path, opts)
  opts = opts or {}
  if vim.fn.filereadable(abs_path) ~= 1 then return nil end
  local buf = vim.api.nvim_create_buf(false, true)
  local ok = pcall(function()
    local content = vim.fn.readfile(abs_path, '', opts.max_lines or M.DEFAULT_MAX_LINES)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    -- filetype はファイル名＋内容から判定する（shebang 等も拾える）
    vim.bo[buf].filetype = vim.filetype.match({ filename = abs_path, buf = buf }) or ''
  end)
  local text = ok and M.render_buf(buf, opts) or nil
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return text
end

M._private = {
  build_sgr = build_sgr,
  sgr_for_capture = sgr_for_capture,
}

return M
