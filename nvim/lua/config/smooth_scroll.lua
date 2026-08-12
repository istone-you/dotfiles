-- Ctrl-d / Ctrl-u のスクロールをアニメーションさせる。
-- neoscroll.nvim (karb94) のソースを読んで、その中核の考え方を借りている。
--
-- ══ neoscroll から借りたところ ══
--
-- 1. 「1 フレーム 1 行に固定し、行の間の“時間”を変える」
--    これが滑らかさの本体。位置を等間隔の時間で補間すると、速い区間で
--    1 フレーム 2〜3 行飛ぶことになり、そこで動きの対応付けが切れてカクつく。
--    neoscroll は必ず 1 行ずつ進め、代わりに次のフレームまでの待ち時間を
--    libuv の timer:set_repeat() で毎回変える（scroll.lua:compute_time_step）。
-- 2. イージング関数が「位置 → 時間」の逆関数になっている
--    neoscroll の quadratic は 1-(1-x)^(1/2) で、通常のイージング(時間→位置)の
--    逆。k 行目に進むまでの時間を duration*(ef(k/n) - ef((k-1)/n)) で出すため。
-- 3. アニメーション中はカーソルを隠す（scroll.lua:hide_cursor）
--    行ごとに動くカーソルが目に付くと、それだけで粗く見える。
-- 4. アニメーション中は WinScrolled / CursorMoved を止める
--    （config.lua:ignored_events）。
-- 5. WinLeave でアニメーションを畳む（init.lua:teardown_callback）。
--
-- ══ neoscroll と変えたところ ══
--
-- ・移動先の求め方: neoscroll は「何行動くか」を自前で計算し、fold 越えの行数
--   （window.lua:get_lines_above/below）や scrolloff・EOF での停止条件
--   （logic.lua:who_scrolls, stop_eof, respect_scrolloff, cursor_scrolls_alone）を
--   すべて自前のルールとして持っている。ここではその代わりに probe を使う。
--   素の `normal! <C-d>` を一度実行して winsaveview() で着地点だけ控え、
--   winrestview() で即座に戻す。折り返し・fold・ファイル端・[count] 指定の
--   扱いを Vim 自身に計算させるので、着地点は素の Vim と必ず一致し、
--   上記のルール群がまるごと不要になる。
-- ・1 行進める手段: neoscroll は `normal! <C-e>gj` を撃つため、折り返し行で
--   カーソルがずれるのを後から追いかけて補正している（scroll.lua:162-203）。
--   ここでは probe で終点が分かっているので、topline と lnum を同じ係数で
--   winrestview() するだけでよく、その補正が要らない。
-- ・イベントは終了時に 1 回だけ発火させる。neoscroll は止めるだけだが、
--   この設定では scrollbar.lua と context.lua が WinScrolled / CursorMoved を
--   購読しており、発火しないとスクロールバーが取り残される。
-- ・対象は Ctrl-d / Ctrl-u だけ。理由は下記。
--
-- ══ 対象を Ctrl-d / Ctrl-u に絞った理由 ══
--
-- ・新しいキーを増やさない。着地点も [count] も素の Vim と同じ
--   （Ctrl-b は herdr の prefix と衝突する）
-- ・zz / zt / zb は対象外。search / problems / todo_tree / namu / glance /
--   git_conflict / diff_review / code_notes / panel.shell が内部で
--   `normal! zz` を呼んでおり、ジャンプ系機能すべてが二段階の動きになる
-- ・ホイールは触らない。mousescroll=ver:1 で既に 1 行単位

require('config.hidden_cursor') -- HiddenCursor ハイライト群の定義を先に済ませる
local win_util = require('config.util.win_util')

local M = {}

local uv = vim.uv or vim.loop

-- ── チューニング ──
local MS_PER_LINE = 14   -- 1 行あたりの目安時間(ms)
local MIN_DURATION = 70  -- アニメーション全体の下限(ms)
local MAX_DURATION = 220 -- 上限(ms)
local MIN_STEP = 6       -- 1 ステップの下限(ms)。これを割るならステップ数を減らす
local MIN_TRAVEL = 2     -- これ以下の移動行数はアニメーションせず即座に飛ぶ
local HIDE_CURSOR = true -- アニメーション中はカーソルを隠す

-- イージング。neoscroll と同じく「進んだ行の割合 x → 経過時間の割合」を返す
-- 逆関数であることに注意（通常のイージングの向きではない）。
-- nil にすると等速（neoscroll の既定も "linear" = 等速）。
--   等速  : 全ステップが同じ間隔。素直で、終わりに溜めがない
--   減速系: 出だしが速く着地でゆっくり止まる。ただし最後の 1 行に
--           全体の 3 割ほど時間を使うので「粘る」感じになる
local EASING = nil

M.easing = {
  quadratic = function(x) return 1 - (1 - x) ^ (1 / 2) end,
  cubic = function(x) return 1 - (1 - x) ^ (1 / 3) end,
  quartic = function(x) return 1 - (1 - x) ^ (1 / 4) end,
  sine = function(x) return 2 * math.asin(x) / math.pi end,
}

