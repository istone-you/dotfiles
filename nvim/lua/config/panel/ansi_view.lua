-- 外部コマンドが吐く ANSI(SGR)付きテキストを、通常バッファ＋extmarkハイライトへ
-- 「そのまま」写す（dockerパネルのログ表示などで使う）。端末バッファ(nvim_open_term)と違い
-- 通常バッファなので、CursorLineの選択ハイライトや通常のカーソル移動・ジャンプが効く。
-- 独自のレンダリングはせず、受け取った色をそのまま再現する。
--
-- 対応するエスケープ: SGR(ESC[...m)、EL(ESC[...K = 現在の背景色で行末まで塗る=ブロック背景)。
-- それ以外の CSI は読み飛ばす。

local M = {}

-- ── 色変換 ───────────────────────────────────────
-- 基本16色。外部コマンドは端末のパレットの色を指定してくるので、
-- こちらも端末のパレット vim.g.terminal_color_* を最優先で使う（＝端末で見た時と同じ色になる）。
-- 未設定時のフォールバックは、安っぽい原色ではなくパネルと同系の tokyonight 系にする
-- （特に青は #0000ee のような見づらい濃紺ではなく #7aa2f7）。
local DEFAULT = {
  [0] = '#15161e', [1] = '#f7768e', [2] = '#9ece6a', [3] = '#e0af68',
  [4] = '#7aa2f7', [5] = '#bb9af7', [6] = '#7dcfff', [7] = '#a9b1d6',
  [8] = '#414868', [9] = '#f7768e', [10] = '#9ece6a', [11] = '#e0af68',
  [12] = '#7aa2f7', [13] = '#bb9af7', [14] = '#7dcfff', [15] = '#c0caf5',
}
local function BASIC(n)
  local t = vim.g['terminal_color_' .. n]
  return (type(t) == 'string' and t) or DEFAULT[n]
end
local CUBE = { 0, 95, 135, 175, 215, 255 }

local function xterm256(n)
  if n < 16 then return BASIC(n) end
  if n >= 232 then local v = 8 + (n - 232) * 10; return string.format('#%02x%02x%02x', v, v, v) end
  n = n - 16
  local r = CUBE[math.floor(n / 36) % 6 + 1]
  local g = CUBE[math.floor(n / 6) % 6 + 1]
  local b = CUBE[n % 6 + 1]
  return string.format('#%02x%02x%02x', r, g, b)
end

-- ── ハイライトグループのキャッシュ（状態→グループ名） ──
local hl_seq = 0
local hl_cache = {}

local function group_for(st)
  -- reverse は fg/bg を入れ替えて表現する
  local fg, bg = st.fg, st.bg
  if st.reverse then fg, bg = bg or '#000000', fg or '#c0caf5' end
  local key = table.concat({
    fg or '-', bg or '-', st.bold and 'b' or '-', st.italic and 'i' or '-', st.underline and 'u' or '-',
  }, '|')
  if key == '-|-|-|-|-' then return nil end -- 完全デフォルトは色付け不要
  local cached = hl_cache[key]
  if cached then return cached end
  hl_seq = hl_seq + 1
  local name = 'GitPanelAnsi' .. hl_seq
  local o = {}
  if fg then o.fg = fg end
  if bg then o.bg = bg end
  if st.bold then o.bold = true end
  if st.italic then o.italic = true end
  if st.underline then o.underline = true end
  vim.api.nvim_set_hl(0, name, o)
  hl_cache[key] = name
  return name
end

-- ── SGR パラメータを状態へ適用 ──
local function apply_sgr(st, params)
  local i = 1
  local n = #params
  if n == 0 then params = { 0 }; n = 1 end
  while i <= n do
    local p = params[i]
    if p == 0 then
      st.fg, st.bg, st.bold, st.italic, st.underline, st.reverse = nil, nil, false, false, false, false
    elseif p == 1 then st.bold = true
    elseif p == 3 then st.italic = true
    elseif p == 4 then st.underline = true
    elseif p == 7 then st.reverse = true
    elseif p == 22 then st.bold = false
    elseif p == 23 then st.italic = false
    elseif p == 24 then st.underline = false
    elseif p == 27 then st.reverse = false
    elseif p == 39 then st.fg = nil
    elseif p == 49 then st.bg = nil
    elseif p >= 30 and p <= 37 then st.fg = BASIC(p - 30)
    elseif p >= 90 and p <= 97 then st.fg = BASIC(p - 90 + 8)
    elseif p >= 40 and p <= 47 then st.bg = BASIC(p - 40)
    elseif p >= 100 and p <= 107 then st.bg = BASIC(p - 100 + 8)
    elseif p == 38 or p == 48 then
      local target = (p == 38) and 'fg' or 'bg'
      local mode = params[i + 1]
      if mode == 2 then
        st[target] = string.format('#%02x%02x%02x', params[i + 2] or 0, params[i + 3] or 0, params[i + 4] or 0)
        i = i + 4
      elseif mode == 5 then
        st[target] = xterm256(params[i + 1 + 1] or 0)
        i = i + 2
      end
    end
    i = i + 1
  end
end

-- ── 本体: ansi_text を buf へ描画 ──
--- 戻り値: file_line_predicate を渡した時だけ、それが真を返した行(0-indexed)の一覧。
--- 呼び出し側が行頭ジャンプに使う。
function M.render(buf, ns, ansi_text, file_line_predicate)
  local lines, marks, file_rows = {}, {}, {}
  local line_fills = {} -- [row0] = 背景グループ。行全体(端まで)を塗る＝行単位の帯
  local st = { fg = nil, bg = nil, bold = false, italic = false, underline = false, reverse = false }
  local cur = {}          -- 現在行のテキスト片
  local col = 0           -- 現在行のバイト長
  local run_start = 0     -- 現在の状態が始まったバイト列
  local run_group = nil   -- 現在の状態のグループ
  local fill = nil        -- ELで指定された「行末まで塗る」背景グループ

  local function flush_run()
    if run_group and col > run_start then
      marks[#marks + 1] = { #lines, run_start, col, run_group, false, 100 }
    end
    run_start = col
  end

  local function finish_line()
    flush_run()
    local text = table.concat(cur)
    lines[#lines + 1] = text
    if fill then line_fills[#lines - 1] = fill end -- この行は行全体を塗る（後で line_hl_group）
    cur, col, run_start, fill = {}, 0, 0, nil
    run_group = group_for(st)
  end

  local i, n = 1, #ansi_text
  run_group = group_for(st)
  while i <= n do
    local c = ansi_text:byte(i)
    if c == 27 and ansi_text:byte(i + 1) == 91 then -- ESC '['
      -- パラメータ列を読み、最終バイト(英字)まで
      local j = i + 2
      local params_str = {}
      while j <= n do
        local cj = ansi_text:byte(j)
        if (cj >= 48 and cj <= 57) or cj == 59 then -- 数字 or ';'
          params_str[#params_str + 1] = string.char(cj)
          j = j + 1
        else
          break
        end
      end
      local final = ansi_text:byte(j)
      local params = {}
      for tok in table.concat(params_str):gmatch('[^;]+') do params[#params + 1] = tonumber(tok) end
      if final == 109 then -- 'm' = SGR
        flush_run()
        apply_sgr(st, params)
        run_group = group_for(st)
      elseif final == 75 then -- 'K' = EL: 現在の背景で行末まで（ブロック背景）
        if st.bg then fill = group_for({ bg = st.bg }) end
      end
      i = j + 1
    elseif c == 10 then -- '\n'
      finish_line()
      i = i + 1
    elseif c == 13 then -- '\r' は捨てる
      i = i + 1
    else
      -- 通常文字（UTF-8のマルチバイトも1つずつ足す＝バイト列としてそのまま蓄積）
      cur[#cur + 1] = string.char(c)
      col = col + 1
      i = i + 1
    end
  end
  if #cur > 0 or col > 0 then finish_line() end

  -- ファイル境界（呼び出し側が predicate を渡した時だけ）
  if file_line_predicate then
    for idx, l in ipairs(lines) do
      if file_line_predicate(l, idx) then file_rows[#file_rows + 1] = idx - 1 end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- まず行全体の背景（line_hl_group）を敷く。文字色/語強調のextmarkはこの上に描かれる。
  for row0, group in pairs(line_fills) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row0, 0, { line_hl_group = group, priority = 1 })
  end
  for _, mk in ipairs(marks) do
    local row, c0, c1, group, _, prio = mk[1], mk[2], mk[3], mk[4], mk[5], mk[6]
    local line = lines[row + 1] or ''
    local ec = math.min(c1, #line)
    if ec > c0 then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, math.min(c0, #line), {
        end_row = row, end_col = ec, hl_group = group, priority = prio or 100,
      })
    end
  end
  return file_rows
end

return M
