local T = dofile(TESTS_DIR .. '/helpers.lua')
local winbar = require('config.winbar')

T.describe('winbar', function()
  T.it('shows the cwd-relative path for a normal file window', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/src', 'p')
    T.write_file(dir .. '/src/main.lua', { 'return 1' })

    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/src/main.lua'))

    local win = vim.api.nvim_get_current_win()
    T.ok(winbar.should_show(win), 'a normal file window should get a winbar')

    local s = winbar.build(vim.api.nvim_get_current_buf())
    T.contains(s, 'src › main.lua', 'winbar should show the cwd-relative path as breadcrumbs')
    T.ok(not s:find(dir, 1, true), 'winbar path should be relative (no leading cwd)')

    T.rmrf(dir)
  end)

  T.it('is empty for non-file (nofile) windows like explorer/start-screen', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    T.ok(not winbar.should_show(win), 'a nofile window must not show a winbar')
    T.eq(winbar.winbar_for(win), '', 'nofile window winbar value should be empty')
  end)

  T.it('is empty for an unnamed buffer', function()
    vim.cmd('enew')
    local win = vim.api.nvim_get_current_win()
    T.ok(not winbar.should_show(win), 'an unnamed buffer must not show a winbar')
    T.eq(winbar.winbar_for(win), '', 'unnamed buffer winbar value should be empty')
  end)

  T.it('escapes percent signs in the path so they are not read as statusline items', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/a%b.lua'
    T.write_file(path, { 'return 1' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))

    local s = winbar.build(vim.api.nvim_get_current_buf())
    T.contains(s, 'a%%b.lua', 'a literal % in the path must be escaped as %%')

    T.rmrf(dir)
  end)
end)

local symbols = require('config.util.lsp_symbols')
local K = vim.lsp.protocol.SymbolKind

local function sym(name, kind, s_line, e_line, children)
  return {
    name = name,
    kind = kind,
    range = { start = { line = s_line, character = 0 }, ['end'] = { line = e_line, character = 0 } },
    children = children,
  }
end

--- ハイライト指定を落として、実際に画面へ出る文字だけにする
local function shown(str)
  return (str:gsub('%%#%w+#', ''):gsub('%%%*', ''))
end

--- LSP を起こさずに済むよう、キャッシュ取得だけ差し替える
local function with_symbols(list, fn)
  local orig = winbar.symbols_for
  winbar.symbols_for = function() return list end
  local ok, err = pcall(fn)
  winbar.symbols_for = orig
  if not ok then error(err) end
end

-- シンボルの選別そのものは lsp_symbols_spec.lua で見る。ここは winbar 文字列の組み立て
T.describe('winbar symbol path', function()
  T.it('appends the enclosing symbols, with an icon each, after the file path', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/src', 'p')
    T.write_file(dir .. '/src/main.lua', { 'return 1' })
    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/src/main.lua'))

    with_symbols({ sym('Main', K.Class, 0, 10, { sym('run', K.Method, 0, 10) }) }, function()
      local s = winbar.winbar_for(vim.api.nvim_get_current_win())
      T.eq(shown(s), ' src › main.lua › ' .. symbols.ICONS.Class .. ' Main › ' .. symbols.ICONS.Method .. ' run')
      T.contains(s, '%#WinBarIconType#', 'クラスのアイコンは Type 系の色')
      T.contains(s, '%#WinBarIconFunction#', 'メソッドのアイコンは Function 系の色')
      T.contains(s, '%#WinBarSymbol#', 'シンボル名は WinBarSymbol')
    end)

    T.rmrf(dir)
  end)

  T.it('puts icons only on symbols, never on the path segments', function()
    with_symbols({ sym('run', K.Function, 0, 10) }, function()
      local path = winbar.build(0)
      for _, icon in pairs(symbols.ICONS) do
        T.ok(not path:find(icon, 1, true), 'パス側にアイコンは入れない')
      end
      T.contains(winbar.build_symbols(0, 1), symbols.ICONS.Function, 'シンボル側には入る')
    end)
  end)

  T.it('shows the path alone when no symbol encloses the cursor', function()
    with_symbols({}, function()
      T.eq(winbar.build_symbols(0, 1), '', 'no symbol -> no separator, no trailing junk')
    end)
  end)

  T.it('escapes percent signs coming from a symbol name', function()
    with_symbols({ sym('od%d', K.Function, 0, 10) }, function()
      T.contains(winbar.build_symbols(0, 1), 'od%%d', 'a literal % in a symbol name must be escaped as %%')
    end)
  end)
end)

T.summary()
