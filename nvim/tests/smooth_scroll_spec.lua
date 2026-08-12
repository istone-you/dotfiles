local T = dofile(TESTS_DIR .. '/helpers.lua')
local smooth = require('config.smooth_scroll')

local RAW = smooth.KEYS['<C-d>']
local RAW_U = smooth.KEYS['<C-u>']

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

--- 行数 n のバッファを 1 行目表示の状態で用意する
local function setup_buf(n)
  vim.cmd('silent! only')
  vim.cmd('enew!')
  local lines = {}
  for i = 1, (n or 500) do
    lines[i] = 'line ' .. i
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  -- 前のテストの [count]<C-d> を引きずらないよう 'scroll' を既定値（半画面）へ戻す。
  -- 0 を入れてはいけない。:set scroll=0 も :set scroll& も 0 のまま残り、
  -- その状態の <C-d> は 0 行しかスクロールしなくなる
  vim.wo.scroll = math.floor(vim.api.nvim_win_get_height(0) / 2)
  vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
  return vim.api.nvim_get_current_buf()
end

local function wait_done()
  vim.wait(3000, function() return not smooth.is_animating() end, 5)
end

--- start の位置から cmd を素で実行した着地点を取り、start に戻して返す
local function raw_landing(start, cmd)
  vim.fn.winrestview(start)
  pcall(vim.cmd.normal, { cmd, bang = true })
  local v = vim.fn.winsaveview()
  vim.fn.winrestview(start)
  return v
end

