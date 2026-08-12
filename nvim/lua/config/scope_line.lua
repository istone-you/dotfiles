-- 今カーソルがあるブロックを縦線（│）で示すガイド
--
-- ブロックの範囲は treesitter の folds.scm（@fold キャプチャ）から取る。
--
-- なぜノード型名で判定しないか:
--   「型名に statement / block が入っていればスコープ」という判定は、言語ごとの
--   ノードの流儀の違いを吸収できない。Lua の tree-sitter は `if ... then` と `end` を
--   含まない block（＝中身だけ）を返すのに対し、TypeScript の statement_block は
--   波括弧の行を含む。後者を前提に「開始行と終了行を除いて」描くと、Lua では
--   ガイドが 1 本も出なくなる。folds.scm はどちらの言語でも if_statement を返すので
--   流儀が揃う。畳める単位の定義は言語ごとに上流が持っているものを使う、という考え方。
--
-- folds.scm が無い言語（html 等）はインデントで代用する。

local ns = vim.api.nvim_create_namespace('scope_line')

local function setup_hl()
  vim.api.nvim_set_hl(0, 'ScopeLine', { fg = '#3d59a1' })
end

local function get_indent(line)
  if line:match('^%s*$') then return nil end
  return vim.fn.strdisplaywidth(line:match('^(%s*)'))
end

local function effective_indent(lines, lnum)
  for i = lnum, 0, -1 do
    local ind = get_indent(lines[i + 1] or '')
    if ind then return ind end
  end
  return 0
end

--- folds.scm の @fold から、その行を含む最も内側のブロックを取る
---@param buf integer
---@param row integer 0始まりの行番号
---@return { start_lnum: integer, end_lnum: integer }|nil 0始まり・開始/終了行を含む
local function fold_range(buf, row)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then return nil end
  -- ハイライトが有効なら既に解析済み。まだなら一度だけ解析する
  if #parser:trees() == 0 then
    if not pcall(parser.parse, parser) then return nil end
  end

  local best
  --- 注入言語（html の中の css/js 等）も見たいので言語ツリーを再帰でたどる
  local function visit(ltree)
    local query = vim.treesitter.query.get(ltree:lang(), 'folds')
    if query then
      for _, tree in pairs(ltree:trees()) do
        -- 走査はカーソル行に重なるノードだけに絞る（毎 CursorMoved 走るので）
        for _, node in query:iter_captures(tree:root(), buf, row, row + 1) do
          local sr, _, er, _ = node:range()
          -- 1行で閉じるものはガイドを引く余地が無い
          if sr <= row and row <= er and sr < er then
            if not best or (er - sr) < (best.end_lnum - best.start_lnum) then
              best = { start_lnum = sr, end_lnum = er }
            end
          end
        end
      end
    end
    for _, child in pairs(ltree:children()) do visit(child) end
  end
  visit(parser)

  return best
end

--- folds.scm が無い言語向け。インデントが浅くなる行を境目とみなす
local function indent_range(lines, lnum)
  local cur_indent = effective_indent(lines, lnum)
  if cur_indent == 0 then return nil end

  local start_lnum = nil
  for i = lnum - 1, 0, -1 do
    local ind = get_indent(lines[i + 1] or '')
    if ind and ind < cur_indent then
      start_lnum = i
      break
    end
  end
  if not start_lnum then return nil end

  local start_indent = get_indent(lines[start_lnum + 1]) or 0
  local end_lnum = lnum
  for i = lnum + 1, #lines - 1 do
    local ind = get_indent(lines[i + 1] or '')
    if ind then
      if ind <= start_indent then
        end_lnum = i
        break
      end
      end_lnum = i
    end
  end
  if end_lnum <= start_lnum then return nil end
  return { start_lnum = start_lnum, end_lnum = end_lnum }
end

local function update(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if vim.bo[buf].buftype ~= '' then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1

  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)

  local range = fold_range(buf, lnum) or indent_range(lines, lnum)
  if not range then return end

  local start_indent = get_indent(lines[range.start_lnum + 1] or '') or 0
  local end_indent = get_indent(lines[range.end_lnum + 1] or '') or start_indent
  local guide_col = math.max(math.min(start_indent, end_indent), 0)

  for i = range.start_lnum + 1, range.end_lnum - 1 do
    local line = lines[i + 1] or ''
    local ind = get_indent(line)
    if (not ind) or guide_col < ind then
      vim.api.nvim_buf_set_extmark(buf, ns, i, 0, {
        virt_text = { { '│', 'ScopeLine' } },
        virt_text_win_col = guide_col,
      })
    end
  end
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })
vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter' }, {
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= '' then return end
    update(buf)
  end,
})

return {
  _fold_range = fold_range,
  _indent_range = indent_range,
  _update = update,
}
