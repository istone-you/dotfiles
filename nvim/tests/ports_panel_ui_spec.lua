-- 実際に ports_panel.open() でUIを開き、実キー入力で操作して結果を確認する。
-- lsof の実出力には依存できない（実行環境ごとに中身が違う）ため、docker_panel_helpers.lua
-- と同じ方針で「偽lsof」シェルスクリプトを作って ports.bin に差し替える。
-- 偽lsofは呼ばれた引数をログへ追記し、kill も同じログに乗せるので操作の検証ができる。

local T = dofile(TESTS_DIR .. '/helpers.lua')
local ports = require('config.ports_panel.ports')

local FIELD_OUTPUT = {
  'p111', 'cnode', 'Listone',
  'f20', 'PTCP', 'n*:3000', 'TST=LISTEN', 'TQR=0', 'TQS=0',
  'f21', 'PTCP', 'n*:3000', 'TST=LISTEN',
  'f22', 'PTCP', 'n127.0.0.1:3000->127.0.0.1:54321', 'TST=ESTABLISHED',
  'p222', 'cpostgres', 'Lpostgres',
  'f5', 'PTCP', 'n127.0.0.1:5432', 'TST=LISTEN',
}

local state

local function fake_lsof()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile(FIELD_OUTPUT, dir .. '/field.txt')
  vim.fn.writefile({ 'COMMAND PID USER FD TYPE NODE NAME', 'node 111 istone 20u IPv4 TCP *:3000 (LISTEN)' },
    dir .. '/sockets.txt')
  vim.fn.writefile({}, dir .. '/calls.log')

  local bin = dir .. '/lsof'
  vim.fn.writefile({
    '#!/bin/sh',
    'STATE="' .. dir .. '"',
    'printf "%s\\n" "$*" >> "$STATE/calls.log"',
    -- -F 付き（一覧取得）とそれ以外（PIDのソケット一覧）を出し分ける
    'case "$*" in',
    '  *-F*) cat "$STATE/field.txt";;',
    '  *) cat "$STATE/sockets.txt";;',
    'esac',
    'exit 0',
  }, bin)
  vim.fn.system({ 'chmod', '+x', bin })

  ports.bin = bin
  ports.command_log = {}
  return { dir = dir, bin = bin, log = dir .. '/calls.log' }
end

local function calls()
  if vim.fn.filereadable(state.log) == 0 then return {} end
  return vim.fn.readfile(state.log)
end

local function called(needle)
  for _, line in ipairs(calls()) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

local function win_by_title(part)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= '' and cfg.title then
      local chunks = {}
      for _, c in ipairs(cfg.title) do table.insert(chunks, c[1]) end
      if table.concat(chunks):find(part, 1, true) then return w end
    end
  end
  return nil
end

local function left_win()
  return win_by_title('Listening') or win_by_title('Connections')
end

local function right_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, v = pcall(vim.api.nvim_win_get_var, w, 'portspanel_right')
    if ok and v then return w end
  end
  return nil
end

local function lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function find_row(win, substring)
  for i, l in ipairs(lines(win)) do
    if l:find(substring, 1, true) then return i end
  end
  return nil
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function press(keys)
  local w = left_win()
  vim.api.nvim_set_current_win(w)
  feed(keys)
end

local function open()
  local pp = require('config.ports_panel')
  pcall(pp.close)
  pp.open(false)
  vim.wait(600)
  return pp
end

T.describe('ports_panel: Listening', function()
  T.it('lists listening ports with the owning process', function()
    state = fake_lsof()
    open()

    local w = left_win()
    T.ok(w ~= nil, 'listening panel should be open')
    local body = table.concat(lines(w), '\n')
    T.contains(body, '3000')
    T.contains(body, 'node')
    T.contains(body, '111')
    T.contains(body, '5432')
    T.contains(body, 'postgres')
    -- 同じポートを2つのfdで持っていても1行にまとまる
    local count = 0
    for _, l in ipairs(lines(w)) do
      if l:find('node', 1, true) then count = count + 1 end
    end
    T.eq(count, 1)
    -- 確立済み接続は Listening には出さない
    T.ok(not body:find('54321', 1, true), 'established peers must not appear in the listening panel')

    require('config.ports_panel').close()
    vim.wait(200)
    vim.fn.delete(state.dir, 'rf')
    ports.bin = 'lsof'
  end)

  T.it('shows the socket list of the selected process in the right pane', function()
    state = fake_lsof()
    open()

    local w = left_win()
    local row = find_row(w, '3000')
    T.ok(row ~= nil, 'a row for port 3000 should exist')
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { row, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(w) })
    -- Process タブ → Sockets タブへ
    press(']')
    vim.wait(500)

    local rw = right_win()
    T.ok(rw ~= nil, 'right pane should exist')
    T.contains(table.concat(lines(rw), '\n'), '*:3000')
    T.ok(called('-p 111'), 'lsof should be asked for the sockets of the selected pid')

    require('config.ports_panel').close()
    vim.wait(200)
    vim.fn.delete(state.dir, 'rf')
    ports.bin = 'lsof'
  end)
