local T = dofile(TESTS_DIR .. '/helpers.lua')
local init = require('config.diff_review')
local server = require('config.diff_review.server')

T.describe('diff_review/init.lua', function()
  T.it('registers the DiffReview commands', function()
    local cmds = vim.api.nvim_get_commands({})
    T.ok(cmds.DiffReview ~= nil, 'DiffReview command should exist')
    T.ok(cmds.DiffReviewClose ~= nil, 'DiffReviewClose command should exist')
  end)

  T.it('maps <leader>R in normal mode', function()
    local map = vim.fn.maparg('<leader>R', 'n', false, true)
    T.eq(map.desc, '差分レビューをブラウザで開く（AIとコメントでやりとり）')
  end)

  T.it('requires an explicit port (selection-based, no default)', function()
    T.ok(select(1, init._private.parse_port('')) == nil, 'empty port is rejected')
    T.eq(init._private.parse_port('8080'), 8080)
    T.ok(select(1, init._private.parse_port('abc')) == nil)
    T.ok(select(1, init._private.parse_port('99999')) == nil)
  end)

  T.it('resolves the git root of the current buffer', function()
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/x.txt', { 'hi' })
    end)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/x.txt')
    vim.api.nvim_set_current_buf(buf)

    local root
    init._private.resolve_root(function(r) root = r end)
    T.wait_until(function() return root ~= nil end)
    -- macOS の /var→/private/var 揺れを避けるため resolve 済み実体で比較する
    T.eq(vim.fn.resolve(root), vim.fn.resolve(vim.fs.normalize(dir)))

    vim.api.nvim_buf_delete(buf, { force = true })
    T.rmrf(dir)
  end)

  T.it('apply_views bumps the version only when the diff actually changed', function()
    init._private.state.last_sig = nil
    local a = { uncommitted = { files = { { path = 'a' } } }, unstaged = { files = {} }, staged = { files = {} } }
    local v0 = server.version()
    T.eq(init._private.apply_views(a), true)
    local v1 = server.version()
    T.ok(v1 > v0, 'changed diff bumps version')
    -- 同じ内容ならバンプしない(毎ポーリングでブラウザを無駄に再取得させない)
    T.eq(init._private.apply_views(a), false)
    T.eq(server.version(), v1)
    -- force なら同じでもバンプ
    T.eq(init._private.apply_views(a, true), true)
    T.ok(server.version() > v1)
    -- 内容が変われば当然バンプ
    local v2 = server.version()
    T.eq(init._private.apply_views({ uncommitted = { files = { { path = 'b' } } }, unstaged = { files = {} }, staged = { files = {} } }), true)
    T.ok(server.version() > v2)
  end)

  T.it('tick picks up an external change without a BufWritePost', function()
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/f.txt', { 'a' })
      T.git(d, { '-C', d, 'add', '-A' })
      T.git(d, { '-C', d, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'base' })
    end)
    init._private.state.root = vim.fs.normalize(dir)
    init._private.state.last_sig = nil
    init._private.state.polling = false

    local port
    for p = 26800, 26850 do if server.start(p) then port = p break end end
    T.ok(port, 'server should start')

    -- nvim の保存を経由しない外部変更（ディスクに直接、未追跡ファイルを作成）
    T.write_file(dir .. '/ext.txt', { 'external' })
    local function has_ext()
      for _, f in ipairs((server.state.diff_models.uncommitted or { files = {} }).files) do
        if f.path == 'ext.txt' then return true end
      end
      return false
    end
    T.ok(not has_ext(), 'not visible before the tick')
    init._private.tick()
    T.wait_until(has_ext)
    T.ok(has_ext(), 'external change is picked up by the polling tick')

    server.stop()
    init._private.state.root = nil
    T.rmrf(dir)
  end)
end)

T.summary()
