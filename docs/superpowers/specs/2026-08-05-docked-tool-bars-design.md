# Docked tool bars

Date: 2026-08-05
Status: Approved

## Mandate

Flutter/Dart is a thin UI shell; document logic lives in Rust. This change is
presentation only — no operation logic moves, and no Rust changes are required.

## Problem

The ribbon's command panels (MIME tools, edit tools) open as full-height
overlays inside the ribbon. Two consequences:

1. **They cover the document.** Every one of these tools transforms the current
   selection, yet the panel hides the very text being transformed. You choose an
   operation blind.
2. **They waste vertical space.** A panel is a title row with a back arrow
   (~48px), an 8px gap, a chip grid (~80px), a 16px gap, and an Apply button
   (~40px) — roughly 190px to present what is really one row of choices.

The window now has a minimum width of 800px, so there is horizontal room to
spend and vertical room to reclaim.

## Goals

- Tool panels become slim bars docked above the editor, like the find bar, so
  the document — and the selection — stays visible and selectable.
- Drop the title-plus-back-arrow row. The title becomes a rounded tab centered
  on the bar's top edge.
- A close button on the same line as the controls, plus Esc, as in the find bar.
- Extract the chrome the bars share instead of duplicating the find bar's
  layout a twelfth time.

## Decisions

Settled during design; recorded so the reasoning survives:

| Question | Decision |
|---|---|
| Docked or overlay? | **Docked.** Opening a tool closes the ribbon and docks a bar above the editor, pushing it down. |
| Which panels convert? | **Edit tools (4) and MIME tools (7).** `new` and `autodelete` stay in the ribbon — they are forms, not toolbars. |
| Find bar and tool bar together? | **One at a time.** Opening either closes the other. |
| Title tab placement | **Centered** on the bar's top edge. |
| Chips that do not fit | **Wrap to a second line.** Everything stays visible; no scrolling, no hidden options. |
| Apply model | **Split, deliberately** — see below. |

## The two bar families

They behave differently on purpose. Written down because it otherwise reads as
an inconsistency bug.

### Edit bars — no Apply button

`Convert Case`, `EOL Conversion`, `Blank Operations`, `Comment/Uncomment`.

Every edit operation is self-contained: there are no modifier controls, and the
"blend" variants (`edit.case.proper_blend`, `edit.case.sentence_blend`) are
separate operations rather than a checkbox. With nothing to configure, a
select-then-Apply step is pure overhead.

So each chip becomes an **action button that runs on click**. The bar stays open
afterwards, so several operations can be run in sequence. Each operation is
already its own undo step, so a mis-click is one Ctrl+Z.

This makes `EditToolsPanel` stateless: the four `_selected*Op` fields and
`_currentOp` all disappear along with the `Apply` button, and the widget stops
being a `StatefulWidget`. The bar no longer remembers a previous choice — with
one-click apply there is nothing to remember.

```
┌──────────────────────────────────────────────────────┐
│        ╭─ Comment/Uncomment ─╮                       │
│  [Toggle Single Line] [Block Comment] [Block Uncom]  ✕│
│  [Single Line Comment] [Single Line Uncomment]        │
└──────────────────────────────────────────────────────┘
```

### MIME bars — Apply retained

`Base64`, `Quoted-printable` and `URL` encode/decode, plus `SAML Decode`.

These carry checkboxes that change what the operation does, so the user must be
able to set options before anything runs. Chips select the variant, checkboxes
modify it, `Apply` executes.

```
┌──────────────────────────────────────────────────────┐
│        ╭─ Base64 Encode ─╮                           │
│  ☑ Padding  ☐ By line            [▶ Apply]          ✕│
└──────────────────────────────────────────────────────┘
```

(Option labels above are the real ones — `Padding`, `By line`, `Strict`,
`Unix EOL` — and vary by category.)

## Architecture

### `lib/docked_bar.dart` (new) — the shared chrome

`DockedBar` owns everything a docked bar has in common:

- the surface container, colour and padding
- an optional centered title tab
- a right-pinned close button
- the overflow-proof layout conventions the find bar established: flexible
  content that can shrink, rigid controls that must stay reachable, and nothing
  that can produce a `RenderFlex` overflow at any width

```dart
DockedBar({
  String? title,               // null -> no tab (the find bar)
  required Widget child,       // the control cluster
  required VoidCallback onClose,
})
```

`title` is optional so **the find bar keeps exactly its current appearance**. It
adopts `DockedBar` for the chrome but passes no title, so no tab appears. Giving
find a "Find"/"Replace" tab later is a one-argument change; it is out of scope
here because it was not asked for.

### Placement — above the document tab bar

Both bars dock **between the window chrome and the document tab bar**, not
between the tab bar and the editor:

```
┌───────────────────────────────────────┐
│ ☰  Read | Tail | ✓Edit        ☀ ─ □ │  window chrome
├────────╭─ Comment/Uncomment ─╮────────┤  ← the tab hangs from the chrome
│ [Toggle] [Block Comment] [Block Unc] ✕│  tool bar
├───────────────────────────────────────┤
│ notes.txt │ main.rs │                 │  document tabs
├───────────────────────────────────────┤
│ 1  the document…                      │  editor
└───────────────────────────────────────┘
```

