# fix-corpus-aligned-mod-text.md

Fix three KaTeX-corpus rendering issues: the `aligned` env column gap
("1b"/"317b" collisions), `\bmod`/`\mod` spacing + `\pmod` paren sizing, and
`\text` content (braces/escapes/tilde). EDIT ONLY parser.zig/layout.zig
(metrics.zig untouched). SKIP gates. All values measured on the XeTeX +
KaTeX references at 30pt.

## 1. Aligned env column gap

**Issue (vision)**: `\begin{aligned} a &= 1 & b &= 2 \\ 3a &= 3 & 17b &= 34
\end{aligned}` rendered "1b" and "317b" — the columns after the relation
column were ADJACENT (col1→col2 gap 0).

**Reference** (XeTeX \showbox at 30pt): amsmath's aligned `\ialign` preamble
`\hfil\strut@$\displaystyle{##}$\tabskip\z@skip &$\displaystyle{{}##}$\hfil
\tabskip\alignsep@\crcr` repeats every two templates; `\alignsep@ =
\minalignsep` = 10pt (a FIXED dimension) lands BEFORE columns 2, 4, ...
(0-indexed), 0 between col0-col1 and col2-col3, and
`\math@cr@@@aligned`'s phantom `&\kern-\alignsep@` cancels the trailing
tabskip (no gap after the last column). Template A (`\hfil` before) makes
EVEN columns right-aligned, template B makes ODD columns left-aligned.
KaTeX agrees on the pattern (1em pregap after odd 1-based columns) but
scales the gap (30pt at 30pt) — TeX's fixed 10pt is the primary reference.

**Fix** (src/layout/layout.zig layoutEnv):
- `col_origin` loop: for `aligned`, `x += 10.0` before columns
  `c >= 2 && c % 2 == 0` (the amsmath tabskip pattern; no trailing gap).
- Column alignment: EVEN columns right-aligned (`col_w[c] - cl.w`), ODD
  left-aligned (was: only col 0 right).

