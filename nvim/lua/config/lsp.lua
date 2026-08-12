local util = require('config.util.lsp_util')

local function load_local_lsp_config()
  local path = vim.fn.stdpath('config') .. '/local.lua'
  if vim.fn.filereadable(path) == 1 then
    local ok, result = pcall(dofile, path)
    if ok and type(result) == 'table' then return result end
  end
  return {}
end

local local_cfg = load_local_lsp_config()

vim.lsp.config('gopls', {
  cmd         = { 'gopls' },
  filetypes   = { 'go', 'gomod', 'gowork', 'gotmpl' },
  root_markers = { 'go.work', 'go.mod', '.git' },
  settings    = {
    gopls = {
      analyses  = { unusedparams = true },
      staticcheck = true,
      gofumpt   = true,
    },
  },
})

vim.lsp.config('ts_ls', {
  cmd         = { 'typescript-language-server', '--stdio' },
  filetypes   = { 'typescript', 'typescriptreact', 'javascript', 'javascriptreact' },
  root_markers = { 'tsconfig.json', 'jsconfig.json', 'package.json', '.git' },
  init_options = local_cfg.tsserver_path and {
    tsserver = { path = local_cfg.tsserver_path },
  } or nil,
})

-- Terraform / OpenTofu:
-- tofu-ls があればそれを使い、無ければ terraform-ls を救済として使う。
-- どちらも無ければ他 LSP と同様に無効（enable しない）。
vim.lsp.config('tofu_ls', {
  cmd          = { 'tofu-ls', 'serve' },
  filetypes    = { 'opentofu', 'opentofu-vars', 'terraform', 'terraform-vars' },
  root_markers = { '.terraform', '.opentofu', '.git' },
  settings     = {
    ['tofu-ls'] = {
      tofu = {
        path = vim.fn.exepath('tofu'),
      },
    },
  },
})

vim.lsp.config('terraformls', {
  cmd          = { 'terraform-ls', 'serve' },
  filetypes    = { 'terraform', 'terraform-vars' },
  root_markers = { '.terraform', '.opentofu', '.git' },
  settings     = {
    ['terraform-ls'] = {
      -- CLI は tofu 優先、無ければ terraform
      terraformExecPath = util.has_cmd('tofu') and vim.fn.exepath('tofu')
                          or vim.fn.exepath('terraform'),
    },
  },
})

vim.lsp.config('taplo', {
  cmd          = { 'taplo', 'lsp', 'stdio' },
  filetypes    = { 'toml' },
  root_markers = { '.taplo.toml', 'taplo.toml', '.git' },
})

vim.lsp.config('yamlls', {
  cmd          = { 'yaml-language-server', '--stdio' },
  filetypes    = { 'yaml', 'yaml.docker-compose', 'yaml.gitlab' },
  root_markers = { '.git' },
  before_init  = util.yamlls_before_init,
})

vim.lsp.config('biome', {
  cmd          = { 'biome', 'lsp-proxy' },
  filetypes    = {
    'javascript',
    'javascriptreact',
    'typescript',
    'typescriptreact',
    'json',
    'jsonc',
    'css',
    'graphql',
  },
  root_markers = { 'biome.json', 'biome.jsonc', 'package.json', '.git' },
})

vim.lsp.config('bashls', {
  cmd          = { 'bash-language-server', 'start' },
  filetypes    = { 'sh', 'bash' },
  root_markers = { '.git' },
})

-- Rust:
-- rust-analyzer は rustup 経由で入るのが普通なので、cmd はそのまま `rust-analyzer`。
-- check.command は clippy があればそちらを使う（無い環境で clippy を指定すると
-- 保存のたびに rust-analyzer がエラーを出すため）。tofu-ls / terraform-ls の
-- 振り分けと同じ考え方。
vim.lsp.config('rust_analyzer', {
  cmd          = { 'rust-analyzer' },
  filetypes    = { 'rust' },
  root_markers = { 'Cargo.toml', 'rust-project.json', '.git' },
  settings     = {
    ['rust-analyzer'] = {
      cargo = { allFeatures = true },
      check = {
        command = util.has_cmd('cargo-clippy') and 'clippy' or 'check',
      },
    },
  },
})

