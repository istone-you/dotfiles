# .config

Neovim 等の設定ファイル群。

## nvim の機能

プラグインは使わず、すべて Lua で自作している（`nvim/lua/config/` 配下）。キーマップの全一覧は Neovim 上で `Space ?` を押すと開くパネルで確認できる。

### エディタ / UI

| 機能 | 説明 | 主なキー |
|---|---|---|
| `start_screen` | 起動時（ファイル未指定）に表示する編集不可のスタート画面。空の `[No Name]` バッファを置き換える | — |
| `tabline` | VSCode 風のバッファタブライン（Nerd Font アイコン付き） | `Tab` / `Shift-Tab` で切替、`Space q` で閉じる |
| `winbar` | 各ウィンドウ上端に開いているファイルの cwd 相対パスをパンくず表示 | — |
| `scrollbar` | 各ウィンドウにスクロールバーを表示 | — |
| `hidden_cursor` | 一覧選択系パネル（explorer / git パネル等）でテキストカーソルを隠し、カーソル行の強調だけで現在地を示す | — |
| `panel_focus` | 非フォーカスのパネルでは選択強調を沈め、どこにフォーカスがあるか分かるようにする | — |
| `treesitter` | tree-sitter による構文ハイライトと折りたたみ。プラグインは使わず、パーサは自前ビルド（`nvim/tools/build-parsers.sh`）、クエリは `nvim/queries/` に vendoring。対象言語は `lsp.lua` に合わせてある | `zc` / `za`（折りたたみ）、`an` / `in`（ノード選択） |
| `hlchunk` | 現在カーソルがあるコードチャンク（囲みブロック）を縦線でハイライト | — |
| `zenkaku` | 全角スペース（U+3000）を灰色背景で可視化する（VS Code の zenkaku 相当） | — |
| `autopairs` | 括弧・クォートを自動でペア補完（閉じの上でスキップ、空ペアの `<BS>` で両削除、括弧内 `<CR>` でインデント展開）。直前が `\` やクォートが単語隣接なら補完しない | 入力時に自動 |
| `surround` | 単語（`iw`）や選択範囲を括弧・クォートでトグル的に囲む/外す（開き括弧キー `( [ {` はスペース付き `( x )`、閉じキー `) ] }` はスペース無し `(x)`） | `Space s{文字}` |
| `context` | スクロールアウトした親スコープ行をスティッキーに表示 | — |
| `indent` | 開いたファイルの中身からインデント幅（タブ / スペース何個）を検出してバッファに適用。優先順位は `.editorconfig`（Neovim 組み込み）> 自動検出 > 既定値（2 スペース） | — |
| `quit_confirm` | `:q` などで Neovim を終了する直前に確認ポップアップを出す（`:q!` など `!` 付きは即終了） | `:q` / `:qa` 等 |
| `auto_quit` | 実編集ウィンドウが無くなり、explorer や git パネル等のユーティリティ窓だけ残ったら自動終了 | — |

### ファイル / 検索 / ナビゲーション

| 機能 | 説明 | 主なキー |
|---|---|---|
| `explorer` | ファイルエクスプローラ（右パネル・単一カラム）。作成 / リネーム / 削除 / コピー / 再帰検索など | `Space e` |
| `search` | 全ファイル内容検索 / 置換。Ctrl-i/Ctrl-e で include/exclude グロブ絞り込み欄へ出入り（ファイル名検索は explorer の `/`） | `Space /`、`Space *` |

### Git

| 機能 | 説明 | 主なキー |
|---|---|---|
| `git_panel` | git 管理パネル（中央ポップアップ）。Files / Commits / Branches / Stash / Worktree / PR を切替 | `Space g` |
| `git_blame` | GitLens 風のインライン git blame 表示 | — |
| `git_gutter` | VSCode 風にエディタ余白（ガター）へ git 差分を表示 | — |
| `git_conflict` | VSCode 風のコンフリクト解消。衝突ブロックを色分けし、現在 / 入力側 / 両方を採用（ファイル全体も可）・衝突間の移動・左右 diff 比較。pull で衝突したら git パネルが Files へ切り替わり `m` で解消メニュー | `Space x c` / `]x` |
| `github_permalink` | 現在行 / 選択行の GitHub パーマリンクを生成してコピー | `Space G` |

### Docker

| 機能 | 説明 | 主なキー |
|---|---|---|
| `docker_panel` | docker 管理パネル（中央ポップアップ）。Project / Containers / Images / Volumes / Networks を切替。右ペインは `[` / `]` またはクリックで Logs / Stats / Config / Top を切替。コンテナは compose プロジェクト単位、イメージ / ボリュームは使用中・未使用でグルーピング表示。起動・停止・削除・prune・コンテナ内シェル起動まで行える | `Space d` |

git パネルと docker パネルは UI の骨格（レイアウト・タブバー・コマンドログ・右ペイン・拡大トグル・自動更新）を `config/panel/shell.lua` で共有していて、見た目と操作感は完全に同じになっている。

### LSP

| 機能 | 説明 | 主なキー |
|---|---|---|
| `lsp` | LSP の設定。ホバー / リネーム / コードアクション / フォーマット / 診断ジャンプ | `K`、`Space r n`、`Space c a`、`Space f`、`[d` / `]d`、`Space E` |
| `completion` | VSCode 風の LSP 補完。トリガー文字に加えて単語入力中も自動でメニューを出す（`vim.lsp.completion` + 自前のデバウンス層） | `Tab` / `S-Tab` で候補移動、`Enter` 確定、`Ctrl-Space` 手動 |
| `path_intellisense` | パス断片入力時にファイル／フォルダ名を補完（VS Code の Path Intellisense 相当。`./` `../` `~/` `/` や `/` を含む断片で発火） | Insert 中（パス文脈）・`Ctrl-Space` |
| `signature` | シグネチャヘルプ（引数ヒント）。`(` や `,` を打つと自動表示 | `Space k`、インサート中 `Ctrl-s` |
| `problems` | 問題パネル。開いているバッファ全体の診断をファイルごとにまとめた一覧（下部パネル）。重要度フィルタ付き | `Space p` |
| `todo_tree` | TODO/FIXME/BUG 等のコメントタグを workspace から検索し、右サイドバーにデフォルト折り畳みの tree / flat / tags 表示・チェックボックス式のタグ種別選択・ジャンプ・ハイライトを行う | `Space T`、パネル内 `f`、`]t` / `[t` |
| `glance` | 定義元 / 参照元 / 型定義 / 実装をプレビューパネルで表示 | `g d` / `g r` / `g y` / `g i` |
| `namu` | LSP シンボル検索 | `Space s s` |

### ターミナル

| 機能 | 説明 | 主なキー |
|---|---|---|
| `terminal` | git リポジトリのルートで右側にターミナルを開く | `Space t` |
| `term_utils` | ターミナルバッファをタブライン / バッファ一覧から隠す。通常モードは `Ctrl-h/j/k/l`、ターミナルモードは `Ctrl-h/j` で隣のウィンドウへ移動する | `Ctrl-h/j/k/l`、端末内 `Ctrl-h/j` |

### その他

| 機能 | 説明 | 主なキー |
|---|---|---|
| `browser` | HTML / MarkdownをローカルHTTPサーバで既定ブラウザに開く（Markdownは保存時に自動リフレッシュ） | `Space o` |
| `diff_review` | 作業ツリーの差分をブラウザ（difit 風）で開き、その差分上で AI と双方向にコメントをやりとりする（hunk 参考）。行クリック（shift で範囲）でコメント追加・スレッド返信、unified/side-by-side 切替、ファイルツリー（折りたたみ・compact folders）、All/Unstaged/Staged 切替、シンタックスハイライト、全コメント削除。差分は保存＋定期ポーリングで自動更新（git add/commit/外部編集も反映）。AI は `.agents/skills/nvim-diff-review` の HTTP API 経由で読み書きする | `Space R`、`:DiffReview` / `:DiffReviewClose` |
| `code_notes` | ブラウザ上の Code Notes とローカル HTTP API を組み合わせ、AI / 人間が file/line/lineEnd/text の entry を追加し、status（open/closed）・entry 配下 comments・一覧/詳細/コード断片・nvim ジャンプを使ってコードリーディング用メモを共有する。AI は `.agents/skills/nvim-code-notes` の HTTP API 経由で読み書きする | `Space B`、`:CodeNotes` / `:CodeNotesClose` |
| `nvim_api` | 起動中の nvim が持っている情報（LSP の定義 / 参照 / シンボル / ホバー、診断、開いているバッファ）を、ローカル HTTP API で AI から読めるようにする。nvim 起動時に 127.0.0.1 の空きポートで自動起動し、`.agents/skills/nvim-api` の HTTP API 経由で叩く。LSP の待ちは全て非同期（`vim.wait` を使わない）なので、AI が問い合わせている間もエディタは固まらない。grep と違い LSP はスコープを解決するため、同名シンボルや import のエイリアスを取り違えない | `:NvimApi` / `:NvimApiStart` / `:NvimApiStop` |
| `http_client` | `.http` / `.rest` ファイルに書いた HTTP リクエストを実行し、結果を右パネルに表示（変数・環境ファイル対応） | `Space h r` |
| `copy_with_path` | Code Notes 用の location、または選択コードをファイルパス（行番号付き）とともにコピー | `Space y`、`Space Y` |
| `copy_all` | バッファ全内容をコピー | `Space A` |
| `ports_panel` | 使用中のポートと、それを掴んでいるプロセスの一覧パネル（Listening / Connections の2タブ。プロセスの終了・ブラウザで開く・ポート番号コピー） | `Space P`、`:Ports` |
| `shortcuts` | Neovim のショートカット一覧パネル | `Space ?` |

## 対応言語

LSP と treesitter が効く filetype の一覧。ここに無い言語は LSP なし・従来の正規表現 syntax になる。
treesitter を効かせるには[パーサのビルド](#treesitter-パーサのビルド)が必要。

| filetype | LSP | treesitter |
|---|---|---|
| `go` `gomod` `gowork` | gopls | ○ |
| `gotmpl` | gopls | △ Neovim が filetype を判定しないため `:set ft=gotmpl` が要る |
| `typescript` `typescriptreact` | ts_ls / biome | ○ |
| `javascript` `javascriptreact` | ts_ls / biome | ○ |
| `terraform` `terraform-vars` | tofu_ls / terraformls | ○ |
| `opentofu` `opentofu-vars` | tofu_ls | ○ |
| `toml` | taplo | ○ |
| `yaml` `yaml.docker-compose` `yaml.gitlab` | yamlls | ○ |
| `json` `jsonc` | biome | ○ |
| `css` `graphql` | biome | ○ |
| `sh` `bash` | bashls | ○ |
| `lua` | lua_ls | ○（Neovim 同梱でビルド不要） |

## nvim が依存する CLI ツール

`nvim/` 配下の自作機能が内部で呼び出しているツール。

| ツール | 用途 |
|---|---|
| `git` | git_panel, github_permalink, terminal, diff_review, code_notes, nvim_api など git 操作全般（diff_review は作業ツリー差分の取得に `git diff HEAD` と未追跡ファイルの `--no-index` を使う。code_notes / nvim_api は `git rev-parse --show-toplevel` でリポジトリ root を解決するだけで、git 管理下でなければ cwd に倒す） |
| `cc` / `c++` | `nvim/tools/build-parsers.sh` による tree-sitter パーサのビルド（macOS は Xcode Command Line Tools 付属）。ビルド済みの `.so` があれば nvim の実行時には不要 |
| `docker` | `docker_panel` のコンテナ / イメージ / ボリューム / ネットワーク操作全般（無い場合はパネルを開いた時にエラー通知して閉じる） |
| `gh` | `git_panel` の GitHub PR 取得・認証（branches.lua の PR 表示、pr.lua の PRパネル: 一覧/詳細/diff/checkout/ブラウザ表示） |
| `curl` | `git_panel/git.lua` の GitHub GraphQL API 呼び出し（PR情報取得）、`http_client` のリクエスト実行 |
| `xdg-open` / `open` | `browser` のプレビューURLを既定ブラウザで開く。`xdg-open`（Linux）→ `open`（macOS）の順に探索し、どちらも無い場合はURLを通知するのみ |
| `lsof` | `ports_panel` の使用中ポート一覧・プロセスのソケット一覧（無い場合はパネルを開いた時にエラー通知して閉じる） |
| `ps` | `ports_panel` の右ペイン Process タブ（選択中ポートを掴んでいるプロセスの詳細） |
| `kill` | `ports_panel` の `d`（SIGTERM） / `D`（SIGKILL） |
| `delta` | `git_panel` の diff 色付き表示（任意、無くても素のテキストにフォールバック） |
| `rg` (ripgrep) | `search.lua` の全文検索・置換、`todo_tree.lua` の TODO タグ検索 |
| `fzf` | `search.lua`（検索UI） |
| `fd` | `explorer.lua` の再帰ファイル名検索（`/`）・空ディレクトリ検索 |
| `herdr` | `git_panel` Worktree パネルの `w`（カーソル行の worktree を herdr ワークスペースとして開く）／`herdr.lua` の `Space a c/x/a`（右ペインで claude/codex/agent を開く。右にエージェントがいれば再利用、無ければ右に split して起動。選択中は選択範囲の場所を入力欄へ挿入）／問題パネル（`Space p`）の `a` / `A` / `gA`（カーソル行・同ファイル・現フィルタの診断をエージェントへ送る。送り先は picker）。`HERDR_ENV=1` の herdr セッション内でのみ有効、無ければ警告のみ |

## treesitter パーサのビルド

新しい環境では一度これを実行する。忘れるとエラーは出ず、静かに従来の正規表現 syntax に戻る。

```sh
nvim/tools/build-parsers.sh           # 全部
nvim/tools/build-parsers.sh go tsx    # 言語を絞る
nvim/tools/build-parsers.sh -f        # 記録を無視して作り直す
```

`.so` はアーキ依存なので git に入れていない（`nvim/.gitignore`）。ビルドしたリビジョンを
`nvim/parser-info/` に記録しているので、2 回目以降は変更のあった言語だけが作り直される。
ズレは `nvim/tests/run.sh treesitter` でも落ちる。

対象言語とクエリの更新手順は `nvim/queries/README.md`。

## ローカル設定

`nvim/local.lua` はマシン固有の設定を書くファイルで、`.gitignore` に登録済み。存在する場合のみ読み込まれる。

現在サポートしているキー：

| キー | 説明 |
|------|------|
| `tsserver_path` | `typescript-language-server` が使う `tsserver.js` の絶対パス |
| `browser.opener` | ブラウザ opener 実行ファイル名または絶対パス（未指定時は `xdg-open` → `open` の順に自動探索） |
| `browser.host` | HTML / Markdown プレビューサーバの bind host（未指定時は Dev Container から見やすい `0.0.0.0`） |
| `browser.html.opener` / `browser.markdown.opener` | 種別ごとに opener を上書き |
| `browser.html.host` / `browser.markdown.host` | 種別ごとに bind host を上書き |

```lua
-- nvim/local.lua
return {
  tsserver_path = '/app/web/node_modules/typescript/lib/tsserver.js',
  browser = {
    opener = 'xdg-open',
    host = '0.0.0.0',
  },
}
```
