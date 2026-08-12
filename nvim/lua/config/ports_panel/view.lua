-- ポート一覧パネルの中身。Listening / Connections の2タブは列と絞り込みが違うだけなので
-- 同じ描画・操作をこのモジュールで共有し、init.lua から M.new(...) で2つ作る。
--
-- 右ペインは Process（ps の詳細）と Sockets（そのPIDが掴んでいるソケット一覧）の2タブ。

local ports = require('config.ports_panel.ports')
local tabs_mod = require('config.panel.tabs')
local text = require('config.panel.text')

local M = {}

--- ローカルアドレスの表示。`*`（全アドレス待ち受け）は見た目が紛れるので明示する
local function addr_label(addr)
  if addr == nil or addr == '' or addr == '*' then return '*' end
  return addr
end

--- 一覧の1行を組み立てる。列は呼び出し側（kind）で変わる
local function format_row(entry, widths, kind)
  local port = text.rpad(tostring(entry.port or '?'), widths.port)
  local proto = text.pad(entry.proto or '', widths.proto)
  local command = text.pad(entry.command or '', widths.command)
  local pid = text.rpad(tostring(entry.pid or ''), widths.pid)
  if kind == 'connections' then
    return string.format('  %s %s  %s  %s  %s', port, proto, command, pid, entry.peer or '')
  end
  return string.format('  %s %s  %s  %s  %s', port, proto, command, pid, addr_label(entry.addr))
end

--- kind: 'listening' | 'connections'
---@param opts { name: string, kind: string, title: string, empty: string }
function M.new(opts)
  local V = {}

  local ctx
  local entries = {}
  local line_entries = {}
  local total_rows = 0
  local cursor_mem = nil
  local tabs = tabs_mod.new({ 'Process', 'Sockets' })
  --- show_detail からタブ描画のコールバックへ渡すため前方宣言する
  local show_current

  --- エントリの同一性はポート＋PID＋相手先で見る。再取得のたびに
  --- テーブルは作り直されるので、カーソル位置はこのキーで復元する
  local function entry_key(e)
    return table.concat({ e.proto or '', e.addr or '', e.port or '', e.pid or '', e.peer or '' }, '|')
  end

  local function current_entry()
    return ctx.current_entry(function() return line_entries end)
  end

  function V.remember_cursor()
    local entry = current_entry()
    if entry then cursor_mem = entry_key(entry) end
  end

  local function still_current(key)
    if ctx.current_panel_name() ~= opts.name then return false end
    local entry = current_entry()
    return entry ~= nil and entry_key(entry) == key
  end

  local function show_detail(entry)
    tabs:render(ctx, function() show_current() end)
    if not entry then
      ctx.set_right_lines({ '  ' .. opts.empty }, 'text', nil, opts.name .. ':none')
      return
    end
    local key = entry_key(entry)
    local tab = tabs:current()
    if tab == 'Process' then
      ports.process_detail(entry.pid, function(out)
        if tabs:current() ~= tab then return end
        if not still_current(key) then return end
        local lines = vim.split(out ~= '' and out or '(プロセス情報を取得できません)', '\n', { plain = true })
        ctx.set_right_lines(lines, 'text', nil, key .. ':process')
      end)
    else
      ports.process_sockets(entry.pid, function(out)
        if tabs:current() ~= tab then return end
        if not still_current(key) then return end
        local lines = vim.split(out ~= '' and out or '(ソケットを取得できません)', '\n', { plain = true })
        ctx.set_right_lines(lines, 'text', nil, key .. ':sockets')
      end)
    end
  end

  show_current = function()
    show_detail(current_entry())
  end

  local function render()
    local lines, hl_queue = {}, {}
    line_entries = {}
    local function push(text_line, entry, hlgroup)
      table.insert(lines, text_line)
      line_entries[#lines] = entry
      if hlgroup then table.insert(hl_queue, { #lines - 1, hlgroup }) end
    end

    push(string.format('  %s  (%d)', opts.title, #entries), nil, 'GitPanelHeader')
    push('', nil)

    local widths = { port = 5, proto = 3, command = 0, pid = 0 }
    for _, e in ipairs(entries) do
      widths.port = math.max(widths.port, #tostring(e.port or '?'))
      widths.proto = math.max(widths.proto, #(e.proto or ''))
      widths.command = math.max(widths.command, vim.fn.strdisplaywidth(e.command or ''))
      widths.pid = math.max(widths.pid, #tostring(e.pid or ''))
    end
    widths.command = math.min(widths.command, 24)

    local remembered_row = nil
    for _, e in ipairs(entries) do
      push(format_row(e, widths, opts.kind), e)
      local row = #lines - 1
      -- ポート番号だけ強調し、残りは淡くする（どのポートかを最初に読ませる）
      local port_end = 2 + widths.port
      table.insert(hl_queue, { row, 'GitPanelSection', 2, port_end })
      table.insert(hl_queue, { row, 'GitPanelDim', port_end, -1 })
      if cursor_mem == entry_key(e) then remembered_row = #lines end
    end
    if #entries == 0 then push('  ' .. opts.empty, nil) end

    total_rows = #lines
    ctx.set_left_lines(lines, hl_queue)

    local target = remembered_row
    if not target then
      for i = 1, total_rows do
        if line_entries[i] then target = i; break end
      end
    end
    if target then
      ctx.set_left_cursor(target)
      show_detail(line_entries[target])
    else
      show_detail(nil)
    end
  end

  function V.refresh(auto_capture)
    if auto_capture then V.remember_cursor() end
    ports.sockets(function(all)
      if ctx.current_panel_name() ~= opts.name then return end
      entries = (opts.kind == 'connections') and ports.established(all) or ports.listening(all)
      render()
    end)
  end

  --- signal: 'TERM' | 'KILL'
  local function kill(signal)
    local entry = current_entry()
    if not entry then return end
    cursor_mem = entry_key(entry)
    local label = signal == 'KILL' and '強制終了' or '終了'
    ctx.confirm(string.format('%s しますか？\n%s (PID %s)  port %s', label, entry.command, entry.pid, entry.port),
      function(ok)
        if not ok then return end
        ports.kill(entry.pid, signal, ctx.done_refresh(V.refresh, label))
      end)
  end

  --- ローカルの待ち受けポートはブラウザで開けることが多いので、その導線を持たせる
  local function open_in_browser()
    local entry = current_entry()
    if not entry then return end
    if not tonumber(entry.port) then
      vim.notify('ポート番号が特定できません', vim.log.levels.WARN)
      return
    end
    require('config.browser.util').open_url('http://localhost:' .. entry.port, { title = 'Ports' })
  end

  local function yank_port()
    local entry = current_entry()
    if not entry then return end
    local value = tostring(entry.port)
    vim.fn.setreg('"', value)
    if vim.g.clipboard ~= nil then
      vim.fn.setreg('+', value)
    end
    vim.notify('コピーしました: ' .. tostring(entry.port))
  end

  function V.keymaps()
    return vim.tbl_extend('force', {
      d = function() kill('TERM') end,
      D = function() kill('KILL') end,
      o = open_in_browser,
      y = yank_port,
    }, tabs_mod.keymaps(tabs, show_current))
  end

  function V.activate(c)
    ctx = c
    ctx.setup_cursor_clamp(
      function() return line_entries end,
      function() return total_rows end,
      function(entry)
        cursor_mem = entry_key(entry)
        show_detail(entry)
      end
    )
    V.refresh()
  end

  return V
end

return M
