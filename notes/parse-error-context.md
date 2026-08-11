# Parse-error context

Threads parse-error context (kind + source span + message) through the whole
pipeline, so clients can pretty-print failures with position and a caret.
Error VALUES are unchanged — every test still `expectError`s the same
`error.Xxx`; the `Info` is an out-param filled only on error, only when the
caller passes a non-null pointer.

## API

New module `src/parse/error.zig` (re-exported as `ztex.parse.err`,
`ztex.parse.Info`, `ztex.parse.Kind`):

```zig
pub const Kind = enum { dangling_escape, invalid_utf8, unexpected_r_group,
    unexpected_script, double_script, unknown_command, missing_argument,
    missing_script, unclosed_group, unexpected_middle, unknown_environment,
    mismatched_end, unclosed_environment };

pub const Info = struct {
    kind: Kind,
    span: atom.Span,            // byte span of the offending input
    pub fn message(self: Info) []const u8;   // TeX-style message
};

pub fn lineCol(src: []const u8, offset: usize) struct { line: usize, col: usize }; // 1-based
pub fn sourceLine(src: []const u8, offset: usize) []const u8;                      // \r trimmed
```

Signatures threaded:

```zig
lexer.lex(ast: *atom.Ast, err_info: ?*Info) Error!void
parser.Parser.init(gpa, src, tokens, err_info: ?*Info) Parser
parse.parse(gpa, src, err_info: ?*Info) Error!atom.Ast
ztex.render(gpa, src, size_pt, err_info: ?*parse.Info) !draw.DrawList
Context.render(self, gpa, src, size_pt, err_info: ?*parse.Info) !draw.DrawList
```

Every parser error-return site goes through `Parser.fail(kind, span)` (a
private helper that records the Info and returns the matching error value via
one kind→error switch — the lexer's two kinds are set at their sites). Span
policy: point at the offending token (`\nosuchcmd` → the command token,
stray `}` → the brace); for "expected X but hit end of input" a zero-width
span at end of source (`\frac{a}` → offset 8); for an unclosed construct the
opening brace / `\left` command.

`main.zig` catches parse errors and prints a caret diagnostic to stderr,
then exits 1; non-parse errors (arg errors, OOM) keep the previous path.

## Pretty-print examples

```
$ ztex -i '\frac{1}{2}}'
ztex: parse error: Unexpected '}' (UnexpectedRGroup) at line 1, col 12
\frac{1}{2}}
           ^

$ ztex -i '\nosuchcmd{x}'
ztex: parse error: Unknown command (UnknownCommand) at line 1, col 1
\nosuchcmd{x}
^^^^^^^^^^

$ ztex -i $'x + y\n\\frac{1}{2}}\nz'
ztex: parse error: Unexpected '}' (UnexpectedRGroup) at line 2, col 12
\frac{1}{2}}
           ^
```

## Tests

- `src/parse/error.zig`: `lineCol` 1-based line/col incl. EOF clamp;
  `sourceLine` returns the containing line, CR trimmed.
- `src/parse/lexer.zig`: dangling escape → `.dangling_escape`, span covers
  the backslash; invalid UTF-8 → `.invalid_utf8`, span covers the bad byte.
- `src/parse/root.zig`:
  - `\nosuchcmd{x}` → `.unknown_command`, span [0,10) (the command token)
  - `abc\` → `.dangling_escape`, span [3,4)
  - `\frac{a}` → `.missing_argument`, zero-width span at offset 8 (EOF)
  - `\frac{1}{2}}` → `.unexpected_r_group`, span at the stray `}` (offset 11)
  - `\left(` → `.unclosed_group`, span at the `\left` command
  - multiline `x + y\n\frac{1}{2}}\nz` → `.unexpected_r_group` at line 2,
    col 12; `lineCol`/`sourceLine` resolve the position
- Existing parser/lexer error tests unchanged (error values identical).
- Call sites updated: `src/root.zig`, `src/context.zig`,
  `src/tests/regression.zig` (dump/dumpSvg/dumpAtoms),
  `src/tests/integration.zig`, `src/tests/sanity.zig`, `src/bench/main.zig`.

## Notes

- Zig 0.16 rejects implicit `anyerror` → narrow error-set coercion, so the
  kind→error mapping lives in `Parser.fail`'s switch (the lexer's sites
  return literals), instead of a shared `Kind.toError()`.
- `\left(` with no `\right` previously panicked (u32 underflow): the
  `errdefer self.delim_depth -= 1` double-fired after the manual decrement
  once the error-return path was exercised by the new test. The `\right`
  check now runs inside the protected region (delim_depth still 1), so the
  errdefer fires exactly once.
- `\frac{1}}` (one stray brace) reports `.missing_argument` at the stray
  brace, not `.unexpected_r_group`: the denominator parser sees the stray
  `}` as a non-`{` argument token before the row loop sees it. Use a
  complete construct (`\frac{1}{2}}`) for the r_group path.