-- アニメーション中に止めるイベント。これは最適化ではなく機能要件で、
-- scrollbar.lua と context.lua が購読しているため、毎ステップ再描画が走ると
-- ステップ間隔が乱れて「滑らかにする」目的そのものが壊れる。
local SUPPRESSED = { 'WinScrolled', 'CursorMoved', 'CursorMovedI' }

-- キーマップの lhs -> `normal!` に渡す生のバイト列。
-- `normal!` は `<C-d>` という表記を解釈しないので制御文字そのものを渡す
M.KEYS = {
  ['<C-d>'] = '\004',
  ['<C-u>'] = '\021',
}

-- ══════════════════════════════════════════════
-- 純粋関数
-- ══════════════════════════════════════════════

--- 移動行数からステップ数（＝実際に描くコマ数）を決める。
--- 原則 1 コマ 1 行だが、1 ステップが MIN_STEP を割るほど長い移動のときだけ
--- コマ数を間引く（端末が追いつかないので粒度を上げても意味がない）
function M.steps_for(travel)
  if travel <= 0 then return 0 end
  local max_steps = math.floor(M.duration_for(travel) / MIN_STEP)
  return math.max(1, math.min(travel, max_steps))
end

--- 移動行数からアニメーション全体の長さ(ms)を決める
function M.duration_for(travel)
  return math.max(MIN_DURATION, math.min(MAX_DURATION, travel * MS_PER_LINE))
end

--- k 番目(1 始まり)のステップの待ち時間(ms)。
--- neoscroll scroll.lua:compute_time_step と同じ考え方で、イージング関数
--- （位置→時間）の差分を取る。等速なら duration/steps。
function M.time_step(k, steps, duration, easing)
  if steps < 1 then return duration end
  local ef = M.easing[easing or '']
  local ms
  if not ef then
    ms = duration / steps
  else
    ms = duration * (ef(k / steps) - ef((k - 1) / steps))
  end
  return math.max(1, math.floor(ms + 0.5))
end

local function lerp(a, b, c)
  return math.floor(a + (b - a) * c + 0.5)
end

-- topline と lnum を同じ係数で進める。横方向とカーソル桁は途中で動かす意味が
-- ないので終点の値をそのまま使う
function M.interpolate(from, to, c)
  return {
    topline = lerp(from.topline, to.topline, c),
    lnum = lerp(from.lnum, to.lnum, c),
    col = to.col,
    coladd = to.coladd,
    curswant = to.curswant,
    leftcol = to.leftcol,
    skipcol = to.skipcol,
  }
end

-- 2 つの view の隔たり。topline と lnum の大きい方を移動行数とみなす
-- （ファイル末尾では topline が動かず lnum だけ動くケースがある）
function M.distance(from, to)
  return math.max(math.abs(to.topline - from.topline), math.abs(to.lnum - from.lnum))
end

-- ══════════════════════════════════════════════
-- アニメーション状態
-- ══════════════════════════════════════════════

-- 同時に走るアニメーションは 1 本だけ。Ctrl-d はカレントウィンドウに対する
-- 操作なので、複数ウィンドウが同時にアニメーションすることはない。
-- タイマーは neoscroll と同じくモジュール寿命で 1 個だけ持ち、start/stop で
-- 使い回す（毎回 new_timer/close すると閉じ忘れと二重 close の危険がある）
local timer = uv.new_timer()
local state = nil
local saved_eventignore = nil
local saved_guicursor = nil

local function suppress_events()
  if saved_eventignore ~= nil then return end
  saved_eventignore = vim.o.eventignore
  vim.opt.eventignore:append(SUPPRESSED)
end

local function restore_events()
  if saved_eventignore == nil then return end
  vim.o.eventignore = saved_eventignore
  saved_eventignore = nil
end

-- カーソルを隠す。guicursor はグローバルオプションで hidden_cursor.lua も
-- 触るため、戻すときは「自分が入れた値のままか」を必ず確認する
local function hide_cursor()
  if not HIDE_CURSOR then return end
  if saved_guicursor ~= nil then return end
  if not vim.o.termguicolors or vim.o.guicursor == '' then return end
  if vim.o.guicursor == 'a:HiddenCursor' then return end -- 既に hidden_cursor が隠している
  saved_guicursor = vim.o.guicursor
  vim.o.guicursor = 'a:HiddenCursor'
end

local function unhide_cursor()
  if saved_guicursor == nil then return end
  if vim.o.guicursor == 'a:HiddenCursor' then
    vim.o.guicursor = saved_guicursor
  end
  saved_guicursor = nil
end

local function fire_events(win, buf)
  if not vim.api.nvim_win_is_valid(win) then return end
  pcall(vim.api.nvim_exec_autocmds, 'WinScrolled', {
    pattern = tostring(win),
    modeline = false,
  })
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_exec_autocmds, 'CursorMoved', { buffer = buf, modeline = false })
  end
end

local function apply(win, view)
  if not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(view)
  end)
end

