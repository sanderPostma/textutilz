# Persistence, session restore & UI batch — design

Date: 2026-07-14
Status: approved

## Goal

Make textutilz restore its full tab/session state across restarts using a
Rust-owned SQLite store (Diesel), tighten scratch-document lifecycle around the
auto-delete modes, add a close-confirmation dialog, and land a set of UI fixes.
Upholds the founding mandate: **document/persistence logic lives in Rust; Dart is
a thin UI shell.**

## 1. Auto-delete modes → lifecycle

Auto-delete governs cleanup, not restorability. Scratch content always lives in
the DB and restores on reopen.

| Mode | Ctrl+S / Save | Restores on reopen | Cleanup |
|---|---|---|---|
| **off** | savable (scratch → Save As) | yes | none |
| **onAppClose** | no-op | **no** — discarded at app close | never persisted to the DB; on-disk scratch file removed at app close |
| **atMidnight** | no-op | yes (from DB) | purged (row + file) once a midnight has passed since creation; live midnight timer also removes them |

"Auto-delete tabs should not save" = Save/Ctrl+S is a no-op for `onAppClose` and
`atMidnight`; only `off` is savable.

## 2. Rust persistence layer — `rust/src/api/store.rs` (new)

- **Diesel** with `libsqlite3-sys` `"bundled"` feature (no system sqlite dep),
  synchronous — matches the existing `frb(sync)` style of `EditSession`.
- DB file lives in the **OS-correct per-user data dir** via the `dirs` crate:
  `dirs::data_dir()/textutilz/textutilz.db` — Linux `~/.local/share`, macOS
  `~/Library/Application Support`, Windows `%APPDATA%`. The scratch dir moves to
  the same base (`.../textutilz/scratch`). A Rust helper exposes these paths so
  Dart no longer hardcodes `~/.local/share`.
- Schema via idempotent `CREATE TABLE IF NOT EXISTS` at `open()` (hand-written
  `table!` macros give typed queries). No diesel-CLI/migrations tooling for a
  two-table schema.
- **`documents`**: `id`, `display_name`, `path`, `is_transient`, `content_type`,
  `extension`, `auto_delete`, `view_mode`, `font_read`, `font_tail`, `font_edit`,
  `scratch_content` (TEXT, NULL for real files — never duplicate large mmap'd
  files into sqlite), `created_day` (epoch day, for atMidnight purge),
  `tab_order`, `is_active`.
- **`settings`**: `key` PK / `value` TEXT (holds `theme_mode`; room to grow).
- `AppStore` is `frb(opaque)`, methods take `&mut self` (like `EditSession`):
  - `open() -> AppStore`
  - `save_session(docs: Vec<DocRecord>)` — one transaction: delete all rows,
    insert the passed set in `tab_order`. Caller passes every tab it wants
    persisted.
  - `load_session(today_epoch_day: i64) -> Vec<DocRecord>` — first deletes
    `atMidnight` rows with `created_day < today_epoch_day`, then returns the rest
    ordered by `tab_order`.
  - `get_setting(key) -> Option<String>` / `set_setting(key, value)`.
- `DocRecord` — plain frb struct mirroring the columns above.

### EditSession additions

- `content_string() -> String` — full current text (base + overlay), used to
  capture scratch content for the DB.
- `create_scratch(path, content) -> EditSession` — writes `content` to `path`
  (creating parent dirs) then opens it, so Dart never performs document IO.

### Path helpers (Rust, `frb(sync)`)

- `app_data_dir() -> String` and `scratch_dir() -> String` — OS-correct paths via
  the `dirs` crate, created if missing. Dart uses these instead of building paths
  from `$HOME`.

## 3. Dart wiring (thin)

- **Startup**: `AppStore.open()` → `loadSession(todayEpochDay)` → rebuild tabs
  (scratch → `create_scratch` from `scratch_content`; real file → `open`, skip if
  the file is gone); restore the active tab; `getSetting('theme_mode')` →
  `themeNotifier`.
- **Persist** (`_persistSession`): called after structural changes (create / open
  / close / switch tab, mode change, save) and on close. Builds `List<DocRecord>`
  from tabs, capturing `content_string()` for scratch docs, and calls
  `saveSession`. `todayEpochDay` is computed in Dart from `DateTime.now()`.
- **Theme toggle** writes `set_setting('theme_mode', ...)`.
- **`onWindowClose`**: remove on-disk scratch files for `onAppClose` docs, persist
  the session, then destroy.

## 4. Close confirmation (`x` / Ctrl+W)

- Dirty savable tab (`off`) → **Save / Discard / Cancel** (Save routes through the
  existing Save-As flow, awaited before close).
- Dirty auto-delete tab (`onAppClose` / `atMidnight`) → **Discard / Cancel**.
- Clean tab → closes immediately.

## 5. UI fixes

- Ribbon blocks left-aligned (the `AnimatedSwitcher` wrapping the menu table
  currently centers its child → `alignment: Alignment.centerLeft`).
- Numpad Enter handled alongside `LogicalKeyboardKey.enter` in the editor.
- Trash-can glyph on tabs with `autoDelete != off` (distinct from the dirty dot).
- Title bar and tab bar get distinct color treatments, differing between light and
  dark themes.

## Testing

- Rust unit tests for `store.rs`: round-trip `save_session`/`load_session`,
  ordering by `tab_order`, `atMidnight` purge by `created_day`, settings get/set,
  scratch_content null vs present.
- `EditSession` tests: `content_string` reflects edits; `create_scratch` writes +
  opens.
- Manual: restart app and confirm tabs, active tab, view modes, font sizes, theme,
  and scratch content restore; confirm close dialog behavior per mode.
