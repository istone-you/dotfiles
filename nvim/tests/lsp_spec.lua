-- lsp.luaは実LSPサーバーの起動確認まではしない(gopls/typescript-language-server等
-- が居ない環境でも通す)。検証するのは: 静的なサーバー設定が正しく登録されるか、
-- LspAttach時にバッファローカルキーマップが張られるか、保存時フォーマットの
-- フィルタが意図したクライアントだけを通すか、バイナリ欠落時に enable しないか
local T = dofile(TESTS_DIR .. '/helpers.lua')
require('config.lsp')

T.describe('lsp.lua: server config registration', function()
  T.it('registers gopls/ts_ls/tofu_ls/terraformls/taplo/yamlls/biome/bashls/lua_ls with the right cmd/filetypes/root_markers', function()
    local gopls = vim.lsp.config.gopls
    T.eq(gopls.cmd, { 'gopls' })
    T.contains(table.concat(gopls.filetypes, ','), 'go')
    T.contains(table.concat(gopls.root_markers, ','), 'go.mod')
    T.eq(gopls.settings.gopls.staticcheck, true)

    local ts_ls = vim.lsp.config.ts_ls
    T.eq(ts_ls.cmd, { 'typescript-language-server', '--stdio' })
    T.contains(table.concat(ts_ls.filetypes, ','), 'typescript')

    local tofu_ls = vim.lsp.config.tofu_ls
    T.eq(tofu_ls.cmd, { 'tofu-ls', 'serve' })
    T.contains(table.concat(tofu_ls.filetypes, ','), 'terraform')

    local terraformls = vim.lsp.config.terraformls
    T.eq(terraformls.cmd, { 'terraform-ls', 'serve' })
    T.contains(table.concat(terraformls.filetypes, ','), 'terraform')

    local taplo = vim.lsp.config.taplo
    T.eq(taplo.cmd, { 'taplo', 'lsp', 'stdio' })
    T.eq(taplo.filetypes, { 'toml' })

    local yamlls = vim.lsp.config.yamlls
    T.eq(yamlls.cmd, { 'yaml-language-server', '--stdio' })
    T.contains(table.concat(yamlls.filetypes, ','), 'yaml')

    local biome = vim.lsp.config.biome
    T.eq(biome.cmd, { 'biome', 'lsp-proxy' })
    T.contains(table.concat(biome.filetypes, ','), 'typescript')
    T.contains(table.concat(biome.root_markers, ','), 'biome.json')

    local bashls = vim.lsp.config.bashls
    T.eq(bashls.cmd, { 'bash-language-server', 'start' })
    T.contains(table.concat(bashls.filetypes, ','), 'sh')
    T.contains(table.concat(bashls.filetypes, ','), 'bash')
    T.contains(table.concat(bashls.root_markers, ','), '.git')

    local lua_ls = vim.lsp.config.lua_ls
    T.eq(lua_ls.cmd, { 'lua-language-server' })
    T.eq(lua_ls.filetypes, { 'lua' })
    T.contains(table.concat(lua_ls.root_markers, ','), '.luarc.json')
    T.eq(lua_ls.settings.Lua.runtime.version, 'LuaJIT')
    T.eq(lua_ls.settings.Lua.diagnostics.globals, { 'vim' })
    T.eq(lua_ls.settings.Lua.format.enable, false, 'lua_ls の整形は桁揃えを崩すので無効')
  end)

  T.it('points lua_ls workspace.library at VIMRUNTIME and the config lua dir', function()
    local library = vim.lsp.config.lua_ls.settings.Lua.workspace.library
    local joined = table.concat(library, ',')
    T.contains(joined, vim.env.VIMRUNTIME .. '/lua')
    T.contains(joined, vim.fn.stdpath('config') .. '/lua')
  end)
end)

