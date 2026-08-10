local T = dofile(TESTS_DIR .. '/helpers.lua')
local herdr = require('config.herdr')
local P = herdr._private

-- vim.system を非同期(コールバック)形で差し替え、responder(cmd) が返す JSON を on_exit に
-- 渡す。open_agent は vim.schedule 経由でチェインするので、テスト側は wait_until で回して待つ。
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

local function find_call(calls, pred)
  for _, c in ipairs(calls) do
    if pred(c) then return c end
  end
  return nil
end

local function is(cmd, sub, sub2)
  return cmd[2] == sub and (sub2 == nil or cmd[3] == sub2)
end

-- responder ヘルパ: よく使う応答
local function json(tbl)
  return { code = 0, stdout = vim.json.encode(tbl) }
end
local function neighbor_with(pane_id)
  return json({ result = { neighbor = { neighbor_pane_id = pane_id } } })
end
local function neighbor_none()
  return json({ result = { neighbor = {} } }) -- neighbor_pane_id は null
end
local function pane_with_agent(pane_id, agent)
  return json({ result = { pane = { pane_id = pane_id, agent = agent } } })
end
local function split_returns(pane_id)
  return json({ result = { pane = { pane_id = pane_id } } })
end

-- テスト用に保存済みバッファを開く(location_text は現在バッファ名を使う)
local function open_saved_buffer()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/sample.lua'
  vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e' }, path)
  vim.cmd.edit(path)
  return path, dir
end

local function with_herdr_env(fn)
  local saved = vim.env.HERDR_ENV
  vim.env.HERDR_ENV = '1'
  local ok, err = pcall(fn)
  vim.env.HERDR_ENV = saved
  if not ok then error(err) end
end

-- ── ノーマル (未選択): 右ペインでエージェントを開く ──────────────────────
T.describe('herdr.lua: open agent in the right pane (normal / no selection)', function()
  T.it('just focuses the right pane when an agent already runs there', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is(cmd, 'pane', 'neighbor') then return neighbor_with('w1:pR') end
        if is(cmd, 'pane', 'get') then return pane_with_agent('w1:pR', 'codex') end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        P.open_agent('claude', 'claude') -- location 無し
        T.wait_until(function()
          return find_call(calls, function(c) return is(c, 'pane', 'focus') end) ~= nil
        end, 2000)
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'focus') end) ~= nil, 'should focus the right pane')
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'split') end) == nil, 'must not split when one exists')
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'send-text') end) == nil, 'nothing to insert')
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'run') end) == nil, 'must not launch a second agent')
      end)
    end)
  end)

  T.it('splits right and launches the chosen agent when nothing is on the right', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is(cmd, 'pane', 'neighbor') then return neighbor_none() end
        if is(cmd, 'pane', 'split') then return split_returns('w1:pNEW') end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        P.open_agent('claude', 'claude')
        T.wait_until(function()
          return find_call(calls, function(c) return is(c, 'pane', 'run') and c[4] == 'w1:pNEW' end) ~= nil
        end, 2000)
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'split') end) ~= nil, 'should split right')
        T.ok(
          find_call(calls, function(c) return is(c, 'pane', 'run') and c[4] == 'w1:pNEW' and c[5] == 'claude' end)
            ~= nil,
          'should launch the chosen agent'
        )
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'send-text') end) == nil, 'nothing to insert')
        T.ok(
          find_call(calls, function(c) return is(c, 'wait', 'agent-status') end) == nil,
          'no idle wait needed without a location'
        )
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'focus') end) ~= nil, 'should focus the new pane')
      end)
    end)
  end)
end)

