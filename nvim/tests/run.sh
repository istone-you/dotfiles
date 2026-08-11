#!/usr/bin/env bash
# 最小のテストランナー。tests/*_spec.luaをnvim -lで
# 個別プロセスとして実行し、exit codeで合否判定する。
# 既定ではCPU数ぶん並列に走らせる(各specは独立プロセスなので副作用は共有しない)。
# 使い方: nvim/tests/run.sh [パターン] [-j 並列数]
#   例: nvim/tests/run.sh explorer     explorerを含むspecだけ
#       nvim/tests/run.sh -j 1         逐次実行(出力を流しながら見たいとき)
set -uo pipefail
cd "$(dirname "$0")/.."   # -> nvim/
NVIM_DIR="$(pwd)"
TESTS_DIR="$NVIM_DIR/tests"
SELF="$TESTS_DIR/run.sh"

# ── 内部モード ──
# xargs から1ファイルぶんだけ実行する。標準出力と exit code を $RUN_OUT_DIR に落とし、
# 親側があとで元の順番に並べ直して表示する(並列でも出力が混ざらないようにするため)
if [ "${1:-}" = "--run-one" ]; then
  f="$2"
  base="$(basename "$f")"
  nvim -u NONE --cmd "set rtp+=$NVIM_DIR" --cmd "lua TESTS_DIR = '$TESTS_DIR'" -l "$f" \
    >"$RUN_OUT_DIR/$base.out" 2>&1
  echo $? >"$RUN_OUT_DIR/$base.code"
  exit 0
fi

# ── 引数 ──
PATTERN=''
JOBS=''
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="${2:-}"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
    *) PATTERN="$1"; shift ;;
  esac
done
if [ -z "$JOBS" ]; then
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
fi

# 端末に出す時だけ色を付ける(パイプ/リダイレクト先がファイル等の時は無効化)
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# ok/FAILの行と各ファイルの集計行に色を付ける(自作ハーネスのprint出力をそのまま
# 色付けするだけで、パース対象の数値自体はBASH_REMATCHで色付け前の$outから取るので
# 集計ロジックには影響しない)
colorize() {
  sed \
    -e "s/^  ok   - /  ${C_GREEN}ok${C_RESET}   - /" \
    -e "s/^  FAIL - /  ${C_RED}${C_BOLD}FAIL${C_RESET} - /" \
    -e "s/^\([0-9]* total, \)\([0-9]* passed\)\(, \)\([0-9]* failed\)$/\1${C_GREEN}\2${C_RESET}\3${C_RED}\4${C_RESET}/"
}

files=()
for f in "$TESTS_DIR"/*_spec.lua; do
  base="$(basename "$f")"
  if [ -n "$PATTERN" ] && [[ "$base" != *"$PATTERN"* ]]; then
    continue
  fi
  files+=("$f")
done

if [ ${#files[@]} -eq 0 ]; then
  echo "no spec matched: ${PATTERN:-(all)}"
  exit 1
fi

RUN_OUT_DIR="$(mktemp -d)"
export RUN_OUT_DIR NVIM_DIR TESTS_DIR
trap 'rm -rf "$RUN_OUT_DIR"' EXIT

[ "$JOBS" -gt 1 ] && echo "${C_CYAN}running ${#files[@]} spec files with ${JOBS} jobs…${C_RESET}"
printf '%s\0' "${files[@]}" | xargs -0 -P "$JOBS" -n1 "$SELF" --run-one

pass=0
fail=0
failed_files=()
total_cases=0
passed_cases=0
failed_cases=0

# 実行順ではなくファイル名順に並べ直して表示する(並列でも出力が毎回同じ並びになる)
for f in "${files[@]}"; do
  base="$(basename "$f")"
  out="$(cat "$RUN_OUT_DIR/$base.out" 2>/dev/null)"
  code="$(cat "$RUN_OUT_DIR/$base.code" 2>/dev/null || echo 1)"
  echo "${C_CYAN}${C_BOLD}── $base ──${C_RESET}"
  echo "$out" | colorize
  if [[ "$out" =~ ([0-9]+)\ total,\ ([0-9]+)\ passed,\ ([0-9]+)\ failed ]]; then
    total_cases=$((total_cases + ${BASH_REMATCH[1]}))
    passed_cases=$((passed_cases + ${BASH_REMATCH[2]}))
    failed_cases=$((failed_cases + ${BASH_REMATCH[3]}))
  fi
  if [ "$code" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_files+=("$base")
  fi
  echo
done

echo "======================================"
file_color="$C_GREEN"; [ "$fail" -gt 0 ] && file_color="$C_RED"
case_color="$C_GREEN"; [ "$failed_cases" -gt 0 ] && case_color="$C_RED"
echo "files: $((pass + fail))  ${C_GREEN}passed: $pass${C_RESET}  ${file_color}failed: $fail${C_RESET}"
echo "cases: $total_cases  ${C_GREEN}passed: $passed_cases${C_RESET}  ${case_color}failed: $failed_cases${C_RESET}"
if [ ${#failed_files[@]} -gt 0 ]; then
  echo "${C_RED}${C_BOLD}failed files:${C_RESET}"
  for f in "${failed_files[@]}"; do echo "  ${C_RED}- $f${C_RESET}"; done
  exit 1
fi
