local T = dofile(TESTS_DIR .. '/helpers.lua')
local todo = require('config.todo_tree')

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function rg_match(path, line, col, text, tag)
  return vim.json.encode({
    type = 'match',
    data = {
      path = { text = path },
      lines = { text = text .. '\n' },
      line_number = line,
      submatches = {
        { match = { text = tag }, start = col, ['end'] = col + #tag },
      },
    },
  })
end

T.describe('todo_tree.parse_rg_json', function()
  T.it('ripgrep json から TODO 項目をファイル名順・行順に取り出す', function()
    local root = vim.fn.getcwd()
    local text = table.concat({
      rg_match(root .. '/b.lua', 3, 5, '-- TODO: b item', 'TODO'),
      rg_match(root .. '/a.lua', 1, 3, '// FIXME: a item', 'FIXME'),
      vim.json.encode({ type = 'summary', data = {} }),
    }, '\n')
    local items = todo.parse_rg_json(text, root)

    T.eq(#items, 2)
    T.eq(items[1].path, 'a.lua')
    T.eq(items[1].tag, 'FIXME')
    T.eq(items[1].lnum, 1)
    T.eq(items[1].col, 3)
    T.eq(items[1].after, 'a item')
    T.eq(items[2].path, 'b.lua')
  end)
end)

T.describe('todo_tree.build', function()
  local items = {
    { path = 'a.lua', abs_path = '/tmp/a.lua', lnum = 1, col = 3, tag = 'TODO', text = '// TODO: one', after = 'one' },
    { path = 'a.lua', abs_path = '/tmp/a.lua', lnum = 4, col = 3, tag = 'FIXME', text = '// FIXME: two', after = 'two' },
    { path = 'b.md', abs_path = '/tmp/b.md', lnum = 2, col = 6, tag = 'BUG', text = '- BUG: three', after = 'three' },
  }

  T.it('tree 表示はデフォルトでファイル単位に折り畳む', function()
    local lines, meta = todo.build(items)
    T.contains(lines[1], 'TODO Tree')
    T.contains(lines[2], 'TODO:1')
    T.contains(lines[4], 'a.lua')
    T.contains(lines[4], '(2)')
    T.contains(lines[5], 'b.md')
    T.contains(lines[5], '(1)')
    T.eq(meta[4].kind, 'group')
    T.eq(meta[4].key, 'file:a.lua')
    T.ok(not table.concat(lines, '\n'):find('one', 1, true), 'collapsed file should hide child TODO rows')
  end)

  T.it('同じ親ディレクトリ配下のファイルをディレクトリノードにまとめる', function()
    local nested = {
      { path = 'src/a.lua', abs_path = '/tmp/src/a.lua', lnum = 1, col = 3, tag = 'TODO', text = '-- TODO: one', after = 'one' },
      { path = 'src/nested/b.lua', abs_path = '/tmp/src/nested/b.lua', lnum = 2, col = 3, tag = 'BUG', text = '-- BUG: two', after = 'two' },
    }
    local lines, meta = todo.build(nested)
    T.contains(lines[4], 'src')
    T.contains(lines[4], '(2)')
    T.eq(meta[4].key, 'dir:src')
    T.ok(not table.concat(lines, '\n'):find('a.lua', 1, true), 'collapsed directory should hide child files')
  end)

  T.it('表示上の子が1つだけ続く場合は1行に圧縮する', function()
    local nested = {
      { path = 'a/b/c/deep.lua', abs_path = '/tmp/a/b/c/deep.lua', lnum = 1, col = 3, tag = 'TODO', text = '-- TODO: deep', after = 'deep' },
      { path = 'a/b/c/deep2.lua', abs_path = '/tmp/a/b/c/deep2.lua', lnum = 2, col = 3, tag = 'TODO', text = '-- TODO: deep2', after = 'deep2' },
      { path = 'onlyfile/single.lua', abs_path = '/tmp/onlyfile/single.lua', lnum = 2, col = 3, tag = 'BUG', text = '-- BUG: single', after = 'single' },
    }
    local lines, meta = todo.build(nested)
    T.contains(lines[4], 'a/b/c')
    T.eq(meta[4].key, 'dir:a/b/c')
    T.contains(lines[5], 'onlyfile/single.lua')
    T.eq(meta[5].key, 'file:onlyfile/single.lua')
  end)

  -- ディスク上に兄弟が何個あろうと、TODO ツリーに載っている子だけで数える
  T.it('子がファイル1つだけのディレクトリもファイル名まで繋げる', function()
    local nested = {
      { path = 'a/b/c/deep.lua', abs_path = '/tmp/a/b/c/deep.lua', lnum = 1, col = 3, tag = 'TODO', text = '-- TODO: deep', after = 'deep' },
    }
    local lines, meta = todo.build(nested)
    T.contains(lines[4], 'a/b/c/deep.lua')
    T.eq(meta[4].key, 'file:a/b/c/deep.lua')
    T.eq(lines[5], nil)
  end)

  T.it('展開時は親子ノードの矢印も階層に応じてインデントする', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/src/nested', 'p')
    T.write_file(dir .. '/src/a.lua', { '-- TODO: one' })
    -- nested の子を2つにして圧縮させず、3階層のインデントを見る
    T.write_file(dir .. '/src/nested/b.lua', { '-- BUG: two' })
    T.write_file(dir .. '/src/nested/c.lua', { '-- BUG: three' })
    vim.fn.chdir(dir)
    todo.open()
    todo.expand_all()
    local pbuf = vim.api.nvim_win_get_buf(todo.win_id())
    local lines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
    T.ok(lines[4]:match('^ src'), 'root dir arrow should be at column 1')
    T.ok(lines[5]:match('^   nested'), 'child dir arrow should be indented')
    T.ok(lines[6]:match('^     b%.lua'), 'grandchild file arrow should be indented')
    T.ok(lines[10]:match('^   a%.lua'), 'child file arrow should be indented')
    todo.close()
    T.rmrf(dir)
  end)

  T.it('項目がなければ空表示を出す', function()
    local lines, meta = todo.build({})
    T.contains(lines[4], 'TODO はありません')
    T.eq(meta, {})
  end)
end)

T.describe('todo_tree.scan', function()
  T.it('workspace を rg で検索し、TODO/FIXME/BUG を拾う', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', {
      'local x = 1',
      '-- TODO: write tests',
      '-- FIXME: fix edge',
    })
    T.write_file(dir .. '/node_modules/ignored.js', {
      '// TODO: ignored',
    })

    local items, err = todo.scan(dir)
    T.eq(err, nil)
    T.eq(#items, 2)
    T.eq(items[1].path, 'a.lua')
    T.eq(items[1].tag, 'TODO')
    T.eq(items[2].tag, 'FIXME')

    T.rmrf(dir)
  end)

  T.it('コメントではないタグや文字列内のコメント風テキストは拾わない', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', {
      "local TAG_HL = {",
      "  TODO = 'TodoTreeTodo',",
      "  FIXME = 'TodoTreeFixme',",
      "}",
      "local s = '// TODO: inside string'",
      "local t = '# FIXME: also string'",
      "local x = 1 -- TODO: inline comment",
      "-- BUG: real comment",
    })

    local items, err = todo.scan(dir)
    T.eq(err, nil)
    T.eq(#items, 2)
    T.eq(items[1].tag, 'TODO')
    T.eq(items[1].after, 'inline comment')
    T.eq(items[2].tag, 'BUG')
    T.eq(items[2].after, 'real comment')

    T.rmrf(dir)
  end)
end)

