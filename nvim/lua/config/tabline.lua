-- VSCode風バッファタブライン（Nerd Fontsアイコン付き）
--
-- タブはエディタ列の範囲だけに描く。左右のサイドバー（explorer / shortcuts 等）が
-- 開いている間はその桁数を予約し、タブがパネルの上に被らないようにする。
-- 収まりきらないときは横スクロールし、現在のバッファのタブが必ず見える位置まで寄せる。

-- アイコン定義は config.util.file_icons に集約（explorer/git_panel/tabline で共有）。
-- タブラインはアイコンの後ろに空白を1つ付けて表示する。
local file_icons = require('config.util.file_icons')

local M = {}

-- 横スクロール位置（桁数）。描画のたびに現在のタブが入るよう調整する。
local scroll = 0

-- 直近の描画で、どの画面桁にどのタブがあったか（ドラッグの当たり判定用）。
local layout = {}

-- ドラッグ中に掴んでいるタブの、並びの中での位置。
local drag_index = nil

local function get_icon(filename, path)
  return file_icons.get(filename, false, path) .. ' '
end

local function set_highlights()
  vim.api.nvim_set_hl(0, 'TabLineFill',     { bg = 'NONE' }) -- タブが無い所は透明
  vim.api.nvim_set_hl(0, 'TabLine',         { fg = '#8b8b8b', bg = '#2d2d2d' })
  vim.api.nvim_set_hl(0, 'TabLineSel',      { fg = '#ffffff', bg = '#1e1e1e', underline = true, sp = '#007acc' })
  vim.api.nvim_set_hl(0, 'TabLineMod',      { fg = '#e8a44a', bg = '#2d2d2d' })
  vim.api.nvim_set_hl(0, 'TabLineModSel',   { fg = '#e8a44a', bg = '#1e1e1e', underline = true, sp = '#007acc' })
  vim.api.nvim_set_hl(0, 'TabLineClose',    { fg = '#555555', bg = '#2d2d2d' })
  vim.api.nvim_set_hl(0, 'TabLineCloseSel', { fg = '#aaaaaa', bg = '#1e1e1e' })
end

_G._bufline_click = function(bufnr, _, button)
  if button == 'l' then
    require('config.util.win_util').open_buf(bufnr)
  end
end

_G._bufline_close = function(bufnr, _, button)
  if button == 'l' then
    local cycle = require('config.util.buf_cycle')
    local bufs = cycle.list()
    if #bufs > 1 then
      if vim.api.nvim_get_current_buf() == bufnr then
        cycle.prev()
      end
      vim.cmd('bd ' .. bufnr)
    end
  end
end

--- タブラインのすぐ下の段にあるサイドバーが占める左右の桁数。
--- 画面全幅を占める窓（explorer の全画面表示など）は編集領域が無いので数えない。
local function reserved()
  local win_util = require('config.util.win_util')
  local cols = vim.o.columns
  local left, right = 0, 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not win_util.is_float(w) and win_util.is_sidebar(w) then
      local pos = vim.api.nvim_win_get_position(w)
      local width = vim.api.nvim_win_get_width(w)
      if pos[1] <= 1 and width < cols then -- 最上段かつ全幅ではない
        if pos[2] == 0 then
          left = math.max(left, width + 1) -- サイドバー幅 + 区切り1桁
        elseif pos[2] + width >= cols then
          right = math.max(right, width + 1)
        end
      end
    end
  end
  return left, right
end