-- ── ビジュアル (選択): 選択範囲の場所を右のエージェントへ挿入 ────────────
T.describe('herdr.lua: send selection location to the right pane (visual)', function()
  T.it('reuses the right neighbor when it already runs an agent', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is(cmd, 'pane', 'neighbor') then return neighbor_with('w1:pR') end
        if is(cmd, 'pane', 'get') then return pane_with_agent('w1:pR', 'codex') end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        P.open_agent('claude', 'claude', 'foo/bar.lua:2-4')
        T.wait_until(function()
          return find_call(calls, function(c) return is(c, 'pane', 'send-text') and c[4] == 'w1:pR' end) ~= nil
        end, 2000)
        local sent = find_call(calls, function(c) return is(c, 'pane', 'send-text') and c[4] == 'w1:pR' end)
        T.ok(sent ~= nil, 'should send-text into the existing right pane')
        T.ok(sent[5]:find('foo/bar.lua:2-4', 1, true) ~= nil, 'should insert the selected range location')
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'run') end) == nil, 'must not press Enter (no pane run)')
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'split') end) == nil, 'must not split when reusing')
      end)
    end)
  end)

  T.it('splits right, launches the agent, waits idle, then inserts when nothing is on the right', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is(cmd, 'pane', 'neighbor') then return neighbor_none() end
        if is(cmd, 'pane', 'split') then return split_returns('w1:pNEW') end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        P.open_agent('claude', 'claude', 'foo/bar.lua:3')
        T.wait_until(function()
          return find_call(calls, function(c) return is(c, 'pane', 'send-text') and c[4] == 'w1:pNEW' end) ~= nil
        end, 2000)
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'split') end) ~= nil, 'should split right')
        T.ok(
          find_call(calls, function(c) return is(c, 'pane', 'run') and c[4] == 'w1:pNEW' and c[5] == 'claude' end)
            ~= nil,
          'should launch the chosen agent (run with Enter)'
        )
        T.ok(
          find_call(calls, function(c) return is(c, 'wait', 'agent-status') and c[4] == 'w1:pNEW' end) ~= nil,
          'should wait for idle before inserting'
        )
        local sent = find_call(calls, function(c) return is(c, 'pane', 'send-text') and c[4] == 'w1:pNEW' end)
        T.ok(sent[5]:find('foo/bar.lua:3', 1, true) ~= nil, 'inserts the single-line location')
      end)
    end)
  end)

  T.it('splits a new pane when the right neighbor is a plain shell (no agent)', function()
    with_herdr_env(function()
      local responder = function(cmd)
        if is(cmd, 'pane', 'neighbor') then return neighbor_with('w1:pR') end
        if is(cmd, 'pane', 'get') then return pane_with_agent('w1:pR', nil) end -- agent 無し
        if is(cmd, 'pane', 'split') then return split_returns('w1:pNEW') end
        return { code = 0, stdout = '' }
      end
      with_async_stubs(responder, function(calls)
        P.open_agent('claude', 'claude', 'foo/bar.lua:1-2')
        T.wait_until(function()
          return find_call(calls, function(c) return is(c, 'pane', 'split') end) ~= nil
        end, 2000)
        T.ok(find_call(calls, function(c) return is(c, 'pane', 'split') end) ~= nil, 'should split, not reuse a shell')
      end)
    end)
  end)
end)

-- ── 共通のガード / location_text / キーマップ ────────────────────────────
T.describe('herdr.lua: guards, location text, keymaps', function()
  T.it('warns and does nothing when not inside herdr', function()
    local saved = vim.env.HERDR_ENV
    vim.env.HERDR_ENV = nil
    with_async_stubs(function() return { code = 0, stdout = '' } end, function(calls, notifies)
      P.open_agent('claude', 'claude', 'foo/bar.lua:1')
      T.eq(#calls, 0, 'must not call herdr outside herdr')
      T.ok(#notifies >= 1, 'should warn the user')
    end)
    vim.env.HERDR_ENV = saved
  end)

  T.it('location_text: single line has no range', function()
    local path, dir = open_saved_buffer()
    local loc = P.location_text(3, 3)
    T.ok(loc ~= nil)
    T.eq(loc:sub(-2), ':3', 'single line has no start-end range')
    vim.cmd('bwipeout!')
    T.rmrf(dir)
  end)

  T.it('location_text: multi line uses start-end', function()
    local path, dir = open_saved_buffer()
    local loc = P.location_text(2, 4)
    T.ok(loc ~= nil)
    T.eq(loc:sub(-4), ':2-4', 'multi line uses a range')
    vim.cmd('bwipeout!')
    T.rmrf(dir)
  end)

  T.it('location_text: nil (with warning) for an unsaved buffer', function()
    local orig_notify = vim.notify
    local notifies = {}
    vim.notify = function(msg, level) notifies[#notifies + 1] = { msg = msg, level = level } end
    vim.cmd('enew') -- 名前無しバッファ
    local loc = P.location_text(1, 1)
    vim.notify = orig_notify
    T.eq(loc, nil, 'unsaved buffer has no location')
    T.ok(#notifies >= 1, 'should warn the user')
    vim.cmd('bwipeout!')
  end)

  T.it('binds all three agents under the <leader>a namespace', function()
    T.eq(#P.agents, 3)
    local keys = {}
    for _, a in ipairs(P.agents) do keys[a.cmd] = a.key end
    T.eq(keys.claude, '<leader>ac')
    T.eq(keys.codex, '<leader>ax')
    T.eq(keys.agent, '<leader>aa')
  end)

  T.it('binds both normal and visual variants for each agent', function()
    local function has_map(mode, suffix)
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        if m.callback and m.lhs:sub(-#suffix) == suffix then return true end
      end
      return false
    end
    for _, suffix in ipairs({ 'ac', 'ax', 'aa' }) do
      T.ok(has_map('n', suffix), 'normal <leader>' .. suffix .. ' should exist')
      T.ok(has_map('x', suffix), 'visual <leader>' .. suffix .. ' should exist')
    end
  end)
end)

T.summary()
