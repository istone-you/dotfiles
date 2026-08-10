local T = dofile(TESTS_DIR .. '/helpers.lua')
local picker = require('config.util.picker')

local function fmt(item)
  return { tag = item.tag or '', text = item.text or '', right = item.right or '' }
end

local function lines()
  return vim.api.nvim_buf_get_lines(picker.state.results_buf, 0, -1, false)
end

T.describe('util/picker.lua: numbered selection', function()
  T.it('index_label maps 1..9 then a..z, nil beyond 35', function()
    T.eq(picker.index_label(1), '1')
    T.eq(picker.index_label(9), '9')
    T.eq(picker.index_label(10), 'a')
    T.eq(picker.index_label(11), 'b')
    T.eq(picker.index_label(35), 'z')
    T.eq(picker.index_label(36), nil)
  end)

  T.it('labels rows past 9 with letters (a, b, ...)', function()
    local items = {}
    for i = 1, 12 do items[i] = { text = 'item' .. i } end
    picker.open({ title = ' t ', numbered = true, items = items, format = fmt, on_select = function() end })
    local ls = lines()
    T.eq(ls[9]:sub(1, 2), '9 ')
    T.eq(ls[10]:sub(1, 2), 'a ')
    T.eq(ls[12]:sub(1, 2), 'c ')
    picker.close()
  end)

  T.it('select_index picks a letter-labeled row', function()
    local chosen
    local items = {}
    for i = 1, 12 do items[i] = { text = 'item' .. i, id = i } end
    picker.open({ title = ' t ', numbered = true, items = items, format = fmt, on_select = function(it) chosen = it end })
    picker.select_index(11) -- ラベル 'b'
    T.eq(chosen.id, 11)
  end)

  T.it('shows 1..9 number prefixes when numbered', function()
    picker.open({
      title = ' t ',
      numbered = true,
      items = { { text = 'a' }, { text = 'b' }, { text = 'c' } },
      format = fmt,
      on_select = function() end,
    })
    local ls = lines()
    T.eq(ls[1]:sub(1, 2), '1 ')
    T.eq(ls[2]:sub(1, 2), '2 ')
    T.eq(ls[3]:sub(1, 2), '3 ')
    picker.close()
  end)

  T.it('does not add number prefixes when not numbered', function()
    picker.open({
      title = ' t ',
      items = { { text = 'alpha' } },
      format = fmt,
      on_select = function() end,
    })
    -- 先頭が数字+空白になっていない（tag 空なので text 先頭 'a' が来る）
    T.ok(lines()[1]:sub(1, 2) ~= '1 ', 'no number gutter when numbered is off')
    picker.close()
  end)

  T.it('select_index confirms the numbered item', function()
    local chosen
    picker.open({
      title = ' t ',
      numbered = true,
      items = { { text = 'a', id = 1 }, { text = 'b', id = 2 }, { text = 'c', id = 3 } },
      format = fmt,
      on_select = function(it) chosen = it end,
    })
    picker.select_index(2)
    T.ok(not picker.is_open(), 'picker closes after selecting')
    T.eq(chosen.id, 2, 'selects the 2nd item by number')
  end)

  T.it('select_index ignores out-of-range numbers', function()
    local chosen
    picker.open({
      title = ' t ',
      numbered = true,
      items = { { text = 'a' } },
      format = fmt,
      on_select = function(it) chosen = it end,
    })
    picker.select_index(5) -- 範囲外
    T.eq(chosen, nil, 'nothing selected for out-of-range')
    T.ok(picker.is_open(), 'picker stays open')
    picker.close()
  end)

  T.it('filter=false opens without a prompt window and selects by label', function()
    local chosen
    picker.open({
      title = ' t ',
      numbered = true,
      filter = false,
      items = { { text = 'a', id = 1 }, { text = 'b', id = 2 }, { text = 'c', id = 3 } },
      format = fmt,
      on_select = function(it) chosen = it end,
    })
    T.ok(picker.is_open(), 'picker is open')
    T.eq(picker.state.filtering, false, 'filtering disabled')
    T.eq(picker.state.prompt_buf, nil, 'no prompt buffer in no-filter mode')
    -- リスト窓自体がフォーカスされている
    T.eq(vim.api.nvim_get_current_win(), picker.state.results_win)
    picker.select_index(3)
    T.eq(chosen.id, 3)
  end)

  -- close() が prompt_win=nil の穴で ipairs 早期終了し、リスト窓を閉じ損ねる回帰を防ぐ。
  -- is_open() は state を nil にするだけなので窓の実体で確認する。
  T.it('filter=false: close() actually removes the list window', function()
    picker.open({
      title = ' t ',
      numbered = true,
      filter = false,
      items = { { text = 'a' }, { text = 'b' } },
      format = fmt,
      on_select = function() end,
    })
    local win = picker.state.results_win
    T.ok(vim.api.nvim_win_is_valid(win), 'window is open')
    picker.close()
    T.ok(not vim.api.nvim_win_is_valid(win), 'window is really closed, not just is_open()=false')
  end)

  T.it('numbering follows the filtered result, not the original list', function()
    picker.open({
      title = ' t ',
      numbered = true,
      items = { { text = 'apple' }, { text = 'banana' }, { text = 'cherry' } },
      format = fmt,
      on_select = function() end,
    })
    picker.filter('a') -- apple / banana が残る（cherry は落ちる）
    local ls = lines()
    T.eq(#picker.state.filtered, 2)
    T.eq(ls[1]:sub(1, 2), '1 ')
    T.eq(ls[2]:sub(1, 2), '2 ')
    picker.close()
  end)
end)

T.summary()
