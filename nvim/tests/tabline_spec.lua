local T = dofile(TESTS_DIR .. '/helpers.lua')
require('config.tabline')

T.describe('tabline', function()
  T.it('renders each listed buffer with its extension icon, and marks the modified one', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/main.lua', { 'return 1' })
    T.write_file(dir .. '/readme.md', { '# hi' })

    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/main.lua'))
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/readme.md'))
    vim.bo.modified = true

    local s = _G._tabline()
    T.contains(s, 'main.lua')
    T.contains(s, 'readme.md')
    T.contains(s, '●', 'modified buffer should show the dot marker')
    T.contains(s, 'TabLineModSel', 'the current+modified buffer should use the ModSel highlight')
    T.contains(s, vim.fn.nr2char(0xe620), 'main.lua should use the lua icon') -- .lua icon codepoint

    T.rmrf(dir)
  end)

  T.it('terminal buffers are excluded from the tabline', function()
    -- buftype='terminal'は直接代入できないため、nvim_open_termで本物のterminal
    -- バッファを作る
    local tbuf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_open_term(tbuf, {})
    local s = _G._tabline()
    -- tabline側は各バッファを"%<bufnr>@v:lua._bufline_click@"というクリック領域として
    -- 出力するので、そのbufnr宛のクリック領域が無い=一覧に含まれていないことの確認になる
    T.ok(not s:find('%' .. tbuf .. '@v:lua._bufline_click@', 1, true),
      'a terminal buffer must not get a tabline entry')
    vim.api.nvim_buf_delete(tbuf, { force = true })
  end)
end)

T.describe('tabline sidebar padding', function()
  T.it('pads the tabline so tabs do not sit above a left-side explorer', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/main.lua', { 'return 1' })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/main.lua'))

    local explorer = require('config.explorer')
    explorer.open(false) -- 既定は左
    vim.wait(60)
    local padded = _G._tabline()
    T.ok(padded:find('^%%#TabLineFill#   ', 1) ~= nil, 'left explorer → tabline starts with fill padding')

    explorer.close()
    vim.wait(30)
    local plain = _G._tabline()
    T.ok(plain:find('^%%#TabLineFill#   ', 1) == nil, 'no padding once explorer is closed')

    T.rmrf(dir)
  end)
end)

--- タブライン文字列の実際の表示幅（%#hl# / クリック領域 / %X を除いた分）。
local function display_width(s)
  local text = s
    :gsub('%%#[^#]*#', '')
    :gsub('%%%d+@[^@]*@', '')
    :gsub('%%X', '')
    :gsub('%%%%', '%%')
  return vim.fn.strdisplaywidth(text)
end

local function make_buffers(dir, n)
  vim.fn.mkdir(dir, 'p')
  local names = {}
  for i = 1, n do
    local name = string.format('%s/file_%02d.lua', dir, i)
    T.write_file(name, { 'return ' .. i })
    vim.cmd('edit ' .. vim.fn.fnameescape(name))
    names[i] = vim.fn.fnamemodify(name, ':t')
  end
  return names
end

T.describe('tabline overflow', function()
  T.it('never draws wider than the editor columns', function()
    local dir = vim.fn.tempname()
    make_buffers(dir, 30)

    T.ok(display_width(_G._tabline()) <= vim.o.columns, 'タブラインが画面幅を超えないこと')

    T.rmrf(dir)
  end)

  T.it('scrolls so the current buffer stays visible', function()
    local dir = vim.fn.tempname()
    local names = make_buffers(dir, 30)

    -- 最後に開いたバッファが現在バッファ。右端の外にあるのでスクロールされる
    local s = _G._tabline()
    T.contains(s, names[#names], '現在のタブが見えること')
    T.contains(s, '‹', '左に隠れたタブがあることを示すこと')

    -- 先頭のファイルへ戻ると、そのタブが見える位置まで巻き戻る
    vim.cmd('buffer ' .. vim.fn.fnameescape(dir .. '/file_01.lua'))
    local back = _G._tabline()
    T.contains(back, names[1], '戻り先のタブが見えること')
    T.ok(not back:find(names[#names], 1, true), '遠いタブは見えなくなること')
    T.contains(back, '›', '右に隠れたタブがあることを示すこと')

    T.rmrf(dir)
  end)

  T.it('reserves the columns of a right-side panel', function()
    local dir = vim.fn.tempname()
    make_buffers(dir, 30)
    local full = display_width(_G._tabline())

    vim.cmd('botright 30vsplit')
    local panel = vim.api.nvim_get_current_win()
    require('config.util.win_util').mark_sidebar(panel, vim.api.nvim_win_get_buf(panel))
    local narrowed = display_width(_G._tabline())
    vim.api.nvim_win_close(panel, true)

    T.ok(narrowed < full, '右パネルの分だけ狭くなること: ' .. narrowed .. ' < ' .. full)
    T.ok(narrowed <= vim.o.columns - 31, '予約した桁にタブを描かないこと')

    T.rmrf(dir)
  end)
end)

T.describe('tabline drag reorder', function()
  local tabline = require('config.tabline')
  local cycle = require('config.util.buf_cycle')

  --- 並びの index 番目のタブの中央の画面桁。
  local function center_of(index)
    for _, item in ipairs(tabline._layout()) do
      if item.index == index then return math.floor((item.x0 + item.x1) / 2) end
    end
  end

  T.it('moves the grabbed tab to where the mouse goes', function()
    local dir = vim.fn.tempname()
    make_buffers(dir, 3)
    _G._tabline()

    local before = vim.deepcopy(cycle.list())
    T.eq(#before >= 3, true)

    local from, to = #before - 2, #before -- 後ろから 3 番目を末尾へ
    local moved = before[from]

    tabline.drag_end()
    tabline.drag(center_of(from))         -- 掴む
    tabline.drag(center_of(to))           -- 動かす
    tabline.drag_end()                    -- 離す

    local after = cycle.list()
    T.eq(after[to], moved, '掴んだタブが移動先にいること')
    T.eq(#after, #before, 'タブの数は変わらないこと')

    T.rmrf(dir)
  end)

  T.it('ignores a drag that does not land on a tab', function()
    local dir = vim.fn.tempname()
    make_buffers(dir, 3)
    _G._tabline()

    local before = vim.deepcopy(cycle.list())
    tabline.drag_end()
    T.eq(tabline.drag(vim.o.columns - 1), false, 'タブが無い桁では何もしないこと')
    T.eq(cycle.list(), before, '並びが変わらないこと')

    T.rmrf(dir)
  end)

  T.it('keeps the cycle order in sync with the tab order', function()
    local dir = vim.fn.tempname()
    make_buffers(dir, 3)
    _G._tabline()

    local bufs = cycle.list()
    local last = bufs[#bufs]
    cycle.move(last, -1)

    local after = cycle.list()
    T.eq(after[#after - 1], last, '移動後の並びが list に反映されること')
    T.eq(_G._tabline():find('%%' .. last .. '@') ~= nil, true, 'タブラインにも残ること')

    T.rmrf(dir)
  end)
end)

T.summary()
