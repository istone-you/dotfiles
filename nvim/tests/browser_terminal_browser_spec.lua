local T = dofile(TESTS_DIR .. '/helpers.lua')
local tb = require('config.browser.terminal_browser')
local browser = require('config.browser.util')

-- vim.system を非同期(コールバック)形で差し替え、responder(cmd) が返す応答を on_exit に渡す。
-- terminal_browser は vim.schedule 経由でチェインするので、テスト側は wait_until で回して待つ。
local function with_async_stubs(responder, fn)
  local orig_system = vim.system
  local orig_notify = vim.notify
  local orig_exec = vim.fn.executable
  local calls, notifies = {}, {}
  vim.fn.executable = function() return 1 end
  vim.notify = function(msg, level) notifies[#notifies + 1] = { msg = msg, level = level } end
  vim.system = function(cmd, _opts, on_exit)
    calls[#calls + 1] = cmd
    local res = responder(cmd) or { code = 0, stdout = '' }
    if on_exit then on_exit(res) end
    return { wait = function() return res end }
  end
  local ok, err = pcall(fn, calls, notifies)
  vim.system = orig_system
  vim.notify = orig_notify
  vim.fn.executable = orig_exec
  if not ok then error(err) end
end

local function with_herdr_env(fn)
  local saved = vim.env.HERDR_ENV
  vim.env.HERDR_ENV = '1'
  local ok, err = pcall(fn)
  vim.env.HERDR_ENV = saved
  if not ok then error(err) end
end

local function find_call(calls, pred)
  for _, c in ipairs(calls) do
    if pred(c) then return c end
  end
  return nil
end

local function is_herdr(cmd, sub, sub2)
  return cmd[1] == 'herdr' and cmd[2] == sub and (sub2 == nil or cmd[3] == sub2)
end

local function is_tb(cmd, sub)
  return cmd[1] == 'terminal-browser' and cmd[2] == sub
end

-- responder ヘルパ
local function json(tbl)
  return { code = 0, stdout = vim.json.encode(tbl) }
end
local function neighbor_with(pane_id)
  return json({ result = { neighbor = { neighbor_pane_id = pane_id } } })
end
local function neighbor_none()
  return json({ result = { neighbor = {} } }) -- neighbor_pane_id は null
end
local function ls_with(key, pane_id)
  return json({ self = { tab = 'w1:t1', pane = 'w1:p1' }, browsers = { { key = key, pane = { tab = 'w1:t1', pane = pane_id } } } })
end
--- pane process-info の応答。前面プロセスの cmdline を並べる。
local function process_info(...)
  local procs = {}
  for _, cmdline in ipairs({ ... }) do
    procs[#procs + 1] = { cmdline = cmdline, argv0 = cmdline, name = cmdline, pid = 1 }
  end
  return json({ result = { process_info = { foreground_processes = procs } } })
end
local BROWSER_PROC = '/opt/terminal-browser/bin/terminal-browser open localhost:6275'

-- ── ls --json のペイン照合 ────────────────────────────────────────────────
T.describe('terminal_browser.lua: browser_key_at', function()
  T.it('finds the browser key running in the given pane', function()
    T.eq(tb.browser_key_at(ls_with('90107-1', 'w1:p2').stdout, 'w1:p2'), '90107-1')
  end)

  T.it('returns nil when the browser is in another pane', function()
    T.eq(tb.browser_key_at(ls_with('90107-1', 'w1:p5').stdout, 'w1:p2'), nil)
  end)

  T.it('returns nil when no browser is running', function()
    local out = vim.json.encode({ self = { tab = 'w1:t1', pane = 'w1:p1' }, browsers = {} })
    T.eq(tb.browser_key_at(out, 'w1:p2'), nil)
  end)

  T.it('returns nil when the browser reports no pane', function()
    local out = vim.json.encode({ browsers = { { key = '90107-1', pane = vim.NIL } } })
    T.eq(tb.browser_key_at(out, 'w1:p2'), nil)
  end)

  T.it('returns nil for broken output or a missing pane id', function()
    T.eq(tb.browser_key_at('not json', 'w1:p2'), nil)
    T.eq(tb.browser_key_at('', 'w1:p2'), nil)
    T.eq(tb.browser_key_at(ls_with('90107-1', 'w1:p2').stdout, nil), nil)
    T.eq(tb.browser_key_at(ls_with('90107-1', 'w1:p2').stdout, ''), nil)
  end)
end)

-- ── 右ペインで開く ────────────────────────────────────────────────────────
T.describe('terminal_browser.lua: open', function()
  T.it('adds a tab to the browser already running in the right pane', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is_herdr(cmd, 'pane', 'neighbor') then return neighbor_with('w1:p2') end
        if is_herdr(cmd, 'pane', 'process-info') then return process_info(BROWSER_PROC) end
        if is_tb(cmd, 'ls') then return ls_with('90107-1', 'w1:p2') end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        local done
        tb.open('http://localhost:6275/', function(ok) done = ok end)
        T.wait_until(function() return done ~= nil end)
        T.eq(done, true)

        local new_tab = find_call(calls, function(c) return is_tb(c, 'new-tab') end)
        T.ok(new_tab ~= nil, 'new-tab を発行すること')
        T.contains(new_tab, '--browser')
        T.contains(new_tab, '90107-1')
        T.contains(new_tab, 'http://localhost:6275/')

        T.ok(find_call(calls, function(c) return is_tb(c, 'open') end) == nil, '既存ブラウザがあるなら split しない')
        T.ok(find_call(calls, function(c) return is_herdr(c, 'pane', 'focus') end) ~= nil, '右ペインへフォーカスすること')
      end)
    end)
  end)

  T.it('splits right and launches the browser when there is no right pane', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is_herdr(cmd, 'pane', 'neighbor') then return neighbor_none() end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        local done
        tb.open('http://localhost:6275/', function(ok) done = ok end)
        T.wait_until(function() return done ~= nil end)
        T.eq(done, true)

        local opened = find_call(calls, function(c) return is_tb(c, 'open') end)
        T.ok(opened ~= nil, 'open --split right を発行すること')
        T.contains(opened, '--split')
        T.contains(opened, 'right')
        T.contains(opened, 'http://localhost:6275/')

        T.ok(find_call(calls, function(c) return is_tb(c, 'ls') end) == nil, '右が無いならブラウザ一覧は引かない')
        T.ok(find_call(calls, function(c) return is_tb(c, 'new-tab') end) == nil, '再利用は試みない')
      end)
    end)
  end)

  T.it('splits right when the right pane runs something else (an agent etc.)', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is_herdr(cmd, 'pane', 'neighbor') then return neighbor_with('w1:p2') end
        if is_herdr(cmd, 'pane', 'process-info') then return process_info('nvim') end
        if is_tb(cmd, 'ls') then return ls_with('90107-1', 'w1:p9') end -- 別ペインのブラウザだけ
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        local done
        tb.open('http://localhost:6275/', function(ok) done = ok end)
        T.wait_until(function() return done ~= nil end)
        T.eq(done, true)

        T.ok(find_call(calls, function(c) return is_tb(c, 'open') end) ~= nil, '右に新しく起動すること')
        T.ok(find_call(calls, function(c) return is_tb(c, 'new-tab') end) == nil, '別ペインのブラウザは使わない')
      end)
    end)
  end)

  -- ペインを閉じてもブラウザのプロセスが残ると `ls` に残り続け、herdr 再起動で
  -- pane id が振り直されると、その古い id が実在する別のペインと衝突しうる。
  -- 自称 id だけで判定すると見えないブラウザにタブを送ってしまう。
  T.it('ignores a background browser still claiming the right pane id', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is_herdr(cmd, 'pane', 'neighbor') then return neighbor_with('w1:p2') end
        -- 右ペインで動いているのは terminal-browser ではない
        if is_herdr(cmd, 'pane', 'process-info') then return process_info('nvim') end
        -- ペインを失ったブラウザが同じ id を名乗ったまま残っている
        if is_tb(cmd, 'ls') then return ls_with('90107-1', 'w1:p2') end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        local done
        tb.open('http://localhost:6275/', function(ok) done = ok end)
        T.wait_until(function() return done ~= nil end)
        T.eq(done, true)

        T.ok(find_call(calls, function(c) return is_tb(c, 'new-tab') end) == nil, '裏で生きているブラウザには送らない')
        T.ok(find_call(calls, function(c) return is_tb(c, 'open') end) ~= nil, '右に新しく起動すること')
      end)
    end)
  end)

  T.it('splits right when the pane process cannot be inspected', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is_herdr(cmd, 'pane', 'neighbor') then return neighbor_with('w1:p2') end
        if is_herdr(cmd, 'pane', 'process-info') then return { code = 1, stdout = '', stderr = 'no such pane' } end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        local done
        tb.open('http://localhost:6275/', function(ok) done = ok end)
        T.wait_until(function() return done ~= nil end)
        T.eq(done, true)

        T.ok(find_call(calls, function(c) return is_tb(c, 'open') end) ~= nil, '判別できないなら右に新規起動する')
        T.ok(find_call(calls, function(c) return is_tb(c, 'ls') end) == nil, 'ブラウザ一覧は引かない')
      end)
    end)
  end)

  T.it('reports the error instead of notifying when terminal-browser fails', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is_herdr(cmd, 'pane', 'neighbor') then return neighbor_none() end
        if is_tb(cmd, 'open') then return { code = 1, stdout = '', stderr = 'no pane access' } end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(_calls, notifies)
        local ok, err
        tb.open('http://localhost:6275/', function(o, e)
          ok = o
          err = e
        end)
        T.wait_until(function() return ok ~= nil end)
        T.eq(ok, false)
        T.eq(err, 'no pane access')
        T.eq(#notifies, 0, '通知するかは呼び出し側の判断なのでここでは出さない')
      end)
    end)
  end)
