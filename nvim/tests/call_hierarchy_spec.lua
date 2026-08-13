local T = dofile(TESTS_DIR .. '/helpers.lua')
local ch = require('config.call_hierarchy')

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function close_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

local function range(line, char)
  return { start = { line = line, character = char or 0 },
           ['end'] = { line = line, character = (char or 0) + 4 } }
end

--- CallHierarchyItem。kind=12 は Function
local function item(name, file, line)
  return {
    name           = name,
    kind           = 12,
    uri            = vim.uri_from_fname(file),
    range          = range(line),
    selectionRange = range(line),
  }
end

--- LSP を差し替えて「呼び出し階層を返すサーバーが1つ繋がっている」体にする。
---@param opts { supports?: boolean, prepare?: table, incoming?: table, outgoing?: table, calls?: table }
local function fake_client(opts)
  opts = opts or {}
  local client
  client = {
    id              = 1,
    offset_encoding = 'utf-16',
    supports_method = function(_, method)
      if opts.supports == false then return false end
      return method == 'textDocument/prepareCallHierarchy'
    end,
    request = function(_, method, params, handler)
      if opts.calls then table.insert(opts.calls, { method = method, params = params }) end
      if method == 'textDocument/prepareCallHierarchy' then
        handler(nil, opts.prepare)
      elseif method == 'callHierarchy/incomingCalls' then
        local fn = opts.incoming
        handler(nil, type(fn) == 'function' and fn(params.item) or fn)
      elseif method == 'callHierarchy/outgoingCalls' then
        local fn = opts.outgoing
        handler(nil, type(fn) == 'function' and fn(params.item) or fn)
      end
      return true, 1
    end,
  }
  vim.lsp.get_clients      = function() return { client } end
  vim.lsp.get_client_by_id = function() return client end
  return client
end

local function tree_window()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= '' and cfg.focusable ~= false then return w end
  end
end

local function preview_window()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= '' and cfg.focusable == false then return w end
  end
end

local function tree_lines()
  local w = tree_window()
  if not w then return {} end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
end

--- 表示を「インデント + マーカー + 名前」だけに落として比較しやすくする。
--- 各行は "<indent><marker> <icon> <name>  <file>:<line>" の形。
--- マーカーもアイコンもマルチバイトなので、Lua の文字クラス([▾▸…])では
--- バイト単位に割れて壊れる。%S+ の位置で切り出すこと
local function tree_shape()
  local out = {}
  for _, l in ipairs(tree_lines()) do
    local indent, marker, _, name = l:match('^( *)(%S+) (%S+) (%S+)')
    if marker then table.insert(out, indent .. marker .. ' ' .. name) end
  end
  return out
end

--- a.lua(呼び先) を b.lua と c.lua から呼んでいる、という素材
local function setup_files()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local lines = {}
  for i = 1, 30 do lines[i] = 'line ' .. i end
  T.write_file(dir .. '/a.lua', lines)
  T.write_file(dir .. '/b.lua', lines)
  T.write_file(dir .. '/c.lua', lines)
  vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))
  return dir
end