T.describe('todo_tree panel', function()
  T.it('Space T で右サイドバーとして開閉し、nofile のサイドバー扱いになる', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', { '-- TODO: panel item' })
    vim.fn.chdir(dir)

    feed('<leader>T')
    vim.wait(120)
    T.eq(todo.is_open(), true)
    local pwin = todo.win_id()
    local pbuf = vim.api.nvim_win_get_buf(pwin)
    T.eq(vim.bo[pbuf].buftype, 'nofile')
    T.eq(vim.bo[pbuf].filetype, 'todo-tree')
    T.eq(vim.api.nvim_win_get_width(pwin), todo.PANEL_WIDTH)
    T.eq(require('config.util.win_util').is_editor(pwin), false)

    vim.api.nvim_set_current_win(pwin)
    feed('q')
    vim.wait(80)
    T.eq(todo.is_open(), false)
    T.rmrf(dir)
  end)

  T.it('f でチェックボックス popup を開き、表示するタグ種別を複数選択する', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', {
      '-- TODO: only todo item',
      '-- FIXME: only fixme item',
      '-- BUG: only bug item',
    })
    vim.fn.chdir(dir)

    todo.open()
    local pwin = todo.win_id()
    local pbuf = vim.api.nvim_win_get_buf(pwin)
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), '\n')
    end

    T.contains(text(), 'a.lua')

    vim.api.nvim_set_current_win(pwin)
    feed('f')
    vim.wait(80)
    local popup
    for _, w in ipairs(T.floating_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == 'todo-tree-filter' then popup = w end
    end
    T.ok(popup ~= nil, 'tag filter popup should open')
    vim.api.nvim_set_current_win(popup)
    feed('c')
    vim.wait(20)
    vim.api.nvim_win_set_cursor(popup, { 3, 0 }) -- 1: header, 2: TODO, 3: FIXME
    feed(' <CR>')
    vim.wait(120)
    todo.expand_all()

    T.contains(text(), 'tags:FIXME')
    T.contains(text(), 'only fixme item')
    T.ok(not text():find('only todo item', 1, true), 'TODO should be hidden while FIXME filter is active')

    -- 後続テストへ状態を漏らさない
    todo.select_tag_filter()
    vim.wait(80)
    popup = nil
    for _, w in ipairs(T.floating_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == 'todo-tree-filter' then popup = w end
    end
    T.ok(popup ~= nil, 'tag filter popup should reopen')
    vim.api.nvim_set_current_win(popup)
    feed('a<CR>')
    vim.wait(120)
    todo.close()
    T.rmrf(dir)
  end)

  T.it('Enter で TODO の位置へジャンプする', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/a.lua'
    T.write_file(path, {
      'local x = 1',
      '-- TODO: jump here',
    })
    vim.fn.chdir(dir)
    vim.cmd.edit(path)

    todo.open()
    local pwin = todo.win_id()
    vim.api.nvim_set_current_win(pwin)
    todo.toggle_node(true)
    vim.api.nvim_win_set_cursor(pwin, { 5, 0 })
    todo.jump()

    T.eq(vim.loop.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.loop.fs_realpath(path))
    T.eq(vim.api.nvim_win_get_cursor(0), { 2, 3 })

    todo.close()
    T.rmrf(dir)
  end)
end)

T.describe('todo_tree navigation keymaps', function()
  T.it(']t / [t で現在ファイル内の TODO を前後移動する', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/a.lua'
    T.write_file(path, {
      '-- TODO: first',
      'local x = 1',
      '-- FIXME: second',
    })
    vim.fn.chdir(dir)
    vim.cmd.edit(path)
    todo.refresh()

    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    feed(']t')
    vim.wait(80)
    T.eq(vim.api.nvim_win_get_cursor(0), { 3, 3 })

    feed('[t')
    vim.wait(80)
    T.eq(vim.api.nvim_win_get_cursor(0), { 1, 3 })

    T.rmrf(dir)
  end)
end)

T.summary()