T.describe('smooth_scroll', function()
  -- ══════════════════════════════════════════════
  T.describe('duration_for', function()
    T.it('短い距離は下限に張り付く', function()
      T.eq(smooth.duration_for(1), 70)
      T.eq(smooth.duration_for(0), 70)
    end)

    T.it('長い距離は上限に張り付く', function()
      T.eq(smooth.duration_for(100), 220)
      T.eq(smooth.duration_for(1000), 220)
    end)

    T.it('中間では 1 行あたり一定時間で伸びる', function()
      T.eq(smooth.duration_for(10), 140)
      T.ok(smooth.duration_for(11) > smooth.duration_for(10))
    end)
  end)

  -- ══════════════════════════════════════════════
  -- neoscroll から借りた中核。1 コマ 1 行に固定して、行の間の時間を変える
  T.describe('steps_for', function()
    T.it('現実的な移動距離では 1 コマ 1 行になる', function()
      for _, travel in ipairs({ 3, 5, 11, 15, 22, 30 }) do
        T.eq(smooth.steps_for(travel), travel,
          ('%d 行の移動は %d コマ（1 コマ 1 行）であること'):format(travel, travel))
      end
    end)

    T.it('1 コマが短くなりすぎる長距離だけコマ数を間引く', function()
      -- duration は 220ms 上限、1 コマの下限は 6ms なので 36 コマが限界
      T.eq(smooth.steps_for(37), 36)
      T.eq(smooth.steps_for(200), 36)
    end)

    T.it('移動が無ければ 0 コマ', function()
      T.eq(smooth.steps_for(0), 0)
    end)
  end)

  -- ══════════════════════════════════════════════
  T.describe('time_step', function()
    T.it('等速なら全コマが同じ間隔になる', function()
      local steps, dur = 10, 140
      for k = 1, steps do
        T.eq(smooth.time_step(k, steps, dur, nil), 14)
      end
    end)

    T.it('イージング指定時は合計がほぼ duration に一致する', function()
      for name in pairs(smooth.easing) do
        local steps, dur = 11, 154
        local total = 0
        for k = 1, steps do
          total = total + smooth.time_step(k, steps, dur, name)
        end
        T.ok(math.abs(total - dur) <= steps,
          ('%s: 合計 %d が duration %d から離れすぎ'):format(name, total, dur))
      end
    end)

    T.it('減速系のイージングではコマ間隔が単調に伸びる', function()
      local steps, dur = 11, 154
      local prev = 0
      for k = 1, steps do
        local ms = smooth.time_step(k, steps, dur, 'quadratic')
        T.ok(ms >= prev, ('コマ %d の間隔 %d が前コマ %d より短い'):format(k, ms, prev))
        prev = ms
      end
      T.ok(smooth.time_step(steps, steps, dur, 'quadratic')
        > smooth.time_step(1, steps, dur, 'quadratic') * 3,
        '出だしが速く着地が遅いこと')
    end)

    T.it('0 ms のコマは作らない（タイマーが暴走する）', function()
      for k = 1, 40 do
        T.ok(smooth.time_step(k, 40, 70, 'quartic') >= 1)
      end
    end)
  end)

  -- ══════════════════════════════════════════════
  T.describe('interpolate', function()
    T.it('端点は from / to に一致する', function()
      local from = { topline = 10, lnum = 20 }
      local to = { topline = 40, lnum = 50 }
      local a = smooth.interpolate(from, to, 0)
      T.eq(a.topline, 10)
      T.eq(a.lnum, 20)
      local b = smooth.interpolate(from, to, 1)
      T.eq(b.topline, 40)
      T.eq(b.lnum, 50)
    end)

    T.it('topline と lnum を同じ係数で進める', function()
      local mid = smooth.interpolate({ topline = 0, lnum = 0 }, { topline = 100, lnum = 200 }, 0.5)
      T.eq(mid.topline, 50)
      T.eq(mid.lnum, 100)
    end)

    T.it('topline が動かない場合でも lnum だけ進む（ファイル末尾のケース）', function()
      local mid = smooth.interpolate({ topline = 90, lnum = 95 }, { topline = 90, lnum = 100 }, 0.5)
      T.eq(mid.topline, 90)
      T.eq(mid.lnum, 98)
    end)

    T.it('横方向とカーソル桁は終点の値をそのまま使う', function()
      local from = { topline = 1, lnum = 1, col = 0, leftcol = 0, curswant = 0, coladd = 0, skipcol = 0 }
      local to = { topline = 50, lnum = 50, col = 7, leftcol = 3, curswant = 7, coladd = 1, skipcol = 2 }
      local mid = smooth.interpolate(from, to, 0.5)
      T.eq(mid.col, 7)
      T.eq(mid.leftcol, 3)
      T.eq(mid.curswant, 7)
      T.eq(mid.coladd, 1)
      T.eq(mid.skipcol, 2)
    end)

    -- これが滑らかさの本体。1 コマで 2 行以上飛ぶと動きの対応付けが切れて
    -- カクついて見える（旧実装は等間隔のコマで位置を補間していたため飛んでいた）
    T.it('steps_for のコマ数で刻めば 1 コマ 1 行しか動かない', function()
      for _, travel in ipairs({ 3, 5, 11, 22, 30 }) do
        local from = { topline = 1, lnum = 1 }
        local to = { topline = 1 + travel, lnum = 1 + travel }
        local steps = smooth.steps_for(travel)
        local prev = 1
        for k = 1, steps do
          local v = smooth.interpolate(from, to, k / steps)
          T.ok(v.topline - prev <= 1,
            ('travel=%d のコマ %d で %d 行飛んだ'):format(travel, k, v.topline - prev))
          prev = v.topline
        end
        T.eq(prev, to.topline, '最後のコマで終点に到達すること')
      end
    end)
  end)

  -- ══════════════════════════════════════════════
  T.describe('distance', function()
    T.it('topline と lnum の移動量の大きい方を返す', function()
      T.eq(smooth.distance({ topline = 1, lnum = 1 }, { topline = 11, lnum = 31 }), 30)
      T.eq(smooth.distance({ topline = 1, lnum = 1 }, { topline = 41, lnum = 31 }), 40)
    end)

    T.it('向きに関係なく正の値を返す', function()
      T.eq(smooth.distance({ topline = 50, lnum = 50 }, { topline = 20, lnum = 20 }), 30)
    end)

    T.it('同じ位置なら 0', function()
      T.eq(smooth.distance({ topline = 5, lnum = 5 }, { topline = 5, lnum = 5 }), 0)
    end)
  end)

  -- ══════════════════════════════════════════════
  -- neoscroll は移動行数・fold 越え・scrolloff・EOF 停止をすべて自前で
  -- 計算している（window.lua / logic.lua）。ここでは probe で Vim に計算させる
  T.describe('probe', function()
    T.it('素の normal! と同じ着地点を返す', function()
      setup_buf(500)
      local win = vim.api.nvim_get_current_win()
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, RAW)

      local got = smooth.probe(win, start, RAW)
      T.eq(got.topline, expected.topline, 'topline が素の <C-d> と一致すること')
      T.eq(got.lnum, expected.lnum, 'lnum が素の <C-d> と一致すること')
    end)

    T.it('probe しても表示位置は動かない', function()
      setup_buf(500)
      local win = vim.api.nvim_get_current_win()
      local before = vim.fn.winsaveview()
      smooth.probe(win, before, RAW)
      local after = vim.fn.winsaveview()
      T.eq(after.topline, before.topline)
      T.eq(after.lnum, before.lnum)
    end)

    T.it('base で渡した位置を起点に計算する（表示位置とは独立）', function()
      setup_buf(500)
      local win = vim.api.nvim_get_current_win()
      local base = { topline = 200, lnum = 205, col = 0 }
      local expected = raw_landing(base, RAW)
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })

      local got = smooth.probe(win, base, RAW)
      T.eq(got.topline, expected.topline, '表示位置ではなく base から計算されること')
      T.eq(vim.fn.winsaveview().topline, 1, '表示位置は先頭のままであること')
    end)

    T.it('ファイル先頭で <C-u> しても落ちない', function()
      setup_buf(500)
      local win = vim.api.nvim_get_current_win()
      local got = smooth.probe(win, vim.fn.winsaveview(), RAW_U)
      T.ok(got ~= nil, '先頭でも view を返すこと')
      T.eq(got.topline, 1)
    end)

    T.it('折りたたみを越えても素と着地点が一致する', function()
      setup_buf(500)
      vim.wo.foldmethod = 'manual'
      vim.cmd('normal! zE')
      vim.cmd('5,40fold')
      local win = vim.api.nvim_get_current_win()
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, RAW)

      local got = smooth.probe(win, start, RAW)
      T.eq(got.topline, expected.topline, 'fold 越えの行数計算を自前で持たなくても一致すること')
      T.eq(got.lnum, expected.lnum)
      vim.cmd('normal! zE')
      vim.wo.foldmethod = 'manual'
    end)

    T.it('scrolloff が大きくても素と着地点が一致する', function()
      setup_buf(500)
      vim.wo.scrolloff = 8
      local win = vim.api.nvim_get_current_win()
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, RAW)

      local got = smooth.probe(win, start, RAW)
      T.eq(got.topline, expected.topline)
      T.eq(got.lnum, expected.lnum)
      vim.wo.scrolloff = 0
    end)
  end)

  -- ══════════════════════════════════════════════
  T.describe('scroll', function()
    T.it('最終的な着地点が素の <C-d> と一致する', function()
      setup_buf(500)
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, RAW)

      smooth.scroll(RAW)
      wait_done()
      T.eq(vim.fn.winsaveview().topline, expected.topline)
      T.eq(vim.fn.winsaveview().lnum, expected.lnum)
    end)

    T.it('最終的な着地点が素の <C-u> と一致する', function()
      setup_buf(500)
      vim.fn.winrestview({ topline = 200, lnum = 205, col = 0 })
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, RAW_U)

      smooth.scroll(RAW_U)
      wait_done()
      T.eq(vim.fn.winsaveview().topline, expected.topline)
      T.eq(vim.fn.winsaveview().lnum, expected.lnum)
    end)

    T.it('アニメーション中は途中の位置を通る', function()
      setup_buf(500)
      local start = vim.fn.winsaveview()
      local final = raw_landing(start, RAW)

      smooth.scroll(RAW)
      T.ok(smooth.is_animating(), '呼んだ直後はアニメーション中であること')

      local mid
      vim.wait(400, function()
        local v = vim.fn.winsaveview()
        if v.topline > start.topline and v.topline < final.topline then
          mid = v.topline
          return true
        end
        return not smooth.is_animating()
      end, 2)
      wait_done()

      T.ok(mid ~= nil, '始点と終点の間の topline が観測されること（即座に飛んでいない）')
      T.eq(vim.fn.winsaveview().topline, final.topline, '最終位置は素の <C-d> と同じ')
    end)

    T.it('移動距離が小さいときはアニメーションせず即座に飛ぶ', function()
      setup_buf(500)
      vim.fn.winrestview({ topline = 500, lnum = 500, col = 0 })
      smooth.scroll(RAW)
      T.ok(not smooth.is_animating(), '短距離ではタイマーを回さないこと')
    end)

    T.it('連打しても押した回数ぶん進む', function()
      setup_buf(500)
      local start = vim.fn.winsaveview()
      vim.fn.winrestview(start)
      pcall(vim.cmd.normal, { RAW, bang = true })
      pcall(vim.cmd.normal, { RAW, bang = true })
      local expected = vim.fn.winsaveview()
      vim.fn.winrestview(start)

      smooth.scroll(RAW)
      smooth.scroll(RAW) -- 1 回目のアニメーション中に 2 回目
      wait_done()

      T.eq(vim.fn.winsaveview().topline, expected.topline,
        '中途半端な位置ではなく前回の着地点を起点にすること')
      T.eq(vim.fn.winsaveview().lnum, expected.lnum)
    end)

    T.it('別バッファに差し替わったらアニメーションを打ち切る', function()
      setup_buf(500)
      smooth.scroll(RAW)
      T.ok(smooth.is_animating())

      vim.cmd('enew!')
      vim.wait(500, function() return not smooth.is_animating() end, 5)
      T.ok(not smooth.is_animating(), 'バッファが変わったら止まること')
      T.eq(vim.o.eventignore, '', 'eventignore が戻っていること')
    end)

    -- neoscroll init.lua の WinLeave teardown と同じ
    T.it('別ウィンドウへ移ったらアニメーションを畳む', function()
      setup_buf(500)
      vim.cmd('split')
      vim.cmd('wincmd j')
      smooth.scroll(RAW)
      T.ok(smooth.is_animating())

      vim.cmd('wincmd k')
      T.ok(not smooth.is_animating(), 'フォーカスが外れたら止まること')
      T.eq(vim.o.eventignore, '', 'eventignore が戻っていること')
      vim.cmd('silent! only')
    end)
  end)

  -- ══════════════════════════════════════════════
  T.describe('イベント抑制', function()
    T.it('アニメーション中は WinScrolled / CursorMoved を止める', function()
      setup_buf(500)
      vim.o.eventignore = ''
      smooth.scroll(RAW)
      T.contains(vim.o.eventignore, 'WinScrolled')
      T.contains(vim.o.eventignore, 'CursorMoved')
      T.contains(vim.o.eventignore, 'CursorMovedI')
      wait_done()
      T.eq(vim.o.eventignore, '', '終了後は元に戻すこと')
    end)

    T.it('元の eventignore の値を壊さない', function()
      setup_buf(500)
      vim.o.eventignore = 'BufWritePost'
      smooth.scroll(RAW)
      T.contains(vim.o.eventignore, 'BufWritePost', '元の指定を残したまま追加すること')
      T.contains(vim.o.eventignore, 'WinScrolled')
      wait_done()
      T.eq(vim.o.eventignore, 'BufWritePost')
      vim.o.eventignore = ''
    end)

    -- neoscroll は止めるだけだが、この設定では scrollbar.lua が取り残されるので
    -- 終了時に 1 回だけ発火させる
    T.it('WinScrolled は途中では飛ばず終了時に 1 回だけ発火する', function()
      setup_buf(500)
      vim.o.eventignore = ''
      local count = 0
      local group = vim.api.nvim_create_augroup('SmoothScrollSpec', { clear = true })
      vim.api.nvim_create_autocmd('WinScrolled', {
        group = group,
        callback = function() count = count + 1 end,
      })

      smooth.scroll(RAW)
      vim.wait(40, function() return false end, 10)
      T.eq(count, 0, 'アニメーション中は抑制されること')

      wait_done()
      T.eq(count, 1, '終了時にちょうど 1 回だけ発火すること')
      vim.api.nvim_del_augroup_by_id(group)
    end)

    T.it('短距離で即座に飛んだ場合も 1 回発火する', function()
      setup_buf(500)
      vim.o.eventignore = ''
      local count = 0
      local group = vim.api.nvim_create_augroup('SmoothScrollSpec', { clear = true })
      vim.api.nvim_create_autocmd('WinScrolled', {
        group = group,
        callback = function() count = count + 1 end,
      })

      vim.fn.winrestview({ topline = 500, lnum = 500, col = 0 })
      smooth.scroll(RAW)
      T.eq(count, 1, '即座パスでも scrollbar 等が更新されること')
      vim.api.nvim_del_augroup_by_id(group)
    end)
  end)

  -- ══════════════════════════════════════════════
  -- neoscroll scroll.lua:hide_cursor と同じ。行ごとに動くカーソルが目に付くと
  -- それだけで粗く見える
  T.describe('カーソル退避', function()
    T.it('アニメーション中はカーソルを隠し、終了後に戻す', function()
      setup_buf(500)
      vim.o.termguicolors = true
      vim.o.guicursor = 'n-v-c:block'

      smooth.scroll(RAW)
      T.eq(vim.o.guicursor, 'a:HiddenCursor', 'アニメーション中は隠すこと')
      wait_done()
      T.eq(vim.o.guicursor, 'n-v-c:block', '元の guicursor に戻すこと')
    end)

    T.it('hidden_cursor が既に隠している窓では guicursor を触らない', function()
      setup_buf(500)
      vim.o.termguicolors = true
      vim.o.guicursor = 'a:HiddenCursor' -- hidden_cursor.lua が設定した状態

      smooth.scroll(RAW)
      wait_done()
      T.eq(vim.o.guicursor, 'a:HiddenCursor', '他所の設定を勝手に戻さないこと')
      vim.o.guicursor = 'n-v-c:block'
    end)

    T.it('termguicolors が無効なら触らない', function()
      setup_buf(500)
      vim.o.termguicolors = false
      vim.o.guicursor = 'n-v-c:block'

      smooth.scroll(RAW)
      T.eq(vim.o.guicursor, 'n-v-c:block')
      wait_done()
      T.eq(vim.o.guicursor, 'n-v-c:block')
      vim.o.termguicolors = true
    end)
  end)

  -- ══════════════════════════════════════════════
  T.describe('キーマップ', function()
    local function mapped(mode, lhs)
      local want = vim.api.nvim_replace_termcodes(lhs, true, true, true)
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        if vim.api.nvim_replace_termcodes(m.lhs, true, true, true) == want then return m end
      end
      return nil
    end

    T.it('<C-d> / <C-u> を normal と visual に張る', function()
      for _, lhs in ipairs({ '<C-d>', '<C-u>' }) do
        T.ok(mapped('n', lhs) ~= nil, lhs .. ' が normal に張られていること')
        T.ok(mapped('x', lhs) ~= nil, lhs .. ' が visual に張られていること')
      end
    end)

    -- insert の <C-d> はインデント削除、<C-u> は行削除なので上書きしてはいけない。
    -- ただし Neovim 標準で imap <C-U> -> <C-G>u<C-U> が張られているため、
    -- 「マッピングが無い」ではなく「自分のマッピングではない」を確認する
    T.it('insert モードには張らない', function()
      for _, lhs in ipairs({ '<C-d>', '<C-u>' }) do
        local m = mapped('i', lhs)
        if m then
          T.ok(not tostring(m.desc or ''):find('スムーズスクロール', 1, true),
            lhs .. ' を insert に張ってはいけない')
        end
      end
    end)

    T.it('対象は <C-d> / <C-u> の 2 つだけ', function()
      local keys = vim.tbl_keys(smooth.KEYS)
      table.sort(keys)
      T.eq(keys, { '<C-d>', '<C-u>' })
    end)

    T.it('キーを押すとアニメーションが始まり素の <C-d> と同じ位置に着地する', function()
      setup_buf(500)
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, RAW)

      feed('<C-d>')
      wait_done()
      T.eq(vim.fn.winsaveview().topline, expected.topline)
      T.eq(vim.fn.winsaveview().lnum, expected.lnum)
    end)

    T.it('[count]<C-d> は素と同じく scroll オプションを書き換える', function()
      setup_buf(500)
      local half = math.floor(vim.api.nvim_win_get_height(0) / 2)
      T.eq(vim.wo.scroll, half, '前提として半画面ぶんになっていること')
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, '5' .. RAW)

      vim.wo.scroll = half
      feed('5<C-d>')
      wait_done()
      T.eq(vim.fn.winsaveview().topline, expected.topline, 'count 付きの着地点が素と一致すること')
      T.eq(vim.wo.scroll, 5, "'scroll' が 5 に書き換わること（素の Vim の仕様）")

      local before = vim.fn.winsaveview().topline
      feed('<C-d>')
      wait_done()
      T.eq(vim.fn.winsaveview().topline - before, 5)
    end)
  end)

  -- ══════════════════════════════════════════════
  T.describe('素通し', function()
    T.it('サイドバー窓ではアニメーションしない', function()
      setup_buf(500)
      vim.bo.filetype = 'explorer' -- win_util.SIDEBAR_FT に含まれる
      local start = vim.fn.winsaveview()
      local expected = raw_landing(start, RAW)

      smooth.scroll(RAW)
      T.ok(not smooth.is_animating(), 'サイドバーはタイマーを回さないこと')
      T.eq(vim.fn.winsaveview().topline, expected.topline, 'それでもスクロールはすること')
      vim.bo.filetype = ''
    end)
  end)
end)

T.summary()