-- タイマー由来の表示変更は redraw しないと画面に出ない。
-- ただし headless(nvim -l)で呼ぶとテストの標準出力を消してしまうので、
-- UI が繋がっている時だけ実行する
local function redraw()
  if #vim.api.nvim_list_uis() == 0 then return end
  vim.cmd('redraw')
end

local function stop(opts)
  local s = state
  state = nil
  timer:stop()
  unhide_cursor()
  restore_events()
  if not s then return end
  if not (opts and opts.silent) then
    fire_events(s.win, s.buf)
  end
end

local function frame()
  local s = state
  if not s then return end
  -- ウィンドウが閉じた・別バッファに差し替わったら、その場で打ち切る
  if not vim.api.nvim_win_is_valid(s.win) or vim.api.nvim_win_get_buf(s.win) ~= s.buf then
    stop({ silent = true })
    return
  end

  s.step = s.step + 1
  apply(s.win, M.interpolate(s.from, s.to, s.step / s.steps))
  redraw()

  if s.step >= s.steps then
    stop()
    return
  end
  -- libuv の set_repeat は「今スケジュール済みの次回」には効かず、その次から
  -- 効く。つまりここで指定できるのは step+2 の待ち時間（neoscroll が
  -- time_step / next_time_step / next_next_time_step と 3 つ先読みするのと同じ理由）
  timer:set_repeat(M.time_step(s.step + 2, s.steps, s.duration, s.easing))
end

-- タイマーコールバックで例外が出ても必ず後始末する（eventignore や guicursor を
-- 戻し損ねると、以降 scrollbar が一切更新されない・カーソルが消えたままになる）
local function safe_frame()
  local ok, err = pcall(frame)
  if not ok then
    stop({ silent = true })
    vim.notify('smooth_scroll: ' .. tostring(err), vim.log.levels.WARN)
  end
end

local function start_animation(win, buf, from, to)
  stop({ silent = true })
  local travel = M.distance(from, to)
  local steps = M.steps_for(travel)
  local duration = M.duration_for(travel)

  suppress_events()
  hide_cursor()
  state = {
    win = win,
    buf = buf,
    from = from,
    to = to,
    steps = steps,
    step = 0,
    duration = duration,
    easing = EASING,
  }
  timer:start(
    M.time_step(1, steps, duration, EASING),
    M.time_step(2, steps, duration, EASING),
    vim.schedule_wrap(safe_frame)
  )
  timer:set_repeat(M.time_step(3, steps, duration, EASING))
end

function M.is_animating()
  return state ~= nil
end

-- ══════════════════════════════════════════════
-- probe
-- ══════════════════════════════════════════════

-- base の位置から keys を素で実行し、着地点だけを取って元の表示に戻す。
-- 戻り値は着地点の view（実行できなければ nil）
function M.probe(win, base, keys)
  local to
  vim.api.nvim_win_call(win, function()
    local shown = vim.fn.winsaveview()
    if base then vim.fn.winrestview(base) end
    local ok = pcall(vim.cmd.normal, { keys, bang = true })
    if ok then to = vim.fn.winsaveview() end
    vim.fn.winrestview(shown)
  end)
  return to
end

-- ══════════════════════════════════════════════
-- 入口
-- ══════════════════════════════════════════════

-- アニメーションさせずに素通しすべき状況か
local function should_bypass(win)
  -- マクロ実行中は待たされるのが実害になる（@q の中で何十回も止まる）
  if vim.fn.reg_executing() ~= '' then return true end
  if win_util.is_float(win) or win_util.is_sidebar(win) then return true end
  return false
end

-- raw は M.KEYS の値（制御文字そのもの）
function M.scroll(raw)
  local count = vim.v.count
  local cmd = (count > 0 and tostring(count) or '') .. raw
  local win = vim.api.nvim_get_current_win()

  if should_bypass(win) then
    pcall(vim.cmd.normal, { cmd, bang = true })
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local shown = vim.fn.winsaveview()
  -- 連打時は「今表示されている位置」ではなく「前回の着地点」から次の目標を
  -- 計算する。こうしないとアニメーション中の中途半端な位置が起点になり、
  -- 押した回数ぶん進まなくなる
  local base = (state and state.win == win and state.buf == buf) and state.to or shown

  local to = M.probe(win, base, cmd)
  if not to then
    stop({ silent = true })
    return
  end

  if M.distance(shown, to) <= MIN_TRAVEL then
    stop({ silent = true })
    apply(win, to)
    fire_events(win, buf)
    return
  end

  start_animation(win, buf, shown, to)
end

function M.setup()
  for key, raw in pairs(M.KEYS) do
    vim.keymap.set({ 'n', 'x' }, key, function()
      M.scroll(raw)
    end, { silent = true, desc = 'スムーズスクロール ' .. key })
  end

  -- 別ウィンドウへ移ったらアニメーションを畳む（neoscroll init.lua と同じ）。
  -- 畳まないと、フォーカスの無い窓を裏で動かし続けることになる
  vim.api.nvim_create_autocmd('WinLeave', {
    group = vim.api.nvim_create_augroup('SmoothScrollTearDown', { clear = true }),
    callback = function()
      if state then stop() end
    end,
  })
end

M.setup()

return M