T.describe('call_hierarchy (呼び出し階層)', function()
  T.it('呼び出し階層に対応していない LSP では開かない', function()
    close_floats()
    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg) notified = (notified or '') .. '\n' .. msg end
    fake_client({ supports = false })

    ch.open()
    vim.wait(50)

    vim.notify = orig_notify
    T.ok(notified ~= nil, '通知が出る')
    T.contains(notified, '対応していません')
    T.eq(tree_window(), nil, 'ウィンドウは開かない')
  end)

  T.it('カーソル位置が関数でなければ開かない', function()
    close_floats()
    local dir = setup_files()
    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg) notified = (notified or '') .. '\n' .. msg end
    fake_client({ prepare = {} })

    ch.open()
    vim.wait(80)

    vim.notify = orig_notify
    T.ok(notified ~= nil, '通知が出る')
    T.contains(notified, '見つかりません')
    T.eq(tree_window(), nil, 'ウィンドウは開かない')
    T.rmrf(dir)
  end)

  T.it('開くと1段目（呼び元）が自動で展開される', function()
    close_floats()
    local dir = setup_files()
    fake_client({
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      incoming = function(it)
        if it.name == 'fetchUser' then
          return {
            { from = item('handleLogin', dir .. '/b.lua', 4), fromRanges = { range(4) } },
            { from = item('syncAll',     dir .. '/c.lua', 7), fromRanges = { range(7) } },
          }
        end
        return {}
      end,
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 3 end)

    T.eq(tree_shape(), {
      '▾ fetchUser',
      '  ▸ handleLogin',
      '  ▸ syncAll',
    }, 'ルートが開いて呼び元が2件ぶら下がる')
    T.rmrf(dir)
  end)

  T.it('l / Tab でもう一段たどれる（辿った枝は木として残る）', function()
    close_floats()
    local dir = setup_files()
    fake_client({
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      incoming = function(it)
        if it.name == 'fetchUser' then
          return { { from = item('handleLogin', dir .. '/b.lua', 4), fromRanges = { range(4) } } }
        elseif it.name == 'handleLogin' then
          return { { from = item('ServeHTTP', dir .. '/c.lua', 19), fromRanges = { range(19) } } }
        end
        return {}
      end,
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 2 end)

    local tw = tree_window()
    vim.api.nvim_set_current_win(tw)
    vim.api.nvim_win_set_cursor(tw, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(tw) })
    feed('l')
    vim.wait(200, function() return #tree_shape() >= 3 end)

    T.eq(tree_shape(), {
      '▾ fetchUser',
      '  ▾ handleLogin',
      '    ▸ ServeHTTP',
    }, '2段目を開いても1段目は残ったまま')

    -- h で畳む
    feed('h')
    vim.wait(50)
    T.eq(tree_shape(), {
      '▾ fetchUser',
      '  ▸ handleLogin',
    }, 'h で畳める')
    T.rmrf(dir)
  end)

  T.it('循環（A→B→A）は ↻ を付けて展開させない', function()
    close_floats()
    local dir = setup_files()
    fake_client({
      prepare  = { item('a', dir .. '/a.lua', 0) },
      incoming = function(it)
        if it.name == 'a' then
          return { { from = item('b', dir .. '/b.lua', 1), fromRanges = { range(1) } } }
        elseif it.name == 'b' then
          -- b の呼び元がまた a（同じ位置）
          return { { from = item('a', dir .. '/a.lua', 0), fromRanges = { range(0) } } }
        end
        return {}
      end,
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 2 end)

    local tw = tree_window()
    vim.api.nvim_set_current_win(tw)
    vim.api.nvim_win_set_cursor(tw, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(tw) })
    feed('l')
    vim.wait(200, function() return #tree_shape() >= 3 end)

    T.eq(tree_shape(), {
      '▾ a',
      '  ▾ b',
      '    ↻ a',
    }, '祖先と同じ関数には ↻ が付く')

    -- ↻ の行で l を押しても無限に伸びない
    vim.api.nvim_win_set_cursor(tw, { 3, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(tw) })
    feed('l')
    vim.wait(100)
    T.eq(#tree_shape(), 3, '循環ノードは展開されない')
    T.rmrf(dir)
  end)

  T.it('o / i で呼び先・呼び元を切り替える', function()
    close_floats()
    local dir = setup_files()
    fake_client({
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      incoming = { { from = item('handleLogin', dir .. '/b.lua', 4), fromRanges = { range(4) } } },
      outgoing = { { to = item('queryDB', dir .. '/c.lua', 14), fromRanges = { range(9) } } },
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 2 end)
    T.eq(tree_shape()[2], '  ▸ handleLogin', '既定は呼び元')

    local tw = tree_window()
    vim.api.nvim_set_current_win(tw)
    feed('o')
    vim.wait(200, function() return tree_shape()[2] == '  ▸ queryDB' end)
    T.eq(tree_shape(), { '▾ fetchUser', '  ▸ queryDB' }, 'o で呼び先に切り替わる')
    T.contains(T.win_title_text(tw), '呼び先')

    feed('i')
    vim.wait(200, function() return tree_shape()[2] == '  ▸ handleLogin' end)
    T.eq(tree_shape(), { '▾ fetchUser', '  ▸ handleLogin' }, 'i で呼び元に戻る')
    T.contains(T.win_title_text(tw), '呼び元')
    T.rmrf(dir)
  end)

  T.it('プレビューは呼び出しているその行を出し、Enter も同じ場所へ飛ぶ', function()
    close_floats()
    local dir = setup_files()
    fake_client({
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      -- 呼び元 handleLogin の定義は 4 行目だが、呼んでいるのは 21 行目
      incoming = { { from = item('handleLogin', dir .. '/b.lua', 4), fromRanges = { range(20) } } },
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 2 end)

    local tw, pw = tree_window(), preview_window()
    vim.api.nvim_set_current_win(tw)
    vim.api.nvim_win_set_cursor(tw, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(tw) })
    vim.wait(50)

    T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(pw)), ':t'), 'b.lua',
      'プレビューは呼び元のファイル')
    T.eq(vim.api.nvim_win_get_cursor(pw)[1], 21,
      '定義行(5)ではなく、実際に呼んでいる行(21)を出す')

    feed('<CR>')
    vim.wait(80)
    T.eq(vim.loop.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.loop.fs_realpath(dir .. '/b.lua'))
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 21, 'Enter も呼び出し箇所へ飛ぶ')
    T.rmrf(dir)
  end)

  -- CLAUDE.md のルール: SIDEBAR_FT への登録と mark_sidebar を両方やる
  T.it('ユーティリティ窓として登録され、テキストカーソルも隠れる', function()
    close_floats()
    local dir = setup_files()
    local win_util = require('config.util.win_util')
    fake_client({
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      incoming = {},
    })

    ch.open()
    vim.wait(200, function() return tree_window() ~= nil end)

    local tw, pw = tree_window(), preview_window()
    local tbuf = vim.api.nvim_win_get_buf(tw)
    T.eq(vim.bo[tbuf].filetype, 'callhierarchy', 'SIDEBAR_FT で拾えるよう filetype を持つ')
    T.eq(win_util.SIDEBAR_FT['callhierarchy'], true, 'SIDEBAR_FT に登録されている')
    T.eq(vim.w[tw].sidebar, true, 'mark_sidebar が呼ばれている')
    T.eq(vim.w[pw].sidebar, true, 'プレビュー窓も同様')
    -- 忘れると「この窓を開いている間だけ Space Q で終了しない」形で壊れる
    T.eq(win_util.is_editor(tw), false)
    T.eq(win_util.is_editor(pw), false)

    T.eq(vim.b[tbuf].hide_cursor, true, 'カーソルを隠す対象になっている')
    vim.api.nvim_set_current_win(tw)
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = tbuf })
    T.eq(vim.o.guicursor, 'a:HiddenCursor', 'フォーカス中はテキストカーソルが隠れる')
    T.rmrf(dir)
  end)

  T.it('閉じるとプレビューの強調行が残らない', function()
    close_floats()
    local dir = setup_files()
    fake_client({
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      incoming = { { from = item('handleLogin', dir .. '/b.lua', 4), fromRanges = { range(20) } } },
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 2 end)

    local ns = vim.api.nvim_get_namespaces()['call_hierarchy_hl']
    T.ok(ns ~= nil, 'namespace がある')
    local function marks(path)
      local b = vim.fn.bufnr(path)
      if b == -1 or not vim.api.nvim_buf_is_valid(b) then return 0 end
      return #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {})
    end

    local tw = tree_window()
    vim.api.nvim_set_current_win(tw)
    T.eq(marks(dir .. '/a.lua'), 1, 'ルートの行が強調されている')

    vim.api.nvim_win_set_cursor(tw, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(tw) })
    vim.wait(50)
    T.eq(marks(dir .. '/b.lua'), 1, '移動先が強調される')
    T.eq(marks(dir .. '/a.lua'), 0, '通り過ぎたファイルには残さない')

    feed('q')
    vim.wait(50)
    T.eq(marks(dir .. '/b.lua'), 0, '閉じたら消える')
    T.rmrf(dir)
  end)

  -- LSP は診断を受け取った時点で対象ファイルのバッファを名前だけ作るので、
  -- 階層を辿って別ファイルへ移ると「既にあるが未ロード」のバッファに当たる。
  -- そこで filetype を補わないとプレビューの色が消え、しかもそのバッファは
  -- 残るので、あとで実際にそのファイルを開いても色が付かないままになる
  T.it('別ファイルへ辿ってもプレビューに filetype が付く（色が消えない）', function()
    close_floats()
    local dir = setup_files()

    -- gopls が診断で作った状態を再現する
    local pre = vim.fn.bufadd(dir .. '/b.lua')
    T.eq(vim.api.nvim_buf_is_loaded(pre), false, '前提: 未ロード')
    T.eq(vim.bo[pre].filetype, '', '前提: filetype 無し')

    fake_client({
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      incoming = { { from = item('handleLogin', dir .. '/b.lua', 4), fromRanges = { range(4) } } },
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 2 end)

    local tw = tree_window()
    vim.api.nvim_set_current_win(tw)
    vim.api.nvim_win_set_cursor(tw, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(tw) })
    vim.wait(50)

    local pbuf = vim.api.nvim_win_get_buf(preview_window())
    T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(pbuf), ':t'), 'b.lua', '前提: b.lua を出している')
    T.eq(vim.bo[pbuf].filetype, 'lua', 'プレビューしたバッファに filetype が付く')
    T.rmrf(dir)
  end)

  T.it('展開済みの枝は再取得しない（同じ item を2度問い合わせない）', function()
    close_floats()
    local dir = setup_files()
    local calls = {}
    fake_client({
      calls    = calls,
      prepare  = { item('fetchUser', dir .. '/a.lua', 9) },
      incoming = function(it)
        if it.name == 'fetchUser' then
          return { { from = item('handleLogin', dir .. '/b.lua', 4), fromRanges = { range(4) } } }
        end
        return {}
      end,
    })

    ch.open()
    vim.wait(200, function() return #tree_shape() >= 2 end)

    local tw = tree_window()
    vim.api.nvim_set_current_win(tw)
    vim.api.nvim_win_set_cursor(tw, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(tw) })
    feed('l')  -- handleLogin を展開（0件）
    vim.wait(150)
    feed('h')  -- 畳む
    vim.wait(50)
    feed('l')  -- もう一度開く
    vim.wait(150)

    local n = 0
    for _, c in ipairs(calls) do
      if c.method == 'callHierarchy/incomingCalls' and c.params.item.name == 'handleLogin' then
        n = n + 1
      end
    end
    T.eq(n, 1, '取得済みの枝は開き直しても問い合わせ直さない')
    T.rmrf(dir)
  end)
end)

T.summary()