end)

T.describe('ports_panel: Connections', function()
  T.it('switches to the connections panel and shows the peer', function()
    state = fake_lsof()
    open()

    press('2')
    vim.wait(600)

    local w = left_win()
    local body = table.concat(lines(w), '\n')
    T.contains(body, '127.0.0.1:54321')
    T.contains(body, 'node')
    -- LISTEN だけのソケットは Connections には出さない
    T.ok(not body:find('5432 ', 1, true), 'listen-only sockets must not appear in the connections panel')

    require('config.ports_panel').close()
    vim.wait(200)
    vim.fn.delete(state.dir, 'rf')
    ports.bin = 'lsof'
  end)
end)

T.describe('ports_panel: 操作', function()
  T.it('asks for confirmation before killing and logs the command', function()
    state = fake_lsof()
    open()

    local w = left_win()
    local row = find_row(w, '3000')
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { row, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(w) })

    -- kill は実際に打たない。確認ダイアログが出ること、キャンセルで何も起きないことを見る
    local killed = {}
    local orig_kill = ports.kill
    ports.kill = function(pid, signal, cb)
      table.insert(killed, { pid = pid, signal = signal })
      if cb then cb({ code = 0, stdout = '', stderr = '' }) end
    end

    press('d')
    vim.wait(300)
    local confirm_win = win_by_title('確認')
    T.ok(confirm_win ~= nil, 'a confirmation dialog should be open')
    -- どのプロセスを落とすのかがダイアログに出ていること
    local prompt = table.concat(lines(confirm_win), '\n')
    T.contains(prompt, 'node')
    T.contains(prompt, '111')
    T.contains(prompt, '3000')
    T.eq(#killed, 0, 'nothing should be killed before confirming')

    feed('<Esc>')
    vim.wait(300)
    T.eq(#killed, 0, 'cancelling the confirmation must not kill anything')
    T.eq(win_by_title('確認'), nil, 'the dialog should be gone after cancelling')

    -- 確認して初めて kill が走り、シグナルは TERM
    press('d')
    vim.wait(300)
    feed('y')
    vim.wait(300)
    T.eq(#killed, 1)
    T.eq(killed[1].pid, 111)
    T.eq(killed[1].signal, 'TERM')

    ports.kill = orig_kill
    require('config.ports_panel').close()
    vim.wait(200)
    vim.fn.delete(state.dir, 'rf')
    ports.bin = 'lsof'
  end)

  T.it('stops only the nvim-owned server on d, without killing the process', function()
    state = fake_lsof()
    vim.fn.writefile({
      'p111', 'cnode', 'Listone',
      'f20', 'PTCP', 'n*:3000', 'TST=LISTEN',
      'p222', 'cnvim', 'Lroot',
      'f20', 'PTCP', 'n*:4000', 'TST=LISTEN',
    }, state.dir .. '/field.txt')
    open()

    local w = left_win()
    local row = find_row(w, '4000')
    T.ok(row ~= nil, 'a row for port 4000 should exist')
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { row, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(w) })

    local killed, stopped = {}, {}
    local orig_kill = ports.kill
    local orig_stop = ports.stop_nvim_server
    ports.kill = function(pid, signal, cb)
      table.insert(killed, { pid = pid, signal = signal })
      if cb then cb({ code = 0, stdout = '', stderr = '' }) end
    end
    ports.stop_nvim_server = function(pid, port, cb)
      table.insert(stopped, { pid = pid, port = port })
      cb(true, { id = 'diff_review', label = 'Diff Review' })
    end

    press('d')
    vim.wait(300)
    local confirm_win = win_by_title('確認')
    T.ok(confirm_win ~= nil)
    local prompt = table.concat(lines(confirm_win), '\n')
    T.contains(prompt, 'サーバーを停止')
    T.contains(prompt, 'nvim 自体は終了しません')
    feed('y')
    vim.wait(300)
    T.eq(#killed, 0, 'nvim server stop must not kill the process')
    T.eq(#stopped, 1)
    T.eq(stopped[1].pid, 222)
    T.eq(stopped[1].port, 4000)

    ports.kill = orig_kill
    ports.stop_nvim_server = orig_stop
    require('config.ports_panel').close()
    vim.wait(200)
    vim.fn.delete(state.dir, 'rf')
    ports.bin = 'lsof'
  end)

  T.it('yanks the port number of the row under the cursor', function()
    state = fake_lsof()
    open()

    local w = left_win()
    local row = find_row(w, '5432')
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { row, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(w) })

    vim.fn.setreg('"', '')
    press('y')
    vim.wait(200)
    T.eq(vim.fn.getreg('"'), '5432')

    require('config.ports_panel').close()
    vim.wait(200)
    vim.fn.delete(state.dir, 'rf')
    ports.bin = 'lsof'
  end)
end)

T.summary()
