# queries/

tree-sitter のクエリ（構文木のノードにハイライトグループを割り当てる定義）。
プラグインを入れない方針のため、[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
の `runtime/queries/<lang>/` からコピーしている（Apache-2.0）。

- 取得元リビジョン: `c9f9ed6c1892f629ea399f4ee7905f2686fa13f2`
- 取得するのは `highlights.scm` / `injections.scm` / `folds.scm` の 3 つ。
  `locals.scm` と `indents.scm` は Neovim コアが読まないので置いていない
- 対象言語は `lua/config/lsp.lua` の filetype に合わせている（lua は Neovim 同梱）
- `ecma` / `jsx` / `hcl` はパーサを持たない継承元専用。`typescript/highlights.scm` の
  `; inherits: ecma` から引かれる

更新するときは `nvim/tools/build-parsers.sh` の grammar リビジョンと必ず一緒に上げること。
片方だけ上げるとノード名がズレてバッファを開くたびにエラーが出る。
対応は `nvim/tests/run.sh treesitter` が固定している。