-- Lua:
-- この設定リポジトリ自体が主な対象なので、Neovim ランタイムをライブラリに入れて
-- `vim` グローバルと vim.* API を解決できるようにする。
-- フォーマッタは無効。ここの Lua は `=` を手で桁揃えしているスタイルで、
-- lua-language-server の整形はそれを崩すため（有効にしたいときは format.enable = true）。
vim.lsp.config('lua_ls', {
  cmd          = { 'lua-language-server' },
  filetypes    = { 'lua' },
  root_markers = { '.luarc.json', '.luarc.jsonc', 'stylua.toml', '.stylua.toml', '.git' },
  settings     = {
    Lua = {
      runtime     = { version = 'LuaJIT' },
      diagnostics = { globals = { 'vim' } },
      workspace   = {
        library         = util.nvim_runtime_library(),
        checkThirdParty = false,
      },
      format      = { enable = false },
      telemetry   = { enable = false },
    },
  },
})

-- HTML。タグは `div#id.class` という名前・kind=Field のシンボルとして返るので、
-- winbar のパンくずと context のスティッキーヘッダが HTML でも
-- 「今どの要素の中か」を出せる（VS Code の breadcrumbs と同じ出どころ）。
-- フォーマッタは無効。既存の整形を勝手に崩さないため。
vim.lsp.config('html', {
  cmd          = { 'vscode-html-language-server', '--stdio' },
  filetypes    = { 'html' },
  root_markers = { 'package.json', '.git' },
  init_options = {
    provideFormatter     = false,
    embeddedLanguages    = { css = true, javascript = true },
    configurationSection = { 'html', 'css', 'javascript' },
  },
})

local tf_server = util.has_cmd('tofu-ls') and 'tofu_ls'
  or (util.has_cmd('terraform-ls') and 'terraformls' or nil)

local to_enable = { 'gopls', 'ts_ls', 'taplo', 'yamlls', 'biome', 'bashls', 'lua_ls',
  'rust_analyzer', 'html' }
if tf_server then
  table.insert(to_enable, tf_server)
end
util.enable_if_available(to_enable)

vim.diagnostic.config({
  virtual_text  = { prefix = '●' },
  signs         = true,
  underline     = true,
  update_in_insert = false,
  severity_sort = true,
  float         = { border = 'rounded' },
})

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local function map(key, fn, desc)
      vim.keymap.set('n', key, fn, { buffer = ev.buf, desc = desc })
    end
    -- border 無しだと透過背景でコードと地続きに見えるため付ける（signature と同じ）
    map('K', function() vim.lsp.buf.hover({ border = 'rounded' }) end, 'LSP: ホバー')
    -- 表示中フロートの win id は b:lsp_floating_preview に入る
    map('<Esc>', function()
      local win = vim.b.lsp_floating_preview
      if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end, 'LSP: ホバー/シグネチャを閉じる')
    map('<leader>rn', vim.lsp.buf.rename,           'LSP: リネーム')
    map('<leader>ca', vim.lsp.buf.code_action,      'LSP: コードアクション')
    map('<leader>f',  vim.lsp.buf.format,           'LSP: フォーマット')
    map('[d',         vim.diagnostic.goto_prev,     'LSP: 前の診断へ')
    map(']d',         vim.diagnostic.goto_next,     'LSP: 次の診断へ')
    map('<leader>E',  vim.diagnostic.open_float,    'LSP: 診断の詳細')
  end,
})

util.setup_format_on_save({
  gopls       = true,
  tofu_ls     = true,
  terraformls = true,
  taplo       = true,
  yamlls      = true,
  biome       = true,
  bashls      = true,
  rust_analyzer = true,
})
