-- 単語/選択を括弧・クォートで囲む/外すをトグルする
-- (nvim-surround 相当のうち「追加/削除のトグル」に絞った自作版)
--
--   ノーマル  <leader>s{char}  カーソル下の単語(iw)を囲む / 既に囲まれていれば外す
--   ビジュアル <leader>s{char}  選択範囲を囲む / 既に囲まれていれば外す
--
-- 対応文字: ( ) [ ] { } " ' `
--   開き括弧キー ( [ { は内側にスペースを入れる  ( word )
--   閉じ括弧キー ) ] } はスペース無し             (word)
--   削除時はスペース有無どちらも検出して外す
--
-- <leader>s を単独の完全マップにし、その場で getchar で囲み文字を待つ（受付方式）。
-- ビジュアルのバイト操作は UTF-8 の文字境界を厳密に扱う（日本語等の途中に囲み文字を
-- 差し込んでバイト列を壊さないため）。

local M = {}

-- キー → { 開き, 閉じ }。開き括弧文字・閉じ括弧文字のどちらのキーでも同じペアを扱う
local PAIRS = {
  ['('] = { '(', ')' }, [')'] = { '(', ')' },
  ['['] = { '[', ']' }, [']'] = { '[', ']' },
  ['{'] = { '{', '}' }, ['}'] = { '{', '}' },
  ['"'] = { '"', '"' },
  ["'"] = { "'", "'" },
  ['`'] = { '`', '`' },
}

-- 開き括弧キーのときだけ内側にスペースを足す
local SPACE_KEY = { ['('] = true, ['['] = true, ['{'] = true }

local function esc(s)
  return vim.pesc(s)
end

-- getchar で囲み文字を 1 文字読む。対応外の文字や Esc は nil。
-- 待機中は「受付に入った」ことが分かるようコマンドラインにヒントを出す
-- （意図せず <leader>s を押してしまった時にも気づけるように）。
local HINT = 'surround: '

local function read_key()
  vim.api.nvim_echo({ { HINT } }, false, {})
  vim.cmd('redraw')
  local ok, c = pcall(vim.fn.getcharstr)
  vim.api.nvim_echo({ { '' } }, false, {}) -- ヒントを消す
  if not ok or c == nil or c == '' then return nil end
  if not PAIRS[c] then return nil end
  return c
end

-- ── UTF-8 の文字境界ヘルパ ──────────────────────────────
-- 0-based byte offset(文字先頭)にある 1 文字のバイト長
local function char_len(line, byte0)
  local b = line:byte(byte0 + 1)
  if not b then return 1 end
  if b < 0x80 then return 1
  elseif b < 0xE0 then return 2
  elseif b < 0xF0 then return 3
  else return 4 end
end

-- 0-based byte offset(文字先頭)の 1 つ前の文字の先頭 0-based を返す。無ければ nil
local function prev_char_start(line, byte0)
  if byte0 <= 0 then return nil end
  local i = byte0 - 1
  while i > 0 do
    local b = line:byte(i + 1)
    if b < 0x80 or b >= 0xC0 then break end -- 継続バイト(0x80-0xBF)でなければ先頭
    i = i - 1
  end
  return i
end

local function get_line(row)
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
end

-- カーソル下の単語 [%w_]+ の byte 範囲 (1-based, inclusive) を返す。単語上でなければ nil
local function word_range(line, col0)
  local n = #line
  local c = col0 + 1 -- 0-based → 1-based
  if c < 1 or c > n then return nil end
  local function isw(ch) return ch:match('[%w_]') ~= nil end
  if not isw(line:sub(c, c)) then return nil end
  local s, e = c, c
  while s > 1 and isw(line:sub(s - 1, s - 1)) do s = s - 1 end
  while e < n and isw(line:sub(e + 1, e + 1)) do e = e + 1 end
  return s, e
end

