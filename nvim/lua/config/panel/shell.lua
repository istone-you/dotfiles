-- gitパネル / dockerパネル共通の「パネルシェル」。
-- 元々 git_panel/init.lua が抱えていた汎用部分（レイアウト計算・タブバー・左一覧＋
-- 右プレビュー＋下部コマンドログの3ペイン・拡大トグル・自動更新・クリック処理・
-- ハイライト定義）をここへ切り出し、gitパネルとdockerパネルが同じコードを使うことで
-- 「全く同じ見た目・同じ操作感」を保証する。
-- lazygit / lazydocker が同じ作者・同じUIフレームワーク(gocui)で見た目を揃えているのと同じ考え方。
--
-- 使う側(config/git_panel/init.lua, config/docker_panel/init.lua)は
-- shell.new(cfg) でインスタンスを作り、cfgで「どのパネル一覧を出すか」「コマンド実行層は何か」
-- 「固有のグローバルキーは何か」だけを与える。
--
-- 各パネルモジュール(files.lua / containers.lua など)に渡る ctx のAPIはここで一本化されており、
-- gitパネル用に書かれたモジュールとdockerパネル用のモジュールは全く同じ規約で書ける:
--   ctx.set_left_lines / set_left_cursor / set_right_lines / set_right_ansi / set_right_diff
--   ctx.confirm / input / suggest_input / multiline_input / menu
--   ctx.current_entry / setup_cursor_clamp / done_refresh / set_loading / clear_loading

local ui = require('config.panel.ui')
local ansi_view = require('config.panel.ansi_view')
local hidden_cursor = require('config.hidden_cursor')

local M = {}

--- lazygit(pkg/gui/background.go)は10秒ごとのFiles再取得+2秒ごとの外部変更検知(reflog等)
--- を別々のタイマーで走らせているが、こちらは常に1パネルだけを表示する構成なので
--- 「表示中のパネルを2秒おきに再取得」だけに単純化して同じ体感（外部での操作が
--- 自動的に反映される）を再現する
local DEFAULT_AUTO_REFRESH_INTERVAL_MS = 2000