T.describe('lsp.lua: LspAttach keymaps', function()
  T.it('binds K/<leader>rn/<leader>ca/<leader>f/[d/]d/<leader>E buffer-locally on attach', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_exec_autocmds('LspAttach', { buffer = buf, data = { client_id = 1 } })

    for _, key in ipairs({ 'K', '<leader>rn', '<leader>ca', '<leader>f', '[d', ']d', '<leader>E' }) do
      local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
      local found = false
      for _, m in ipairs(maps) do
        if vim.api.nvim_replace_termcodes(m.lhs, true, false, true)
            == vim.api.nvim_replace_termcodes(key, true, false, true) then
          found = true
        end
      end
      T.ok(found, key .. ' should be bound buffer-locally after LspAttach')
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

-- Neovim 0.11 以降の LSP デフォルトマッピング(gr*)を消しているかどうか。
-- 残っていると gr（peek: 参照元）が「grn などの続きが来るか」を待って
-- timeoutlen ぶん遅れる。機能としては全て別キーに割り当て直してあるので
-- 使わないが、この遅延だけが体感に出るので消す必要がある
T.describe('lsp.lua: built-in gr* mappings', function()
  T.it('removes the built-in gr* LSP mappings so that gr fires without waiting for timeoutlen', function()
    for _, lhs in ipairs({ 'grn', 'grr', 'gri', 'grt', 'grx' }) do
      T.ok(vim.tbl_isempty(vim.fn.maparg(lhs, 'n', false, true)),
        lhs .. ' should be removed (it makes gr wait for timeoutlen)')
    end
    for _, mode in ipairs({ 'n', 'x' }) do
      T.ok(vim.tbl_isempty(vim.fn.maparg('gra', mode, false, true)),
        'gra should be removed in ' .. mode .. ' mode')
    end

    -- 消したあとも、代替として割り当てているキーは生きていること
    require('config.peek')
    T.contains(vim.fn.maparg('gr', 'n', false, true).desc or '', 'references')
    local ev = { buf = vim.api.nvim_get_current_buf() }
    vim.api.nvim_exec_autocmds('LspAttach', { buffer = ev.buf })
    T.contains(vim.fn.maparg('<leader>rn', 'n', false, true).desc or '', 'リネーム')
    T.contains(vim.fn.maparg('<leader>ca', 'n', false, true).desc or '', 'コードアクション')
  end)
end)

T.describe('lsp.lua: format-on-save filter', function()
  T.it('BufWritePre triggers vim.lsp.buf.format with a filter that allows gopls/tofu_ls/terraformls/taplo/yamlls/biome/bashls', function()
    local captured_filter
    local orig_format = vim.lsp.buf.format
    vim.lsp.buf.format = function(opts) captured_filter = opts and opts.filter end

    vim.api.nvim_exec_autocmds('BufWritePre', {})
    vim.lsp.buf.format = orig_format

    T.ok(captured_filter ~= nil, 'BufWritePre should call vim.lsp.buf.format with a filter')
    T.eq(captured_filter({ name = 'gopls' }), true)
    T.eq(captured_filter({ name = 'tofu_ls' }), true)
    T.eq(captured_filter({ name = 'terraformls' }), true)
    T.eq(captured_filter({ name = 'taplo' }), true)
    T.eq(captured_filter({ name = 'yamlls' }), true)
    T.eq(captured_filter({ name = 'biome' }), true)
    T.eq(captured_filter({ name = 'bashls' }), true)
    T.eq(captured_filter({ name = 'ts_ls' }), false, 'ts_ls should not be auto-formatted on save')
    T.eq(captured_filter({ name = 'lua_ls' }), false, 'lua_ls should not be auto-formatted on save')
  end)
end)

T.describe('lsp.lua: enable only when binary exists', function()
  T.it('prefers tofu_ls over terraformls when tofu-ls is available', function()
    if vim.fn.executable('tofu-ls') == 1 then
      T.eq(vim.lsp.is_enabled('tofu_ls'), true)
      T.eq(vim.lsp.is_enabled('terraformls'), false)
    elseif vim.fn.executable('terraform-ls') == 1 then
      T.eq(vim.lsp.is_enabled('tofu_ls'), false)
      T.eq(vim.lsp.is_enabled('terraformls'), true)
    else
      T.eq(vim.lsp.is_enabled('tofu_ls'), false)
      T.eq(vim.lsp.is_enabled('terraformls'), false)
    end
  end)

  T.it('enables gopls/ts_ls/taplo/yamlls/biome/bashls/lua_ls only when their binaries exist', function()
    local pairs_ = {
      { 'gopls', 'gopls' },
      { 'ts_ls', 'typescript-language-server' },
      { 'taplo', 'taplo' },
      { 'yamlls', 'yaml-language-server' },
      { 'biome', 'biome' },
      { 'bashls', 'bash-language-server' },
      { 'lua_ls', 'lua-language-server' },
    }
    for _, p in ipairs(pairs_) do
      local name, bin = p[1], p[2]
      local expect = vim.fn.executable(bin) == 1
      T.eq(vim.lsp.is_enabled(name), expect, name .. ' enable should match ' .. bin)
    end
  end)
end)

T.describe('lsp.lua: yamlls reads .vscode/settings.json', function()
  T.it('loads yaml.* from repo-root .vscode/settings.json when present', function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/.vscode', 'p')
    vim.fn.writefile({
      '{',
      '  "yaml.format.printWidth": 250, // comment',
      '  "yaml.format.bracketSpacing": false,',
      '  "yaml.schemas": { "https://example.com/schema.json": ["*.yml"] },',
      '  "editor.formatOnSave": true,', -- VS Code JSONC の末尾カンマ
      '}',
    }, root .. '/.vscode/settings.json')

    local config = { root_dir = root, settings = {} }
    vim.lsp.config.yamlls.before_init({}, config)

    T.eq(config.settings.yaml.format.printWidth, 250)
    T.eq(config.settings.yaml.format.bracketSpacing, false)
    T.eq(config.settings.yaml.schemas['https://example.com/schema.json'], { '*.yml' })
  end)

  T.it('leaves settings untouched when .vscode/settings.json is absent', function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local config = { root_dir = root, settings = {} }
    vim.lsp.config.yamlls.before_init({}, config)
    T.eq(config.settings, {})
  end)
end)

T.summary()
