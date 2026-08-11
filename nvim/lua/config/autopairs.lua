-- 括弧・クォートの自動ペア（nvim-autopairs 相当）
--
-- 挙動:
--   ・開き括弧/クォートを入力するとペアを補完してカーソルを内側へ  (  → (|)
--   ・閉じ括弧/クォートを既存の閉じの上で入力すると重複させず飛び越す  (|) + ) → ()|
--   ・空ペアの内側で <BS> するとペアごと削除  (|) + <BS> → |
--   ・括弧の内側で <CR> するとインデントして展開  {|} + <CR> → {␍  |␍}
--   ・直前が \（エスケープ）なら補完しない。クォートは単語に隣接する時も補完しない
--     （don't の ' や 変数名の隣を勝手にペアしないため）
--
-- 実装は insert-mode の expr マッピングで「送るべきキー列」を返す方式。
-- カーソル移動に <C-g>U を挟むのは、insert 中のカーソル移動で undo 単位が切れて
-- ドットリピートが壊れるのを防ぐため（nvim-autopairs と同じ手法）。

local M = {}

-- 開き → 閉じ（左右で文字が異なるもの）
local BRACKETS = {
  ['('] = ')',
  ['['] = ']',
  ['{'] = '}',
}

-- 左右が同じ文字のもの（クォート）
local QUOTES = {
  ['"'] = true,
  ["'"] = true,
  ['`'] = true,
}

-- カーソル直前・直後の 1 文字を返す（ASCII のペア文字だけが対象なのでバイト単位で十分）
local function around()
  local col  = vim.api.nvim_win_get_cursor(0)[2] -- 0-based（カーソル前のバイト数）
  local line = vim.api.nvim_get_current_line()
  local prev = col > 0 and line:sub(col, col) or ''
  local next = line:sub(col + 1, col + 1)
  return prev, next
end

local function is_word(ch)
  return ch ~= '' and ch:match('[%w_]') ~= nil
end

-- 特殊バッファ（explorer/プロンプト等）では素の挙動に任せる
local function disabled()
  return vim.bo.buftype ~= ''
end

-- 開き括弧: 補完してカーソルを内側へ。直前が \ ならエスケープなので補完しない
local function on_open(open, close)
  if disabled() then return open end
  local prev = around()
  if prev == '\\' then return open end
  return open .. close .. '<C-g>U<Left>'
end

-- 閉じ括弧: 直後が同じ閉じなら飛び越す。なければそのまま入力
local function on_close(close)
  if disabled() then return close end
  local _, next = around()
  if next == close then return '<C-g>U<Right>' end
  return close
end

-- クォート: スキップ / エスケープ / 単語隣接 / 重複 を見てから補完
local function on_quote(q)
  if disabled() then return q end
  local prev, next = around()
  if next == q then return '<C-g>U<Right>' end        -- 既存の閉じを飛び越す
  if prev == '\\' then return q end                    -- エスケープ
  if is_word(prev) or is_word(next) then return q end  -- 単語に隣接（don't 等）
  if prev == q then return q end                       -- 直前が同じクォート（重複回避）
  return q .. q .. '<C-g>U<Left>'
end

-- <BS>: 空ペアの内側ならペアごと削除
local function on_bs()
  if disabled() then return '<BS>' end
  local prev, next = around()
  if BRACKETS[prev] and next == BRACKETS[prev] then return '<BS><Del>' end
  if QUOTES[prev] and next == prev then return '<BS><Del>' end
  return '<BS>'
end

-- <CR>: 括弧の内側ならインデント展開。
-- 補完メニュー表示中は補完側を優先する（VSCode と同じく Enter で確定）。候補を選んで
-- いなければメニューだけ閉じて、通常の <CR> 処理（括弧展開を含む）へ進む。
local function on_cr()
  if disabled() then return '<CR>' end
  if vim.fn.pumvisible() == 1 then
    if vim.fn.complete_info({ 'selected' }).selected ~= -1 then
      return '<C-y>' -- 選択中の候補を確定
    end
    return '<C-e>' .. M._cr_keys()
  end
  return M._cr_keys()
end

-- <CR> 本体の判定（括弧の内側なら展開、それ以外は素の <CR>）
function M._cr_keys()
  local prev, next = around()
  if BRACKETS[prev] and next == BRACKETS[prev] then
    return '<Cmd>lua require("config.autopairs")._expand_cr()<CR>'
  end
  return '<CR>'
end

-- 括弧内 <CR> の実処理: 開き行とカーソルまで / 空のインデント行 / 閉じ以降 の 3 行に分割
function M._expand_cr()
  local pos    = vim.api.nvim_win_get_cursor(0)
  local row    = pos[1] -- 1-based
  local col    = pos[2] -- 0-based
  local line   = vim.api.nvim_get_current_line()
  local before = line:sub(1, col)
  local after  = line:sub(col + 1)
  local indent = line:match('^%s*') or ''
  local sw     = vim.fn.shiftwidth()
  local unit   = vim.bo.expandtab and string.rep(' ', sw) or '\t'
  local inner  = indent .. unit
  vim.api.nvim_buf_set_lines(0, row - 1, row, false, { before, inner, indent .. after })
  vim.api.nvim_win_set_cursor(0, { row + 1, #inner })
end

local function setup()
  local opt = { expr = true, replace_keycodes = true, silent = true, desc = 'autopairs' }
  for open, close in pairs(BRACKETS) do
    vim.keymap.set('i', open,  function() return on_open(open, close) end, opt)
    vim.keymap.set('i', close, function() return on_close(close) end,      opt)
  end
  for q in pairs(QUOTES) do
    vim.keymap.set('i', q, function() return on_quote(q) end, opt)
  end
  vim.keymap.set('i', '<BS>', on_bs, opt)
  vim.keymap.set('i', '<CR>', on_cr, opt)
end

setup()

return M