--- cfg:
---   id                 … 'git' / 'docker'。augroup名・namespace名の既定値に使う
---   augroup / hl_namespace … 名前を明示指定したい時（既存テストとの互換のため）
---   panels             … { { key, name, title, mod }, ... }
---   left_filetype      … 左ペインのfiletype（既定 'gitpanel'）
---   right_win_var      … 右ペイン特定用のwindow-local変数名
---   review_tree_win_var… レビューツリー特定用のwindow-local変数名
---   command_log()      … コマンドログ(文字列配列)を返す
---   set_log_hook(fn)   … コマンドログ更新時に呼ばれるフックを差し込む
---   start(cb)          … パネルを開いた直後の前提チェック。cb(ok) でokがfalseなら閉じる
---   get_root()         … ctx.get_root() が返す値（gitはリポジトリルート）
---   auto_refresh_ms    … 自動更新間隔（既定2000。falseで無効）
---   diff               … { available(), run(text, width, cb), split_files(raw)?,
---                          toggle_side_by_side()? }  省略可。
---                          split_files があるとdiff拡大時にレビューツリーが出る
---   global_keys(self)  … パネル共通キーに足す固有キー（push/pull等）
---   quit_on_fullscreen_close … 全画面表示から閉じた時にnvim自体を終了するか（既定true）
function M.new(cfg)
  local self = {}

  local PANELS = cfg.panels
  local win = {}
  local origin_win
  local fullscreen_mode = false
  local augrp = vim.api.nvim_create_augroup(cfg.augroup or ('panel_shell_' .. cfg.id), { clear = true })
  local hl_ns = vim.api.nvim_create_namespace(cfg.hl_namespace or ('panel_shell_' .. cfg.id .. '_hl'))
  local current_panel_idx = 1
  local refresh_timer = nil
  --- 右パネルに今実際に描画されている内容（key+内容）。同じなら再描画自体をスキップして
  --- ちらつき/スクロールリセットを防ぐ。パネル切替時にnilへ戻し、必ず最初の1回は描画する
  local last_right_key = nil
  local last_right_content = nil
  --- set_right_diffが「変換前のraw diffテキスト」の変化なしを判定するための別キャッシュ
  --- （set_right_ansi/set_right_linesのキャッシュとは別に、deltaサブプロセス自体の起動も省く）
  local last_right_raw_key = nil
  local last_right_raw_text = nil
  --- 右ペインに今表示している内容の種別: 'diff'(delta出力) | 'ansi'(生ANSI) |
  --- 'lines'(プレーン) | nil。+で拡大した時、diffだけは新しい幅でローカル再生成し、それ以外
  --- (ログ等のANSI)は再取得せずそのまま拡大する、という出し分けに使う。
  local right_kind = nil
  --- 右ペインのサブタブ（ctx.set_right_tabsで設定。クリック判定に使う）
  local right_tabs = nil
  local ctx = {}
  local AUTO_REFRESH_INTERVAL_MS = cfg.auto_refresh_ms or DEFAULT_AUTO_REFRESH_INTERVAL_MS
  local diff_cfg = cfg.diff or {}

  local bind_click
  local bind_diff_keys
  local rerender_right_for_width
  local render_review_stream
  local GLOBAL_KEYS
  local activate_panel
  local layout
  local cmdlog_focused = false
  local collapse_cmdlog
  local diff_focused = false
  local collapse_diff_focus
  local toggle_cmdlog_focus
  local toggle_diff_focus
  local switch_to
  local switch_relative
  --- diff拡大時に左へ出す「変更ファイルツリー」の状態（cfg.diff.split_files がある時だけ使う）
  local review_tree = {
    win = nil,
    buf = nil,
    files = {},
    row_entries = {},
    visible_order = {},
    selected = 1,
    anchors = {},
    previous = nil,
    hidden = false,
    active = false,
  }
  local review_render_seq = 0

  local function diff_available()
    return diff_cfg.available and diff_cfg.available() or false
  end

  -- ══════════════════════════════════════════════
  -- 自動更新
  -- ══════════════════════════════════════════════

  --- 「押したから更新する」(R)と「勝手に定期更新する」(auto refresh)の両方から使う共通処理。
  --- 各パネルモジュールが持つremember_cursor()（無ければ何もしない）で「今カーソルが
  --- 乗っている項目」を記録してからrefresh()する。これをしないと、ユーザーが単に
  --- j/kで見ているだけの項目情報が古いまま(あるいは無いまま)再描画されてカーソルが
  --- 先頭などに戻ってしまう
  --- refresh(true)を渡すと、各パネルモジュールは非同期取得が完了してrender()する直前という
  --- 一番遅いタイミングで現在のカーソル位置を捕捉する。ここ(呼び出し前)で捕捉すると、
  --- 非同期のコマンドが完了するまでの間にユーザーがj/kで動かした分を取りこぼして
  --- カーソルが古い位置に戻ってしまうため、タイミングを意図的に遅らせている
  local function refresh_current_panel(is_auto)
    local spec = PANELS[current_panel_idx]
    if not spec then return end
    local mod = require(spec.mod)
    -- ネットワーク取得系(PR等)は自動更新の対象外にする（点滅・負荷防止。手動Rは対象）
    if is_auto and mod.auto_refresh == false then return end
    -- 第2引数で「勝手に走った更新か、ユーザーがRを押した更新か」を伝える。
    -- 重い取得(dockerのボリュームサイズ = docker system df -v 等)を自動更新から外すのに使う
    mod.refresh(true, { auto = is_auto and true or false })
  end

  local function start_auto_refresh()
    if refresh_timer or cfg.auto_refresh_ms == false then return end
    refresh_timer = vim.uv.new_timer()
    refresh_timer:start(AUTO_REFRESH_INTERVAL_MS, AUTO_REFRESH_INTERVAL_MS, vim.schedule_wrap(function()
      -- hunkステージング中やモーダル表示中(フォーカスがleft_win以外)は再描画で状態が
      -- 消えてしまうため、左パネルにフォーカスがある時だけ自動更新する
      if not (win.left_win and vim.api.nvim_win_is_valid(win.left_win)) then return end
      if vim.api.nvim_get_current_win() ~= win.left_win then return end
      refresh_current_panel(true)
    end))
  end

  local function stop_auto_refresh()
    if refresh_timer then
      refresh_timer:stop()
      refresh_timer:close()
      refresh_timer = nil
    end
  end

  --- vキー(delta side-by-side切替)相当。left_buf(GLOBAL_KEYS経由)と、diffパネルを
  --- +で拡大してフォーカスが移った時(bind_diff_keys)の両方から使うため共通化する。
  --- side-by-sideの切替は出力形式が変わるだけなので、再取得せずローカル再生成で足りる。
  local function toggle_side_by_side_key()
    if not diff_cfg.toggle_side_by_side then return end
    local on = diff_cfg.toggle_side_by_side()
    rerender_right_for_width()
    vim.notify('delta side-by-side: ' .. (on and 'ON' or 'OFF'), vim.log.levels.INFO)
  end

  -- ══════════════════════════════════════════════
  -- コマンドログ
  -- ══════════════════════════════════════════════

  local function render_cmdlog()
    if not (win.cmdlog_buf and vim.api.nvim_buf_is_valid(win.cmdlog_buf)) then return end
    local log = cfg.command_log and cfg.command_log() or {}
    local lines = {}
    for i = 1, #log do
      -- 1エントリに改行が混じっていても nvim_buf_set_lines が落ちないよう分解する
      for _, l in ipairs(vim.split(tostring(log[i]), '\n', { plain = true })) do
        table.insert(lines, l)
      end
    end
    if #lines == 0 then lines = { '(まだ実行なし)' } end
    vim.bo[win.cmdlog_buf].modifiable = true
    vim.api.nvim_buf_set_lines(win.cmdlog_buf, 0, -1, false, lines)
    vim.bo[win.cmdlog_buf].modifiable = false
    -- lazygitのAutoscroll相当: 末尾に追記していく分、ビューを常に一番下へ追従させる
    if win.cmdlog_win and vim.api.nvim_win_is_valid(win.cmdlog_win) then
      pcall(vim.api.nvim_win_set_cursor, win.cmdlog_win, { #lines, 0 })
    end
  end
  ctx.render_cmdlog = render_cmdlog
  -- stream_output=trueのコマンドが実行中に標準出力/エラーを流し込んでくるたびに
  -- 呼ばれる（vim.schedule済み）。パネルが開いていない時にも呼ばれるが、
  -- render_cmdlogはcmdlog_bufの有効性チェックを持っているので安全
  if cfg.set_log_hook then cfg.set_log_hook(render_cmdlog) end

  -- ══════════════════════════════════════════════
  -- 汎用ヘルパー（各パネルモジュールに渡す）
  -- ══════════════════════════════════════════════

  local function refocus_left()
    if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
      vim.api.nvim_set_current_win(win.left_win)
    end
  end
  ctx.refocus_left = refocus_left

  function ctx.open_file_in_origin(path)
    self.close()
    if origin_win and vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  end

  function ctx.confirm(message, on_result)
    ui.confirm(message, { refocus_win = win.left_win }, on_result)
  end

  function ctx.input(title, default, on_submit)
    ui.input(title, default, { refocus_win = win.left_win }, on_submit)
  end

  function ctx.multiline_input(title, on_submit)
    ui.multiline_input({ title = title, refocus_win = win.left_win }, on_submit)
  end

  --- lazygitのPrompt+FindSuggestionsFunc相当。get_candidates(text)は全候補からの
  --- フィルタ済み配列を返す関数（fuzzy検索は呼び出し側でvim.fn.matchfuzzy等を使う）
  function ctx.suggest_input(title, get_candidates, on_submit)
    ui.suggest_input(title, { refocus_win = win.left_win }, get_candidates, on_submit)
  end

  function ctx.menu(title, items, on_choice)
    ui.menu(title, items, { refocus_win = win.left_win }, on_choice)
  end

  --- 端末バッファでのANSI表示(set_right_ansi)は通常のプレーンテキスト表示に
  --- 戻す時/ANSI表示に切り替える時にバッファを作り直す必要がある（terminalバッファは
  --- nvim_buf_set_linesで書き換えられない・逆にプレーンバッファはchansendを受け付けない）
  local function recreate_right_buf(as_terminal)
    local old_buf = win.right_buf
    win.right_buf = vim.api.nvim_create_buf(false, true)
    if not as_terminal then
      vim.bo[win.right_buf].buftype = 'nofile'
      vim.bo[win.right_buf].buflisted = false
    end
    -- nvim_win_set_bufはフォーカスしていなくてもBufEnterを発火し、その一瞬だけ
    -- 「カレントバッファ」がこのバッファとして扱われる。hidden_cursorの判定
    -- (vim.b.hide_cursor)がその瞬間に走るため、ウィンドウへ差し込む前に必ずマークする
    hidden_cursor.mark_buffer(win.right_buf)
    -- 新しいバッファをウィンドウへ差し込んでから古いバッファを消す。逆順（先に削除）だと、
    -- 特にterminalバッファを表示中に削除した時、Neovimがwin.right_win自体を閉じてしまうことが
    -- あり、そのウィンドウIDを監視しているWinClosedハンドラでパネル全体が閉じてしまっていた
    if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
      vim.api.nvim_win_set_buf(win.right_win, win.right_buf)
    end
    if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
      pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
    end
    bind_click(win.right_buf)
    bind_diff_keys(win.right_buf)
  end

  --- 内容が前回と全く同じなら右パネルに一切触れない（プレーンバッファへのnvim_buf_set_lines
  --- は同一内容の再設定ならスクロール位置を動かさないので元々問題無いが、
  --- set_right_ansiはterminalバッファを毎回作り直すため、内容が同じでも
  --- 呼ぶたびに先頭に戻る/自動追従でちらつく。key+内容が変わっていない時は描画自体を
  --- スキップすることで、スクロール位置の復元を頑張る必要も無く両方解決する
  local function unchanged(key, content_sig)
    if key == nil then return false end
    local same = key == last_right_key and content_sig == last_right_content
    last_right_key, last_right_content = key, content_sig
    return same
  end

  --- key: 今表示している内容の識別子（ファイルpath/コミットhash/コンテナID等）。省略時(nil)は
  --- 変化なし判定の対象外（静的なメッセージ表示などで使う）
  function ctx.set_right_lines(lines, filetype, hl_queue, key)
    if not (win.right_buf and vim.api.nvim_buf_is_valid(win.right_buf)) then return end
    if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then vim.wo[win.right_win].cursorline = false end
    if unchanged(key, table.concat(lines, '\n')) then return end
    right_kind = 'lines'
    if vim.bo[win.right_buf].buftype == 'terminal' then recreate_right_buf(false) end
    vim.bo[win.right_buf].modifiable = true
    vim.bo[win.right_buf].filetype = filetype or 'diff'
    vim.api.nvim_buf_set_lines(win.right_buf, 0, -1, false, lines)
    vim.bo[win.right_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(win.right_buf, hl_ns, 0, -1)
    for _, h in ipairs(hl_queue or {}) do
      vim.api.nvim_buf_add_highlight(win.right_buf, hl_ns, h[2], h[1], h[3] or 0, h[4] or -1)
    end
  end

  --- 生ANSIテキストをそのまま色付きで表示する（nvim_open_termでlibvtermに
  --- 解釈させる。実プロセスは繋がず、静的な色付きテキストの表示器として使うだけ）
  function ctx.set_right_ansi(ansi_text, key)
    if not (win.right_win and vim.api.nvim_win_is_valid(win.right_win)) then return end
    if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then vim.wo[win.right_win].cursorline = false end
    if unchanged(key, ansi_text) then return end
    right_kind = 'ansi'
    recreate_right_buf(true)
    local chan = vim.api.nvim_open_term(win.right_buf, {})
    vim.api.nvim_chan_send(chan, ansi_text)
  end

  --- ANSI出力を「通常バッファ」へ写す（端末バッファのset_right_ansiとは別経路）。
  --- こうすると通常バッファなので CursorLine の選択ハイライトが効く。色・背景（ブロック帯）・
  --- 行番号・side-by-side は delta の出力をそのまま再現する。
  local function set_right_delta(ansi_text, key)
    if not (win.right_buf and vim.api.nvim_buf_is_valid(win.right_buf)) then return end
    if unchanged(key, ansi_text) then return end -- 同じ内容なら触らない（スクロール保持）
    right_kind = 'diff'
    if vim.bo[win.right_buf].buftype == 'terminal' then recreate_right_buf(false) end
    ansi_view.render(win.right_buf, hl_ns, ansi_text)
    if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
      vim.wo[win.right_win].cursorline = true -- 選択（カーソル行）ハイライト
    end
  end

  --- ANSI付きテキストを「通常バッファ」へ描画する（deltaを通さない版。dockerのログ表示用）。
  --- set_right_ansi(端末バッファ)と違い通常バッファなので、CursorLineの選択ハイライトや
  --- 通常のカーソル移動・検索が効き、再描画のたびに先頭へ戻ることもない。
  --- opts.bottom=true で末尾へ追従する（ログの tail 表示）
  function ctx.set_right_ansi_text(ansi_text, key, opts)
    if not (win.right_buf and vim.api.nvim_buf_is_valid(win.right_buf)) then return end
    if unchanged(key, ansi_text) then return end
    right_kind = 'ansi'
    if vim.bo[win.right_buf].buftype == 'terminal' then recreate_right_buf(false) end
    ansi_view.render(win.right_buf, hl_ns, ansi_text)
    if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
      vim.wo[win.right_win].cursorline = true
      if opts and opts.bottom then
        pcall(vim.api.nvim_win_set_cursor, win.right_win, { vim.api.nvim_buf_line_count(win.right_buf), 0 })
      end
    end
  end

  --- 右ペインのボーダータイトル。chunksは
  --- 文字列 または {{text, hlgroup}, ...} を渡せる（nilでタイトルを消す）
  function ctx.set_right_title(chunks)
    if not (win.right_win and vim.api.nvim_win_is_valid(win.right_win)) then return end
    if chunks == nil then
      pcall(vim.api.nvim_win_set_config, win.right_win, { title = '' })
      return
    end
    pcall(vim.api.nvim_win_set_config, win.right_win, { title = chunks, title_pos = 'center' })
  end

  --- 右ペインのサブタブ（lazydockerの Logs / Stats / Config / Top 相当）。
  --- 表示は右ペインの枠のタイトルで、左のタブバーと同じ GitPanelTab* で色付けする。
  --- names: {'Logs','Stats',...} / idx: 選択中(1始まり) / on_select(i): クリックで選ばれた時
  --- names が空/nil ならタブ表示を消す
  function ctx.set_right_tabs(names, idx, on_select)
    if not names or #names == 0 then
      right_tabs = nil
      ctx.set_right_title(nil)
      return
    end
    right_tabs = { names = names, idx = idx, on_select = on_select }
    local chunks = {}
    for i, name in ipairs(names) do
      table.insert(chunks, { ' ' .. name .. ' ', i == idx and 'GitPanelTabActive' or 'GitPanelTabInactive' })
    end
    ctx.set_right_title(chunks)
  end

  --- 枠のタイトルとして描かれたサブタブのクリック判定。
  --- ボーダー上のクリックは getmousepos() の winid が 0 になり「どのウィンドウか」では
  --- 判定できない（実測済み）が、screenrow/screencol は正確に取れる。そこで右ペインの
  --- 画面上の位置から、タブごとの桁範囲を割り出して突き合わせる。
  ---
  --- 座標の対応（実UIを張ったNeovimで画面を読んで確認した値）:
  ---   ・nvim_win_get_position はボーダーを含む「箱の左上」を0始まりで返す
  ---   ・タイトルが描かれるのはその箱の1行目 = 1始まりの画面行では pos[1] + 1
  ---   ・タイトルは左上の角文字の次からウィンドウ幅ぶんの範囲に中央寄せされる
  ---     = 0始まりの開始桁は pos[2] + 1 + (ウィンドウ幅 - タイトル幅) / 2
  local function right_tab_click(pos)
    if not right_tabs or not (win.right_win and vim.api.nvim_win_is_valid(win.right_win)) then return false end
    local wpos = vim.api.nvim_win_get_position(win.right_win)
    if pos.screenrow ~= wpos[1] + 1 then return false end

    local labels, total = {}, 0
    for _, name in ipairs(right_tabs.names) do
      local text = ' ' .. name .. ' '
      table.insert(labels, text)
      total = total + vim.fn.strdisplaywidth(text)
    end
    local col = pos.screencol - 1
    local x = wpos[2] + 1 + math.floor((vim.api.nvim_win_get_width(win.right_win) - total) / 2)
    for i, text in ipairs(labels) do
      local w = vim.fn.strdisplaywidth(text)
      if col >= x and col < x + w then
        if i ~= right_tabs.idx and right_tabs.on_select then right_tabs.on_select(i) end
        return true
      end
      x = x + w
    end
    return false
  end

  function ctx.right_width()
    return (win.right_win and vim.api.nvim_win_is_valid(win.right_win))
      and vim.api.nvim_win_get_width(win.right_win) or 80
  end

  --- deltaが使えれば自動で通して色付き表示、無ければ素のテキスト表示にフォールバックする。
  --- ファイルdiff・commit show・stash show -pなど「diffテキストを右パネルに出す」処理は
  --- 各パネルモジュールで同じ内容だったのでここに一本化した。
  --- rawの生diffが前回と同じならdeltaへ渡すことすらしない（無駄なサブプロセス起動も省く）
  function ctx.set_right_diff(text, key)
    if key ~= nil and key == last_right_raw_key and text == last_right_raw_text then
      return
    end
    last_right_raw_key, last_right_raw_text = key, text
    if not diff_available() then
      ctx.set_right_lines(vim.split(text, '\n', { plain = true }), 'diff', nil, key)
      return
    end
    local width = ctx.right_width()
    diff_cfg.run(text, width, function(ansi)
      if ansi then
        set_right_delta(ansi, key) -- delta出力を通常バッファへ忠実に描画（選択ハイライトが効く）
      else
        ctx.set_right_lines(vim.split(text, '\n', { plain = true }), 'diff', nil, key)
      end
    end)
  end

  --- side-by-side切替等、キャッシュ済みの内容と無関係に右パネルを強制再描画したい時に使う
  function ctx.invalidate_right_cache()
    last_right_key, last_right_content = nil, nil
    last_right_raw_key, last_right_raw_text = nil, nil
  end

  --- 右ペインのdiff(delta出力)だけを、今のウィンドウ幅で再生成する。
  --- +拡大/縮小・vのside-by-side切替から呼ぶ。deltaの出力は生成時の幅で固定されるため
  --- 幅が変わると追従しないが、raw diffはキャッシュ済みなので再取得せずdeltaに通し直すだけ。
  --- diff以外(ANSIログ・プレーンlines)は幅が変わっても再取得しない＝そのまま拡大する。
  function rerender_right_for_width()
    if right_kind ~= 'diff' then return end
    if not (diff_available() and last_right_raw_text and last_right_raw_text ~= '') then return end
    if diff_focused and review_tree.win and vim.api.nvim_win_is_valid(review_tree.win) then
      render_review_stream(last_right_raw_text, last_right_raw_key, review_tree.selected)
      return
    end
    local raw, key = last_right_raw_text, last_right_raw_key
    local width = ctx.right_width()
    diff_cfg.run(raw, width, function(ansi)
      if ansi then
        set_right_delta(ansi, key)
      else
        ctx.set_right_lines(vim.split(raw, '\n', { plain = true }), 'diff', nil, key)
      end
    end)
  end

  --- 各パネルモジュールのcurrent_entry()が全て同じ内容（left_winのカーソル行を
  --- line_entriesから引く）だったのでここに一本化した。呼び出し側は自分の
  --- line_entriesを返すクロージャを渡す
  function ctx.current_entry(get_line_entries)
    if not (win.left_win and vim.api.nvim_win_is_valid(win.left_win)) then return nil end
    local row = vim.api.nvim_win_get_cursor(win.left_win)[1]
    return get_line_entries()[row]
  end

  --- 操作後の定型パターン(コマンドログ更新→失敗時のみ通知→再取得)を共通化。
  --- refresh_fnは各パネルのM.refresh（呼び出し側が事前にcursor_memを設定していれば
  --- そこへ着地する。auto_captureは渡さない＝明示的操作の結果として呼ばれるため）
  function ctx.done_refresh(refresh_fn, label)
    return function(res)
      ctx.render_cmdlog()
      if res.code ~= 0 then vim.notify(label .. '失敗: ' .. (res.stderr or ''), vim.log.levels.ERROR) end
      refresh_fn()
    end
  end

  function ctx.set_left_lines(lines, hl_queue)
    if not (win.left_buf and vim.api.nvim_buf_is_valid(win.left_buf)) then return end
    vim.bo[win.left_buf].modifiable = true
    vim.api.nvim_buf_set_lines(win.left_buf, 0, -1, false, lines)
    vim.bo[win.left_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(win.left_buf, hl_ns, 0, -1)
    for _, h in ipairs(hl_queue or {}) do
      vim.api.nvim_buf_add_highlight(win.left_buf, hl_ns, h[2], h[1], h[3] or 0, h[4] or -1)
    end
    render_cmdlog()
  end

  function ctx.set_left_cursor(row)
    if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
      pcall(vim.api.nvim_win_set_cursor, win.left_win, { row, 0 })
    end
  end

  function ctx.get_left_win() return win.left_win end
  function ctx.get_left_buf() return win.left_buf end
  function ctx.get_right_win() return win.right_win end
  function ctx.get_right_buf() return win.right_buf end
  function ctx.get_root() return cfg.get_root and cfg.get_root() or nil end
  --- 表示中のパネル名（'files'/'containers'等）。パネルモジュールが非同期処理の完了時などに
  --- 「自分が今表示されているか」を判定し、非表示のパネルが誤って左バッファへ描画するのを防ぐ
  function ctx.current_panel_name() return PANELS[current_panel_idx] and PANELS[current_panel_idx].name end

  --- カーソルをlist entryのある行にクランプする汎用CursorMoved
  function ctx.setup_cursor_clamp(get_line_entries, get_total_rows, on_land)
    vim.api.nvim_create_autocmd('CursorMoved', {
      group = augrp,
      buffer = win.left_buf,
      callback = function()
        if not (win.left_win and vim.api.nvim_win_is_valid(win.left_win)) then return end
        local row = vim.api.nvim_win_get_cursor(win.left_win)[1]
        local entries = get_line_entries()
        if entries[row] then
          on_land(entries[row])
          return
        end
        local total = get_total_rows()
        for r = row, total do
          if entries[r] then
            pcall(vim.api.nvim_win_set_cursor, win.left_win, { r, 0 })
            return
          end
        end
        for r = row, 1, -1 do
          if entries[r] then
            pcall(vim.api.nvim_win_set_cursor, win.left_win, { r, 0 })
            return
          end
        end
      end,
    })
  end

  -- ══════════════════════════════════════════════
  -- パネル切替
  -- ══════════════════════════════════════════════

  -- render_tabbarで再計算するタブごとのクリック判定用バイト列範囲: { {start_col,end_col,idx}, ... }
  local tab_click_ranges = {}

  --- 左右パネルの上に全幅で常時表示するタブバー。狭い端末でも左パネルの枠内に
  --- 収まらないため、専用の1行ウィンドウにしている
  local function render_tabbar(idx)
    if not (win.tabbar_buf and vim.api.nvim_buf_is_valid(win.tabbar_buf)) then return end
    local parts = {}
    for _, p in ipairs(PANELS) do
      table.insert(parts, ' [' .. p.key .. '] ' .. p.title .. ' ')
    end
    vim.bo[win.tabbar_buf].modifiable = true
    vim.api.nvim_buf_set_lines(win.tabbar_buf, 0, -1, false, { table.concat(parts) })
    vim.bo[win.tabbar_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(win.tabbar_buf, hl_ns, 0, -1)
    tab_click_ranges = {}
    local col = 0
    for i, part in ipairs(parts) do
      local hl = (i == idx) and 'GitPanelTabActive' or 'GitPanelTabInactive'
      vim.api.nvim_buf_add_highlight(win.tabbar_buf, hl_ns, hl, 0, col, col + #part)
      table.insert(tab_click_ranges, { start_col = col, end_col = col + #part, idx = i })
      col = col + #part
    end
  end

  function switch_to(idx)
    -- コマンドログを@で拡大したままタブを切り替えると、後から作られたcmdlog_winが
    -- left_win/right_winの上に居座り続けて新しいパネルが見えなくなるため、
    -- 切替時は必ず元の大きさに戻す。同じタブへの切替(idx==current)でも、
    -- 拡大解除とleft_winへのフォーカス復帰は行う（キー/クリックどちらの経路でも
    -- 一貫して「拡大表示から抜けてそのパネルを見る」動きになるようにする）
    collapse_cmdlog()
    -- 別パネルへ切り替える時は直後の activate_panel が右ペインを描き直すので rerender 不要。
    -- 同じパネルへ（＝拡大から抜けるだけ）の時だけ、狭い幅でdiffを再生成する。
    collapse_diff_focus(idx == current_panel_idx)
    if idx ~= current_panel_idx then activate_panel(idx) end
    if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
      vim.api.nvim_set_current_win(win.left_win)
    end
  end

  function switch_relative(delta)
    local idx = current_panel_idx + delta
    if idx < 1 then idx = #PANELS end
    if idx > #PANELS then idx = 1 end
    switch_to(idx)
  end

  --- <LeftMouse>はクリック先ではなく「クリックした瞬間にフォーカスがあった」
  --- バッファのキーマップで解決される。パネル内の全バッファに同じハンドラを
  --- 仕込むことで、どこにフォーカスがあっても1回目のクリックで判定が走るようにする。
  --- タブバーへのクリックはタブ切替、それ以外は<LeftMouse>を上書きしたことで
  --- 消えてしまう既定動作(クリック先へフォーカス移動+カーソル位置決め)を自前で再現する
  local function handle_panel_click()
    local pos = vim.fn.getmousepos()
    if right_tab_click(pos) then return end
    if pos.winid == win.tabbar_win then
      local col = pos.column - 1
      for _, r in ipairs(tab_click_ranges) do
        if col >= r.start_col and col < r.end_col then
          switch_to(r.idx)
          break
        end
      end
      if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
        vim.api.nvim_set_current_win(win.left_win)
      end
      return
    end
    if pos.winid and pos.winid ~= 0 and vim.api.nvim_win_is_valid(pos.winid) then
      vim.api.nvim_set_current_win(pos.winid)
      if pos.line > 0 then
        pcall(vim.api.nvim_win_set_cursor, pos.winid, { pos.line, math.max(0, pos.column - 1) })
      end
    end
  end

  function bind_click(buf)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set('n', '<LeftMouse>', handle_panel_click, { buffer = buf, nowait = true, silent = true })
    end
  end

  --- 左ペイン以外(コマンドログ・diff拡大・レビューツリー)にフォーカスがある間も
  --- タブ切替キーが効くようにする
  local function bind_switch_keys(buf)
    for _, p in ipairs(PANELS) do
      local target = p
      vim.keymap.set('n', p.key, function()
        for i, q in ipairs(PANELS) do
          if q == target then switch_to(i) end
        end
      end, { buffer = buf, nowait = true, silent = true })
    end
    vim.keymap.set('n', '<Left>', function() switch_relative(-1) end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', '<Right>', function() switch_relative(1) end, { buffer = buf, nowait = true, silent = true })
  end

  -- lazygit(pkg/gui/controllers/helpers/window_arrangement_helper.go getExtrasWindowSize)相当:
  -- コマンドログにフォーカスすると、通常の固定行数(CommandLogSize)ではなく利用可能な
  -- 領域いっぱいに広がる。ここではFiles/Diffが占めていた領域も含めて丸ごと専有させる

  --- 拡大表示を元の大きさに戻す（フォーカスの移動はしない）。switch_toからも呼ぶため、
  --- toggle_cmdlog_focusのelse分岐から切り出している
  function collapse_cmdlog()
    if not cmdlog_focused then return end
    cmdlog_focused = false
    if not (win.cmdlog_win and vim.api.nvim_win_is_valid(win.cmdlog_win)) then return end
    local L = layout()
    vim.api.nvim_win_set_config(win.cmdlog_win, {
      relative = 'editor', row = L.cmdlog_row, col = L.outer_col,
      width = L.cmdlog_w, height = L.cmdlog_h,
    })
    vim.wo[win.cmdlog_win].cursorline = false
    -- 拡大解除で元の見た目（カーソル非表示）に戻す。次にフォーカスが移った窓の
    -- WinEnter で hidden_cursor.apply が走り guicursor に反映される。
    if win.cmdlog_buf and vim.api.nvim_buf_is_valid(win.cmdlog_buf) then
      vim.b[win.cmdlog_buf].hide_cursor = true
    end
  end

  function toggle_cmdlog_focus()
    if not (win.cmdlog_win and vim.api.nvim_win_is_valid(win.cmdlog_win)) then return end
    if not cmdlog_focused then
      collapse_diff_focus() -- 同じ領域を専有するため排他
      local L = layout()
      cmdlog_focused = true
      vim.api.nvim_win_set_config(win.cmdlog_win, {
        relative = 'editor', row = L.top_row, col = L.outer_col,
        width = L.tabbar_w, height = L.box_h + L.cmdlog_h + 2,
      })
      vim.wo[win.cmdlog_win].cursorline = true
      -- 拡大中は内容を選択コピーできるように、テキストカーソルを表示する
      -- （set_current_win の WinEnter で hidden_cursor.apply が visible 側へ戻す）。
      vim.b[win.cmdlog_buf].hide_cursor = false
      vim.api.nvim_set_current_win(win.cmdlog_win)
      vim.api.nvim_win_set_cursor(win.cmdlog_win, { math.max(1, vim.api.nvim_buf_line_count(win.cmdlog_buf)), 0 })
    else
      collapse_cmdlog()
      if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
        vim.api.nvim_set_current_win(win.left_win)
      end
    end
  end

  -- ══════════════════════════════════════════════
  -- diff拡大時のレビューツリー（cfg.diff.split_files がある時だけ有効）
  -- ══════════════════════════════════════════════

  local function review_tree_width(L)
    return math.min(math.max(24, math.floor(L.tabbar_w * 0.28)), math.max(18, L.tabbar_w - 42))
  end

  local function close_review_tree()
    review_render_seq = review_render_seq + 1
    if review_tree.win and vim.api.nvim_win_is_valid(review_tree.win) then
      pcall(vim.api.nvim_win_close, review_tree.win, true)
    end
    if review_tree.buf and vim.api.nvim_buf_is_valid(review_tree.buf) then
      pcall(vim.api.nvim_buf_delete, review_tree.buf, { force = true })
    end
    review_tree.win, review_tree.buf = nil, nil
    review_tree.files, review_tree.row_entries, review_tree.visible_order, review_tree.anchors = {}, {}, {}, {}
    review_tree.selected = 1
    review_tree.previous = nil
    review_tree.hidden = false
    review_tree.active = false
  end

  local function visible_line_count(text)
    if not text or text == '' then return 0 end
    local _, n = text:gsub('\n', '')
    return text:sub(-1) == '\n' and n or (n + 1)
  end

  local function build_review_tree(files)
    local root = { name = '', path = '', is_dir = true, children = {} }
    local dirs = { [''] = root }
    local function dir(path)
      if dirs[path] then return dirs[path] end
      local parent_path = path:match('^(.*)/[^/]+$') or ''
      local parent = dir(parent_path)
      local node = { name = path:match('([^/]+)$') or path, path = path, is_dir = true, children = {} }
      table.insert(parent.children, node)
      dirs[path] = node
      return node
    end
    for i, f in ipairs(files) do
      local parent_path = f.path:match('^(.*)/[^/]+$') or ''
      table.insert(dir(parent_path).children, {
        name = f.path:match('([^/]+)$') or f.path,
        path = f.path,
        is_dir = false,
        index = i,
        status = f.status or 'M',
        added = f.added or 0,
        deleted = f.deleted or 0,
      })
    end
    local function sort(node)
      table.sort(node.children, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.name:lower() < b.name:lower()
      end)
      for _, c in ipairs(node.children) do if c.is_dir then sort(c) end end
    end
    sort(root)
    return root
  end

  local function scroll_review_to_selected()
    local rwin = win.right_win
    if not (rwin and vim.api.nvim_win_is_valid(rwin)) then return end
    local row = review_tree.anchors[review_tree.selected] or 1
    pcall(vim.api.nvim_win_set_cursor, rwin, { math.max(1, row), 0 })
    vim.api.nvim_win_call(rwin, function() vim.cmd('normal! zt') end)
  end

  local function render_review_tree()
    local lines, hls = {}, {}
    review_tree.row_entries = {}
    review_tree.visible_order = {}
    local selected_row = 1
    local tree = build_review_tree(review_tree.files)

    local function push(text, entry, hl)
      table.insert(lines, text)
      review_tree.row_entries[#lines] = entry
      if entry and entry.index == review_tree.selected then selected_row = #lines end
      if hl then table.insert(hls, { #lines - 1, hl, 0, -1 }) end
    end

    push('  Changed files', nil, 'GitPanelHeader')
    local function walk(node, depth)
      for _, child in ipairs(node.children) do
        local indent = string.rep('  ', depth)
        if child.is_dir then
          push('  ' .. indent .. '▼ ' .. child.name .. '/', nil, 'GitPanelSection')
          walk(child, depth + 1)
        else
          local status = child.status or 'M'
          local status_hl = ({
            A = 'GitPanelAdded',
            M = 'GitPanelModified',
            D = 'GitPanelDeleted',
            R = 'GitPanelRenamed',
          })[status] or 'GitPanelModified'
          local stat = ''
          if child.added > 0 or child.deleted > 0 then
            stat = string.format('  +%d -%d', child.added, child.deleted)
          end
          table.insert(review_tree.visible_order, child.index)
          local line = '  ' .. indent .. status .. ' ' .. child.name .. stat
          push(line, { index = child.index }, nil)
          local row = #lines - 1
          local status_col = #('  ' .. indent)
          table.insert(hls, { row, status_hl, status_col, status_col + 1 })
          local plus_col = line:find('+%d+', 1)
          local minus_col = line:find('-%d+', 1)
          if plus_col then table.insert(hls, { row, 'GitPanelReviewAdded', plus_col - 1, plus_col - 1 + #tostring(child.added) + 1 }) end
          if minus_col then table.insert(hls, { row, 'GitPanelReviewDeleted', minus_col - 1, minus_col - 1 + #tostring(child.deleted) + 1 }) end
        end
      end
    end
    walk(tree, 0)
    if #lines == 1 then push('  (差分なし)', nil) end

    if not (review_tree.buf and vim.api.nvim_buf_is_valid(review_tree.buf)) then return end

    vim.bo[review_tree.buf].modifiable = true
    vim.api.nvim_buf_set_lines(review_tree.buf, 0, -1, false, lines)
    vim.bo[review_tree.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(review_tree.buf, hl_ns, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_add_highlight(review_tree.buf, hl_ns, h[2], h[1], h[3], h[4])
    end
    if review_tree.win and vim.api.nvim_win_is_valid(review_tree.win) then
      pcall(vim.api.nvim_win_set_cursor, review_tree.win, { selected_row, 0 })
    end
  end

  local function move_review_selection(delta)
    if #review_tree.files == 0 then return end
    local order = review_tree.visible_order
    local pos = 1
    for i, idx in ipairs(order) do
      if idx == review_tree.selected then pos = i; break end
    end
    pos = math.max(1, math.min(#order, pos + delta))
    review_tree.selected = order[pos] or review_tree.selected
    render_review_tree()
    scroll_review_to_selected()
  end

  local toggle_review_tree

  local function bind_review_tree_keys(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
    local function collapse_and_refocus()
      collapse_diff_focus(true)
      if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
        vim.api.nvim_set_current_win(win.left_win)
      end
    end
    vim.keymap.set('n', 'j', function() move_review_selection(1) end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', '<Down>', function() move_review_selection(1) end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', 'k', function() move_review_selection(-1) end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', '<Up>', function() move_review_selection(-1) end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', 't', function() toggle_review_tree() end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', 'v', toggle_side_by_side_key, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', '@', function() toggle_cmdlog_focus() end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', '+', collapse_and_refocus, { buffer = buf, nowait = true, silent = true })
    for _, key in ipairs({ 'q', '<Esc>' }) do
      vim.keymap.set('n', key, collapse_and_refocus, { buffer = buf, nowait = true, silent = true })
    end
    bind_switch_keys(buf)
  end

  local function position_review_windows()
    local L = layout()
    if review_tree.hidden then
      if review_tree.win and vim.api.nvim_win_is_valid(review_tree.win) then
        pcall(vim.api.nvim_win_close, review_tree.win, true)
        review_tree.win = nil
      end
      vim.api.nvim_win_set_config(win.right_win, {
        relative = 'editor', row = L.top_row, col = L.outer_col,
        width = L.tabbar_w, height = L.box_h + L.cmdlog_h + 2,
        zindex = 70,
      })
      return
    end

    local tree_w = review_tree_width(L)
    if not (review_tree.buf and vim.api.nvim_buf_is_valid(review_tree.buf)) then
      review_tree.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[review_tree.buf].buftype = 'nofile'
      vim.bo[review_tree.buf].buflisted = false
      vim.bo[review_tree.buf].modifiable = false
      vim.bo[review_tree.buf].filetype = cfg.left_filetype or 'gitpanel'
      hidden_cursor.mark_buffer(review_tree.buf)
      bind_click(review_tree.buf)
      bind_review_tree_keys(review_tree.buf)
    end
    if not (review_tree.win and vim.api.nvim_win_is_valid(review_tree.win)) then
      review_tree.win = vim.api.nvim_open_win(review_tree.buf, false, {
        relative = 'editor', row = L.top_row, col = L.outer_col,
        width = tree_w, height = L.box_h + L.cmdlog_h + 2,
        style = 'minimal', border = 'single', title = ' Changed ', title_pos = 'center',
        zindex = 70,
      })
      vim.api.nvim_win_set_var(review_tree.win, cfg.review_tree_win_var or 'gitpanel_review_tree', true)
      vim.wo[review_tree.win].wrap = false
      vim.wo[review_tree.win].number = false
      vim.wo[review_tree.win].signcolumn = 'no'
      vim.wo[review_tree.win].cursorline = true
      vim.wo[review_tree.win].winhighlight = 'Normal:GitPanelBg,CursorLine:GitPanelCursorLine,FloatBorder:GitPanelBorder'
    else
      vim.api.nvim_win_set_config(review_tree.win, {
        relative = 'editor', row = L.top_row, col = L.outer_col,
        width = tree_w, height = L.box_h + L.cmdlog_h + 2,
        zindex = 70,
      })
    end
    vim.api.nvim_win_set_config(win.right_win, {
      relative = 'editor', row = L.top_row, col = L.outer_col + tree_w + 2,
      width = L.tabbar_w - tree_w - 2, height = L.box_h + L.cmdlog_h + 2,
      zindex = 70,
    })
  end

  toggle_review_tree = function()
    if not review_tree.active then return end
    review_tree.hidden = not review_tree.hidden
    position_review_windows()
    if review_tree.hidden then
      if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
        vim.api.nvim_set_current_win(win.right_win)
      end
    else
      render_review_tree()
      if review_tree.win and vim.api.nvim_win_is_valid(review_tree.win) then
        vim.api.nvim_set_current_win(review_tree.win)
      end
    end
    scroll_review_to_selected()
  end

  function render_review_stream(raw, key, selected)
    if not (win.right_buf and vim.api.nvim_buf_is_valid(win.right_buf)) then return end
    review_render_seq = review_render_seq + 1
    local seq = review_render_seq
    local files = diff_cfg.split_files(raw)
    review_tree.files = files
    review_tree.selected = math.max(1, math.min(selected or review_tree.selected or 1, math.max(1, #files)))
    render_review_tree()
    if not selected and review_tree.visible_order[1] then
      review_tree.selected = review_tree.visible_order[1]
      render_review_tree()
    end
    last_right_raw_key, last_right_raw_text = key, raw
    right_kind = 'diff'
    if #files == 0 then
      ctx.set_right_lines({ '  (差分なし)' }, 'diff', nil, key)
      return
    end

    local width = ctx.right_width()
    local outputs, pending = {}, #files
    local function finish()
      if seq ~= review_render_seq then return end
      if not (win.right_buf and vim.api.nvim_buf_is_valid(win.right_buf)) then return end
      local anchors = {}
      local row = 1
      local parts = {}
      local order = review_tree.visible_order
      if #order == 0 then
        order = {}
        for i = 1, #files do table.insert(order, i) end
      end
      for _, i in ipairs(order) do
        local f = files[i]
        local text = outputs[i] or f.raw_text or ''
        anchors[i] = row
        table.insert(parts, text)
        row = row + visible_line_count(text) + 1
        table.insert(parts, '')
      end
      local rendered = table.concat(parts, '\n')
      review_tree.anchors = anchors
      if not unchanged(key, rendered) then
        if vim.bo[win.right_buf].buftype == 'terminal' then recreate_right_buf(false) end
        ansi_view.render(win.right_buf, hl_ns, rendered)
        if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
          vim.wo[win.right_win].cursorline = true
        end
      end
      render_review_tree()
      scroll_review_to_selected()
    end

    local function done_one(i, text)
      outputs[i] = text and text ~= '' and text or files[i].raw_text
      pending = pending - 1
      if pending == 0 then finish() end
    end

    if not diff_available() then
      for i, f in ipairs(files) do outputs[i] = f.raw_text end
      finish()
      return
    end
    for i, f in ipairs(files) do
      diff_cfg.run(f.raw_text, width, function(text) done_one(i, text) end)
    end
  end

  local function enter_review_diff_focus()
    diff_focused = true
    review_tree.previous = {
      raw_key = last_right_raw_key,
      raw_text = last_right_raw_text,
    }
    review_tree.hidden = true
    review_tree.active = true
    position_review_windows()
    if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
      vim.api.nvim_set_current_win(win.right_win)
    end

    local spec = PANELS[current_panel_idx]
    local panel = spec and require(spec.mod)
    local function show(raw)
      if not diff_focused then return end
      position_review_windows()
      render_review_stream(raw or '', 'review:' .. (spec and spec.name or 'diff'))
      if review_tree.hidden then
        if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
          vim.api.nvim_set_current_win(win.right_win)
        end
      elseif review_tree.win and vim.api.nvim_win_is_valid(review_tree.win) then
        vim.api.nvim_set_current_win(review_tree.win)
      end
    end
    ctx.set_right_lines({ '  読み込み中...' }, 'diff', nil, 'review:loading')
    if panel and panel.review_diff then
      panel.review_diff(show)
    else
      show(last_right_raw_text or '')
    end
  end

  --- Diffパネルの拡大表示。lazygit本体は+/_でNORMAL/HALF/FULLの3段階の画面モードを
  --- 切り替え、main(diff)にフォーカスがある時だけ左の一覧が縮む/消えるという仕組み
  --- (window_arrangement_helper.go getMidSectionWeights)だが、ここではコマンドログの
  --- @トグルと揃えたシンプルな2状態トグルにしている。cmdlog拡大と同じ領域(タブバーの
  --- 下、左一覧/右ペイン/コマンドログが占めていた範囲全体)を専有する
  --- 拡大表示を元の大きさに戻す（フォーカスの移動はしない）。switch_toからも呼ぶため、
  --- toggle_diff_focusのelse分岐から切り出している
  --- rerenderを呼ぶかどうかは呼び出し側が制御する。パネル切替(switch_to)経由では、
  --- 直後のactivate_panelが右ペインを normal幅で描き直すため rerender は不要（=false）。
  --- +で同じパネル内を縮小する時だけ、新しい(狭い)幅でdiffを再生成する必要がある。
  function collapse_diff_focus(rerender)
    if not diff_focused then return end
    local previous = review_tree.previous
    local had_review_tree = review_tree.win and vim.api.nvim_win_is_valid(review_tree.win)
    diff_focused = false
    close_review_tree()
    if not (win.right_win and vim.api.nvim_win_is_valid(win.right_win)) then return end
    local L = layout()
    vim.api.nvim_win_set_config(win.right_win, {
      relative = 'editor', row = L.top_row, col = L.right_col,
      width = L.right_w, height = L.box_h,
      zindex = 50,
    })
    -- delta出力は生成時の幅で固定されているため、幅が変わったら新しい幅で再生成する。
    -- ただし再取得(ネットワーク/git)はせず、キャッシュ済みraw diffをdeltaに通し直すだけ。
    -- diff以外は rerender_right_for_width が何もしない＝再取得なしでそのまま。
    if rerender and had_review_tree and previous and previous.raw_text then
      ctx.invalidate_right_cache()
      ctx.set_right_diff(previous.raw_text, previous.raw_key)
    elseif rerender then
      rerender_right_for_width()
    end
  end

  function toggle_diff_focus()
    if not (win.right_win and vim.api.nvim_win_is_valid(win.right_win)) then return end
    if not diff_focused then
      collapse_cmdlog() -- 同じ領域を専有するため排他
      if diff_cfg.split_files and right_kind == 'diff' and last_right_raw_text and last_right_raw_text ~= '' then
        enter_review_diff_focus()
        return
      end
      local L = layout()
      diff_focused = true
      vim.api.nvim_win_set_config(win.right_win, {
        relative = 'editor', row = L.top_row, col = L.outer_col,
        width = L.tabbar_w, height = L.box_h + L.cmdlog_h + 2,
      })
      vim.api.nvim_set_current_win(win.right_win)
      -- 拡大後の幅でdiffだけローカル再生成する（ログ等のANSIは再取得せずそのまま拡大）。
      rerender_right_for_width()
    else
      collapse_diff_focus(true)
      if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
        vim.api.nvim_set_current_win(win.left_win)
      end
    end
  end

  --- 右ペインはrecreate_right_buf()で内容更新のたびにバッファが作り直されるため、
  --- bind_clickと同様、作り直すたびに呼んで再設定する必要がある
  function bind_diff_keys(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
    vim.keymap.set('n', '+', function() toggle_diff_focus() end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', 't', function()
      if diff_focused and review_tree.active then toggle_review_tree() end
    end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set('n', 'v', toggle_side_by_side_key, { buffer = buf, nowait = true, silent = true })
    for _, key in ipairs({ 'q', '<Esc>' }) do
      vim.keymap.set('n', key, function()
        if diff_focused then toggle_diff_focus() else self.close() end
      end, { buffer = buf, nowait = true, silent = true })
    end
    bind_switch_keys(buf)
  end

  function activate_panel(idx)
    current_panel_idx = idx
    last_right_key, last_right_content = nil, nil
    last_right_raw_key, last_right_raw_text = nil, nil
    -- サブタブはパネルごとの持ち物なので、切替時に一旦消す（新しいパネルが必要なら再設定する）
    right_tabs = nil
    local spec = PANELS[idx]
    local panel = require(spec.mod)

    vim.api.nvim_clear_autocmds({ group = augrp, buffer = win.left_buf })

    win.left_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[win.left_buf].buftype    = 'nofile'
    vim.bo[win.left_buf].buflisted  = false
    vim.bo[win.left_buf].modifiable = false
    vim.bo[win.left_buf].filetype   = cfg.left_filetype or 'gitpanel'
    -- ウィンドウへ差し込む前に必ずマークする(recreate_right_bufと同じ理由:
    -- nvim_win_set_bufはフォーカスしていなくてもBufEnterを発火するため)
    hidden_cursor.mark_buffer(win.left_buf)
    vim.api.nvim_win_set_buf(win.left_win, win.left_buf)
    bind_click(win.left_buf)
    vim.wo[win.left_win].wrap         = false
    vim.wo[win.left_win].number       = false
    vim.wo[win.left_win].signcolumn   = 'no'
    vim.wo[win.left_win].cursorline   = true
    vim.wo[win.left_win].winhighlight = 'Normal:GitPanelBg,CursorLine:GitPanelCursorLine,FloatBorder:GitPanelBorder'
    vim.api.nvim_win_set_config(win.left_win, { title = ' ' .. spec.title .. ' ', title_pos = 'center' })
    render_tabbar(idx)

    local keys = vim.tbl_extend('force', GLOBAL_KEYS, panel.keymaps and panel.keymaps() or {})
    for key, fn in pairs(keys) do
      vim.keymap.set('n', key, fn, { buffer = win.left_buf, nowait = true, silent = true })
    end

    panel.activate(ctx)
  end

  -- ══════════════════════════════════════════════
  -- グローバルキー
  -- ══════════════════════════════════════════════

  -- lazygit(WithInlineStatus/WithWaitingStatus)は実行中のパネルにインラインで
  -- "Pushing.../Pulling..."を出す。左パネルのタイトルを一時的に書き換えて同じ役割を持たせる
  -- （通信中に何も表示が変わらず「動いているのか分からない」状態を防ぐ）
  local function set_loading(label)
    if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
      vim.api.nvim_win_set_config(win.left_win, { title = ' ⏳ ' .. label .. '... ', title_pos = 'center' })
    end
  end

  local function clear_loading()
    local spec = PANELS[current_panel_idx]
    if win.left_win and vim.api.nvim_win_is_valid(win.left_win) and spec then
      vim.api.nvim_win_set_config(win.left_win, { title = ' ' .. spec.title .. ' ', title_pos = 'center' })
    end
  end
  -- 各パネルモジュール(files.luaのfetch等)からも同じローディング表示を使えるようにする
  ctx.set_loading = set_loading
  ctx.clear_loading = clear_loading

  local function build_global_keys()
    local keys = {
      ['R'] = function() refresh_current_panel() end,
      ['@'] = function() toggle_cmdlog_focus() end,
      ['+'] = function() toggle_diff_focus() end,
      ['q'] = function() self.close() end,
      ['<Esc>'] = function() self.close() end,
      ['<Left>'] = function() switch_relative(-1) end,
      ['<Right>'] = function() switch_relative(1) end,
    }
    for i, p in ipairs(PANELS) do
      keys[p.key] = function() switch_to(i) end
    end
    if diff_cfg.toggle_side_by_side then keys['v'] = toggle_side_by_side_key end
    return vim.tbl_extend('force', keys, cfg.global_keys and cfg.global_keys(self) or {})
  end

  -- ══════════════════════════════════════════════
  -- レイアウト（90%x90%センター、左パネル+右ペイン+下部コマンドログ）
  -- ══════════════════════════════════════════════

  function layout()
    -- explorer.luaの:Explorer!と同じく、全画面表示時は画面いっぱい(コマンドライン分の
    -- 2行だけ残す)を使う。中身のパネル構成・計算は90%表示と全く同じで、total_w/total_h/
    -- outer_col/outer_rowの元になる値だけが変わる
    local total_w, total_h, outer_col, outer_row
    if fullscreen_mode then
      total_w, total_h = vim.o.columns, vim.o.lines - 2
      outer_col, outer_row = 0, 0
    else
      total_w = math.floor(vim.o.columns * 0.9)
      total_h = math.floor(vim.o.lines * 0.9)
      outer_col = math.floor((vim.o.columns - total_w) / 2)
      outer_row = math.floor((vim.o.lines - total_h) / 2)
    end

    local hgap, vgap = 0, 0
    -- tabbarもcmdlogと同じ「ボーダー付きで全幅」の作り方に統一する
    -- （ボーダー無し要素とボーダー有り要素を混在させるとcol/row計算がずれるため）
    local tabbar_content_h = 1
    local tabbar_screen_h = tabbar_content_h + 2
    local cmdlog_content_h = 6
    local cmdlog_screen_h = cmdlog_content_h + 2

    local tabbar_row = outer_row
    local top_row = tabbar_row + tabbar_screen_h + vgap
    local top_screen_h = total_h - tabbar_screen_h - vgap - cmdlog_screen_h - vgap
    local top_content_h = top_screen_h - 2

    local left_content_w = math.floor(total_w * 0.38) - 2
    local right_content_w = total_w - (left_content_w + 2) - hgap - 2

    return {
      outer_col = outer_col, outer_row = outer_row,
      tabbar_row = tabbar_row, tabbar_w = total_w - 2, tabbar_h = tabbar_content_h,
      top_row = top_row,
      left_w = left_content_w, right_w = right_content_w, box_h = top_content_h,
      right_col = outer_col + left_content_w + 2 + hgap,
      cmdlog_row = top_row + top_screen_h + vgap,
      cmdlog_w = total_w - 2, cmdlog_h = cmdlog_content_h,
    }
  end

  -- ══════════════════════════════════════════════
  -- 開閉
  -- ══════════════════════════════════════════════

  local function close_wins()
    stop_auto_refresh()
    cmdlog_focused = false
    diff_focused = false
    close_review_tree()
    for _, key in ipairs({ 'tabbar_win', 'left_win', 'right_win', 'cmdlog_win' }) do
      local w = win[key]
      if w and vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
      end
    end
    for _, key in ipairs({ 'tabbar_buf', 'left_buf', 'right_buf', 'cmdlog_buf' }) do
      local b = win[key]
      if b and vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    win = {}
    self.win = win
    fullscreen_mode = false
  end

  --- 全画面表示は「これがこのnvimプロセスの用件そのもの」という前提(例: nvim +Git!
  --- で直接立ち上げる運用等)なので、閉じる操作(q/Esc/:q
  --- どれでも最終的にここを通る)がそのまま裏側の元バッファへ戻るのではなく、
  --- nvim自体を終了させる。通常の90%表示ではこれまで通り単に閉じるだけ
  --- opts.keep_nvim=true は「閉じた跡地で続きの作業をする」ケース(dockerパネルの
  --- コンテナ内シェル起動など)用で、全画面でもnvimを終了させない
  function self.close(opts)
    local was_fullscreen = fullscreen_mode
    vim.api.nvim_clear_autocmds({ group = augrp })
    close_wins()
    if cfg.on_close then cfg.on_close() end
    if was_fullscreen and cfg.quit_on_fullscreen_close ~= false and not (opts and opts.keep_nvim) then
      vim.cmd('qall')
    end
  end

  local function open(fullscreen)
    -- コマンドの完了を待たず、ウィンドウは即座に表示する（読み込み中表示→非同期で内容を反映）
    fullscreen_mode = fullscreen or false
    origin_win = vim.api.nvim_get_current_win()
    local L = layout()
    GLOBAL_KEYS = build_global_keys()

    win.tabbar_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[win.tabbar_buf].buftype    = 'nofile'
    vim.bo[win.tabbar_buf].buflisted  = false
    vim.bo[win.tabbar_buf].modifiable = false
    hidden_cursor.mark_buffer(win.tabbar_buf)
    win.tabbar_win = vim.api.nvim_open_win(win.tabbar_buf, false, {
      relative = 'editor', width = L.tabbar_w, height = L.tabbar_h, col = L.outer_col, row = L.tabbar_row,
      style = 'minimal', border = 'single',
    })
    vim.wo[win.tabbar_win].winhighlight = 'Normal:GitPanelBg,FloatBorder:GitPanelBorder'
    bind_click(win.tabbar_buf)

    win.left_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[win.left_buf].buftype = 'nofile'
    win.left_win = vim.api.nvim_open_win(win.left_buf, true, {
      relative = 'editor', width = L.left_w, height = L.box_h, col = L.outer_col, row = L.top_row,
      style = 'minimal', border = 'single',
      title = ' ' .. (PANELS[1] and PANELS[1].title or '') .. ' ', title_pos = 'center',
    })
    hidden_cursor.mark_buffer(win.left_buf)
    bind_click(win.left_buf)
    vim.bo[win.left_buf].modifiable = true
    vim.api.nvim_buf_set_lines(win.left_buf, 0, -1, false, { '  読み込み中...' })
    vim.bo[win.left_buf].modifiable = false

    win.right_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[win.right_buf].buftype    = 'nofile'
    vim.bo[win.right_buf].buflisted  = false
    vim.bo[win.right_buf].modifiable = false
    vim.bo[win.right_buf].filetype   = 'diff'
    hidden_cursor.mark_buffer(win.right_buf)
    -- 右ペインはdiff専用ではなく、詳細やログも出すため、固定のタイトルは付けない。
    win.right_win = vim.api.nvim_open_win(win.right_buf, false, {
      relative = 'editor', width = L.right_w, height = L.box_h, col = L.right_col, row = L.top_row,
      style = 'minimal', border = 'single',
    })
    vim.wo[win.right_win].wrap = false
    vim.wo[win.right_win].signcolumn = 'no'
    vim.wo[win.right_win].winhighlight = 'Normal:GitPanelBg,CursorLine:GitPanelCursorLine,FloatBorder:GitPanelBorder'
    vim.wo[win.right_win].cursorline = false -- diff表示時のみ set_right_delta が有効化する
    -- タイトルで判別できなくなるため、右ペインである印を window-local 変数で持たせておく
    -- （テストや内部からの特定用。ウィンドウは開いている間ID不変なので消えない）
    vim.api.nvim_win_set_var(win.right_win, cfg.right_win_var or 'gitpanel_right', true)
    bind_click(win.right_buf)
    bind_diff_keys(win.right_buf)

    win.cmdlog_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[win.cmdlog_buf].buftype    = 'nofile'
    vim.bo[win.cmdlog_buf].buflisted  = false
    vim.bo[win.cmdlog_buf].modifiable = false
    hidden_cursor.mark_buffer(win.cmdlog_buf)
    win.cmdlog_win = vim.api.nvim_open_win(win.cmdlog_buf, false, {
      relative = 'editor', width = L.cmdlog_w, height = L.cmdlog_h, col = L.outer_col, row = L.cmdlog_row,
      style = 'minimal', border = 'single', title = ' Command Log ', title_pos = 'center',
    })
    vim.wo[win.cmdlog_win].wrap = false
    -- コマンドログは @ 拡大中に内容をマウスで選択コピーできるようにする。
    -- 拡大中にログ内をクリック/ドラッグした時だけ既定のマウス挙動（選択開始）へ
    -- 委ね、それ以外（拡大中の上部タブバークリックや、拡大していない時）は通常の
    -- パネルクリック処理へ回す。expr 中は win/cursor 変更が textlock で禁じられるため、
    -- handle_panel_click は schedule 経由で呼ぶ。
    vim.keymap.set('n', '<LeftMouse>', function()
      if cmdlog_focused and vim.fn.getmousepos().winid == win.cmdlog_win then
        return '<LeftMouse>'
      end
      vim.schedule(handle_panel_click)
      return ''
    end, { buffer = win.cmdlog_buf, expr = true, replace_keycodes = true, nowait = true, silent = true })
    vim.wo[win.cmdlog_win].signcolumn = 'no'
    vim.wo[win.cmdlog_win].winhighlight = 'Normal:GitPanelBg,FloatBorder:GitPanelBorder'
    -- フォーカス中(@で拡大)は @/q/Escで元の大きさに戻す。フォーカス前ならq/Escはパネル自体を閉じる
    for _, key in ipairs({ '@', 'q', '<Esc>' }) do
      vim.keymap.set('n', key, function()
        if cmdlog_focused then toggle_cmdlog_focus() else self.close() end
      end, { buffer = win.cmdlog_buf, nowait = true, silent = true })
    end
    -- 拡大表示中もパネル切替キーは効くようにする（left_bufにしかバインドされていないと、
    -- フォーカスがcmdlog_bufにある間は数字キー/矢印が反応しなくなってしまう）
    bind_switch_keys(win.cmdlog_buf)

    vim.api.nvim_create_autocmd('WinClosed', {
      group = augrp,
      pattern = tostring(win.tabbar_win) .. ',' .. tostring(win.left_win) .. ',' .. tostring(win.right_win) .. ',' .. tostring(win.cmdlog_win),
      callback = function() self.close() end,
    })

    self.win = win

    cfg.start(function(ok)
      if not ok then
        self.close()
        return
      end
      render_cmdlog()
      activate_panel(1)
      start_auto_refresh()
    end)
  end

  function self.open(fullscreen)
    if not (win.left_win and vim.api.nvim_win_is_valid(win.left_win)) then
      open(fullscreen)
    end
  end

  function self.toggle(fullscreen)
    if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
      self.close()
    else
      open(fullscreen)
    end
  end

  function self.is_open()
    return win.left_win ~= nil and vim.api.nvim_win_is_valid(win.left_win)
  end

  --- gitパネル固有のグローバルキー(push/pull等)から使うための公開API
  self.ctx = ctx
  self.win = win
  self.layout = layout
  self.switch_to = function(idx) switch_to(idx) end
  self.refresh_current_panel = function() refresh_current_panel() end
  self.set_loading = set_loading
  self.clear_loading = clear_loading

  return self
end

-- ══════════════════════════════════════════════
-- ハイライト（gitパネル・dockerパネル共通。名前の GitPanel* は歴史的経緯で
-- そのままだが、両パネルが同じ配色になるよう共有している）
-- ══════════════════════════════════════════════

function M.setup_hl()
  vim.api.nvim_set_hl(0, 'GitPanelBg',           { bg = 'NONE' })
  vim.api.nvim_set_hl(0, 'GitPanelBorder',       { bg = 'NONE', fg = '#565f89' })
  vim.api.nvim_set_hl(0, 'GitPanelCursorLine',   { bg = '#2d3250' })
  vim.api.nvim_set_hl(0, 'GitPanelHeader',       { fg = '#7aa2f7', bold = true })
  vim.api.nvim_set_hl(0, 'GitPanelSection',      { fg = '#e0af68', bold = true })
  vim.api.nvim_set_hl(0, 'GitPanelModified',     { fg = '#e0af68' })
  vim.api.nvim_set_hl(0, 'GitPanelAdded',        { fg = '#9ece6a' })
  vim.api.nvim_set_hl(0, 'GitPanelDeleted',      { fg = '#f7768e' })
  vim.api.nvim_set_hl(0, 'GitPanelStatusStaged',   { fg = '#9ece6a' })
  vim.api.nvim_set_hl(0, 'GitPanelStatusUnstaged', { fg = '#f7768e' })
  vim.api.nvim_set_hl(0, 'GitPanelTreeArrow',       { fg = '#626262' })
  vim.api.nvim_set_hl(0, 'GitPanelRenamed',      { fg = '#2ac3de' })
  -- 衝突（VSCode の Source Control と同じく赤・太字で最優先に見せる）
  vim.api.nvim_set_hl(0, 'GitPanelConflict',     { fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'GitPanelUntracked',    { fg = '#9ece6a', italic = true })
  vim.api.nvim_set_hl(0, 'GitPanelCurrent',      { fg = '#9ece6a', bold = true })
  vim.api.nvim_set_hl(0, 'GitPanelUnpushed',     { fg = '#f7768e' })
  vim.api.nvim_set_hl(0, 'GitPanelPushed',       { fg = '#e0af68' })
  vim.api.nvim_set_hl(0, 'GitPanelMerged',       { fg = '#9ece6a' })
  -- lazygit(presentation/branches.go WithPrColor)と同じ配色
  vim.api.nvim_set_hl(0, 'GitPanelPrOpen',       { fg = '#438440' })
  vim.api.nvim_set_hl(0, 'GitPanelPrClosed',     { fg = '#C9453C' })
  vim.api.nvim_set_hl(0, 'GitPanelPrMerged',     { fg = '#8259DD' })
  vim.api.nvim_set_hl(0, 'GitPanelPrDraft',      { fg = '#676C75' })
  -- PRのCI状態（GitHub風: 緑✓ / 黄○ / 赤✗）。dockerパネルでも
  -- running(緑)/restarting等(黄)/exited(赤) の状態色として共有する
  vim.api.nvim_set_hl(0, 'GitPanelCheckOk',      { fg = '#3fb950' })
  vim.api.nvim_set_hl(0, 'GitPanelCheckPending', { fg = '#d29922' })
  vim.api.nvim_set_hl(0, 'GitPanelCheckFail',    { fg = '#f85149' })
  vim.api.nvim_set_hl(0, 'GitPanelHunkSelected', { bg = '#2d3250' })
  vim.api.nvim_set_hl(0, 'GitPanelSelected',     { fg = '#e0af68', bg = '#e0af68' })
  vim.api.nvim_set_hl(0, 'GitPanelReviewAdded',  { fg = '#9ece6a' })
  vim.api.nvim_set_hl(0, 'GitPanelReviewDeleted',{ fg = '#f7768e' })
  vim.api.nvim_set_hl(0, 'GitPanelTabActive',    { fg = '#7aa2f7', bold = true })
  vim.api.nvim_set_hl(0, 'GitPanelTabInactive',  { fg = '#565f89' })
  -- 補助情報（イメージサイズ・作成日時など、主役ではない列）
  vim.api.nvim_set_hl(0, 'GitPanelDim',          { fg = '#565f89' })
  ui.setup_hl()
end

M.setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = M.setup_hl })

return M
