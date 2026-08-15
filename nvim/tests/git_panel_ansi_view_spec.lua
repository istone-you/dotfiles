-- ansi_view.lua（ANSI付きテキストを通常バッファ＋extmarkへ忠実に写す変換器）の単体テスト。
-- dockerパネルのログ表示など、外部コマンドが吐いた色をそのまま見せる経路で使う。

local T = dofile(TESTS_DIR .. '/helpers.lua')
local AV = require('config.git_panel.ansi_view')

local ESC = '\27'

local function render(ansi)
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace('av_test_' .. tostring(buf))
  AV.render(buf, ns, ansi)
  return buf, ns
end

-- グループ名→実際のfg/bg(数値)を引く
local function hl_of(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

T.describe('panel ansi_view (ANSI -> normal buffer)', function()
  T.it('strips escape codes, leaving only the visible text', function()
    local buf = render(ESC .. '[38;2;255;0;0mhello' .. ESC .. '[0m world')
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], 'hello world')
  end)

  T.it('maps a truecolor SGR to an extmark highlight with that exact color', function()
    local buf, ns = render(ESC .. '[38;2;255;0;0mRED' .. ESC .. '[0m')
    local ms = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local found = false
    for _, m in ipairs(ms) do
      local d = m[4]
      if d.hl_group then
        local h = hl_of(d.hl_group)
        if h.fg == tonumber('ff0000', 16) then found = true end
      end
    end
    T.ok(found, 'a highlight with fg #ff0000 should be applied over "RED"')
  end)

  T.it('maps a 256-color SGR (38;5;n) via the xterm cube', function()
    -- 196 = 6x6x6 cube の (5,0,0) = #ff0000
    local buf, ns = render(ESC .. '[38;5;196mX' .. ESC .. '[0m')
    local ms = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local ok = false
    for _, m in ipairs(ms) do
      local h = m[4].hl_group and hl_of(m[4].hl_group)
      if h and h.fg == tonumber('ff0000', 16) then ok = true end
    end
    T.ok(ok, '38;5;196 should resolve to #ff0000')
  end)

  T.it('EL (ESC[K) after a background paints the WHOLE line (line-level block background)', function()
    -- 背景赤 + 文字 + EL → 行全体を端まで塗る（line_hl_group）。文字の後ろだけでなく行単位。
    local buf, ns = render(ESC .. '[48;2;63;0;1m-code' .. ESC .. '[0K' .. ESC .. '[0m')
    local ms = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local has_line_bg = false
    for _, m in ipairs(ms) do
      local d = m[4]
      if d.line_hl_group then
        local h = hl_of(d.line_hl_group)
        if h.bg == tonumber('3f0001', 16) then has_line_bg = true end
      end
    end
    T.ok(has_line_bg, 'EL should set line_hl_group with the current background (#3f0001) = full-line band')
  end)

end)

T.summary()
