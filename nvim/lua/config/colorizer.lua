-- ファイル内のカラーコードをその色で表示する（norcalli/nvim-colorizer.lua 参考）。
-- 対応表記: #RGB / #RGBA / #RRGGBB / #RRGGBBAA / 0xRRGGBB /
--           rgb() / rgba() / hsl() / hsla() / CSS 色名（CSS 系 filetype のみ）
--
-- 描画は decoration provider の on_line で ephemeral extmark を置く方式。
-- こうすると「画面に見えている行」だけをパースするので、巨大なファイルでも
-- バッファ全体を走査せずに済む（nvim-colorizer と同じ考え方）。

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace('colorizer')

-- 極端に長い行（minified CSS 等）は途中で諦める
local MAX_LINE = 2048
-- rgb(...) の中身として許す最大長。ここを超えたら色指定ではないとみなす
local MAX_FN_ARGS = 64

-- 色名（`red` 等）は変数名・識別子と紛らわしいので CSS 系の filetype だけで拾う
local NAME_FILETYPES = {
  css = true,
  scss = true,
  sass = true,
  less = true,
  stylus = true,
  html = true,
  xml = true,
  svg = true,
  vue = true,
  svelte = true,
  astro = true,
}

local FN_KIND = { rgb = 'rgb', rgba = 'rgb', hsl = 'hsl', hsla = 'hsl' }

-- ══════════════════════════════════════════════
-- 小物
-- ══════════════════════════════════════════════

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function to_hex(r, g, b)
  return string.format('%02x%02x%02x',
    clamp(math.floor(r + 0.5), 0, 255),
    clamp(math.floor(g + 0.5), 0, 255),
    clamp(math.floor(b + 0.5), 0, 255))
end

--- '#abc' の 3 桁を 'aabbcc' へ展開する
local function expand3(s)
  local a, b, c = s:sub(1, 1), s:sub(2, 2), s:sub(3, 3)
  return (a .. a .. b .. b .. c .. c):lower()
end

--- 単語の一部（識別子の途中）かどうか。`--my-red` のような CSS 変数も弾きたいので `-` も含める
local function is_word_char(c)
  return c ~= '' and c:match('[%w_%-]') ~= nil
end

