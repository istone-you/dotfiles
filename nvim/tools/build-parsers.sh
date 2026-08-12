#!/usr/bin/env bash
# tree-sitter パーサ(nvim/parser/*.so)をビルドする。
#
# grammar は <url>/archive/<revision>.tar.gz で取得してコンパイルする。
# ビルドしたリビジョンを parser-info/<lang>.revision に記録し、固定値と一致していて
# .so もあるならその言語は飛ばすので、何度実行しても安全。
# 生成される .so はアーキ依存のバイナリなので git には入れていない(.gitignore 済み)。
#
# 使い方: nvim/tools/build-parsers.sh [-f] [言語名...]
#   -f  記録を無視して全部ビルドし直す
set -euo pipefail

# 対象言語は lua/config/lsp.lua で LSP を設定している filetype に揃えている。
# lua だけは Neovim にパーサもクエリも同梱されているのでここには無い。
# URL とリビジョンは nvim/queries/ のクエリと同じコミットの
# lua/nvim-treesitter/parsers.lua から取っている(出所は nvim/queries/README.md)。
# 上げる時もそこから取ること。grammar 側の最新 HEAD を拾うとクエリとノード名がズレ、
# バッファを開くたびにエラーが出る。
#
# 言語名|リポジトリ|固定リビジョン|src ディレクトリ(リポジトリ root からの相対)
PARSERS=(
  "go|https://github.com/tree-sitter/tree-sitter-go|2346a3ab1bb3857b48b29d779a1ef9799a248cd7|src"
  "gomod|https://github.com/camdencheek/tree-sitter-go-mod|2e886870578eeba1927a2dc4bd2e2b3f598c5f9a|src"
  "gowork|https://github.com/omertuc/tree-sitter-go-work|949a8a470559543857a62102c84700d291fc984c|src"
  "gotmpl|https://github.com/ngalaiko/tree-sitter-go-template|aa71f63de226c5592dfbfc1f29949522d7c95fac|src"
  "typescript|https://github.com/tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|typescript/src"
  "tsx|https://github.com/tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|tsx/src"
  "javascript|https://github.com/tree-sitter/tree-sitter-javascript|58404d8cf191d69f2674a8fd507bd5776f46cb11|src"
  "terraform|https://github.com/tree-sitter-grammars/tree-sitter-hcl|64ad62785d442eb4d45df3a1764962dafd5bc98b|dialects/terraform/src"
  "toml|https://github.com/tree-sitter-grammars/tree-sitter-toml|64b56832c2cffe41758f28e05c756a3a98d16f41|src"
  "yaml|https://github.com/tree-sitter-grammars/tree-sitter-yaml|a1c4812a73ec5e089de8e441fdea3a921e8d5079|src"
  "json|https://github.com/tree-sitter/tree-sitter-json|001c28d7a29832b06b0e831ec77845553c89b56d|src"
  "css|https://github.com/tree-sitter/tree-sitter-css|dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f|src"
  "graphql|https://github.com/bkegley/tree-sitter-graphql|5e66e961eee421786bdda8495ed1db045e06b5fe|src"
  "bash|https://github.com/tree-sitter/tree-sitter-bash|a06c2e4415e9bc0346c6b86d401879ffb44058f7|src"
  "rust|https://github.com/tree-sitter/tree-sitter-rust|77a3747266f4d621d0757825e6b11edcbf991ca5|src"
)

NVIM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$NVIM_DIR/parser"
INFO_DIR="$NVIM_DIR/parser-info"
WORK_DIR="${TMPDIR:-/tmp}/nvim-ts-parsers"

FORCE=0
while [ $# -gt 0 ] && [ "${1:-}" = "-f" ]; do
  FORCE=1
  shift
done

mkdir -p "$OUT_DIR" "$INFO_DIR" "$WORK_DIR"

built=0
skipped=0

for entry in "${PARSERS[@]}"; do
  IFS='|' read -r lang repo rev srcdir <<<"$entry"

  # 引数で言語が指定されていたら、それ以外は飛ばす
  if [ $# -gt 0 ]; then
    match=0
    for want in "$@"; do [ "$want" = "$lang" ] && match=1; done
    [ "$match" = 1 ] || continue
  fi

  stamp="$INFO_DIR/$lang.revision"
  if [ "$FORCE" = 0 ] && [ -f "$OUT_DIR/$lang.so" ] && [ -f "$stamp" ] \
    && [ "$(cat "$stamp")" = "$rev" ]; then
    echo "==> $lang is up to date"
    skipped=$((skipped + 1))
    continue
  fi

  # tarball を取って展開する。同じリポジトリ・同じリビジョンを複数の言語が
  # 使う(typescript と tsx)ので、展開先は リポジトリ名-リビジョン で共有する
  src="$WORK_DIR/$(basename "$repo")-$rev"
  if [ ! -d "$src" ]; then
    echo "==> download $(basename "$repo")@${rev:0:7}"
    tarball="$WORK_DIR/$(basename "$repo")-$rev.tar.gz"
    curl --silent --fail --show-error --location --retry 3 \
      -o "$tarball" "$repo/archive/$rev.tar.gz"
    mkdir -p "$src"
    tar -xzf "$tarball" -C "$src" --strip-components=1
    rm -f "$tarball"
  fi

  # scanner は無い grammar もある(go)。あるものだけ渡す
  sources=("$src/$srcdir/parser.c")
  [ -f "$src/$srcdir/scanner.c" ] && sources+=("$src/$srcdir/scanner.c")

  # scanner.cc(C++)を持つ grammar は c++ でリンクする必要がある
  compiler=cc
  if [ -f "$src/$srcdir/scanner.cc" ]; then
    sources+=("$src/$srcdir/scanner.cc")
    compiler=c++
  fi

  echo "==> build $lang -> parser/$lang.so"
  "$compiler" -shared -fPIC -Os -I "$src/$srcdir" "${sources[@]}" -o "$OUT_DIR/$lang.so"
  # ビルドが通ってから記録する(失敗した .so を最新扱いにしないため)
  printf '%s' "$rev" >"$stamp"
  built=$((built + 1))
done

echo "done. built=$built skipped=$skipped -> $OUT_DIR"
