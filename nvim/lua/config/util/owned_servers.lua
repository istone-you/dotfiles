-- この nvim プロセスが自前で listen している HTTP サーバを、ポート番号で止める。
--
-- ports_panel が「nvim ごと kill せずサーバーだけ閉じたい」ときに使う。
-- 自プロセスならここを直接呼び、別 nvim なら相手の nvim-api 経由で同じ処理を依頼する。
--
-- providers はテストから差し替えられるようにフィールドで持つ。

local M = {}

---@class OwnedServerProvider
---@field id string
---@field label string
---@field module string
---@field serving_port fun(mod: table): integer|nil
---@field stop fun(mod: table)

M.providers = {
  {
    id = 'diff_review',
    label = 'Diff Review',
    module = 'config.diff_review',
    serving_port = function(mod) return mod.serving_port and mod.serving_port() or nil end,
    stop = function(mod) mod.close({ silent = true }) end,
  },
  {
    id = 'code_notes',
    label = 'Code Notes',
    module = 'config.code_notes',
    serving_port = function(mod) return mod.serving_port and mod.serving_port() or nil end,
    stop = function(mod) mod.close({ silent = true }) end,
  },
  {
    id = 'notes',
    label = 'Notes Browser',
    module = 'config.notes_web',
    serving_port = function(mod) return mod.serving_port and mod.serving_port() or nil end,
    stop = function(mod) mod.stop() end,
  },
  {
    id = 'markdown',
    label = 'Markdown preview',
    module = 'config.browser.markdown',
    serving_port = function(mod) return mod.serving_port and mod.serving_port() or nil end,
    stop = function(mod) mod.stop({ notify = false }) end,
  },
  {
    id = 'html',
    label = 'HTML preview',
    module = 'config.browser.html',
    serving_port = function(mod) return mod.serving_port and mod.serving_port() or nil end,
    stop = function(mod) mod.stop({ notify = false }) end,
  },
  {
    id = 'nvim_api',
    label = 'nvim API',
    module = 'config.nvim_api',
    serving_port = function(mod) return mod.serving_port and mod.serving_port() or nil end,
    stop = function(mod) mod.stop({ silent = true }) end,
  },
}

--- このプロセスが port で待ち受けている自前サーバを探す。
---@return OwnedServerProvider|nil provider
---@return table|nil mod
function M.find(port)
  port = tonumber(port)
  if not port then return nil, nil end
  for _, p in ipairs(M.providers) do
    local ok, mod = pcall(require, p.module)
    if ok and type(mod) == 'table' then
      local ok_port, serving = pcall(p.serving_port, mod)
      if ok_port and tonumber(serving) == port then
        return p, mod
      end
    end
  end
  return nil, nil
end

--- port の自前サーバを止める。無ければ false。
---@return boolean stopped
---@return OwnedServerProvider|nil provider
function M.stop(port)
  local provider, mod = M.find(port)
  if not provider or not mod then return false, nil end
  provider.stop(mod)
  return true, provider
end

return M
