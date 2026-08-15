-- unified diff を色付きで表示するためのレンダラ。入口はここだけで、中身は
-- parse（構造化）→ words（語単位差分）→ syntax（treesitter）→ render（桁組みと extmark）
-- に分かれている。
--
-- 色は最初から extmark として作るので ANSI を経由しない。表示先は通常バッファなので、
-- CursorLine の選択ハイライトや検索・ジャンプがそのまま効く。

local render = require('config.panel.diff.render')

return {
  render = render.render,
  concat = render.concat,
  apply = render.apply,
  setup_hl = render.setup_hl,
  HL = render.HL,
}