**Before/after** (glyph-origin deltas, 30pt):
| pair | before | after | XeTeX | delta |
|---|---|---|---|---|
| `1`→`b` (row 1) | 15.00 | 55.00 | 55.38 | 0.38 |
| `3`→`1` (row 2, the 10pt gap) | 0.00 | 25.00 | 24.99 | 0.01 |
| `7`→`b` (row 2) | 15.00 | 15.00 | 15.39 | 0.39 |
| `b`→`=` | 21.62 | 21.62 | 21.63 | 0.01 |
Worst relative delta 0.38pt ≤ 0.5pt. The 7→b residual is the missing
cross-family italic-correction kern (7's IC 0.39pt, TeX applies it between
different-font chars; ztex rows don't kern — pre-existing).

## 2. \bmod / \mod spacing + \pmod parens

**Issue**: `a \bmod b` — the space before/after the roman "mod" word was
the opname's ord→op thin glue (3mu = 5.0pt at 30) — "too tight"; `\mod`
had NO leading space and no argument; the \pmod/pod parens were flagged
"too large with extra padding".

**Reference** (XeTeX \showbox at 30pt):
- `\bmod` = `\mskip-\medmuskip\mkern5mu\mathbin{mod}\penalty900\mkern5mu
  \mskip-\medmuskip`: the ord↔bin medmuskip (4mu) cancels, NET 5mu each
  side — measured a→m 24.20pt = a advance + 8.334pt (5mu) exactly.
- `\mod{arg}` = `\allowbreak \if@display\mkern18mu\else\mkern12mu\fi
  {\operator@font mod}\,\,#1`: leading 18mu (display) / 12mu otherwise +
  two thin spaces (6mu) before the arg (KaTeX \mathchoice agrees).
- `\pmod{n}` = leading 18mu/8mu + '(' + mod + 6mu + n + ')'; the parens are
  BASE-size LM parens hugging the argument (verified: ztex paren advance
  11.67pt == XeTeX 11.68pt == KaTeX 11.67pt; ink identical to the XeTeX
  pane — the "too large with extra padding" nit is the leading-space
  difference vs the XeTeX pane's inline-mode 8mu, see §4).

**Fix**:
- parser.zig: `mod`/`bmod` moved out of the `.opname` map into dedicated
  `.mod`/`.bmod` commands. `bmod()` → row `[5mu space, opname "mod",
  5mu space]` marked `bmod_row_data` (6); `mod()` → row `[opname "mod",
  6mu space, arg]` marked `mod_row_data` (7), arg via parseScriptArg.
- layout.zig: `layoutBmod` places the pieces back-to-back (no inter-atom
  glue — the kerns carry all spacing, matching TeX's net); `layoutMod`
  applies the style-dependent leading kern (18mu display / 12mu otherwise)
  then places `[mod, 6mu, arg]` back to back. `leftRole` forces the
  `\mod` row to ord (the leading \mkern is not a noad — TeX's first atom
  is the ord "mod" group, so neighbors get no glue). `\bmod` is already
  ord (space leaves).

**Before/after** (30pt, vs XeTeX):
- `a \bmod 2`: a→m 20.87 → **24.20** (ref 24.20, delta 0.00); d→2
  23.67+1.35 → **25.01** (ref 23.67; delta = cmr d 16.68 vs LM 15.33,
  pre-existing roman-metric gap).
- `d \mod{56}`: leading 1.67 (opname glue) → **30.00** (18mu display; the
  KaTeX/amsmath display value — the XeTeX pane shows 12mu because its
  `$\displaystyle$` wrapper is INLINE mode, \if@display false); mod→arg
  5.0 → **10.00** (6mu, ref 10.00).
- `c \pmod{4}` / `b \pod 3`: parens base-size, hugging — advance 11.67 ==
  refs; unchanged (verified correct).

## 3. \text content (braces / escapes / tilde)

**Issue** (Text corpus `\frac{a}{b}\text{c~ {ab} \ e}+fg`): `~` rendered as
a WIDE tilde glyph (0.556em); literal `{` `}`; a literal backslash before
`e`.

**Reference** (XeTeX \showbox at 30pt): `~` = \nobreakspace, `\ ` = control
space, and literal spaces are ALL the text font's interword space
(\fontdimen2) — 9.06pt = 0.302em at 30pt for Latin Modern Roman. Braces are
grouping; `\'e` etc. map to the accented char (no backslash).

**Fix** (src/layout/layout.zig layoutText — the `.text` atom stays a leaf
whose span covers the braced group; the content is decoded at layout):
- `~`, ` `, `\ ` → a 0.302em glue (`text_space_em`) — narrow non-breaking
  space.
- `{...}` → grouping (braces never output; nested handled).
- Backslash escapes consumed without leaking the backslash: `\i`→U+0131,
  `\j`→U+0237; accents `\' \` \" \^ \~ \. \= \H \r \v \u \c \d \b \t` over
  a braced group or single atom (TeX skips spaces after the command —
  `\H e` ≡ `\H{e}`) map to the precomposed char (175-entry
  `text_accent_table`, LM-Roman-covered), else base + combining mark
  (0x0300-0x030C, 0x0323, 0x0331; not 0x0327/0x0361 which LM lacks), else
  plain base; `\{ \} \$ \% \& \# \_` emit the literal char; unknown
  commands vanish.
- Source combining clusters (`e̋`) emit the base + zero-width mark boxes.
- `textEmitChar` marks a box synthetic when the drawn glyph's utf-8 ≠ the
  source bytes (accented escapes) so flatten dupes instead of leaking
  `\'` etc.

**Before/after**: `\text{c~ {ab} \ e}` now renders `c [9.06] [9.06] a b
[9.06] [9.06] e` — no tilde glyph, no braces, no backslash; the `~`/space
widths match the ref exactly (9.06pt). Letter-advance deltas (c 13.32 vs
lmr17-optical 12.18, a 15.0 vs 13.77, b 16.68 vs 15.33) are the
pre-existing cmr-table-vs-drawn-LM/optical-size gap affecting all
\text/\mathrm at 30pt. AccentsText corpus probes: `\'`→í/á/Á,
`\.\i`→i+U+0307, `\`\i`→ì, `\"\i`→ï, `\H{a}`→a+U+030B, `\r{a}`→å, `\i`→ı
— all backslash-free.

## 4. Remaining deltas / notes

- Aligned: worst 0.38pt vs XeTeX at 30pt (the parent's ≤0.5pt bar).
- \bmod: 0.00pt vs XeTeX. \mod/\pmod/\pod leading: 18mu display matches
  KaTeX (the corpus reference); the XeTeX pane shows 8mu/12mu because its
  `$\displaystyle $` wrapper is inline mode (`\if@display` false) — a
  wrapper artifact, not a ztex defect; KaTeX's style-based \mathchoice
  agrees with ztex (verified in the KaTeX source: 18mu/12mu display
  branches).
- "pmod paren sizing": measured identical to both refs (same LM glyph,
  advance 11.67pt, hugs the arg); the vision nit's "extra padding" is the
  leading-space difference described above.
- Pre-existing gaps surfaced (not introduced, out of scope): cmr-vs-LM
  roman letter advances (\text/\mathrm words, "mod" m/o/d); missing
  cross-family italic-correction kerns (7→b 0.39pt); KaTeX-vs-XeTeX
  aligned gap scaling (1em vs fixed 10pt).

Verification: `zig build` + `zig build test` pass (all existing tests,
goldens intentionally unchanged — parent regenerates). Rendered the three
corpus entries + AccentsText probe at -s 30 and compared per-glyph origins
to the XeTeX references; critique.py --ref --no-critique -s 30 artifacts in
/tmp/refcrit/ (3-pane combined PNGs).
