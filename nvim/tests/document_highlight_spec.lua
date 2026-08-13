local T = dofile(TESTS_DIR .. '/helpers.lua')
local dh = require('config.document_highlight')

--- documentHighlight を返すクライアントを1つ繋がっている体にする。
--- 返す result はテストごとに差し替える
---@param opts { supports?: boolean, result?: table, on_request?: fun(params: table) }
local function fake_client(opts)
  opts = opts or {}
  local supports = opts.supports ~= false
  vim.lsp.get_clients = function()
    return { {
      offset_encoding = 'utf-16',
      supports_method = function(_, method)
        return supports and method == 'textDocument/documentHighlight'
      end,
      request = function(_, _, params, handler)
        if opts.on_request then opts.on_request(params) end
        handler(nil, opts.result)
        return true, 1
      end,
    } }
  end
end

--- ハイライト用の extmark を (行, hl_group) の一覧で取り出す。
--- namespace は組み込み(vim.lsp.util.buf_highlight_references)側の持ち物なので
--- ns を指定せず全部から拾い、LspReference* だけに絞る
local function highlights(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local hl = m[4] and m[4].hl_group
    if type(hl) == 'string' and hl:match('^LspReference') then
      table.insert(out, { line = m[2], hl = hl })
    end
  end
  table.sort(out, function(a, b) return a.line < b.line end)
  return out
end

local function open_file()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  T.write_file(dir .. '/a.lua', {
    'local count = 1',
    'count = count + 1',
    'print(count)',
  })
  vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))
  return dir, vim.api.nvim_get_current_buf()
end

-- kind: 1=Text, 2=Read, 3=Write
local RESULT = {
  { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 11 } }, kind = 3 },
  { range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 5 } }, kind = 3 },
  { range = { start = { line = 2, character = 6 }, ['end'] = { line = 2, character = 11 } }, kind = 2 },
}

T.describe('document_highlight (カーソル下シンボルの同一箇所ハイライト)', function()
  T.it('カーソルが止まると同じシンボルが光り、書き込みは読み取りと色が変わる', function()
    local dir, buf = open_file()
    fake_client({ result = RESULT })

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300, function() return #highlights(buf) > 0 end)

    T.eq(highlights(buf), {
      { line = 0, hl = 'LspReferenceWrite' },
      { line = 1, hl = 'LspReferenceWrite' },
      { line = 2, hl = 'LspReferenceRead' },
    }, '3箇所が kind ごとの色で光る')

    T.rmrf(dir)
  end)

  T.it('カーソルを動かすと即座に消える（次の結果が来るまで前のシンボルが光り続けない）', function()
    local dir, buf = open_file()
    fake_client({ result = RESULT })

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300, function() return #highlights(buf) > 0 end)
    T.ok(#highlights(buf) > 0, '前提: 一度光っている')

    -- 次の CursorMoved はデバウンス前にまずクリアする
    fake_client({ result = {} })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    T.eq(#highlights(buf), 0, 'カーソル移動の時点で消えている')

    T.rmrf(dir)
  end)

  T.it('インサートに入ると消える', function()
    local dir, buf = open_file()
    fake_client({ result = RESULT })

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300, function() return #highlights(buf) > 0 end)
    T.ok(#highlights(buf) > 0, '前提: 一度光っている')

    vim.api.nvim_exec_autocmds('InsertEnter', { buffer = buf })
    T.eq(#highlights(buf), 0, '編集中は光らせない')

    T.rmrf(dir)
  end)

  T.it('documentHighlight 非対応のサーバーでは何も起きない', function()
    local dir, buf = open_file()
    local requested = false
    fake_client({ supports = false, result = RESULT, on_request = function() requested = true end })

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300)

    T.eq(requested, false, 'リクエスト自体を投げない')
    T.eq(#highlights(buf), 0, 'ハイライトも付かない')

    T.rmrf(dir)
  end)

  T.it('パネル等（buftype が空でないバッファ）では動かない', function()
    local requested = false
    fake_client({ result = RESULT, on_request = function() requested = true end })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'count = 1' })
    vim.api.nvim_set_current_buf(buf)

    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300)

    T.eq(requested, false, '一覧パネルの上でLSPに問い合わせない')
    T.eq(#highlights(buf), 0, 'ハイライトも付かない')
  end)

  T.it('応答が返る前にカーソルが動いていたら、その結果は捨てる', function()
    local dir, buf = open_file()
    local saved_handler
    vim.lsp.get_clients = function()
      return { {
        offset_encoding = 'utf-16',
        supports_method = function() return true end,
        -- handler をすぐ呼ばずに保持して、あとから「遅れて返ってきた」体で呼ぶ
        request = function(_, _, _, handler) saved_handler = handler; return true, 1 end,
      } }
    end

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300, function() return saved_handler ~= nil end)
    T.ok(saved_handler ~= nil, '前提: リクエストが飛んでいる')

    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- 応答前にカーソルが動いた
    saved_handler(nil, RESULT)

    T.eq(#highlights(buf), 0, '古い位置の結果でハイライトしない')

    T.rmrf(dir)
  end)

  T.it('DocumentHighlightToggle で表示を切り替えられる', function()
    local dir, buf = open_file()
    fake_client({ result = RESULT })
    local orig_notify = vim.notify
    vim.notify = function() end

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300, function() return #highlights(buf) > 0 end)
    T.ok(#highlights(buf) > 0, '前提: 光っている')

    vim.cmd('DocumentHighlightToggle')
    T.eq(dh.is_enabled(), false, 'OFFになる')
    T.eq(#highlights(buf), 0, 'OFFにした時点で消える')

    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(300)
    T.eq(#highlights(buf), 0, 'OFFの間はカーソルを動かしても光らない')

    vim.cmd('DocumentHighlightToggle')
    T.eq(dh.is_enabled(), true, 'ONに戻る')
    vim.wait(300, function() return #highlights(buf) > 0 end)
    T.ok(#highlights(buf) > 0, 'ONに戻すとその場で光る')

    vim.notify = orig_notify
    T.rmrf(dir)
  end)
end)

T.summary()
