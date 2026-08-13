local T = dofile(TESTS_DIR .. '/helpers.lua')
local preview_buf = require('config.util.preview_buf')

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

T.describe('preview_buf (プレビュー用バッファの読み込み)', function()
  T.it('まだ存在しないファイルのバッファを読み込んで filetype を付ける', function()
    local dir = tmpdir()
    T.write_file(dir .. '/a.lua', { 'local a = 1' })

    local buf = preview_buf.load(dir .. '/a.lua')

    T.eq(vim.api.nvim_buf_is_loaded(buf), true, '読み込まれている')
    T.eq(vim.bo[buf].filetype, 'lua', 'filetype が付く')
    T.rmrf(dir)
  end)

  -- 本命。LSP は診断を受け取った時点で vim.uri_to_bufnr() により対象ファイルの
  -- バッファを作るので、一度も開いていないファイルでも「名前だけの unloaded な
  -- バッファ」が先にできている。この状態で bufadd + bufload すると中身は読めるが
  -- filetype 検出（新規作成時の経路）を通らず ft が空のままになる
  T.it('LSP が先に作った空バッファでも filetype を補う', function()
    local dir = tmpdir()
    T.write_file(dir .. '/b.lua', { 'local b = 2' })

    -- LSP が作った状態を再現する（バッファはあるが未ロード・ft 無し）
    local pre = vim.fn.bufadd(dir .. '/b.lua')
    T.eq(vim.api.nvim_buf_is_loaded(pre), false, '前提: まだ読み込まれていない')
    T.eq(vim.bo[pre].filetype, '', '前提: filetype も付いていない')

    local buf = preview_buf.load(dir .. '/b.lua')

    T.eq(buf, pre, '既存のバッファを使い回す')
    T.eq(vim.api.nvim_buf_is_loaded(buf), true, '読み込まれる')
    T.eq(vim.bo[buf].filetype, 'lua',
      'ft が空のままだと treesitter が起動せず、そのファイルを後で開いても色が付かなくなる')
    T.rmrf(dir)
  end)

  T.it('拡張子で判別できないファイルでも落ちない', function()
    local dir = tmpdir()
    T.write_file(dir .. '/notes', { 'ただのテキスト' })

    local buf = preview_buf.load(dir .. '/notes')

    T.eq(vim.api.nvim_buf_is_loaded(buf), true, '読み込みはできる')
    T.eq(vim.bo[buf].filetype, '', 'filetype は空のまま（例外にはしない）')
    T.rmrf(dir)
  end)

  -- 別プロセスが同じファイルを開いている / クラッシュ後のスワップが残っていると
  -- bufload は E325 で例外を投げる。ここで巻き添えに止まると呼び出し元の
  -- プレビュー更新まで死んで「選択を動かしても中身が変わらない」状態になる
  T.it('スワップファイルが残っていても例外にせず filetype を付ける', function()
    local dir = tmpdir()
    T.write_file(dir .. '/d.lua', { 'local d = 4' })

    -- bufload が必ず失敗する状況を作る（読み込み中に例外を投げさせる）
    local buf = vim.fn.bufadd(dir .. '/d.lua')
    local orig_bufload = vim.fn.bufload
    vim.fn.bufload = function() error('Vim:E325: ATTENTION') end

    local ok, got = pcall(preview_buf.load, dir .. '/d.lua')
    vim.fn.bufload = orig_bufload

    T.eq(ok, true, '例外を呼び出し元へ投げない')
    T.eq(got, buf, 'バッファ番号は返す')
    T.eq(vim.bo[buf].filetype, 'lua', '読み込みに失敗しても filetype は補う')
    T.rmrf(dir)
  end)

  T.it('既に filetype が付いているバッファは上書きしない', function()
    local dir = tmpdir()
    T.write_file(dir .. '/c.txt', { 'hello' })
    local pre = vim.fn.bufadd(dir .. '/c.txt')
    vim.fn.bufload(pre)
    vim.bo[pre].filetype = 'markdown' -- 手で変えた状態

    local buf = preview_buf.load(dir .. '/c.txt')

    T.eq(vim.bo[buf].filetype, 'markdown', 'ユーザーが設定した filetype を尊重する')
    T.rmrf(dir)
  end)
end)

T.summary()
