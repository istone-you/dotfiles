-- メモ帳。stdpath('config')/notes/ 以下に *.md を置き、内容は実ファイルとして永続化する。
-- <leader>m で fzf + rg の1画面を開く。空クエリでメモ一覧（各行は先頭行＝見出しで表示）、
-- 打てば本文をインクリメンタル検索、Enter でその位置を開く。Ctrl-n で空メモを即作成して開く。
--
-- 探すのは常に「中身」なのでファイル名は識別子でよく、作成時に名前を決めさせない。
-- ファイル名はタイムスタンプ、タイトルは本文の先頭行で管理する（Obsidian 等と同じ発想）。
-- 一覧表示は fzf の --with-nth で「path:1:1:先頭行」の先頭行部分だけを見せ、パスは裏に隠す。
-- fzf/rg の使い方は search.lua の流儀に合わせている。
-- Requirements: rg, fzf
--
-- ロジック（new_note_path / create_blank / parse_result_line）は dir を引数で受け、
-- stdpath や時刻に触れずテストできるようにしてある。UI（M.open）だけが M.dir()/os.date を使う。

local M = {}

local win_util = require('config.util.win_util')

local function has_cmd(name)
  return vim.fn.executable(name) == 1
end

--- notes ディレクトリの絶対パス（= ~/.config/nvim/notes）。
--- symlink 差異を避けるため normalize してから返す（.config/CLAUDE.md のパス方針）。
function M.dir()
  return vim.fs.normalize(vim.fn.stdpath('config') .. '/notes')
end

--- dir/<stamp>.md を返す。既にあれば -2, -3 ... を付けて衝突を避ける（同秒の連続作成対策）。
function M.new_note_path(dir, stamp)
  local base = dir .. '/' .. stamp
  local path = base .. '.md'
  local n = 2
  while vim.fn.filereadable(path) == 1 do
    path = base .. '-' .. n .. '.md'
    n = n + 1
  end
  return path
end

--- 空のメモを作ってその絶対パスを返す。タイトルは付けない（本文の先頭行に任せる）。
function M.create_blank(dir, stamp)
  vim.fn.mkdir(dir, 'p')
  local path = M.new_note_path(dir, stamp)
  local f = io.open(path, 'w')
  if f then f:close() end
  return path
end

--- fzf で選ばれた 1 行を { path, lnum, col } に分解する。dir を基準に相対パスを絶対化する。
--- 本文ヒット行（path:line:col:text）も一覧行（path:1:1:先頭行）も同じ形なので同じ処理で扱える。
--- rg --color=always の ANSI は先に除去する。空行・パス無しは nil。
function M.parse_result_line(line, dir)
  line = (line or ''):gsub('\27%[[0-9;]*m', '')
  if line == '' then return nil end
  local path, lnum, col = line:match('^(.-):(%d+):(%d+):')
  if not path then
    path, lnum = line:match('^(.-):(%d+):')
    col = '1'
  end
  if not path then
    path, lnum, col = line, '1', '1'
  end
  if path == '' then return nil end
  if path:sub(1, 1) ~= '/' then
    path = dir .. '/' .. path
  end
  return { path = path, lnum = tonumber(lnum) or 1, col = tonumber(col) or 1 }
end

--- 通常バッファとして開く（編集・保存は標準どおり）。編集窓へ必ず開く。
local function open_result(res)
  if not res then return end
  win_util.focus_editor()
  vim.cmd('edit ' .. vim.fn.fnameescape(res.path))
  pcall(vim.api.nvim_win_set_cursor, 0, { res.lnum, math.max(res.col - 1, 0) })
  vim.cmd('normal! zz')
end

-- fzf の reload コマンド（search.lua と同様に {q} を fzf が埋める）。
-- 空クエリ: *.md を「path:1:1:先頭行」で列挙（先頭の # は外す。空ファイルはファイル名で代替）。
-- 非空クエリ: 本文検索（no-match の exit1 は || true で握る）。
-- printf の \n を活かすため長括弧文字列（エスケープ非処理）で書く。
local function rg_reload()
  -- [==[ ]==] を使う理由: 中の sed の [[:space:]] に ]] が含まれ、素の [[ ]] だと早期終了する。
  return [==[set -f; if test x{q} = x; then rg --files -g '*.md' | while IFS= read -r f; do t=$(grep -m1 . -- "$f" 2>/dev/null | sed 's/^#\+[[:space:]]*//'); [ -z "$t" ] && t=$(basename "$f" .md); printf '%s:1:1:%s\n' "$f" "$t"; done; else rg --column --line-number --no-heading --color=always --smart-case -g '*.md' -- {q} || true; fi]==]