The title tab must hang from the window chrome to read correctly. Docked below
the document tab bar it would appear to dangle off the file tabs, which looks
like a rendering bug rather than a design.

**The find bar moves up with it.** The two bars occupy the same slot — they are
mutually exclusive, they share `DockedBar`, and leaving one above the tabs and
one below would be an arbitrary inconsistency. The find bar's appearance is
unchanged; only where it sits in the column moves.

Because that slot is outside the view-mode branch, both bars carry an explicit
`ViewMode.edit` guard that the old placement got for free from its position.

### The title tab

A centered pill with rounded *bottom* corners, painted in the bar's surface
colour inside an otherwise transparent row, so it reads as hanging from the
chrome above rather than as a heading inside the bar. Roughly 20px tall.

### Content widgets

`EditToolsPanel` and `SingleMimeToolPanel` keep their operation lists and their
logic. What changes is the frame:

- drop `Align` + `ConstrainedBox(maxWidth: 680/560)` — the bar owns width now
- fold the `Apply` button into the chip `Wrap` (MIME only) rather than sitting
  below a 16px gap
- tighten spacing to bar proportions

The chips are already laid out with `Wrap`, so the two-line behaviour largely
falls out of removing the width constraint.

### State

`main.dart` gains `String? _activeToolPanelId` beside the existing
`_isFindVisible`. Mutual exclusion is enforced in the two open functions and
nowhere else: `_openFind` clears `_activeToolPanelId`, and `_openToolBar` clears
`_isFindVisible`. Keeping the rule in one place is what makes "one bar at a
time" verifiable by reading.

`Esc` generalises from "close the find bar" to "close whichever bar is open".

### Ribbon routing

`menu_ribbon.dart` gains an `onOpenToolBar(String panelId)` callback. The 11
mime/edit commands route through it and close the ribbon. `new` and
`autodelete` keep the existing in-ribbon path, so `RibbonPanelScaffold` stays —
it is still the right shape for those two.

## Vertical budget

| | Now | After |
|---|---|---|
| Title + back arrow | ~48px | ~20px (the tab row) |
| Gap | 8px | 0 |
| Chips | ~80px | ~32px (one row) or ~64px (two) |
| Gap + Apply | ~56px | inline (MIME) / 0 (edit) |
| **Total** | **~190px** | **~52px (one row) – ~84px (two)** |

Even the two-row worst case is under half the current height, and the common
one-row case is roughly a quarter of it.

## Edge cases

- **No editable document** (hex mode, no tabs): tool bars cannot be opened, and
  the ribbon entries stay disabled exactly as they do today.
- **Tool bar open, tab switched to hex**: the bar closes, matching how the find
  bar retargets.
- **Disabled state**: with no Apply button, the edit bars disable the action
  buttons themselves when `editToolsEnabled` is false.
- **Narrow window**: chips wrap to a second line. The close button stays pinned
  and reachable at every width — this is what the sweep test guards.
- **Applying does not close the bar**, in either family.

## Testing

- **Width sweep, 400→1600px**, over a tool bar in both its one-line and two-line
  states, asserting no overflow and that the close button stays findable. This
  is the only test type that has reliably caught layout defects in this
  codebase; two hand-picked widths have twice failed to.
- The title tab renders the expected label for a given panel id.
- Edit bar: clicking an action button invokes the run callback with the right
  op id, and the buttons are disabled when the tool is disabled.
- MIME bar: `Apply` invokes with the selected variant and the checkbox state.

## Known gaps

**Mutual exclusion between the find bar and tool bars cannot be tested
automatically.** It lives in `_MyHomePageState`, which no test harness drives —
the same limitation already recorded for `_openFind` and `_retargetFind`. It is
a manual check, listed below rather than papered over.

## Manual verification

1. Choosing a MIME or edit tool closes the ribbon and docks a bar above the
   editor; the document is visible and the selection intact.
2. The title tab is centered and reads as attached to the chrome above.
3. Clicking an edit action applies it immediately; one Ctrl+Z reverts it.
4. A MIME bar requires Apply, and honours its checkboxes.
5. The bar stays open after applying, so a second operation can be run.
6. Opening find while a tool bar is open closes the tool bar, and vice versa.
7. Esc and the ✕ both close the open bar.
8. `New` and `Auto-delete` still open inside the ribbon, unchanged.
9. At 800px the chips wrap without overflow and the ✕ stays reachable.

## Phasing

1. `DockedBar` + adopt it in the find bar (no visual change) — proves the
   component against the existing width sweep before anything depends on it.
2. Edit bars: stateless `EditToolsPanel`, immediate apply, ribbon routing,
   `_activeToolPanelId` state, Esc generalisation.
3. MIME bars.

Phase 1 is deliberately a no-op visually. If the find panel's sweep test still
passes after it adopts `DockedBar`, the shared chrome is sound.
