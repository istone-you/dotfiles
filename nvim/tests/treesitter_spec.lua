local T = dofile(TESTS_DIR .. '/helpers.lua')
local ts = require('config.treesitter')

-- nvim/tools/build-parsers.sh がビルドする言語（lua は Neovim 同梱なので入っていない）
local LANGS = {
  'go', 'gomod', 'gowork', 'gotmpl',
  'typescript', 'tsx', 'javascript',
  'terraform', 'toml', 'yaml', 'json', 'css', 'graphql', 'bash', 'rust',
}

-- パーサ(.so)は .gitignore 済みでビルドしないと存在しない。
-- ビルド済みの環境でだけ実パースまで検証し、無い環境では純粋なロジックだけ見る
local function has_parser(lang)
  return #vim.api.nvim_get_runtime_file('parser/' .. lang .. '.so', false) > 0
end

-- folds.scm が無い言語では enable_fold が false を返すことだけ見たいので、
-- 実バッファを用意せず現在バッファ相手に呼ぶ（buf 不一致で早期 return する経路も含む）
local function M_enable_fold_result(lang)
  return ts.enable_fold(vim.api.nvim_get_current_buf(), lang)
end

local function new_buf(ft, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = ''
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  if ft then vim.bo[buf].filetype = ft end
  return buf
end

T.describe('treesitter', function()
  T.describe('lang_for', function()
    T.it('maps filetypes whose name differs from the language name', function()
      T.eq(ts.lang_for('typescriptreact'), 'tsx')
      T.eq(ts.lang_for('javascriptreact'), 'javascript')
      T.eq(ts.lang_for('jsonc'), 'json')
      T.eq(ts.lang_for('sh'), 'bash')
    end)

    T.it('folds every terraform flavour onto the terraform dialect', function()
      T.eq(ts.lang_for('terraform'), 'terraform')
      T.eq(ts.lang_for('terraform-vars'), 'terraform')
      T.eq(ts.lang_for('opentofu'), 'terraform')
      T.eq(ts.lang_for('opentofu-vars'), 'terraform')
    end)

    T.it('resolves compound filetypes by their leading component', function()
      T.eq(ts.lang_for('yaml.gitlab'), 'yaml')
      T.eq(ts.lang_for('yaml.docker-compose'), 'yaml')
      -- 表に無い複合 filetype も先頭部分に倒れる
      T.eq(ts.lang_for('yaml.ansible'), 'yaml')
    end)

    T.it('passes through filetypes that share the language name', function()
      T.eq(ts.lang_for('go'), 'go')
      T.eq(ts.lang_for('typescript'), 'typescript')
      T.eq(ts.lang_for('lua'), 'lua')
    end)

    T.it('returns nil for an unset filetype', function()
      T.eq(ts.lang_for(''), nil)
      T.eq(ts.lang_for(nil), nil)
    end)
  end)

  T.describe('should_start', function()
    T.it('accepts a normal file buffer', function()
      -- python はパーサを置いていないので、autocmd 経由の start が失敗して
      -- 有効化されない = should_start の判定だけを単独で見られる
      local buf = new_buf('python', { 'x = 1' })
      T.ok(ts.should_start(buf), 'a normal buffer should be eligible')
    end)

    T.it('rejects non-file buffers (terminal / panels)', function()
      local buf = new_buf('python', { 'x = 1' })
      vim.bo[buf].buftype = 'nofile'
      T.ok(not ts.should_start(buf), 'nofile buffers should be skipped')
    end)

    T.it('rejects buffers without a filetype', function()
      local buf = new_buf(nil, { 'x' })
      T.ok(not ts.should_start(buf), 'a buffer with no filetype should be skipped')
    end)

    T.it('rejects buffers larger than MAX_BYTES', function()
      local buf = new_buf('python', { string.rep('a', 100) })
      local orig = ts.MAX_BYTES
      ts.MAX_BYTES = 10
      local got = ts.should_start(buf)
      ts.MAX_BYTES = orig
      T.ok(not got, 'oversized buffers should fall back to regex syntax')
    end)

    T.it('rejects invalid buffers', function()
      local buf = new_buf('python', { 'x = 1' })
      vim.api.nvim_buf_delete(buf, { force = true })
      T.ok(not ts.should_start(buf), 'a deleted buffer should be skipped')
    end)
  end)

  T.describe('start', function()
    T.it('returns false without erroring when no parser exists', function()
      local buf = new_buf('python', { 'x = 1' })
      T.eq(ts.start(buf), false)
      T.eq(vim.treesitter.highlighter.active[buf], nil)
    end)

    T.it('registers filetype -> language aliases', function()
      T.eq(vim.treesitter.language.get_lang('typescriptreact'), 'tsx')
    end)
  end)

  T.describe('vendored parsers', function()
    for _, lang in ipairs(LANGS) do
      T.it('loads the ' .. lang .. ' parser and its queries', function()
        if not has_parser(lang) then
          print('         (skipped: parser/' .. lang .. '.so not built)')
          return
        end
        T.ok(pcall(vim.treesitter.language.add, lang), lang .. ' parser should load (ABI mismatch?)')
        -- クエリは grammar のノード名に依存する。grammar だけ更新すると
        -- ここが落ちるので、クエリとリビジョンのズレはこのテストで気付ける
        for _, kind in ipairs({ 'highlights', 'injections' }) do
          local ok, q = pcall(vim.treesitter.query.get, lang, kind)
          T.ok(ok and q ~= nil, lang .. '/' .. kind .. '.scm should parse against the grammar')
        end
      end)
    end
  end)

  T.describe('FileType autocmd', function()
    T.it('highlights a go buffer end to end', function()
      if not has_parser('go') then
        print('         (skipped: parser/go.so not built)')
        return
      end
      local buf = new_buf('go', {
        'package main',
        '',
        'func Greet(name string) string {',
        '\treturn name',
        '}',
      })
      T.ok(vim.treesitter.highlighter.active[buf] ~= nil, 'FileType should have started treesitter')
      -- 二重に start しない（コアの ftplugin が既に有効にしている言語のため）
      T.ok(not ts.should_start(buf), 'an already-highlighted buffer should be skipped')

      vim.treesitter.get_parser(buf):parse(true)
      local caps = {}
      for _, c in ipairs(vim.treesitter.get_captures_at_pos(buf, 0, 0)) do
        table.insert(caps, c.capture)
      end
      T.contains(caps, 'keyword.import', '`package` should be captured as a keyword')
    end)

    T.it('highlights a tsx buffer through the typescriptreact alias', function()
      if not has_parser('tsx') then
        print('         (skipped: parser/tsx.so not built)')
        return
      end
      local buf = new_buf('typescriptreact', {
        'export const App = () => <div>hi</div>;',
      })
      T.ok(vim.treesitter.highlighter.active[buf] ~= nil, 'FileType should have started treesitter')
      T.eq(vim.treesitter.get_parser(buf):lang(), 'tsx')
    end)
  end)
  -- 対象言語の基準は「lsp.lua で LSP を設定している filetype」。
  -- lsp.lua に言語が増えたらここが落ちて、パーサとクエリの追加を促す
  T.describe('coverage against lsp.lua', function()
    local function lsp_filetypes()
      require('config.lsp')
      local seen, out = {}, {}
      for _, name in ipairs({ 'gopls', 'ts_ls', 'tofu_ls', 'terraformls', 'taplo',
        'yamlls', 'biome', 'bashls', 'lua_ls', 'rust_analyzer' }) do
        for _, ft in ipairs((vim.lsp.config[name] or {}).filetypes or {}) do
          if not seen[ft] then
            seen[ft] = true
            table.insert(out, ft)
          end
        end
      end
      table.sort(out)
      return out
    end

    T.it('has queries for every filetype configured in lsp.lua', function()
      local missing = {}
      for _, ft in ipairs(lsp_filetypes()) do
        local lang = ts.lang_for(ft)
        local found = #vim.api.nvim_get_runtime_file('queries/' .. lang .. '/highlights.scm', false) > 0
        if not found then table.insert(missing, ft .. ' -> ' .. lang) end
      end
      T.eq(missing, {}, 'add queries/<lang>/highlights.scm for these (see queries/README.md)')
    end)

    T.it('has a parser built for every filetype configured in lsp.lua', function()
      local missing = {}
      for _, ft in ipairs(lsp_filetypes()) do
        local lang = ts.lang_for(ft)
        if not has_parser(lang) then table.insert(missing, ft .. ' -> ' .. lang) end
      end
      if #missing > 0 and not has_parser('go') then
        print('         (skipped: parsers not built)')
        return
      end
      T.eq(missing, {}, 'add these to nvim/tools/build-parsers.sh and rebuild')
    end)
  end)
  -- build-parsers.sh の固定リビジョンと、実際にビルドした時の記録
  -- (parser-info/<lang>.revision) がズレていないか。nvim-treesitter の
  -- needs_update() 相当の検知をここでやる（起動時ではなくテストで拾う）
  T.describe('parser revisions', function()
    local NVIM_DIR = TESTS_DIR:gsub('/tests$', '')

    local function pinned_revisions()
      local out = {}
      for line in io.lines(NVIM_DIR .. '/tools/build-parsers.sh') do
        local lang, rev = line:match('^%s*"([%w_]+)|[^|]+|(%x+)|')
        if lang then out[lang] = rev end
      end
      return out
    end

    T.it('pins a revision for every language the module can resolve to', function()
      local pinned = pinned_revisions()
      local missing = {}
      for _, lang in ipairs(LANGS) do
        if not pinned[lang] then table.insert(missing, lang) end
      end
      T.eq(missing, {}, 'these languages are missing from tools/build-parsers.sh')
    end)

    T.it('has built .so files that match the pinned revisions', function()
      if not has_parser('go') then
        print('         (skipped: parsers not built)')
        return
      end
      local stale = {}
      for lang, rev in pairs(pinned_revisions()) do
        local f = io.open(NVIM_DIR .. '/parser-info/' .. lang .. '.revision', 'r')
        local got = f and f:read('*a') or nil
        if f then f:close() end
        if got ~= rev then
          table.insert(stale, string.format('%s (built=%s pinned=%s)',
            lang, (got or 'none'):sub(1, 7), rev:sub(1, 7)))
        end
      end
      table.sort(stale)
      T.eq(stale, {}, 'run nvim/tools/build-parsers.sh to rebuild these')
    end)
  end)
  -- Neovim 0.12 が持っている構文木ベースの機能（折りたたみ / インクリメンタル選択）が
  -- 実際に効いているか。ハイライトだけ有効でここが死んでいる状態を防ぐ
  T.describe('core integration', function()
    -- run.sh は -u NONE なので filetype 検出が働かない。
    -- FileType を明示的に起こして本番と同じ経路（autocmd -> start -> enable_fold）を通す
    local function open(path, ft)
      vim.cmd('edit ' .. path)
      vim.bo.filetype = ft
      return vim.api.nvim_get_current_buf()
    end

    T.it('drives folding from folds.scm', function()
      if not has_parser('go') then
        print('         (skipped: parser/go.so not built)')
        return
      end
      local buf = open(TESTS_DIR .. '/fixtures_ts_fold.go', 'go')
      T.eq(vim.wo.foldmethod, 'expr')
      T.eq(vim.wo.foldexpr, 'v:lua.vim.treesitter.foldexpr()')
      -- 開いた直後に畳まれていないこと
      T.ok(vim.wo.foldlevel >= 99, 'buffers should open unfolded')
      vim.cmd('normal! zx')
      local folded = 0
      for l = 1, vim.api.nvim_buf_line_count(buf) do
        if vim.fn.foldlevel(l) > 0 then folded = folded + 1 end
      end
      T.ok(folded > 0, 'the function body should produce a fold')
    end)

    T.it('leaves folding alone for languages without folds.scm', function()
      if not has_parser('gomod') then
        print('         (skipped: parser/gomod.so not built)')
        return
      end
      T.eq(#vim.api.nvim_get_runtime_file('queries/gomod/folds.scm', false), 0)
      T.eq(M_enable_fold_result('gomod'), false)
    end)

    T.it('enables folding for languages core already started (lua)', function()
      -- コアの ftplugin/lua.lua が先に start するので M.start は false を返すが、
      -- 折りたたみは設定されていないので on_filetype 側で拾う必要がある
      vim.cmd('edit ' .. TESTS_DIR .. '/fixtures_ts_fold.go')
      local buf = vim.api.nvim_get_current_buf()
      vim.treesitter.stop(buf)
      vim.bo[buf].filetype = 'go'
      vim.treesitter.start(buf, 'go')      -- コアの ftplugin を模す
      vim.wo[0][0].foldmethod = 'manual'   -- コアは foldmethod を変えない
      ts.on_filetype(buf)
      T.eq(vim.wo.foldmethod, 'expr')
    end)

    T.it('expands a visual selection to the enclosing node', function()
      if not has_parser('go') then
        print('         (skipped: parser/go.so not built)')
        return
      end
      open(TESTS_DIR .. '/fixtures_ts_fold.go', 'go')
      vim.api.nvim_win_set_cursor(0, { 4, 4 })
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes('vin<Esc>', true, false, true), 'x', false)
      local s_, e_ = vim.fn.getpos("'<"), vim.fn.getpos("'>")
      -- ノードの大きさは位置次第（識別子なら 1 行に収まる）なので、
      -- 「カーソル下の 1 文字より広い範囲が選ばれたか」だけを見る
      local single = s_[2] == e_[2] and s_[3] == e_[3]
      T.ok(not single, string.format(
        'v_in should select a node, got %d,%d..%d,%d', s_[2], s_[3], e_[2], e_[3]))
    end)
  end)
end)

T.summary()
