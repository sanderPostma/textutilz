# Structured-format tooling — design

Date: 2026-08-06
Status: approved (user authorised unattended implementation of the whole scope)

## Problem

The first pass at structured-format tooling was built in Dart. `pubspec.yaml`
gained `xml`, `yaml` and `yaml_writer`; `lib/structured_tools_panel.dart` does
its pretty-print and minify with `jsonDecode` / `XmlDocument.parse` / `loadYaml`;
`lib/markup_styling.dart` is a hand-rolled, line-local character scanner. Rust
has no format code at all — `rust/Cargo.toml` carries `serde_json` only, used by
`jwt.rs` and `commands.rs` for serialisation.

That violates the standing mandate recorded at `TODO.md:9`: *non-UI logic is
done in Rust, direct UI-related logic may be in Dart*. It also blocks every
feature now being asked for, because a line-local scanner with no parse state
cannot report an error position, cannot match a bracket across lines, and cannot
find a fold region.

Seven asks:

1. Comment/uncomment must use the right syntax per format (`#` for YAML,
   `<!-- -->` for XML, none for strict JSON, `//` only for JSON5).
2. JSON5 support.
3. Escape/unescape for formats that have an escaping scheme.
4. Validation, surfaced as a double-clickable error list.
5. Syntax colouring, including matched open/close bracket and tag pairs.
6. Block collapse (folding).
7. Silent format autodetection, including for unsaved documents with no
   meaningful extension.

## Root cause of the reported comment bug

`get_comment_symbols` (`rust/src/api/edit_ops.rs:3-16`) keys on file extension
alone and falls through to `_ => ("//", "/* */")`. JSON is absent from the table,
so it gets `//`. A YAML document saved as `.txt` also gets `//`. Meanwhile
styling uses an unrelated table, `MarkupStyling._aliases`
(`lib/markup_styling.dart:41`), which does consult `contentType`. Two
unreconciled detection paths is the actual defect; patching the comment table
alone leaves them free to drift apart again.

## Architecture

One Rust module tree, `rust/src/markup/`, with a single lexer per format.
Each lexer is a streaming state machine over rows. One pass produces everything:

- **token spans** for colouring,
- **fold regions** for collapse,
- **bracket/tag pairs** for match highlighting,
- **diagnostics** for validation.

Colouring, folding, matching and validation therefore agree by construction
rather than by three separate scanners happening to concur.

```
rust/src/markup/
  mod.rs        the façade: analyse, tokenise, validate, format, pair_at
  language.rs   MarkupLanguage, detection and sniffing, comment styles
  token.rs      TokenKind, Token, RowTokens, FoldRegion, Diagnostic,
                BracketPair, LexState, Utf16Cols
  lexer.rs      the MarkupLexer trait + shared row-walking drivers
  json.rs       JSON and JSON5 lexer, validator, formatter
  xml.rs        XML lexer, validator, formatter
  yaml.rs       YAML lexer and folds; parse/validate via yaml-rust2
  escape.rs     per-format escape/unescape
rust/src/api/structured.rs   the Dart-facing wire types and conversions
```

The domain module sits *outside* `src/api/` because the code generator scans
that directory and cannot mirror the trait objects and borrowed slices the
lexers use.

### Incremental tokenisation

Documents are mmap-backed and may be very large, so nothing may be O(document)
per frame. The scheme mirrors how find already pages by viewport:

- `LexState` is a small `Copy` struct (`mode`, `quote`, `pending`, `depth`, a
  64-bit object-vs-array `stack`, and `indent`) capturing everything a lexer
  needs to resume at a row boundary. The `stack` is what lets the JSON family
  tell an object key from a string value without lookahead.
- A full pass walks the document once and stores a `LexState` every
  `CHECKPOINT_ROWS` (128) rows — not one per row, which would cost more memory
  than the structure it describes — plus the fold regions, bracket pairs and
  diagnostics.
- Viewport tokenisation resumes from the nearest checkpoint and re-lexes at most
  128 rows to reach its start. Tokens are never cached document-wide.
- The analysis pass is debounced on edit and skipped above a size cap; above the
  cap, colouring still works (viewport lexing from a default state), while
  folding and validation are unavailable.

### What stays in Dart

Only the parts that are genuinely UI: the token-kind → `Color` mapping, span
construction for the `TextPainter`, gutter hit-testing and painting, and panel
layout. `lib/markup_styling.dart` shrinks to a colour table plus a
`TextSpan` builder driven by Rust tokens; all lexing, detection and formatting
leave it.

### Detection

One Rust function replaces both existing tables:

```
detect_language(extension, content_type, sample) -> MarkupLanguage
```

Extension first, then content type, then content sniffing over a leading sample
for the unsaved-document case (leading `<?xml`/`<`; leading `{`/`[` with a JSON5
probe for comments and unquoted keys; a `---` document marker or a
`key:`-at-indent-0 shape for YAML). Both colouring and `get_comment_symbols`
route through it, so the JSON `//` bug cannot recur and cannot re-diverge.

