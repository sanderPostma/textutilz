# Document State, New-Document Flow, Font Size & Editor Fixes — Design

Date: 2026-07-14

Batch of six items. #2/#3/#4 interlock through per-document state.

## #3 Document state model (foundation)

Split the current `TabState` into:

- **`DocumentMeta`** — serializable metadata, ready for sqlite:
  `id`, `displayName`, `path`, `isTransient` (scratch/new vs opened),
  `contentType`, `extension`, `autoDelete` (enum `off` / `onAppClose` /
  `atMidnight`), `viewMode` (`Read` / `Tail` / `Edit`), `fontSizes`
  (`{read, tail, edit}`), `isDirty`. Provides `toMap()` / `fromMap()`.
- **`TabRuntime`** — a `DocumentMeta` plus non-persistable handles:
  `FileBuffer`, `ScrollController`, `stats` notifier, `editorKey`.

In-memory `List<TabRuntime>` for now. Persistence to sqlite arrives later;
this pass only structures the model.

## #2 New document flow

- Add **New** to the File column. It switches the **whole ribbon** into a
  `newDocument` mode (search field + table both replaced), matching "including
  the search field / common parent".
- **New panel**:
  - Back/cancel arrow top-left → return to normal ribbon.
  - Name field, prefilled `new N` (N = incrementing counter).
  - Content type: text field default "Plain Text" + small extension field
    default `txt` (free text).
  - Auto-delete radio: `Off` (default) / `When closing the app` / `At midnight`.
  - Create / Cancel buttons.
- **Create** → write scratch file `~/.local/share/textutilz/scratch/<name>.<ext>`,
  open as `FileBuffer`, add a transient `TabRuntime` in Edit mode, close the
  ribbon, focus it.

### Rust fix (prerequisite)
`FileBuffer::open` currently calls `Mmap::map` unconditionally, which fails on a
0-byte file. Handle empty files (empty buffer, `line_offsets = [0]`). Also fixes
opening any empty file.

## #4 Ctrl-wheel font size

Ctrl + scroll-wheel over the content changes the current view's font size,
clamped 8–40px (±1 per notch), stored in `meta.fontSizes[viewMode]`
(per-document, per-view). Read / Tail / Edit each read their size from there.
Default 14 for all three.

## #1 Click-outside closes ribbon

While the ribbon is open, a transparent tap-barrier (`Positioned.fill` behind
the ribbon panel, below the header) closes it on any tap. Present only when the
ribbon is visible, so it never interferes with other UI.

## #5 Ctrl-Home / Ctrl-End in Edit mode

In the editor's key handler, Ctrl+Home → document top (row 0, col 0),
Ctrl+End → document bottom (last row, last col). Plain Home/End stay line-wise.

## #6 Blinking caret

500ms toggle timer, only while the editor is focused; resets to visible on any
cursor move or edit. Editor paints the caret according to the blink state.

## Auto-delete enforcement (scope)

`autoDelete` stored now. In-session enforcement this pass:
- `onAppClose` → delete flagged scratch files on window close.
- `atMidnight` → timer deletes flagged files at next local midnight while running.

Cross-restart enforcement (leftovers from a previous run) lands with sqlite.

## Defaults

New docs open in Edit mode; font range 8–40px, default 14; scratch dir
`~/.local/share/textutilz/scratch`.