--- s の表示幅で [from, to) の範囲だけを返す（0 始まり、全角は 2 桁）。
--- 半分だけ入る全角文字は、はみ出さないよう同じ幅の空白に置き換える。
local function slice(s, from, to)
  local out, x = {}, 0
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    local w = vim.fn.strdisplaywidth(ch)
    local lo, hi = math.max(x, from), math.min(x + w, to)
    if hi > lo then
      out[#out + 1] = (lo == x and hi == x + w) and ch or string.rep(' ', hi - lo)
    end
    x = x + w
  end
  return table.concat(out)
end

--- タブライン文字列に埋め込む（% はエスケープが要る）。
local function escape(s)
  return (s:gsub('%%', '%%%%'))
end

-- 対象バッファと並び順は buf_cycle が持つ（Tab 巡回の順と一致させる）。
local function listed_buffers()
  return require('config.util.buf_cycle').list()
end

--- 1 バッファ分のタブを、ハイライト単位の断片に分けて返す。
local function build_tab(bufnr, is_cur)
  local fullpath = vim.api.nvim_buf_get_name(bufnr)
  local name     = fullpath ~= '' and vim.fn.fnamemodify(fullpath, ':t') or '[No Name]'
  local icon     = get_icon(name, fullpath)
  local modified = vim.bo[bufnr].modified

  local label_hl
  if is_cur then
    label_hl = modified and 'TabLineModSel' or 'TabLineSel'
  else
    label_hl = modified and 'TabLineMod' or 'TabLine'
  end

  local parts = {
    { hl = label_hl, text = '  ' .. icon .. name .. (modified and ' ●' or '') .. '  ', click = '_bufline_click' },
    { hl = is_cur and 'TabLineCloseSel' or 'TabLineClose', text = '×  ', click = '_bufline_close' },
  }

  local width = 0
  for _, p in ipairs(parts) do
    p.width = vim.fn.strdisplaywidth(p.text)
    width = width + p.width
  end
  return { bufnr = bufnr, parts = parts, width = width }
end

--- 断片を [from, to) の範囲で切り出して文字列にする。x は断片の開始桁。
local function emit(part, bufnr, x, from, to)
  local text = slice(part.text, from - x, to - x)
  if text == '' then return '' end
  return table.concat({
    '%', tostring(bufnr), '@v:lua.', part.click, '@',
    '%#', part.hl, '#', escape(text), '%X',
  })
end

local function tabline()
  local current = vim.api.nvim_get_current_buf()
  local left, right = reserved()
  local avail = math.max(0, vim.o.columns - left - right)

  local tabs = {}
  local total, cur_start, cur_end = 0, nil, nil
  for _, bufnr in ipairs(listed_buffers()) do
    local tab = build_tab(bufnr, bufnr == current)
    tab.start = total
    total = total + tab.width
    if bufnr == current then
      cur_start, cur_end = tab.start, total
    end
    tabs[#tabs + 1] = tab
  end

  -- 現在のタブが見える位置まで寄せる（barbar と同じ判定）。
  -- 左に隠れていればその頭まで、右に隠れていれば足りない分だけ右へ。
  if cur_start then
    if scroll > cur_start then
      scroll = cur_start
    elseif scroll + avail < cur_end then
      scroll = scroll + (cur_end - (scroll + avail))
    end
  end
  scroll = math.max(0, math.min(scroll, math.max(0, total - avail)))

  -- 端に隠れているタブがあることを矢印で示す。矢印の分だけ表示範囲を狭める。
  local more_left = scroll > 0
  local more_right = total - scroll > avail
  local from = scroll + (more_left and 1 or 0)
  local to = scroll + avail - (more_right and 1 or 0)

  local s = {}
  if left > 0 then
    s[#s + 1] = '%#TabLineFill#' .. string.rep(' ', left)
  end
  if more_left then
    s[#s + 1] = '%#TabLineFill#‹'
  end

  for _, tab in ipairs(tabs) do
    if tab.start < to and tab.start + tab.width > from then
      local x = tab.start
      for _, part in ipairs(tab.parts) do
        s[#s + 1] = emit(part, tab.bufnr, x, from, to)
        x = x + part.width
      end
    end
  end

  if more_right then
    s[#s + 1] = '%#TabLineFill#›'
  end
  s[#s + 1] = '%#TabLineFill#'

  -- ドラッグの当たり判定用に、画面上のどの桁がどのタブかを覚えておく。
  -- x0/x1 は 0 始まりの画面桁で、見えている範囲に切り詰めてある。
  layout = {}
  for i, tab in ipairs(tabs) do
    local x0 = math.max(left + tab.start - scroll, left + (more_left and 1 or 0))
    local x1 = math.min(left + tab.start + tab.width - scroll, left + avail - (more_right and 1 or 0))
    if x1 > x0 then
      layout[#layout + 1] = { bufnr = tab.bufnr, index = i, x0 = x0, x1 = x1 }
    end
  end

  return table.concat(s)
end

--- 画面桁（0 始まり）にあるタブの、並びの中での位置。無ければ nil。
local function index_at(col)
  for _, item in ipairs(layout) do
    if col >= item.x0 and col < item.x1 then return item.index end
  end
end

--- 並びの index にいるバッファ。
local function bufnr_at_index(index)
  for _, item in ipairs(layout) do
    if item.index == index then return item.bufnr end
  end
end

--- ドラッグ 1 ステップ。掴んだタブをマウス下の位置まで動かす。
--- barbar (lua/barbar/events.lua の mouse_drag_handler) と同じ考え方。
function M.drag(col)
  local index = index_at(col)
  if not index then return false end

  if drag_index == nil then
    drag_index = index
    return false
  end
  if drag_index == index then return false end

  local bufnr = bufnr_at_index(drag_index)
  if not bufnr then return false end

  local moved = require('config.util.buf_cycle').move(bufnr, index - drag_index)
  drag_index = index
  if moved then
    vim.cmd('redrawtabline')
  end
  return moved
end

function M.drag_end()
  drag_index = nil
end

-- マウスのドラッグはキーマップではなく on_key で拾う。
-- <LeftDrag> をマップすると、エディタ本文での範囲選択まで奪ってしまうため。
local LEFT_DRAG = vim.api.nvim_replace_termcodes('<LeftDrag>', true, true, true)
local LEFT_RELEASE = vim.api.nvim_replace_termcodes('<LeftRelease>', true, true, true)

vim.on_key(function(key)
  if key == LEFT_DRAG then
    local ok, pos = pcall(vim.fn.getmousepos)
    if ok and pos.screenrow == 1 then -- タブラインの行だけ
      M.drag(pos.screencol - 1)
    end
  elseif key == LEFT_RELEASE then
    M.drag_end()
  end
end)

set_highlights()

vim.api.nvim_create_autocmd('ColorScheme', { callback = set_highlights })

_G._tabline = tabline
vim.opt.tabline = '%!v:lua._tabline()'

M._layout = function() return layout end

return M