-- ノーマル: カーソル下の単語をトグル（行全体を再構築するのでバイト破損は起きない）
local function toggle_normal(key)
  local open, close = PAIRS[key][1], PAIRS[key][2]
  local pos  = vim.api.nvim_win_get_cursor(0)
  local row  = pos[1]
  local line = vim.api.nvim_get_current_line()
  local ws, we = word_range(line, pos[2])
  if not ws then return end

  local left  = line:sub(1, ws - 1)
  local word  = line:sub(ws, we)
  local right = line:sub(we + 1)

  -- 既に囲まれているか: left 末尾が open(+空白) / right 先頭が (空白+)close
  local pre  = left:match('^(.-)' .. esc(open) .. '%s*$')
  local post = right:match('^%s*' .. esc(close) .. '(.-)$')
  if pre ~= nil and post ~= nil then
    vim.api.nvim_set_current_line(pre .. word .. post)
    vim.api.nvim_win_set_cursor(0, { row, #pre })
    return
  end

  local sp = SPACE_KEY[key] and ' ' or ''
  vim.api.nvim_set_current_line(left .. open .. sp .. word .. sp .. close .. right)
  vim.api.nvim_win_set_cursor(0, { row, #left + #open + #sp })
end

-- ビジュアル: 選択範囲をトグル。選択端は getchar 前に捕捉した getpos('v')/('.') を受け取る。
-- 挿入/削除位置は UTF-8 の文字境界に合わせる（囲み文字は ASCII 1 バイト前提）。
local function toggle_visual(key, p1, p2)
  local open, close = PAIRS[key][1], PAIRS[key][2]
  local sr, sc = p1[2], p1[3] -- 1-based row / byte(文字先頭)
  local er, ec = p2[2], p2[3]
  if sr > er or (sr == er and sc > ec) then
    sr, sc, er, ec = er, ec, sr, sc
  end

  local sline = get_line(sr)
  local eline = get_line(er)
  local s0 = sc - 1 -- 選択開始文字の 0-based 先頭
  local e0 = ec - 1 -- 選択終了文字の 0-based 先頭

  -- 選択終端の「次」の 0-based byte（終端文字のバイト長ぶん進める。行選択等はクランプ）
  local end_after
  if e0 >= #eline then
    end_after = #eline
  else
    end_after = e0 + char_len(eline, e0)
  end

  -- 外す判定: 選択の直前 / 直後の 1 文字（マルチバイト対応）
  local ps = prev_char_start(sline, s0)
  local before = ps and sline:sub(ps + 1, s0) or ''
  local after  = eline:sub(end_after + 1, end_after + char_len(eline, end_after))
  if before == open and after == close then
    -- 外側の囲みを外す（後ろ→前の順でインデックスずれを防ぐ）
    vim.api.nvim_buf_set_text(0, er - 1, end_after, er - 1, end_after + #after, {})
    vim.api.nvim_buf_set_text(0, sr - 1, ps, sr - 1, s0, {})
    return
  end
  -- 囲む（後ろに閉じ→前に開き）
  vim.api.nvim_buf_set_text(0, er - 1, end_after, er - 1, end_after, { close })
  vim.api.nvim_buf_set_text(0, sr - 1, s0, sr - 1, s0, { open })
end

-- テストから直接叩けるよう公開
M.toggle_normal = toggle_normal
M.toggle_visual = toggle_visual

local function setup()
  -- <leader>s を単独の完全マップにして、その場で getchar で囲み文字を待つ。
  -- 多段マップ(<leader>s( 等)だと待ち時間の timeout で素の s(ビジュアルの change)が
  -- 暴発して選択が消えるため、この方式にしている。
  vim.keymap.set('n', '<leader>s', function()
    local key = read_key()
    if key then toggle_normal(key) end
  end, { silent = true, desc = 'surround (toggle)' })

  vim.keymap.set('x', '<leader>s', function()
    -- getchar で待つ前に選択範囲を捕捉しておく
    local p1, p2 = vim.fn.getpos('v'), vim.fn.getpos('.')
    -- 先に visual を抜ける。抜けないと getchar 待ちの間ずっと '-- VISUAL --' が
    -- 出っぱなしになり、受付メッセージがそれに隠れてしまう
    vim.cmd('normal! \27')
    local key = read_key()
    if key then toggle_visual(key, p1, p2) end
  end, { silent = true, desc = 'surround (toggle)' })
end

setup()

return M
