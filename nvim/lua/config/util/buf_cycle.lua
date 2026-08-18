-- タブラインと同じ対象（listed・名前付き・非 terminal）だけを巡回する。
-- 空の[No Name]はタブに出ないのに :bnext では挟まるため、ここ経由に揃える。

local M = {}

-- タブの並び。タブラインのドラッグで入れ替えた結果をここに持つ。
-- ここに無いバッファ（新しく開いたもの）は bufnr 順で末尾に付く。
local order = {}

local function filtered()
  return vim.tbl_filter(function(b)
    return vim.bo[b].buflisted
      and vim.api.nvim_buf_is_valid(b)
      and vim.bo[b].buftype ~= 'terminal'
      and vim.api.nvim_buf_get_name(b) ~= ''
  end, vim.api.nvim_list_bufs())
end

function M.list()
  local bufs = filtered()
  local alive = {}
  for _, b in ipairs(bufs) do alive[b] = true end

  local out, seen = {}, {}
  for _, b in ipairs(order) do
    if alive[b] and not seen[b] then
      out[#out + 1] = b
      seen[b] = true
    end
  end
  for _, b in ipairs(bufs) do
    if not seen[b] then
      out[#out + 1] = b
      seen[b] = true
    end
  end

  order = out -- 閉じたバッファを落として詰め直す
  return out
end

--- bufnr を steps 分だけ並びの中で動かす（負で左）。動いたら true。
function M.move(bufnr, steps)
  local bufs = M.list()
  local idx
  for i, b in ipairs(bufs) do
    if b == bufnr then
      idx = i
      break
    end
  end
  if not idx then return false end

  local target = math.max(1, math.min(#bufs, idx + steps))
  if target == idx then return false end

  table.remove(bufs, idx)
  table.insert(bufs, target, bufnr)
  order = bufs
  return true
end

local function cycle(dir)
  local bufs = M.list()
  if #bufs == 0 then return end
  local cur = vim.api.nvim_get_current_buf()
  local idx
  for i, b in ipairs(bufs) do
    if b == cur then
      idx = i
      break
    end
  end
  local win_util = require('config.util.win_util')
  if not idx then
    win_util.open_buf(dir > 0 and bufs[1] or bufs[#bufs])
    return
  end
  local next_idx = ((idx - 1 + dir) % #bufs) + 1
  win_util.open_buf(bufs[next_idx])
end

function M.next() cycle(1) end
function M.prev() cycle(-1) end

-- バッファを削除するが、それを表示しているウィンドウは閉じない。
-- nvim_buf_delete は対象を表示中のウィンドウごと閉じてしまい、開いている
-- ファイルを削除すると「最後の編集窓が消える → auto_quit が nvim を終了」を招く。
-- 先に各ウィンドウを別バッファ（巡回対象の別ファイル、無ければ新規の空バッファ）へ
-- 退避してから削除することで、窓とレイアウトを保つ。
---@param bufnr integer
---@return boolean deleted
function M.delete_keep_windows(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end

  local alt
  for _, b in ipairs(M.list()) do
    if b ~= bufnr then alt = b break end
  end

  local fallback
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      local target = alt
      if not target then
        -- 他に開いているファイルが無ければ空バッファを1つ作って各窓で共有する
        if not fallback then fallback = vim.api.nvim_create_buf(true, false) end
        target = fallback
      end
      vim.api.nvim_win_set_buf(win, target)
    end
  end

  local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  return ok
end

return M