--- HSL → RGB。h は度（0-360）、s/l は 0-1
---@return integer, integer, integer
function M.hsl_to_rgb(h, s, l)
  h = (h % 360) / 360
  s = clamp(s, 0, 1)
  l = clamp(l, 0, 1)
  if s == 0 then
    local v = l * 255
    return v, v, v
  end
  local function hue(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end
  local q = l < 0.5 and l * (1 + s) or (l + s - l * s)
  local p = 2 * l - q
  return hue(p, q, h + 1 / 3) * 255, hue(p, q, h) * 255, hue(p, q, h - 1 / 3) * 255
end

-- ══════════════════════════════════════════════
-- パーサ（純粋関数。テストはここを直接叩く）
-- ══════════════════════════════════════════════

--- '12' / '50%' / '120deg' を数値と単位に割る
---@return number|nil, string
local function number_unit(tok)
  local v, unit = tok:match('^([%+%-]?%d*%.?%d+)(.*)$')
  if not v then return nil, '' end
  return tonumber(v), unit
end

--- rgb の 1 成分（0-255 または %）
local function rgb_component(tok)
  local v, unit = number_unit(tok)
  if not v then return nil end
  if unit == '%' then return clamp(v / 100 * 255, 0, 255) end
  if unit ~= '' then return nil end
  return clamp(v, 0, 255)
end

--- 0-1 のアルファ（`0.5` でも `50%` でも書ける）
local function alpha_component(tok)
  local v, unit = number_unit(tok)
  if not v then return nil end
  if unit == '%' then return clamp(v / 100, 0, 1) end
  if unit ~= '' then return nil end
  return clamp(v, 0, 1)
end

--- CSS の色相。単位無し / deg / turn / rad を受ける
local function hue_component(tok)
  local v, unit = number_unit(tok)
  if not v then return nil end
  if unit == '' or unit == 'deg' then return v end
  if unit == 'turn' then return v * 360 end
  if unit == 'rad' then return v * 180 / math.pi end
  return nil
end

--- 百分率（s / l 用）。単位無しも 0-100 として受ける
local function percent_component(tok)
  local v, unit = number_unit(tok)
  if not v then return nil end
  if unit ~= '' and unit ~= '%' then return nil end
  return clamp(v / 100, 0, 1)
end

--- `rgb(1, 2, 3 / 50%)` の中身をトークンへ割る（`,` `空白` `/` はすべて区切り扱い）
local function split_args(inner)
  local out = {}
  for tok in (inner:gsub('/', ' ')):gmatch('[^%s,]+') do
    out[#out + 1] = tok
  end
  return out
end

---@return string|nil hex, number|nil alpha
local function parse_fn_args(kind, inner)
  local args = split_args(inner)
  if #args < 3 or #args > 4 then return nil end

  local hex
  if kind == 'rgb' then
    local r = rgb_component(args[1])
    local g = rgb_component(args[2])
    local b = rgb_component(args[3])
    if not (r and g and b) then return nil end
    hex = to_hex(r, g, b)
  else
    local h = hue_component(args[1])
    local s = percent_component(args[2])
    local l = percent_component(args[3])
    if not (h and s and l) then return nil end
    hex = to_hex(M.hsl_to_rgb(h, s, l))
  end

  local alpha
  if args[4] then
    alpha = alpha_component(args[4])
    if not alpha then return nil end
  end
  return hex, alpha
end

--- CSS / X11 の色名テーブル（小文字名 → 'rrggbb'）。Neovim 組み込みの色マップを使う
local color_names = nil
local function names_table()
  if not color_names then
    color_names = {}
    for name, value in pairs(api.nvim_get_color_map()) do
      color_names[name:lower()] = string.format('%06x', value)
    end
  end
  return color_names
end

--- `#fff` 系。桁数がちょうど 3/4/6/8 のときだけ採用する
--- （`#1234567` のような中途半端な並びを 6 桁として拾わないため）
local function match_hex(line, i)
  if line:sub(i, i) ~= '#' then return nil end
  local n = #line
  local j = i + 1
  while j <= n and line:sub(j, j):match('^%x$') do j = j + 1 end
  local len = j - i - 1
  local body = line:sub(i + 1, j - 1)
  if len == 8 then
    return { from = i - 1, to = i + 8, hex = body:sub(1, 6):lower(), alpha = tonumber(body:sub(7, 8), 16) / 255 }
  elseif len == 6 then
    return { from = i - 1, to = i + 6, hex = body:lower() }
  elseif len == 4 then
    local a = body:sub(4, 4)
    return { from = i - 1, to = i + 4, hex = expand3(body:sub(1, 3)), alpha = tonumber(a .. a, 16) / 255 }
  elseif len == 3 then
    return { from = i - 1, to = i + 3, hex = expand3(body) }
  end
  return nil
end

--- `0xff0000`（Go / Rust / C 等でよく書く形）。6 桁ちょうどのときだけ
local function match_0x(line, i)
  if line:sub(i, i + 1):lower() ~= '0x' then return nil end
  if is_word_char(line:sub(i - 1, i - 1)) then return nil end
  local body = line:sub(i + 2, i + 7)
  if not body:match('^%x%x%x%x%x%x$') then return nil end
  if line:sub(i + 8, i + 8):match('^%x$') then return nil end
  return { from = i - 1, to = i + 7, hex = body:lower() }
end

--- `rgb(...)` / `rgba(...)` / `hsl(...)` / `hsla(...)`
local function match_fn(line, i)
  local name = line:match('^(%a+)%(', i)
  if not name then return nil end
  local kind = FN_KIND[name:lower()]
  if not kind then return nil end
  local prev = line:sub(i - 1, i - 1)
  if is_word_char(prev) or prev == '#' then return nil end

  local open = i + #name
  local close = line:find(')', open + 1, true)
  if not close or close - open - 1 > MAX_FN_ARGS then return nil end

  local hex, alpha = parse_fn_args(kind, line:sub(open + 1, close - 1))
  if not hex then return nil end
  return { from = i - 1, to = close, hex = hex, alpha = alpha }
end

--- `red` `rebeccapurple` 等の色名
local function match_name(line, i)
  if is_word_char(line:sub(i - 1, i - 1)) then return nil end
  local word = line:match('^(%a[%a%d]*)', i)
  if not word then return nil end
  if is_word_char(line:sub(i + #word, i + #word)) then return nil end
  local hex = names_table()[word:lower()]
  if not hex then return nil end
  return { from = i - 1, to = i - 1 + #word, hex = hex }
end

--- 1 行からカラーコードを抜き出す
---@param line string
---@param opts { names: boolean }|nil  names=true で CSS 色名も拾う
---@return { from: integer, to: integer, hex: string, alpha: number|nil }[]
--- from / to はバイト単位・0 始まり・to は終端の次（extmark の col / end_col にそのまま渡せる）
function M.parse_line(line, opts)
  local out = {}
  if type(line) ~= 'string' or line == '' or #line > MAX_LINE then return out end
  local names = opts and opts.names or false
  -- 色名を見ないなら、'#' '(' '0' のどれも無い行は確実に空振りなので早期に返す
  if not names and not line:find('[#(0]') then return out end

  local i = 1
  local n = #line
  while i <= n do
    local m = match_hex(line, i)
      or match_0x(line, i)
      or match_fn(line, i)
      or (names and match_name(line, i) or nil)
    if m then
      out[#out + 1] = m
      i = m.to + 1
    else
      i = i + 1
    end
  end
  return out
end

-- ══════════════════════════════════════════════
-- ハイライト
-- ══════════════════════════════════════════════

local hl_cache = {}

--- 背景 hex に対して読みやすい文字色（黒 or 白）を返す
---@param hex string 'rrggbb'
function M.contrast_fg(hex)
  local r = tonumber(hex:sub(1, 2), 16) / 255
  local g = tonumber(hex:sub(3, 4), 16) / 255
  local b = tonumber(hex:sub(5, 6), 16) / 255
  -- 人間の感度に合わせた輝度（nvim-colorizer の色明度判定と同じ係数）
  local luminance = 0.299 * r + 0.587 * g + 0.114 * b
  return luminance > 0.5 and '#000000' or '#ffffff'
end

--- 透明度付きの色を Normal の背景と混ぜて不透明な色にする
---@param hex string 'rrggbb'
---@param alpha number 0-1
---@return string 'rrggbb'
function M.blend(hex, alpha)
  alpha = clamp(alpha, 0, 1)
  local bg = 0x000000
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = 'Normal', link = false })
  if ok and hl and hl.bg then
    bg = hl.bg
  elseif vim.o.background == 'light' then
    bg = 0xffffff
  end
  local br = math.floor(bg / 65536) % 256
  local bgg = math.floor(bg / 256) % 256
  local bb = bg % 256
  local r = tonumber(hex:sub(1, 2), 16) * alpha + br * (1 - alpha)
  local g = tonumber(hex:sub(3, 4), 16) * alpha + bgg * (1 - alpha)
  local b = tonumber(hex:sub(5, 6), 16) * alpha + bb * (1 - alpha)
  return to_hex(r, g, b)
end

--- 色ごとのハイライトグループを作って名前を返す（作成済みなら使い回す）
---@param hex string 'rrggbb'
---@param alpha number|nil
function M.hl_group(hex, alpha)
  if alpha and alpha < 1 then
    hex = M.blend(hex, alpha)
  end
  local name = 'Colorizer_' .. hex
  if not hl_cache[name] then
    api.nvim_set_hl(0, name, { bg = '#' .. hex, fg = M.contrast_fg(hex) })
    hl_cache[name] = true
  end
  return name
end

-- ══════════════════════════════════════════════
-- 描画
-- ══════════════════════════════════════════════

-- バッファごとのパース結果。changedtick が変わったら丸ごと捨てる
local cache = {}

--- そのバッファで色表示をするか。`:ColorizerToggle` で切った場合のみ false
---@param buf integer
function M.is_enabled(buf)
  if not api.nvim_buf_is_valid(buf) then return false end
  local flag = vim.b[buf].colorizer_enabled
  if flag ~= nil then return flag end
  -- 通常の編集バッファのみ（パネル類・ターミナルは対象外）
  return vim.bo[buf].buftype == ''
end

local function use_names(buf)
  return NAME_FILETYPES[vim.bo[buf].filetype] == true
end

--- 行のパース結果をキャッシュ付きで返す
local function line_colors(buf, row, line, names)
  local c = cache[buf]
  local tick = api.nvim_buf_get_changedtick(buf)
  if not c or c.tick ~= tick or c.names ~= names then
    c = { tick = tick, names = names, lines = {} }
    cache[buf] = c
  end
  local hit = c.lines[row]
  if not hit then
    hit = M.parse_line(line, { names = names })
    c.lines[row] = hit
  end
  return hit
end

--- 1 行ぶんの extmark を置く（decoration provider の on_line から呼ばれる）
local function on_line(_, _, buf, row)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line or line == '' then return end
  local names = use_names(buf)
  for _, m in ipairs(line_colors(buf, row, line, names)) do
    -- treesitter や LSP semantic tokens より前に出したいので優先度を高めにする
    pcall(api.nvim_buf_set_extmark, buf, ns, row, m.from, {
      end_col = m.to,
      hl_group = M.hl_group(m.hex, m.alpha),
      ephemeral = true,
      priority = 200,
    })
  end
end

local function redraw(buf)
  pcall(api.nvim__redraw, { buf = buf, valid = false })
end

--- 現在（または指定）バッファの色表示をトグルする
---@param buf integer|nil
---@return boolean 切り替え後の状態
function M.toggle(buf)
  buf = buf or api.nvim_get_current_buf()
  local now = not M.is_enabled(buf)
  vim.b[buf].colorizer_enabled = now
  cache[buf] = nil
  redraw(buf)
  return now
end

function M.setup()
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf, _, _)
      return M.is_enabled(buf)
    end,
    on_line = on_line,
  })

  -- colorscheme を変えると自前のハイライトも消えるので作り直させる
  api.nvim_create_autocmd('ColorScheme', {
    callback = function() hl_cache = {} end,
  })
  api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    callback = function(ev) cache[ev.buf] = nil end,
  })
  -- filetype が決まると色名を拾うかどうかが変わる
  api.nvim_create_autocmd('FileType', {
    callback = function(ev) cache[ev.buf] = nil end,
  })

  api.nvim_create_user_command('ColorizerToggle', function()
    local on = M.toggle()
    vim.notify('カラーコード表示: ' .. (on and 'ON' or 'OFF'), vim.log.levels.INFO)
  end, { desc = 'カラーコードの色表示をトグル（現在バッファ）' })
end

M.setup()

-- テスト用
M._on_line = on_line
M._ns = ns
M._name_filetypes = NAME_FILETYPES

return M
