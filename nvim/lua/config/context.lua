-- スティッキーヘッダ（VSCode の Sticky Scroll 相当）
--
-- 画面上端にスクロールアウトした「今いる宣言の行」をフロートで重ねて表示する。
-- 基準はカーソル行ではなく画面最上行。今どのクラス/関数の中を見ているかが、
-- スクロールしても常に上端に残る。
--
-- 何を貼り付けるか:
--   LSP の documentSymbol が返す宣言（クラス / 関数 / メソッド等）だけ。
--   if / for / block は貼り付けない。VSCode の Sticky Scroll も既定は
--   outlineModel = DocumentSymbolProvider なので同じ方針。
--   取得とキャッシュは util/lsp_symbols.lua（winbar.lua と共用）。

local symbols = require('config.util.lsp_symbols')

local ctx_buf        = nil
local ctx_win        = nil
local ctx_src_win    = nil
local ctx_ns         = vim.api.nvim_create_namespace('context_lnum')
local SEP            = '─'
local orig_scrolloff = nil

-- 画面上にスクロールアウトした親宣言のみ収集する（行番号付き）
---@param buf integer
---@param lines string[] バッファ全行
---@param topline integer 画面最上行（1始まり）
---@return { text: string, lnum: integer }[]
local function collect_contexts(buf, lines, topline)
  local result = {}
  for _, sym in ipairs(symbols.chain_at(buf, topline)) do
    -- 宣言行が画面外に出ているものだけ。見えているものを二重に出さない
    if sym.lnum < topline then
      result[#result + 1] = { text = lines[sym.lnum] or '', lnum = sym.lnum }
    end
  end
  return result
end

local function close()
  if ctx_win and vim.api.nvim_win_is_valid(ctx_win) then
    vim.api.nvim_win_close(ctx_win, true)
  end
  ctx_win = nil
  if orig_scrolloff ~= nil and ctx_src_win and vim.api.nvim_win_is_valid(ctx_src_win) then
    vim.wo[ctx_src_win].scrolloff = orig_scrolloff
  end
  orig_scrolloff = nil
  ctx_src_win    = nil
end

local function ensure_buf()
  if not ctx_buf or not vim.api.nvim_buf_is_valid(ctx_buf) then
    ctx_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[ctx_buf].buftype   = 'nofile'
    vim.bo[ctx_buf].buflisted = false
    vim.bo[ctx_buf].swapfile  = false
  end
  return ctx_buf
end

--- 値が変わったときだけ代入する。
--- 特に 'filetype' は同じ値を入れ直しても FileType → Syntax が必ず発火し、
--- html なら syntax/html.vim（中で css と javascript も読む）を毎回読み直すことになる。
--- ここは CursorMoved ごとに通るので、素直に代入すると 1 行スクロールごとに
--- 8ms 近く持っていかれる。
local function set_if_changed(buf, name, value)
  if vim.bo[buf][name] ~= value then
    vim.bo[buf][name] = value
  end
end

local function update()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()

  if vim.bo[buf].buftype ~= '' then close(); return end

  local topline = vim.fn.line('w0', win)
  local lnum    = vim.api.nvim_win_get_cursor(win)[1] - 1

  if topline <= 1 then close(); return end

  local total    = vim.api.nvim_buf_line_count(buf)
  local lines    = vim.api.nvim_buf_get_lines(buf, 0, total, false)
  local contexts = collect_contexts(buf, lines, topline)

  if #contexts == 0 then close(); return end

  local cbuf    = ensure_buf()
  local info    = vim.fn.getwininfo(win)[1]
  local textoff = info and info.textoff or 0
  local width   = math.max(1, vim.api.nvim_win_get_width(win) - 1)
  local height  = #contexts

  -- 行番号を textoff 幅に合わせてフォーマットしてコンテンツに含める
  local num_width = textoff > 0 and (textoff - 1) or 0
  local display_lines = {}
  for _, ctx in ipairs(contexts) do
    local prefix = textoff > 0
      and string.format('%' .. num_width .. 'd ', (lnum + 1) - ctx.lnum)
      or ''
    table.insert(display_lines, prefix .. ctx.text)
  end

  vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, display_lines)
  set_if_changed(cbuf, 'filetype',   vim.bo[buf].filetype)
  set_if_changed(cbuf, 'tabstop',    vim.bo[buf].tabstop)
  set_if_changed(cbuf, 'shiftwidth', vim.bo[buf].shiftwidth)
  set_if_changed(cbuf, 'expandtab',  vim.bo[buf].expandtab)

  -- 行番号部分に LineNr ハイライトを適用
  vim.api.nvim_buf_clear_namespace(cbuf, ctx_ns, 0, -1)
  if textoff > 0 then
    for i = 0, height - 1 do
      vim.api.nvim_buf_set_extmark(cbuf, ctx_ns, i, 0, {
        end_col  = textoff,
        hl_group = 'LineNr',
      })
    end
  end

  local border = {
    '', '', '', '',
    { SEP, 'TreesitterContextSeparator' },
    { SEP, 'TreesitterContextSeparator' },
    { SEP, 'TreesitterContextSeparator' },
    '',
  }

  local win_cfg = {
    relative  = 'win',
    win       = win,
    row       = 0,
    col       = 0,       -- col=0 でガターごと覆い、行番号はコンテンツ内に含める
    width     = width,
    height    = height,
    focusable = false,
    zindex    = 20,
    style     = 'minimal',
    border    = border,
    noautocmd = true,
  }

  if ctx_win and vim.api.nvim_win_is_valid(ctx_win) then
    vim.api.nvim_win_set_config(ctx_win, win_cfg)
    vim.api.nvim_win_set_buf(ctx_win, cbuf)
  else
    ctx_win = vim.api.nvim_open_win(cbuf, false, win_cfg)
    vim.api.nvim_set_option_value('wrap',           false,                                                  { win = ctx_win })
    vim.api.nvim_set_option_value('winhighlight',   'Normal:TreesitterContext,NormalNC:TreesitterContext',  { win = ctx_win })
    vim.api.nvim_set_option_value('number',         false,                                                  { win = ctx_win })
    vim.api.nvim_set_option_value('relativenumber', false,                                                  { win = ctx_win })
    vim.api.nvim_set_option_value('signcolumn',     'no',                                                   { win = ctx_win })
    vim.api.nvim_set_option_value('foldcolumn',     '0',                                                    { win = ctx_win })
  end

  -- コンテキスト行の裏にカーソルが入らないよう scrolloff をウィンドウローカルで調整
  ctx_src_win = win
  if orig_scrolloff == nil then
    orig_scrolloff = vim.wo[win].scrolloff
  end
  vim.wo[win].scrolloff = math.max(orig_scrolloff, height + 1)

  -- 横スクロールを親ウィンドウに合わせる
  local leftcol = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
  vim.api.nvim_win_call(ctx_win, function()
    vim.fn.winrestview({ leftcol = leftcol })
  end)
end

local function setup_hl()
  vim.api.nvim_set_hl(0, 'TreesitterContext',          { bg = '#232433' })
  vim.api.nvim_set_hl(0, 'TreesitterContextSeparator', { fg = '#3b4261' })
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinScrolled' }, {
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= '' then close(); return end
    update()
  end,
})

vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
  callback = close,
})

vim.api.nvim_create_autocmd('WinEnter', {
  callback = function()
    if ctx_win and vim.api.nvim_get_current_win() == ctx_win then
      vim.cmd('wincmd p')
    end
  end,
})

-- 新しい documentSymbol が届いたら貼り直す（LSP が付いた直後など）
symbols.on_update(function(buf)
  if buf == vim.api.nvim_get_current_buf() then
    pcall(update)
  end
end)

return {
  _collect_contexts = collect_contexts,
  _update = update,
  _close = close,
}