end)

-- ── available: この経路を使う条件 ────────────────────────────────────────
T.describe('terminal_browser.lua: available', function()
  local function with_exec(map, fn)
    local orig = vim.fn.executable
    vim.fn.executable = function(name) return map[name] and 1 or 0 end
    local ok, err = pcall(fn)
    vim.fn.executable = orig
    if not ok then error(err) end
  end

  T.it('is true inside herdr when terminal-browser exists', function()
    with_herdr_env(function()
      with_exec({ herdr = true, ['terminal-browser'] = true }, function()
        T.eq(tb.available(), true)
      end)
    end)
  end)

  T.it('is false when terminal-browser is missing', function()
    with_herdr_env(function()
      with_exec({ herdr = true }, function()
        T.eq(tb.available(), false)
      end)
    end)
  end)

  T.it('is false outside a herdr session', function()
    local saved = vim.env.HERDR_ENV
    vim.env.HERDR_ENV = nil
    with_exec({ herdr = true, ['terminal-browser'] = true }, function()
      T.eq(tb.available(), false)
    end)
    vim.env.HERDR_ENV = saved
  end)
end)

-- ── open_url がこの経路に倒れるか ────────────────────────────────────────
T.describe('browser/util.lua: open_url routes through terminal-browser', function()
  local function with_open_stubs(fn)
    local orig_available = tb.available
    local orig_open = tb.open
    local orig_jobstart = vim.fn.jobstart
    local orig_notify = vim.notify
    local orig_exec = vim.fn.executable
    local jobs, notifies = {}, {}
    vim.fn.executable = function() return 1 end
    vim.fn.jobstart = function(cmd)
      jobs[#jobs + 1] = cmd
      return 1
    end
    vim.notify = function(msg, level) notifies[#notifies + 1] = { msg = msg, level = level } end
    local ok, err = pcall(fn, jobs, notifies)
    tb.available = orig_available
    tb.open = orig_open
    vim.fn.jobstart = orig_jobstart
    vim.notify = orig_notify
    vim.fn.executable = orig_exec
    if not ok then error(err) end
  end

  T.it('uses terminal-browser and skips the OS opener when available', function()
    with_open_stubs(function(jobs)
      local got
      tb.available = function() return true end
      tb.open = function(url) got = url end

      local ret = browser.open_url('http://localhost:6275/', { title = 'Ports' })
      T.eq(ret, 'http://localhost:6275/')
      T.eq(got, 'http://localhost:6275/')
      T.eq(#jobs, 0, 'open / xdg-open は起動しない')
    end)
  end)

  T.it('falls back to the OS opener when terminal-browser fails', function()
    with_open_stubs(function(jobs, notifies)
      tb.available = function() return true end
      tb.open = function(_url, cb) cb(false, 'boom') end

      browser.open_url('http://localhost:6275/', { title = 'Ports' })
      T.eq(#jobs, 1, 'OS の opener へ倒すこと')
      T.contains(jobs[1], 'http://localhost:6275/')
      T.ok(#notifies > 0, '失敗を通知すること')
    end)
  end)

  T.it('uses the OS opener when terminal-browser is not available', function()
    with_open_stubs(function(jobs)
      tb.available = function() return false end
      tb.open = function() error('should not be called') end

      browser.open_url('http://localhost:6275/', { title = 'Ports' })
      T.eq(#jobs, 1)
      T.contains(jobs[1], 'http://localhost:6275/')
    end)
  end)

  T.it('honours an explicit opener from local.lua', function()
    with_open_stubs(function(jobs)
      local orig_config = browser.config
      browser.config = function() return { opener = 'open' } end
      tb.available = function() error('should not be consulted') end

      browser.open_url('http://localhost:6275/', { title = 'Ports' })
      browser.config = orig_config
      T.eq(#jobs, 1)
      T.eq(jobs[1][1], 'open')
    end)
  end)

  T.it("opens nothing and only notifies when opener is 'none'", function()
    with_open_stubs(function(jobs, notifies)
      local orig_config = browser.config
      browser.config = function() return { opener = 'none' } end
      tb.available = function() error('should not be consulted') end

      local ret = browser.open_url('http://localhost:6275/', {
        title = 'Ports',
        fallback_message = 'Ports URL: ',
      })
      browser.config = orig_config
      T.eq(ret, 'http://localhost:6275/')
      T.eq(#jobs, 0, 'opener を起動しないこと')
      T.eq(#notifies, 1)
      T.eq(notifies[1].msg, 'Ports URL: http://localhost:6275/')
      T.eq(notifies[1].level, vim.log.levels.INFO)
    end)
  end)

  T.it("find_opener returns nil for 'none'", function()
    local orig_config = browser.config
    local orig_exec = vim.fn.executable
    browser.config = function() return { opener = 'none' } end
    vim.fn.executable = function() return 1 end
    local ok, opener = pcall(browser.find_opener)
    browser.config = orig_config
    vim.fn.executable = orig_exec
    T.ok(ok)
    T.eq(opener, nil)
  end)
end)

T.summary()
