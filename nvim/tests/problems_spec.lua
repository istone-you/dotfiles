-- config.problems は診断の一覧パネル（VSCode の Problems 相当）。
-- 検証するのは: 診断の収集と並び、表示行の組み立てと行→診断の対応表、
-- フィルタの巡回、パネルの開閉、Enter でのジャンプ、
-- herdr 向け診断テキストの整形と送り出し。
local T = dofile(TESTS_DIR .. '/helpers.lua')
local problems = require('config.problems')

local S  = vim.diagnostic.severity
local ns = vim.api.nvim_create_namespace('problems_spec')

-- 名前付きバッファを作って診断をセットする（collect は無名バッファを除外する）
local function buf_with_diags(name, diags)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })
  vim.diagnostic.set(ns, buf, diags)
  return buf
end

local function clear_all()
  vim.diagnostic.reset(ns)
end

T.describe('problems.collect', function()
  T.it('ファイル名順・行順に並べ、cwd 相対パスを持つ', function()
    clear_all()
    local dir = vim.fn.getcwd()
    local b1 = buf_with_diags(dir .. '/b.lua', {
      { lnum = 2, col = 0, severity = S.ERROR, message = 'b の 3 行目' },
    })
    local b2 = buf_with_diags(dir .. '/a.lua', {
      { lnum = 1, col = 4, severity = S.WARN,  message = 'a の 2 行目' },
      { lnum = 0, col = 0, severity = S.ERROR, message = 'a の 1 行目' },
    })

    local items = problems.collect(S.HINT)
    T.eq(#items, 3)
    T.eq(items[1].path, 'a.lua')
    T.eq(items[1].lnum, 1) -- 診断は 0-based、表示は 1-based
    T.eq(items[2].path, 'a.lua')
    T.eq(items[2].lnum, 2)
    T.eq(items[3].path, 'b.lua')
    T.eq(items[3].lnum, 3)

    clear_all()
    vim.api.nvim_buf_delete(b1, { force = true })
    vim.api.nvim_buf_delete(b2, { force = true })
  end)

  T.it('重要度でフィルタできる', function()
    clear_all()
    local buf = buf_with_diags(vim.fn.getcwd() .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'err' },
      { lnum = 1, col = 0, severity = S.WARN,  message = 'warn' },
      { lnum = 2, col = 0, severity = S.HINT,  message = 'hint' },
    })

    T.eq(#problems.collect(S.HINT), 3)
    T.eq(#problems.collect(S.WARN), 2)
    T.eq(#problems.collect(S.ERROR), 1)

    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('複数行メッセージは 1 行に潰す', function()
    clear_all()
    local buf = buf_with_diags(vim.fn.getcwd() .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = '1 行目\n  2 行目' },
    })
    T.eq(problems.collect(S.HINT)[1].message, '1 行目 2 行目')
    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

T.describe('problems.build', function()
  T.it('ヘッダ＋ファイル見出し＋診断行を組み立て、行→診断の対応表を返す', function()
    local items = {
      { path = 'a.lua', bufnr = 0, lnum = 1, col = 0, severity = S.ERROR, message = 'err1', source = 'lua_ls' },
      { path = 'a.lua', bufnr = 0, lnum = 5, col = 2, severity = S.WARN,  message = 'warn1' },
      { path = 'b.lua', bufnr = 0, lnum = 3, col = 0, severity = S.ERROR, message = 'err2' },
    }
    local lines, meta = problems.build(items)

    T.contains(lines[1], '問題')
    T.contains(lines[1], '2') -- エラー 2 件
    T.eq(lines[2], '')
    T.contains(lines[3], 'a.lua')
    T.contains(lines[4], '1:1')
    T.contains(lines[4], 'err1')
    T.contains(lines[4], '[lua_ls]')
    T.contains(lines[5], '5:3') -- col は 0-based なので +1 して表示
    T.contains(lines[6], 'b.lua')

    -- 見出し行には診断が紐づかず、診断行にだけ紐づく
    T.eq(meta[3], nil)
    T.eq(meta[4].message, 'err1')
    T.eq(meta[5].message, 'warn1')
    T.eq(meta[7].message, 'err2')
  end)

  T.it('診断が無ければ「問題はありません」を出す', function()
    local lines, meta = problems.build({})
    T.contains(lines[3], '問題はありません')
    T.eq(meta, {})
  end)
end)

T.describe('problems: フィルタ巡回', function()
  T.it('f で すべて → エラー+警告 → エラーのみ → すべて と回る', function()
    clear_all()
    local buf = buf_with_diags(vim.fn.getcwd() .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'err' },
      { lnum = 1, col = 0, severity = S.WARN,  message = 'warn' },
      { lnum = 2, col = 0, severity = S.HINT,  message = 'hint' },
    })

    problems.open()
    T.eq(#problems.collect(), 3)
    problems.cycle_filter()
    T.eq(#problems.collect(), 2)
    problems.cycle_filter()
    T.eq(#problems.collect(), 1)
    problems.cycle_filter()
    T.eq(#problems.collect(), 3)
    problems.close()

    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

T.describe('problems: パネルの開閉', function()
  T.it('toggle で開いて閉じる', function()
    T.eq(problems.is_open(), false)
    problems.toggle()
    T.eq(problems.is_open(), true)
    problems.toggle()
    T.eq(problems.is_open(), false)
  end)

  T.it('パネルは nofile / filetype=problems でサイドバー扱いになる', function()
    problems.open()
    local pbuf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    T.eq(vim.bo[pbuf].buftype, 'nofile')
    T.eq(vim.bo[pbuf].filetype, 'problems')
    -- auto_quit / quit_confirm が「実編集ウィンドウ」と誤認しないこと
    T.eq(require('config.util.win_util').is_editor(vim.api.nvim_get_current_win()), false)
    problems.close()
  end)

  T.it('二重に open しても窓は増えない', function()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    problems.open()
    local opened = #vim.api.nvim_tabpage_list_wins(0)
    problems.open()
    T.eq(#vim.api.nvim_tabpage_list_wins(0), opened)
    problems.close()
    T.eq(#vim.api.nvim_tabpage_list_wins(0), before)
  end)
end)

T.describe('problems.nearest_item', function()
  -- ヘッダ(1) 空行(2) ファイル見出し(3) 診断(4,5) ファイル見出し(6) 診断(7)
  local items = { 4, 5, 7 }

  T.it('診断行の上ならその行のまま', function()
    T.eq(problems.nearest_item(items, 4, 1), 4)
    T.eq(problems.nearest_item(items, 7, -1), 7)
  end)

  T.it('下向きに動いてきたなら次の診断行へ送る', function()
    T.eq(problems.nearest_item(items, 1, 1), 4) -- ヘッダ
    T.eq(problems.nearest_item(items, 2, 1), 4) -- 空行
    T.eq(problems.nearest_item(items, 3, 1), 4) -- ファイル見出し
    T.eq(problems.nearest_item(items, 6, 1), 7) -- 2つ目のファイル見出し
  end)

  T.it('上向きに動いてきたなら前の診断行へ戻す', function()
    T.eq(problems.nearest_item(items, 6, -1), 5)
    T.eq(problems.nearest_item(items, 3, -1), 4, '上に診断が無ければ下へ折り返す')
  end)

  T.it('進行方向に候補が無ければ反対側へ折り返す', function()
    T.eq(problems.nearest_item(items, 9, 1), 7)  -- 末尾より下
    T.eq(problems.nearest_item(items, 1, -1), 4) -- 先頭より上
  end)

  T.it('診断が1件も無ければ nil', function()
    T.eq(problems.nearest_item({}, 1, 1), nil)
  end)
end)

T.describe('problems: カーソルの吸着', function()
  local function open_with(diags)
    clear_all()
    local buf = buf_with_diags(vim.fn.getcwd() .. '/a.lua', diags)
    problems.open()
    return buf
  end

  T.it('開いた直後のカーソルは最初の診断行に乗る', function()
    local buf = open_with({
      { lnum = 0, col = 0, severity = S.ERROR, message = 'err1' },
      { lnum = 1, col = 0, severity = S.WARN,  message = 'warn1' },
    })
    -- 1:ヘッダ 2:空行 3:ファイル見出し 4:最初の診断
    T.eq(vim.api.nvim_win_get_cursor(problems.win_id())[1], 4)
    problems.close()
    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('ヘッダ・空行・ファイル見出しに乗せても診断行へ戻される', function()
    local buf = open_with({
      { lnum = 0, col = 0, severity = S.ERROR, message = 'err1' },
      { lnum = 1, col = 0, severity = S.WARN,  message = 'warn1' },
    })
    local pwin = problems.win_id()
    for _, lnum in ipairs({ 1, 2, 3 }) do
      vim.api.nvim_win_set_cursor(pwin, { lnum, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(pwin) })
      T.eq(vim.api.nvim_win_get_cursor(pwin)[1], 4, lnum .. ' 行目から診断行へ寄る')
    end
    problems.close()
    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('診断が無いときはカーソル行の強調を消す', function()
    clear_all()
    problems.open()
    T.eq(vim.wo[problems.win_id()].cursorline, false)
    problems.close()
  end)
end)

T.describe('problems.format_item / format_items', function()
  T.it('診断1件を path:行:列 severity: message [source] にする', function()
    local s = problems.format_item({
      path = 'a.lua', lnum = 10, col = 2, severity = S.ERROR,
      message = 'undefined', source = 'lua_ls',
    })
    T.eq(s, 'a.lua:10:3 error: undefined [lua_ls]')
  end)

  T.it('source が無ければ括弧を付けない', function()
    local s = problems.format_item({
      path = 'a.lua', lnum = 1, col = 0, severity = S.WARN, message = 'x',
    })
    T.eq(s, 'a.lua:1:1 warn: x')
  end)

  T.it('0件は nil、1件は単体フォーマット、複数は改行なしの依頼文', function()
    T.eq(problems.format_items({}), nil)
    local one = {
      path = 'a.lua', lnum = 1, col = 0, severity = S.ERROR, message = 'e1',
    }
    T.eq(problems.format_items({ one }), 'a.lua:1:1 error: e1')
    local two = {
      one,
      { path = 'b.lua', lnum = 2, col = 1, severity = S.WARN, message = 'w1', source = 'tsc' },
    }
    local got = problems.format_items(two)
    T.ok(got:find('これらの診断を修正してください:', 1, true) == 1)
    T.contains(got, 'a.lua:1:1 error: e1')
    T.contains(got, 'b.lua:2:2 warn: w1 [tsc]')
    T.ok(not got:find('\n', 1, true), 'send-text 向けに改行を含めない')
  end)
end)

T.describe('problems.items_for_path', function()
  T.it('現フィルタ下で指定 path の診断だけ返す', function()
    clear_all()
    local dir = vim.fn.getcwd()
    local b1 = buf_with_diags(dir .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'a1' },
      { lnum = 1, col = 0, severity = S.HINT,  message = 'ah' },
    })
    local b2 = buf_with_diags(dir .. '/b.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'b1' },
    })
    problems.open()
    problems.cycle_filter() -- エラー+警告
    problems.cycle_filter() -- エラーのみ
    local only_a = problems.items_for_path('a.lua')
    T.eq(#only_a, 1)
    T.eq(only_a[1].message, 'a1')
    T.eq(#problems.items_for_path('b.lua'), 1)
    problems.cycle_filter() -- すべてへ戻す（filter_idx はモジュール共有）
    problems.close()

    clear_all()
    vim.api.nvim_buf_delete(b1, { force = true })
    vim.api.nvim_buf_delete(b2, { force = true })
  end)
end)

T.describe('problems: herdr へ診断を送る', function()
  T.it('send_current はカーソル行の診断を pick_agent に渡す', function()
    clear_all()
    local buf = buf_with_diags(vim.fn.getcwd() .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'boom', source = 'x' },
    })
    problems.open()
    local sent
    local herdr = require('config.herdr')
    local orig = herdr.pick_agent
    herdr.pick_agent = function(text) sent = text end
    problems.send_current()
    herdr.pick_agent = orig
    T.eq(sent, 'a.lua:1:1 error: boom [x]')
    problems.close()
    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('send_file は同ファイルの診断をまとめて渡す', function()
    clear_all()
    local dir = vim.fn.getcwd()
    local b1 = buf_with_diags(dir .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'e1' },
      { lnum = 1, col = 0, severity = S.ERROR, message = 'e2' },
    })
    local b2 = buf_with_diags(dir .. '/b.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'other' },
    })
    problems.open()
    local sent
    local herdr = require('config.herdr')
    local orig = herdr.pick_agent
    herdr.pick_agent = function(text) sent = text end
    problems.send_file()
    herdr.pick_agent = orig
    T.contains(sent, 'これらの診断を修正してください:')
    T.contains(sent, 'a.lua:1:1 error: e1')
    T.contains(sent, 'a.lua:2:1 error: e2')
    T.ok(not sent:find('other', 1, true), '他ファイルは含めない')
    problems.close()
    clear_all()
    vim.api.nvim_buf_delete(b1, { force = true })
    vim.api.nvim_buf_delete(b2, { force = true })
  end)

  T.it('send_filtered は現フィルタの全件を渡す', function()
    clear_all()
    local buf = buf_with_diags(vim.fn.getcwd() .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'e' },
      { lnum = 1, col = 0, severity = S.WARN,  message = 'w' },
    })
    problems.open()
    problems.cycle_filter() -- エラー+警告（両方残る）
    problems.cycle_filter() -- エラーのみ
    local sent
    local herdr = require('config.herdr')
    local orig = herdr.pick_agent
    herdr.pick_agent = function(text) sent = text end
    problems.send_filtered()
    herdr.pick_agent = orig
    T.eq(sent, 'a.lua:1:1 error: e')
    T.ok(not sent:find('warn', 1, true))
    problems.cycle_filter() -- すべてへ戻す
    problems.close()
    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('診断が無い send_filtered は pick_agent を呼ばず警告する', function()
    clear_all()
    problems.open()
    local called = false
    local herdr = require('config.herdr')
    local orig = herdr.pick_agent
    herdr.pick_agent = function() called = true end
    local warns = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level) warns[#warns + 1] = { msg = msg, level = level } end
    problems.send_filtered()
    vim.notify = orig_notify
    herdr.pick_agent = orig
    T.ok(not called)
    T.ok(#warns > 0)
    problems.close()
  end)
end)

T.describe('problems.jump', function()
  T.it('カーソル行の診断の位置へ移動する', function()
    clear_all()
    local path = vim.fn.getcwd() .. '/a.lua'
    local buf  = buf_with_diags(path, {
      { lnum = 2, col = 1, severity = S.ERROR, message = 'err' },
    })
    -- 編集ウィンドウに対象バッファを載せておく
    vim.api.nvim_set_current_buf(buf)

    problems.open()
    local pwin = vim.api.nvim_get_current_win()
    -- 1:ヘッダ 2:空行 3:ファイル見出し 4:最初の診断
    vim.api.nvim_win_set_cursor(pwin, { 4, 0 })
    problems.jump()

    T.eq(vim.api.nvim_get_current_buf(), buf)
    T.eq(vim.api.nvim_win_get_cursor(0), { 3, 1 })

    problems.close()
    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('見出し行では何も起きない', function()
    clear_all()
    local buf = buf_with_diags(vim.fn.getcwd() .. '/a.lua', {
      { lnum = 0, col = 0, severity = S.ERROR, message = 'err' },
    })
    problems.open()
    local pwin = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(pwin, { 3, 0 }) -- ファイル見出し
    problems.jump()
    T.eq(vim.api.nvim_get_current_win(), pwin, 'パネルから移動しない')
    problems.close()
    clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

T.summary()
