local T = dofile(TESTS_DIR .. '/helpers.lua')
local scrollbar = require('config.scrollbar')

local function new_buf(lines)
  vim.cmd('only')
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf, vim.api.nvim_get_current_win()
end

local function scrollbar_win_for(win)
  return scrollbar._scrollbar_wins[win]
end

local function scrollbar_lines(win)
  local sb = scrollbar_win_for(win)
  if not sb or not vim.api.nvim_win_is_valid(sb) then return {} end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sb), 0, -1, false)
end

--- スクロールバー窓の row 行目に付いているハイライト名。
local function hl_at(win, row)
  local sb = scrollbar_win_for(win)
  if not sb or not vim.api.nvim_win_is_valid(sb) then return nil end
  local buf = vim.api.nvim_win_get_buf(sb)
  local marks = vim.api.nvim_buf_get_extmarks(buf, scrollbar._namespace, { row, 0 }, { row, -1 }, { details = true })
  local first = marks[1]
  return first and first[4] and first[4].hl_group or nil
end

T.describe('scrollbar', function()
  T.it('renders one stable floating scrollbar column for the source window', function()
    local lines = {}
    for i = 1, 200 do lines[i] = 'line ' .. i end
    local _, win = new_buf(lines)
    vim.cmd('resize 10')

    scrollbar.render(win)
    local sb = scrollbar_win_for(win)
    T.ok(sb ~= nil and vim.api.nvim_win_is_valid(sb), 'scrollbar float should exist')
    local cfg = vim.api.nvim_win_get_config(sb)
    T.eq(cfg.width, 1)
    T.eq(cfg.height, vim.api.nvim_win_get_height(win))
    T.eq(cfg.zindex, 60)
    T.eq(#scrollbar_lines(win), vim.api.nvim_win_get_height(win))
  end)

  T.it('blends the float so the text underneath stays visible', function()
    local lines = {}
    for i = 1, 200 do lines[i] = 'line ' .. i end
    local _, win = new_buf(lines)
    vim.cmd('resize 10')

    scrollbar.render(win)
    local sb = scrollbar_win_for(win)
    T.ok(vim.wo[sb].winblend > 0, 'winblend が 0 だとハイライトの blend が効かない')
    T.contains(vim.wo[sb].winhighlight, 'ScrollbarTrack')
    T.eq(vim.api.nvim_get_hl(0, { name = 'ScrollbarTrack' }).blend, 100, 'トラックは完全透過')
    local handle = vim.api.nvim_get_hl(0, { name = 'ScrollbarHandle' })
    T.ok(handle.blend > 0 and handle.blend < 100, 'ハンドルは半透過')
  end)

  T.it('keeps the scrollbar inside the editor height at the bottom', function()
    local lines = {}
    for i = 1, 200 do lines[i] = 'line ' .. i end
    local _, win = new_buf(lines)
    vim.cmd('resize 10')
    vim.api.nvim_win_set_cursor(win, { 200, 0 })
    vim.cmd('normal! zb')

    scrollbar.render(win)
    local cfg = vim.api.nvim_win_get_config(scrollbar_win_for(win))
    T.eq(cfg.height, vim.api.nvim_win_get_height(win))
    T.eq(#scrollbar_lines(win), vim.api.nvim_win_get_height(win))
  end)

  T.it('marks every row as either track or handle', function()
    local lines = {}
    for i = 1, 200 do lines[i] = 'line ' .. i end
    local _, win = new_buf(lines)
    vim.cmd('resize 10')

    scrollbar.render(win)
    local seen = {}
    for row = 0, vim.api.nvim_win_get_height(win) - 1 do
      seen[hl_at(win, row) or '?'] = true
    end
    T.ok(seen.ScrollbarTrack, 'トラックの行があること')
    T.ok(seen.ScrollbarHandle, 'ハンドルの行があること')
  end)

  T.it('renders LSP diagnostics, git diff signs, and search hits with nvim-scrollbar glyphs', function()
    local lines = {}
    for i = 1, 100 do lines[i] = 'line ' .. i end
    lines[75] = 'needle'
    local buf, win = new_buf(lines)
    vim.cmd('resize 10')

    local diag_ns = vim.api.nvim_create_namespace('scrollbar_test_diagnostics')
    vim.diagnostic.set(diag_ns, buf, {
      { lnum = 49, col = 0, severity = vim.diagnostic.severity.ERROR, message = 'boom' },
    })

    local git_ns = vim.api.nvim_create_namespace('git_gutter')
    vim.api.nvim_buf_set_extmark(buf, git_ns, 20, 0, {
      sign_text = '┃',
      sign_hl_group = 'GitGutterChange',
    })
    vim.api.nvim_buf_set_extmark(buf, git_ns, 90, 0, {
      sign_text = '▁',
      sign_hl_group = 'GitGutterDelete',
    })

    vim.o.hlsearch = true
    vim.fn.setreg('/', 'needle')

    scrollbar.render(win)
    local text = table.concat(scrollbar_lines(win), '')
    T.contains(text, '-')
    T.contains(text, '┆')
    T.contains(text, '▁')
    vim.diagnostic.reset(diag_ns, buf)
  end)

  T.it('does not render cursor marks', function()
    local lines = {}
    for i = 1, 100 do lines[i] = 'line ' .. i end
    local _, win = new_buf(lines)
    vim.cmd('resize 10')
    vim.api.nvim_win_set_cursor(win, { 50, 0 })

    scrollbar.render(win)
    T.ok(not table.concat(scrollbar_lines(win), ''):find('•', 1, true), 'cursor marker should be disabled')
  end)

  T.it('does not override normal mouse clicks', function()
    T.ok(vim.fn.maparg('<LeftMouse>', 'n') == '', 'normal <LeftMouse> should remain untouched')
    T.ok(vim.fn.maparg('<LeftDrag>', 'n') == '', 'normal <LeftDrag> should remain untouched')
  end)
end)

T.summary()