end

local HEADER = 'Enter:開く  Ctrl-n:新規メモ  Ctrl-u:入力クリア  Esc:閉じる'

--- メモ画面を開く。fzf をフロート端末で起動し、終了時に「開く / 新規作成」を処理する。
function M.open()
  if not has_cmd('rg') then
    vim.notify('rg が見つかりません', vim.log.levels.ERROR)
    return
  end
  if not has_cmd('fzf') then
    vim.notify('fzf が見つかりません', vim.log.levels.ERROR)
    return
  end

  local dir = M.dir()
  vim.fn.mkdir(dir, 'p')

  local out = vim.fn.tempname()
  local action_file = vim.fn.tempname()
  local closing = false
  local job_id

  -- Ctrl-n: 「new」印を一時ファイルへ書いてから accept。実際の作成は on_exit 側で行う。
  local new_bind = 'ctrl-n:execute-silent(printf new > ' .. action_file .. ')+accept'
  local fzf_cmd = table.concat({
    'fzf',
    '--ansi',
    '--disabled',       -- 絞り込みは rg 側（reload）に任せる
    '--print-query',    -- 1行目に検索文字列
    '--delimiter', ':',
    '--with-nth', '4..', -- 表示は「先頭行 / ヒット本文」だけ（path:line:col は裏に隠す）
    '--prompt', "'メモ検索> '",
    '--header', vim.fn.shellescape(HEADER),
    '--preview-window', "'right,50%'",
    '--preview', vim.fn.shellescape([[sed -n '1,200p' -- {1}]]),
    '--bind', vim.fn.shellescape('start:reload:' .. rg_reload()),
    '--bind', vim.fn.shellescape('change:reload:' .. rg_reload()),
    '--bind', "'ctrl-u:clear-query'",
    '--bind', vim.fn.shellescape(new_bind),
  }, ' ')

  local shell = string.format(
    'cd %s && %s > %s',
    vim.fn.shellescape(dir), fzf_cmd, vim.fn.shellescape(out)
  )

  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.85)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height, col = col, row = row,
    style = 'minimal', border = 'single', title = ' メモ ', title_pos = 'center',
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'

  local function cleanup()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    for _, f in ipairs({ out, action_file }) do pcall(vim.fn.delete, f) end
  end

  local function cancel()
    if closing then return end
    closing = true
    if job_id then pcall(vim.fn.jobstop, job_id) end
    cleanup()
  end

  job_id = vim.fn.termopen({ 'sh', '-c', shell }, {
    on_exit = function()
      vim.schedule(function()
        if closing then return end
        closing = true

        local action
        if vim.fn.filereadable(action_file) == 1 then
          action = vim.trim((vim.fn.readfile(action_file))[1] or '')
        end
        -- --print-query: 1行目が検索文字列、2行目以降が選択行（--with-nth でも出力は元の全行）
        local selected = {}
        if vim.fn.filereadable(out) == 1 then
          local raw = vim.fn.readfile(out)
          for i = 2, #raw do
            if raw[i] ~= '' then selected[#selected + 1] = raw[i] end
          end
        end
        cleanup()

        if action == 'new' then
          local path = M.create_blank(dir, os.date('%Y%m%d-%H%M%S'))
          win_util.focus_editor()
          vim.cmd('edit ' .. vim.fn.fnameescape(path))
          vim.cmd('startinsert') -- すぐタイトル（先頭行）を書ける
          return
        end
        if selected[1] then
          open_result(M.parse_result_line(selected[1], dir))
        end
      end)
    end,
  })

  -- Esc は一段で閉じる（fzf も Esc/Ctrl-c で abort するが、端末側で先取りして確実に閉じる）
  vim.keymap.set('t', '<Esc>', cancel, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, nowait = true })

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then vim.cmd('startinsert') end
  end)
end

vim.keymap.set('n', '<leader>m', M.open,
  { desc = 'メモ帳（notes/ を本文検索・Ctrl-n で新規、内容はローカル永続）' })

return M
