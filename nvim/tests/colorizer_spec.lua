local T = dofile(TESTS_DIR .. '/helpers.lua')
local colorizer = require('config.colorizer')

--- parse_line の結果を { hex, from, to } の配列に均す（比較しやすくする）
local function parse(line, names)
  local out = {}
  for _, m in ipairs(colorizer.parse_line(line, { names = names })) do
    out[#out + 1] = { hex = m.hex, from = m.from, to = m.to, alpha = m.alpha }
  end
  return out
end

local function hexes(line, names)
  local out = {}
  for _, m in ipairs(parse(line, names)) do out[#out + 1] = m.hex end
  return out
end

--- 浮動小数の比較用
local function round(v, digits)
  local mul = 10 ^ (digits or 2)
  return math.floor(v * mul + 0.5) / mul
end

T.describe('colorizer.parse_line: #hex', function()
  T.it('reads 3 / 6 digit forms', function()
    T.eq(hexes('color: #f00;'), { 'ff0000' })
    T.eq(hexes('color: #ff0000;'), { 'ff0000' })
    T.eq(hexes('#AbCdEf'), { 'abcdef' }, '大文字でも小文字に正規化する')
  end)

  T.it('reads 4 / 8 digit forms with alpha', function()
    local m = parse('#f008')[1]
    T.eq(m.hex, 'ff0000')
    T.eq(round(m.alpha), round(0x88 / 255))

    local m8 = parse('#ff000080')[1]
    T.eq(m8.hex, 'ff0000')
    T.eq(round(m8.alpha), round(0x80 / 255))
  end)

  T.it('reports byte offsets that can be handed to extmarks as-is', function()
    -- from は0始まり、to は終端の次
    local m = parse('  #f00')[1]
    T.eq(m.from, 2)
    T.eq(m.to, 6)
  end)

  T.it('ignores digit counts that are not exactly 3/4/6/8', function()
    T.eq(hexes('#12345'), {}, '5桁は色ではない')
    T.eq(hexes('#1234567'), {}, '7桁を6桁として拾わない')
    T.eq(hexes('#gg0000'), {}, '16進以外は拾わない')
  end)

  T.it('finds more than one color on the same line', function()
    T.eq(hexes('#fff #000'), { 'ffffff', '000000' })
  end)
end)

T.describe('colorizer.parse_line: 0xRRGGBB', function()
  T.it('reads the 0x form used in Go / Rust / C', function()
    T.eq(hexes('local red = 0xff0000'), { 'ff0000' })
    T.eq(hexes('0XFF0000'), { 'ff0000' }, '0X でも読む')
  end)

  T.it('does not read it in the middle of an identifier or a longer literal', function()
    T.eq(hexes('a0xff0000'), {}, '識別子の途中は色ではない')
    T.eq(hexes('0xff00001'), {}, '7桁以上は色ではない')
  end)
end)

T.describe('colorizer.parse_line: rgb / hsl functions', function()
  T.it('reads rgb() and rgba()', function()
    T.eq(hexes('rgb(255, 0, 0)'), { 'ff0000' })
    T.eq(hexes('rgb(100%, 0%, 0%)'), { 'ff0000' }, '% 指定も読む')
    local m = parse('rgba(255, 0, 0, 0.5)')[1]
    T.eq(m.hex, 'ff0000')
    T.eq(round(m.alpha), 0.5)
  end)

  T.it('reads the space / slash separated CSS Color 4 form', function()
    local m = parse('rgb(255 0 0 / 50%)')[1]
    T.eq(m.hex, 'ff0000')
    T.eq(round(m.alpha), 0.5)
  end)

  T.it('reads hsl() and hsla()', function()
    T.eq(hexes('hsl(0, 100%, 50%)'), { 'ff0000' })
    T.eq(hexes('hsl(120, 100%, 50%)'), { '00ff00' })
    T.eq(hexes('hsl(0.5turn, 100%, 50%)'), { '00ffff' }, 'turn 単位も読む')
  end)

  T.it('rejects malformed argument lists', function()
    T.eq(hexes('rgb(255, 0)'), {}, '成分が足りない')
    T.eq(hexes('rgb(255, 0, 0, 0, 0)'), {}, '成分が多い')
    T.eq(hexes('rgb(255, 0, 0px)'), {}, '知らない単位')
    T.eq(hexes('myrgb(255, 0, 0)'), {}, '識別子の途中から始まるものは拾わない')
  end)
end)

T.describe('colorizer.parse_line: CSS color names', function()
  T.it('reads names only when asked (names=true)', function()
    T.eq(hexes('color: red;', false), {}, 'CSS系以外のfiletypeでは変数名と紛らわしいので拾わない')
    T.eq(hexes('color: red;', true), { 'ff0000' })
  end)

  T.it('does not read a name that is part of a longer identifier', function()
    T.eq(hexes('--my-red: 1;', true), {}, 'CSS変数の一部は色名ではない')
    T.eq(hexes('reddish', true), {})
    T.eq(hexes('infrared', true), {})
  end)

  T.it('enables names for CSS-ish filetypes only', function()
    local ft = colorizer._name_filetypes
    T.ok(ft.css and ft.html and ft.scss, 'CSS/HTML系は色名を拾う')
    T.ok(not ft.lua and not ft.go, 'それ以外は拾わない')
  end)
end)

T.describe('colorizer.parse_line: guards', function()
  T.it('gives up on very long lines', function()
    local long = string.rep('x', 3000) .. '#ff0000'
    T.eq(hexes(long), {}, 'minified CSS などは諦める')
  end)

  T.it('returns an empty list for empty or non-string input', function()
    T.eq(colorizer.parse_line(''), {})
    T.eq(colorizer.parse_line(nil), {})
  end)

  T.it('short-circuits lines that cannot contain a color', function()
    T.eq(hexes('local foo = bar'), {}, "'#' '(' '0' が無ければ確実に空振り")
  end)
end)

T.describe('colorizer color math', function()
  T.it('converts hsl to rgb', function()
    local r, g, b = colorizer.hsl_to_rgb(0, 1, 0.5)
    T.eq({ math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5) }, { 255, 0, 0 })

    local r2, g2, b2 = colorizer.hsl_to_rgb(0, 0, 1)
    T.eq({ math.floor(r2 + 0.5), math.floor(g2 + 0.5), math.floor(b2 + 0.5) }, { 255, 255, 255 },
      '彩度0は無彩色')
  end)

  T.it('picks a readable foreground for the given background', function()
    T.eq(colorizer.contrast_fg('ffffff'), '#000000')
    T.eq(colorizer.contrast_fg('000000'), '#ffffff')
    T.eq(colorizer.contrast_fg('ffff00'), '#000000', '黄色は明るいので黒文字')
    T.eq(colorizer.contrast_fg('0000ff'), '#ffffff', '青は暗いので白文字')
  end)

  T.it('blends a translucent color toward the Normal background', function()
    vim.api.nvim_set_hl(0, 'Normal', { bg = '#000000' })
    T.eq(colorizer.blend('ff0000', 1), 'ff0000', 'alpha=1 はそのまま')
    T.eq(colorizer.blend('ff0000', 0), '000000', 'alpha=0 は背景そのもの')
    T.eq(colorizer.blend('ff0000', 0.5), '800000', '半分だけ背景と混ざる')
  end)
end)

T.describe('colorizer highlight groups', function()
  T.it('creates one highlight group per color and reuses it', function()
    local name = colorizer.hl_group('ff0000')
    T.eq(name, 'Colorizer_ff0000')
    local hl = vim.api.nvim_get_hl(0, { name = name })
    T.eq(hl.bg, 0xff0000)
    T.eq(colorizer.hl_group('ff0000'), name, '2回目も同じ名前を返す')
  end)

  T.it('folds alpha into the group name so blended colors do not collide', function()
    vim.api.nvim_set_hl(0, 'Normal', { bg = '#000000' })
    T.eq(colorizer.hl_group('ff0000', 0.5), 'Colorizer_800000')
  end)
end)

T.describe('colorizer enable / toggle', function()
  T.it('is on for a normal buffer and off for panels and terminals', function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].swapfile = false
    T.ok(colorizer.is_enabled(buf), '通常の編集バッファは対象')

    local panel = vim.api.nvim_create_buf(false, true)
    vim.bo[panel].buftype = 'nofile'
    T.ok(not colorizer.is_enabled(panel), 'パネル類は対象外')
  end)

  T.it('toggles per buffer and remembers the choice', function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].swapfile = false
    T.eq(colorizer.toggle(buf), false, '1回目で OFF')
    T.ok(not colorizer.is_enabled(buf))
    T.eq(colorizer.toggle(buf), true, '2回目で ON')
    T.ok(colorizer.is_enabled(buf))
  end)

  T.it('registers the :ColorizerToggle command', function()
    T.ok(vim.fn.exists(':ColorizerToggle') == 2, ':ColorizerToggle が定義されている')
  end)
end)

T.summary()
