# Ribbon Menu Table — Design

Date: 2026-07-14

## Goal

Replace the loose row of buttons in the ribbon overlay (`_isRibbonVisible`)
with a search field plus a structured, modern, lightly-colorful menu table.

## Layout (top → bottom, inside the existing ribbon overlay)

1. **Search field** — compact (not too tall), rounded, full-width, with a
   leading 🔍 icon.
2. **Body**, swapped by search field contents:
   - Empty field → **menu table** (default).
   - Non-empty field → **stub search-results panel** (`Results for "…"` header +
     empty hitlist placeholder). Clearing the field restores the table. Real
     search wired later.

## Menu table

Three equal-width columns, each a **vertical stack** of items:

| Column | Accent | Items |
|--------|--------|-------|
| File   | blue   | Open, Save, Close Tab |
| Edit   | teal   | Undo, Redo, Cut, Copy, Paste |
| Search | violet | Find, Replace, Go to Line |

- Column headers rendered in their accent color.
- Each cell: subtly tinted rounded row, leading icon + label.
- **Wired now:** Open → `_openFile`, Save → `_saveFile` (disabled unless dirty),
  Close Tab → close active tab. All other items = present but **disabled
  placeholders**.

## Hover behavior

Per-column hover tracked with `MouseRegion`. Hovered column shows at full
accent/opacity; the other two **dim** (reduced opacity / desaturated). No hover
→ neutral resting state for all. Animated with short `AnimatedOpacity` /
`AnimatedContainer`. Purely visual.

## Structure

- New file `lib/menu_ribbon.dart` holding a `MenuRibbon` widget (+ small private
  column/cell widgets). Inputs: action callbacks (open/save/closeTab, with
  enabled flags) and an `onSearchChanged` callback.
- `main.dart` renders `MenuRibbon(...)` inside the existing `Positioned`
  overlay and owns the search-text state that drives the table↔results swap.

## Theme

Accent colors defined for light and dark; cells use `surfaceContainer` tints so
the ribbon reads well in both themes.

## Out of scope (later)

- Real search / hitlist of functions.
- Wiring Undo/Redo/Cut/Copy/Paste/Find/Replace/Go to Line.