### Folding

`FoldRegion { start_row, end_row, start_col, kind, label }` comes from the same
pass — brace/bracket depth for JSON/JSON5, element nesting for XML, indentation
for YAML.

`lib/editor.dart` is a fully custom `CustomPaint` over a fixed monospace grid,
with no `TextField` or `EditableText` in the way, so the change is a
visual-row ⇄ logical-row mapping layer rather than a fight with Flutter's text
machinery. Everything that currently indexes rows must route through it:
`_getLineText`, `_getLineLength`, the painter's row loop, cursor arithmetic,
`gotoLine`, `revealSpan`, `visibleRowRange`, and the find viewport scan.

Gutter presentation follows the reference screenshots: a ⊟/⊞ box per foldable
row, a guide line down the extent of an expanded region, and a horizontal rule
across a collapsed row.

### Validation

`Diagnostic { row, col, end_row, end_col, severity, message }`. Surfaced in a
panel modelled closely on `lib/find_results_panel.dart` — fixed height, header
with a count, `ListView.builder`, and `onDoubleTap` → `revealSpan`. On-demand
first; auto-validation on a debounce is deferred.

## What shipped

All seven asks:

- `rust/src/markup/` — `token`, `lexer`, `json`, `xml`, `yaml`, `language`,
  `escape`, and the `mod` façade. `rust/src/api/structured.rs` is the wire
  format; the domain module sits outside `src/api/` so the lexers can use trait
  objects and borrowed slices that the code generator cannot mirror.
- `xml`, `yaml` and `yaml_writer` are gone from `pubspec.yaml`.
  `lib/structured_tools_panel.dart` calls Rust; `lib/markup_styling.dart` is
  reduced to a colour table and a `TextSpan` builder.
- Comment operations take a `CommentStyle` rather than a file extension. JSON
  reports that it has no comment syntax instead of inserting `//`; XML, which has
  no line comment, wraps each row in `<!-- -->` instead of silently doing
  nothing, which is what it used to do.
- `EditSession` caches lexer checkpoints and bracket pairs against a revision
  counter, so viewport colouring and caret-following pair highlighting do not
  re-scan the document.
- `lib/validation_results_panel.dart`, modelled on the find results panel, plus
  red squiggles under diagnostics in the editor and auto-validation on a 2s
  idle debounce.
- Block collapse: `lib/fold_map.dart` projects document rows to display rows,
  and the editor's gutter draws the ⊟/⊞ boxes, guide lines and collapsed-row
  rule. Folding is display-only — the caret, selections and find spans stay in
  document rows — so collapsing cannot change the document.
- JSON5 is a dialect switch on the JSON bar rather than a Tools entry of its
  own: same format, same operations, and the choice belongs to the document.
- The detected format is shown in the status bar and narrows the Tools menu to
  the matching entry.

295 Rust tests and 182 Dart tests pass. The app builds and runs; the rendering
— syntax colours, fold gutter, squiggles — has **not** been verified by eye,
because this environment has no working screen-capture tool.

## Known limitations (accepted)

These are consequences of decisions above, not outstanding work. They live here
rather than in TODO.md so that list stays a list of things to do.

- **A selection spanning a collapsed region includes its hidden rows.** Folding
  is display-only by design: the caret, selections and find spans are all
  document rows. A shift-click across a collapsed block therefore selects the
  text inside it. Notepad++ behaves the same way.

- **YAML pretty-print re-indents rather than re-emitting.** That is what keeps
  comments, key order and quoting intact, where a loader/emitter round trip
  discards all three. The result is checked by parsing input and output and
  comparing the values, so a reformat that would change the document's meaning
  is refused rather than applied. The guard can in principle decline on a
  document a re-emitting formatter would have handled; no such document has
  turned up, and if one does, the guard is what will report it.

- **Nesting deeper than 64 levels loses exact key colouring.** `LexState.stack`
  is a 64-bit object-vs-array mask (`rust/src/markup/token.rs`). Past that
  depth, JSON key detection falls back to the line-local "is the next character
  a colon" heuristic — which is what the old Dart scanner did at every depth.

## Deferred to TODO.md

- Keyboard shortcuts for folding, and fold-all / unfold-all.
- Persisting collapsed regions with the session.
- A themed or user-configurable token palette (colours are hardcoded today).
- A per-document format override, for when the extension lies.

## Testing

Rust unit tests per lexer covering tokens, folds, diagnostics and round-trip
formatting, including the resume-from-`LexState` property (lexing rows *n..m*
from the stored state equals lexing from row 0 and slicing). Dart widget tests
for the diagnostics panel, the fold gutter, and the docked-bar width regression
the existing `test/tool_bar_layout_test.dart` pins.

Test command — the cargo target directory is `~/.cargo/target`, not
`rust/target`:

```
cd rust && cargo build && cd .. && \
  LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test
```
