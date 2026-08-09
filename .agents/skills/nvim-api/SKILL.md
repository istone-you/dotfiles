---
name: nvim-api
description: >-
  Query the user's running Neovim over its local HTTP API (curl + jq). Two independent uses:
  (a) resolve symbols through the already-indexed LSP — definition, references, hover, document
  and workspace symbols, code actions — instead of guessing with grep; (b) read live diagnostics
  instead of re-running a type-checker to find out what is currently broken. Pick only the
  one you need. 起動中の nvim の LSP・診断を HTTP API 経由で使う（2 つは独立）。
---

# Neovim API

起動中の nvim が既に持っている情報を AI へ開く読み取り口。実体はローカル HTTP サーバで、
nvim 起動時に 127.0.0.1 の空きポートで自動的に立ち上がる。

**用途は 2 つあり、互いに独立している。必要なものだけ使えばよい。**

| やりたいこと | 読む節 | 代表的な入口 |
|---|---|---|
| シンボルの定義・参照・型を正確に知る | [コードを追う](#コードを追う-lsp) | `POST /api/lsp/references` |
| いま何が壊れているか知る | [診断を読む](#診断を読む) | `GET /api/diagnostics/summary` |

なぜ nvim 経由なのか:

- **LSP はスコープで解決する。grep は文字列でしか照合できない。** このリポジトリだけでも
  `function M.open` は 19 個ある。grep では `M.open()` の呼び出しがどのモジュールのものか
  区別できず、そのたびにファイルを開いて確認する羽目になる。`/api/lsp/references` なら
  正解だけが 1 回で返る。TypeScript の `import { open as openPanel }` のようなエイリアスは
  grep では原理的に追えないが、LSP は追える。
- **言語サーバはもう温まっている。** tsserver や gopls のインデックスを自前で立て直すと
  数十秒〜数分かかる。nvim に常駐しているものへ相乗りすれば初手から速い。
- **診断は再実行しなくても読める。** `tsc` や `eslint` を回し直さずに、いま何が赤いかが分かる。

---

## まず（全機能に共通）

### セッションを見つける（repo → port）

```bash
REPO=$(git rev-parse --show-toplevel)
REG="${XDG_CACHE_HOME:-$HOME/.cache}/nvim/nvim-api/sessions.json"
PORT=$(jq -r --arg r "$REPO" '[.[] | select(.repoRoot==$r)] | sort_by(-.startedAt) | .[0].port // empty' "$REG")
BASE="http://localhost:$PORT"
curl -s "$BASE/api/session" | jq
```

- 同じリポジトリを複数の nvim で開いている場合、エントリは複数出る（上の jq は最後に起動した
  ものを選ぶ）。狙いを外していそうなら `jq . "$REG"` で全部見て `pid` や `cwd` で選び直す。
- `PORT` が空なら、そのリポジトリで nvim が動いていないか自動起動が切られている。
  ユーザーに `:NvimApiStart` を実行してもらうこと。
- `/api/session` は `{root, port, pid, nvim, startedAt, capabilities}` を返す。

### パスと位置の決まり

- `file` はリポジトリ root からの相対パス（root 内を指す絶対パスでも可）。
- 位置はすべて **1-based**（`line` は 1 行目が 1、`col` はバイト桁で 1 桁目が 1）。
- **root の外は既定で拒否**（`400 path is outside the repository root`）。絶対パスでも `../`
  でも同じ。nvim にリポジトリ外のファイルを読ませる抜け道を作らないため。
  LSP が**返してくる**パス（Go の stdlib や GOPATH 内の定義元など）は制限の対象外で、
  `locations` にそのまま絶対パスで出る。制限がかかるのは投げる入力パスだけ。

---

## コードを追う (LSP)

**使う場面**: 「この関数を消していいか」「シグネチャを変えたら何が壊れるか」「この値は何型か」。
grep で当たりを付ける前にここへ来る。grep の「見つからなかった」を「使われていない」と読むのが
最も危険な誤りで、それを避けるための節。

```bash
# 参照（本命。grep の代わりに使う）
curl -s -X POST "$BASE/api/lsp/references" -H 'Content-Type: application/json' \
  -d '{"file":"lua/config/diff_review/init.lua","line":143,"col":11}' | jq '.locations'

# 定義へ
curl -s -X POST "$BASE/api/lsp/definition" -H 'Content-Type: application/json' \
  -d '{"file":"lua/config/diff_review/init.lua","line":143,"col":11}' | jq

# 型・シグネチャ・ドキュメント
curl -s -X POST "$BASE/api/lsp/hover" -H 'Content-Type: application/json' \
  -d '{"file":"web/src/App.tsx","line":128,"col":9}' | jq -r '.hover'
```

`definition` / `references` は `{locations: [{file, line, col, end_line, end_col, text}], count}`
を返す。`text` はその行の中身なので、位置を見てからファイルを開き直す必要はたいてい無い。
`references` は既定で宣言自身も含む（`"includeDeclaration": false` で外せる）。

ファイル構造とプロジェクト全体のシンボル検索:

```bash
# 大きいファイルは全部読む前にこれで構造だけ取る
curl -s -X POST "$BASE/api/lsp/document_symbols" -H 'Content-Type: application/json' \
  -d '{"file":"lua/config/problems.lua"}' | jq '.symbols[] | {name, kind, container, line}'

curl -s -X POST "$BASE/api/lsp/workspace_symbols" -H 'Content-Type: application/json' \
  -d '{"query":"DiffReview"}' | jq '.symbols'
```

`document_symbols` は階層を平坦化して返し、親を `container`（`M.open` なら `"M"`）で示す。

いま直せるものを一覧する（適用はしない。実際の修正は通常の編集で行い、差分に出すこと）:

```bash
curl -s -X POST "$BASE/api/lsp/code_actions" -H 'Content-Type: application/json' \
  -d '{"file":"web/src/App.tsx","line":40,"col":1}' | jq '.actions'
```

**未ロードのファイルについて**: `/api/lsp/*` は指定された `file` を自動でロードして LSP の
アタッチを待つので、通常は事前準備は要らない。ただし `workspace_symbols` はプロジェクト全体を
見るため、先にその言語のファイルを開かせておくと結果が安定する。

```bash
curl -s -X POST "$BASE/api/buffers/load" -H 'Content-Type: application/json' \
  -d '{"files":["web/src/App.tsx","web/src/api.ts"]}' | jq
```

---

## 診断を読む

**使う場面**: 自分が編集した直後、テストを回す前。型エラーや未定義参照はここで潰せる。

```bash
curl -s "$BASE/api/diagnostics/summary" | jq                      # まずこれ。ファイル別の件数
curl -s "$BASE/api/diagnostics?severity=error" | jq '.diagnostics'
curl -s "$BASE/api/diagnostics?file=web/src/App.tsx" | jq '.diagnostics'
```

- `summary` は `{files: [{file, error, warn, info, hint, total}], totals, total}`。問題の多い
  ファイル順に並ぶ。**生の診断を全部引く前にこちらを見ること**（数千件になることがある）。
- `/api/diagnostics` は既定で 200 件まで。切られたときは `truncated: true` が立つので、
  `file=` や `severity=` で絞る。`max=` で上限を変えられる。
- `severity` は `error` / `warn` / `info` / `hint`。指定した重要度**以上**が返る。

**自分でファイルを編集した直後に読むときの注意**: nvim のバッファはまだディスクの変更を
知らず、LSP も診断を出し直していない。`refresh=1` を付けると読み直したうえで少し待つ。

```bash
curl -s "$BASE/api/diagnostics?refresh=1&wait_ms=800&severity=error" | jq
```

診断は「サーバーが報告したぶん」しか無い。特定ファイルを確実に見たいときは先に
`/api/buffers/load` でロードさせること。手動で取り込み直したいだけなら
`curl -s -X POST "$BASE/api/refresh" -d '{}'`。

---

## その他の口

```bash
curl -s "$BASE/api/buffers" | jq '.buffers[] | {file, filetype, modified, lsp}'  # 今開いているもの
```

`modified: true` のファイルは人間が未保存で編集中。ディスクの内容と食い違うので、その前提で話すこと。

---

## つまずいたとき（全機能に共通）

- **`PORT` が空** — そのリポジトリで nvim が動いていない。`:NvimApiStart` を頼む。
- **`curl: connection refused`** — nvim が終了済み。レジストリのエントリは終了時に消えるが、
  強制終了だと残ることがある。`/api/session` が返らなければ死んでいる。
- **`409 no LSP client attached`** — その言語のサーバが無いか初期化中。**空の結果と混同しない。**
  「参照 0 件」ではない。`timeout_ms` を上げて再試行する。
- **`409 LSP request timed out`** — 既定 5 秒で打ち切った。大きなファイルの `document_symbols` や、
  インデックス中の `workspace_symbols` で起きる。`"timeout_ms": 20000` などに上げる。
- **`400 line must be a positive integer (1-based)`** — 0-based のまま渡している。
- **`400 path is outside the repository root`** — リポジトリ外を指している。root 相対に直す。
  意図的に外を見たい場合はユーザーに `vim.g.nvim_api_allow_outside_root = true` を頼む。
- **`504 request timed out inside nvim`** — nvim 側が 15 秒応答しなかった保険。通常は出ない。
- **参照が明らかに少ない** — 対象ファイルがロードされた直後で、サーバーがまだプロジェクト全体を
  見ていない可能性がある。`/api/buffers/load` で関係ファイルを温めてから再試行する。
- **localhost がブロックされる** — サンドボックスが localhost を塞いでいる場合はネットワーク
  許可を上げて再試行する。
