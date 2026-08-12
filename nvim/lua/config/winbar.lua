-- ファイルパス + シンボルのパンくずバー（winbar）
--
-- winbar はタブライン(showtabline)の直下・各ウィンドウの上端に出る1行。ここに開いて
-- いるファイルの「cwd 相対パス」と、カーソルが今いる「シンボル(クラス/関数)」を
-- ' › ' 区切りのパンくずで出す。VS Code の breadcrumbs 相当。
--
--   nvim › lua › config › explorer.lua › 󰊕 open › 󰆧 callback
--
-- シンボルはアイコン付きで出す。字形と色の系統は symbols.lua(Space ss のピッカー)と
-- 共有していて、同じ種別はどこで見ても同じ見た目になる。
-- 取得とキャッシュは util/lsp_symbols.lua（context.lua と共用）。
--
-- なぜウィンドウローカル(vim.wo[win])に設定するか:
--   'winbar' はオプション値が非空だと %! の評価結果が空でも winbar 行が確保されてしまう。
--   グローバルに設定すると explorer / git_panel / ターミナル / スタート画面のような特殊
--   ウィンドウにも空バーが1行入り込む。そこで通常のファイルウィンドウだけに文字列を入れ、
--   それ以外は '' にして行ごと消す。

local M = {}

local symbols = require('config.util.lsp_symbols')

local SEP = ' › '

local function set_highlights()
  -- editor が透過なので bg は NONE。current/非current で明るさを変える（淡いグレー）
  vim.api.nvim_set_hl(0, 'WinBar',   { fg = '#8b8b8b', bg = 'NONE' })
  vim.api.nvim_set_hl(0, 'WinBarNC', { fg = '#6d6d6d', bg = 'NONE' })
  -- シンボル名はパスより少し明るくして視線が止まるようにする
  vim.api.nvim_set_hl(0, 'WinBarSymbol', { fg = '#c0caf5', bg = 'NONE' })
  -- アイコンだけ種別ごとに色を変える（配色は colorscheme に追従させたいので link）
  vim.api.nvim_set_hl(0, 'WinBarIconType',       { link = 'Type' })
  vim.api.nvim_set_hl(0, 'WinBarIconFunction',   { link = 'Function' })
  vim.api.nvim_set_hl(0, 'WinBarIconInclude',    { link = 'Include' })
  vim.api.nvim_set_hl(0, 'WinBarIconIdentifier', { link = 'Identifier' })
end

-- winbar を出すウィンドウか（通常のファイルウィンドウのみ）
function M.should_show(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  -- フロートには出さない
  local cfg = vim.api.nvim_win_get_config(win)
  if cfg.relative and cfg.relative ~= '' then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  -- explorer / git_panel / terminal / start画面 等は buftype が空でない
  if vim.bo[buf].buftype ~= '' then return false end
  -- 無名バッファ([No Name])は出さない
  if vim.api.nvim_buf_get_name(buf) == '' then return false end
  return true
end

--- winbar 書式で使えないので % をエスケープする
local function esc(str)
  return (str:gsub('%%', '%%%%'))
end

-- バッファ番号 → winbar 文字列（cwd 相対パスのパンくず）
function M.build(buf)
  local fullpath = vim.api.nvim_buf_get_name(buf)
  local rel      = vim.fn.fnamemodify(fullpath, ':.') -- cwd 相対（cwd 外なら絶対パスのまま）
  -- パス中の % は statusline 書式扱いされるためエスケープ
  local safe = esc(rel)
  -- '/' を ' › ' に置き換えてパンくず表示にする
  local crumb = safe:gsub('/', SEP)
  return ' ' .. crumb
end

--- キャッシュ済みシンボル（テストではここを差し替える）
function M.symbols_for(buf)
  return symbols.symbols_for(buf)
end

--- シンボル部分。無ければ ''
--- アイコンは種別ごとの色、名前は WinBarSymbol で出す
function M.build_symbols(buf, lnum)
  local out = {}
  for _, sym in ipairs(symbols.chain(M.symbols_for(buf), lnum, { markup = symbols.is_markup(buf) })) do
    out[#out + 1] = table.concat({
      SEP,
      '%#WinBarIcon' .. symbols.kind_group(sym.kind) .. '#',
      sym.icon,
      ' %#WinBarSymbol#',
      esc(sym.name),
      '%*',
    })
  end
  return table.concat(out)
end

-- ウィンドウに設定すべき winbar 値（対象外は ''）
function M.winbar_for(win)
  if not M.should_show(win) then return '' end
  local buf  = vim.api.nvim_win_get_buf(win)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  return M.build(buf) .. M.build_symbols(buf, lnum)
end

--- 値が変わったときだけ代入する。
--- 同じ値でも代入すると再描画が走るので、スクロール中のちらつき/コストになる。
local function apply(win)
  local want = M.winbar_for(win)
  if vim.wo[win].winbar ~= want then
    vim.wo[win].winbar = want
  end
end

-- 全ウィンドウの winbar を更新
function M.update_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    pcall(apply, win)
  end
end

set_highlights()
vim.api.nvim_create_autocmd('ColorScheme', { callback = set_highlights })

local grp = vim.api.nvim_create_augroup('user_winbar', { clear = true })
vim.api.nvim_create_autocmd(
  { 'BufWinEnter', 'WinEnter', 'BufEnter', 'WinNew', 'TabEnter', 'DirChanged', 'TermOpen', 'FileType' },
  {
    group = grp,
    -- buftype/filetype がセットされ切ってから判定したいので schedule
    callback = function() vim.schedule(M.update_all) end,
  }
)

-- カーソル行が動いたらシンボル部分だけ貼り替える（現在ウィンドウのみ）。
-- ここでやるのはキャッシュ済みリストの範囲判定だけなので軽い。
vim.api.nvim_create_autocmd('CursorMoved', {
  group = grp,
  callback = function()
    pcall(apply, vim.api.nvim_get_current_win())
  end,
})

-- 新しい documentSymbol が届いたら貼り直す
symbols.on_update(function() M.update_all() end)

M.update_all()

return M
