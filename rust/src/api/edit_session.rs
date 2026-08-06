use std::collections::HashMap;

use crate::api::file_manager::{FileBuffer, LineEdit};

/// Where the caret should sit after an operation. Columns are counted in
/// UTF-16 code units, matching the Dart/Flutter renderer (1 column == 1
/// monospace cell for the BMP, which covers all normal text and code).
pub struct CaretPos {
    pub row: usize,
    pub col: usize,
}

impl CaretPos {
    fn new(row: usize, col: usize) -> Self {
        CaretPos { row, col }
    }
}

/// A primitive text operation. `text` in Insert may contain '\n'.
#[derive(Clone)]
enum Op {
    Insert {
        row: usize,
        col: usize,
        text: String,
    },
    Delete {
        srow: usize,
        scol: usize,
        erow: usize,
        ecol: usize,
    },
}

/// One undo step: one or more primitives applied in order. Undo replays their
/// inverses in reverse; redo replays the forwards in order.
struct UndoEntry {
    prims: Vec<(Op /*forward*/, Op /*inverse*/)>,
    /// Caret after the last forward primitive — used to detect contiguous typing.
    end_row: usize,
    end_col: usize,
    /// True only for a lone single-character insert that may absorb the next one.
    coalescable: bool,
}

/// The editable document: an immutable mmap base ([FileBuffer]) plus a
/// copy-on-write line overlay, with undo/redo. Memory is proportional to the
/// edits, not the file size.
#[flutter_rust_bridge::frb(opaque)]
pub struct EditSession {
    base: FileBuffer,
    /// base line index -> replacement lines (0..n). A base line is materialized
    /// into an owned String only when first edited.
    overlay: HashMap<usize, Vec<String>>,
    /// Sorted keys of `overlay`, for the visual<->logical row mapping.
    edited_rows: Vec<usize>,
    /// Net lines added (or removed) by edits.
    added_lines: i64,
    undo: Vec<UndoEntry>,
    redo: Vec<UndoEntry>,
    /// While Some, insert/delete append to this group instead of the undo stack.
    group: Option<UndoEntry>,
    /// When true, consecutive single-character typing merges into one undo step
    /// (the classic word-at-a-time behavior). When false, every keystroke is its
    /// own step. Shared app setting; applies to all editors alike.
    coalesce: bool,
    /// Bumped by every content change. The markup cache compares against it to
    /// know whether its checkpoints still describe this document.
    revision: u64,
    /// Lexer resume checkpoints for the last language asked about. Rebuilt on
    /// demand rather than eagerly, so a document nobody colours never pays for
    /// one.
    markup_cache: Option<MarkupCache>,
}

/// Lexer checkpoints for one document revision and one language.
///
/// Checkpoints are what make viewport colouring affordable on a large file: a
/// painter that needs row 40,000 resumes from the nearest stored state and
/// re-lexes at most `CHECKPOINT_ROWS` rows, instead of lexing from row 0.
struct MarkupCache {
    language: crate::markup::MarkupLanguage,
    revision: u64,
    checkpoints: Vec<crate::markup::LexState>,
    /// Matched delimiter pairs, kept so that moving the caret is a search over
    /// an existing list rather than a fresh pass over the document.
    pairs: Vec<crate::markup::BracketPair>,
    /// The most recently lexed run of rows, kept so that a caller asking for
    /// one row at a time does not pay the checkpoint warm-up on every row.
    window: Option<TokenWindow>,
}

/// A contiguous run of already-lexed rows, `[start, start + rows.len())`.
struct TokenWindow {
    start: usize,
    rows: Vec<crate::markup::RowTokens>,
}

/// How many rows to lex when a caller asks for fewer.
///
/// The cost being amortised is the resume warm-up: a request starting at row
/// `r` re-lexes from the checkpoint below it, so up to [`CHECKPOINT_ROWS`]
/// rows of work for a single row of output. A viewport painted one row at a
/// time therefore did ~64× the necessary lexing — measured at 5.3 ms per
/// frame for a 50-row viewport, against 0.18 ms for the same rows in one
/// call. Four checkpoints' worth covers a tall window plus scrolling slack.
const TOKEN_WINDOW_ROWS: usize = crate::markup::token::CHECKPOINT_ROWS * 4;

// ---- UTF-16 column helpers (match Dart's code-unit columns) ----------------

fn u16_len(s: &str) -> usize {
    s.chars().map(|c| c.len_utf16()).sum()
}

/// True when `span` lies wholly inside `scope`.
fn span_in_scope(
    span: &crate::api::search::MatchSpan,
    scope: &crate::api::search::SpanScope,
) -> bool {
    let after_start = (span.start_row, span.start_col) >= (scope.start_row, scope.start_col);
    let before_end = (span.end_row, span.end_col) <= (scope.end_row, scope.end_col);
    after_start && before_end
}

/// Byte index in `s` at the given UTF-16 column (clamped to the string end).
fn u16_to_byte(s: &str, col: usize) -> usize {
    let mut u = 0;
    for (b, ch) in s.char_indices() {
        if u >= col {
            return b;
        }
        u += ch.len_utf16();
    }
    s.len()
}

impl EditSession {
    #[flutter_rust_bridge::frb(sync)]
    pub fn open(path: String) -> anyhow::Result<EditSession> {
        let base = FileBuffer::open(path)?;
        Ok(EditSession {
            base,
            overlay: HashMap::new(),
            edited_rows: Vec::new(),
            added_lines: 0,
            undo: Vec::new(),
            redo: Vec::new(),
            group: None,
            coalesce: true,
            revision: 0,
            markup_cache: None,
        })
    }

    /// Set whether consecutive single-character typing coalesces into one undo
    /// step (true) or each keystroke is its own step (false).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_coalesce_undo(&mut self, on: bool) {
        self.coalesce = on;
    }

    /// Create a scratch file at `path` containing `content` (creating parent
    /// dirs), then open a session over it. Keeps document IO on the Rust side so
    /// Dart never writes files itself. Used to rehydrate persisted scratch docs.
    #[flutter_rust_bridge::frb(sync)]
    pub fn create_scratch(path: String, content: String) -> anyhow::Result<EditSession> {
        if let Some(parent) = std::path::Path::new(&path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, content.as_bytes())?;
        EditSession::open(path)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn path(&self) -> String {
        self.base.path.clone()
    }

    /// The full current document text (base + overlay), visual lines joined by
    /// '\n'. Used to capture scratch-document content for persistence.
    #[flutter_rust_bridge::frb(sync)]
    pub fn content_string(&self) -> String {
        // Read the entire base file once to avoid massive OS file open/close syscall overhead
        let original_content = match std::fs::read(&self.base.path) {
            Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(_) => String::new(),
        };

        // Split into lines and strip trailing carriage returns
        let base_lines: Vec<String> = original_content
            .split('\n')
            .map(|line| {
                if line.ends_with('\r') {
                    line[..line.len() - 1].to_string()
                } else {
                    line.to_string()
                }
            })
            .collect();

        let line_count = self.line_count();
        let mut result_lines = Vec::with_capacity(line_count);

        for vrow in 0..line_count {
            let (orow, sub) = self.get_logical(vrow);
            if let Some(lines) = self.overlay.get(&orow) {
                if let Some(line) = lines.get(sub) {
                    result_lines.push(line.clone());
                } else {
                    result_lines.push(String::new());
                }
            } else {
                if let Some(line) = base_lines.get(orow) {
                    result_lines.push(line.clone());
                } else {
                    result_lines.push(String::new());
                }
            }
        }

        result_lines.join("\n")
    }

    /// Fast copy of the entire document to the system clipboard on the Rust side.
    /// Returns the UTF-16 character count of the copied text.
    #[flutter_rust_bridge::frb(sync)]
    pub fn copy_to_clipboard(&self) -> anyhow::Result<usize> {
        let text = self.content_string();
        let len = u16_len(&text);
        let mut ctx = arboard::Clipboard::new()
            .map_err(|e| anyhow::anyhow!("Failed to initialize clipboard: {}", e))?;
        ctx.set_text(text)
            .map_err(|e| anyhow::anyhow!("Failed to set clipboard text: {}", e))?;
        Ok(len)
    }

    /// Calculate selection character count extremely fast (combining small range exact counting and large range O(1) estimation)
    #[flutter_rust_bridge::frb(sync)]
    pub fn selection_char_count(
        &self,
        mut r1: usize,
        mut c1: usize,
        mut r2: usize,
        mut c2: usize,
    ) -> usize {
        let line_count = self.line_count();
        if line_count == 0 {
            return 0;
        }
        if r1 >= line_count {
            r1 = line_count - 1;
        }
        if r2 >= line_count {
            r2 = line_count - 1;
        }

        if r1 > r2 || (r1 == r2 && c1 > c2) {
            std::mem::swap(&mut r1, &mut r2);
            std::mem::swap(&mut c1, &mut c2);
        }

        let mut total_chars = 0;
        let diff = r2 - r1;
        if diff < 100 {
            for r in r1..=r2 {
                let line = self.get_line_visual(r);
                let len = u16_len(&line);
                let start = if r == r1 { std::cmp::min(c1, len) } else { 0 };
                let end = if r == r2 { std::cmp::min(c2, len) } else { len };
                total_chars += end.saturating_sub(start);
                if r < r2 {
                    total_chars += 1; // newline
                }
            }
        } else {
            let start_offset = if r1 < self.base.line_offsets.len() {
                self.base.line_offsets[r1] + c1
            } else {
                self.base.size
            };
            let end_offset = if r2 < self.base.line_offsets.len() {
                self.base.line_offsets[r2] + c2
            } else {
                self.base.size
            };
            total_chars = end_offset.saturating_sub(start_offset);
        }
        total_chars
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_dirty(&self) -> bool {
        // The empty undo stack is the saved/loaded checkpoint (content equals
        // the file on disk), so undoing all the way back clears the dirty flag.
        !self.undo.is_empty()
    }

    /// True when the file at this session's path no longer matches the
    /// version used to build the base line index. Detection stays in Rust so
    /// callers never need to duplicate filesystem identity/mtime logic.
    #[flutter_rust_bridge::frb(sync)]
    pub fn has_external_changes(&self) -> bool {
        self.base.has_external_changes()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn line_count(&self) -> usize {
        (self.base.get_line_count() as i64 + self.added_lines) as usize
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn line(&self, vrow: usize) -> String {
        self.get_line_visual(vrow)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn refresh(&mut self) -> anyhow::Result<()> {
        self.revision = self.revision.wrapping_add(1);
        self.base.refresh()?;
        self.added_lines = 0;
        self.edited_rows.clear();
        self.overlay.clear();
        self.undo.clear();
        self.redo.clear();
        self.group = None;
        Ok(())
    }

    // ---- visual <-> logical mapping (ported from the old Dart model) --------

    fn base_line(&self, orow: usize) -> String {
        self.base.read_line(orow).unwrap_or_default()
    }

    /// (original_row, sub_index) for a visual row.
    ///
    /// Still linear in the number of edited rows, and that is what is left of
    /// Replace All's superlinearity — it runs once per primitive edit, and
    /// Replace All performs two per match.
    ///
    /// An `added_lines == 0` fast path was tried and is **wrong**: a split and
    /// a join in the same session cancel out, so the counter reaches zero
    /// while the mapping is not the identity. Two existing tests catch it
    /// (`replace_all_swaps_content_and_undoes_in_one_step`,
    /// `undo_delete_restores_bytes`). A correct short-circuit needs a count of
    /// rows whose overlay holds other than exactly one line, maintained at
    /// every site that mutates an overlay vector — which is the review cycle
    /// this was always going to need.
    fn get_logical(&self, vrow: usize) -> (usize, usize) {
        let mut current_v = 0usize;
        let mut current_o = 0usize;
        for &erow in &self.edited_rows {
            let unchanged = erow - current_o;
            if vrow < current_v + unchanged {
                return (current_o + (vrow - current_v), 0);
            }
            current_v += unchanged;
            current_o = erow;

            let edited = self.overlay[&erow].len();
            if vrow < current_v + edited {
                return (erow, vrow - current_v);
            }
            current_v += edited;
            current_o += 1;
        }
        (current_o + (vrow - current_v), 0)
    }

    fn get_line_visual(&self, vrow: usize) -> String {
        let (orow, sub) = self.get_logical(vrow);
        if let Some(lines) = self.overlay.get(&orow) {
            lines.get(sub).cloned().unwrap_or_default()
        } else {
            self.base_line(orow)
        }
    }

    /// Materialize the original row backing `vrow` into the overlay (copy-on-write).
    fn prepare_edit(&mut self, vrow: usize) {
        let (orow, _sub) = self.get_logical(vrow);
        if !self.overlay.contains_key(&orow) {
            let line = self.base_line(orow);
            self.overlay.insert(orow, vec![line]);
            // Inserted in place rather than pushed and re-sorted. The list is
            // sorted by construction, so the sort was re-establishing an
            // invariant that already held — at O(n log n) per edit, on a path
            // Replace All drives once per match.
            let at = self.edited_rows.partition_point(|&r| r < orow);
            self.edited_rows.insert(at, orow);
        }
    }

    // ---- raw application (no undo bookkeeping) ------------------------------

    /// Apply an insert; return the caret position just past the inserted text.
    fn do_insert(&mut self, vrow: usize, vcol: usize, text: &str) -> CaretPos {
        let parts: Vec<&str> = text.split('\n').collect();
        let n = parts.len();

        self.prepare_edit(vrow);
        let (orow, sub) = self.get_logical(vrow);

        let mut line = self.overlay.get(&orow).unwrap()[sub].clone();
        let cur_len = u16_len(&line);
        if cur_len < vcol {
            line.push_str(&" ".repeat(vcol - cur_len));
        }
        let bidx = u16_to_byte(&line, vcol);
        let left = line[..bidx].to_string();
        let right = line[bidx..].to_string();

        let end;
        if n == 1 {
            let mut combined = left;
            combined.push_str(parts[0]);
            let end_col = u16_len(&combined);
            combined.push_str(&right);
            self.overlay.get_mut(&orow).unwrap()[sub] = combined;
            end = CaretPos::new(vrow, end_col);
        } else {
            let mut first = left;
            first.push_str(parts[0]);
            let mut last = parts[n - 1].to_string();
            let last_col = u16_len(&last);
            last.push_str(&right);

            let vec = self.overlay.get_mut(&orow).unwrap();
            vec[sub] = first;
            let mut insert_at = sub + 1;
            for part in parts.iter().take(n - 1).skip(1) {
                vec.insert(insert_at, part.to_string());
                insert_at += 1;
            }
            vec.insert(insert_at, last);
            self.added_lines += (n - 1) as i64;
            end = CaretPos::new(vrow + (n - 1), last_col);
        }
        end
    }

    /// Apply a delete over a normalized range; return the removed text and the
    /// caret position (the range start).
    fn do_delete(
        &mut self,
        srow: usize,
        scol: usize,
        erow: usize,
        ecol: usize,
    ) -> (String, CaretPos) {
        if srow == erow {
            self.prepare_edit(srow);
            let (orow, sub) = self.get_logical(srow);
            let line = self.overlay.get(&orow).unwrap()[sub].clone();
            let len = u16_len(&line);
            let s = u16_to_byte(&line, scol.min(len));
            let e = u16_to_byte(&line, ecol.min(len));
            let removed = line[s..e].to_string();
            let mut combined = line[..s].to_string();
            combined.push_str(&line[e..]);
            self.overlay.get_mut(&orow).unwrap()[sub] = combined;
            return (removed, CaretPos::new(srow, scol));
        }

        self.prepare_edit(srow);
        self.prepare_edit(erow);
        let (o1, s1) = self.get_logical(srow);
        let (o2, s2) = self.get_logical(erow);
        let line1 = self.overlay.get(&o1).unwrap()[s1].clone();
        let line2 = self.overlay.get(&o2).unwrap()[s2].clone();
        let len1 = u16_len(&line1);
        let len2 = u16_len(&line2);
        let b1 = u16_to_byte(&line1, scol.min(len1));
        let b2 = u16_to_byte(&line2, ecol.min(len2));

        // Removed text: line1 tail + full intermediate lines + line2 head.
        let mut removed = line1[b1..].to_string();
        for vr in (srow + 1)..erow {
            removed.push('\n');
            removed.push_str(&self.get_line_visual(vr));
        }
        removed.push('\n');
        removed.push_str(&line2[..b2]);

        let mut combined = line1[..b1].to_string();
        combined.push_str(&line2[b2..]);
        self.overlay.get_mut(&o1).unwrap()[s1] = combined;

        // Collect the logical positions of the visual rows to remove, then
        // remove them back-to-front so shared-row indices stay valid.
        let mut to_remove: Vec<(usize, usize)> = Vec::new();
        for vr in (srow + 1)..=erow {
            self.prepare_edit(vr);
            to_remove.push(self.get_logical(vr));
        }
        for &(orow, sub) in to_remove.iter().rev() {
            self.overlay.get_mut(&orow).unwrap().remove(sub);
            self.added_lines -= 1;
        }
        (removed, CaretPos::new(srow, scol))
    }

    /// Apply a single primitive without recording undo; return the resulting caret.
    fn apply(&mut self, op: &Op) -> CaretPos {
        match op {
            Op::Insert { row, col, text } => self.do_insert(*row, *col, text),
            Op::Delete {
                srow,
                scol,
                erow,
                ecol,
            } => self.do_delete(*srow, *scol, *erow, *ecol).1,
        }
    }

    // ---- undo recording -----------------------------------------------------

    fn record(
        &mut self,
        forward: Op,
        inverse: Op,
        start: (usize, usize),
        end: &CaretPos,
        coalescable: bool,
    ) {
        self.redo.clear();
        if let Some(group) = &mut self.group {
            group.prims.push((forward, inverse));
            group.end_row = end.row;
            group.end_col = end.col;
            group.coalescable = false;
            return;
        }
        if coalescable && self.coalesce {
            if let Some(top) = self.undo.last_mut() {
                if top.coalescable && top.end_row == start.0 && top.end_col == start.1 {
                    top.prims.push((forward, inverse));
                    top.end_row = end.row;
                    top.end_col = end.col;
                    return;
                }
            }
        }
        self.undo.push(UndoEntry {
            prims: vec![(forward, inverse)],
            end_row: end.row,
            end_col: end.col,
            coalescable,
        });
    }

    // ---- public mutations ---------------------------------------------------

    #[flutter_rust_bridge::frb(sync)]
    pub fn insert(&mut self, row: usize, col: usize, text: String) -> CaretPos {
        self.revision = self.revision.wrapping_add(1);
        let end = self.do_insert(row, col, &text);
        let inverse = Op::Delete {
            srow: row,
            scol: col,
            erow: end.row,
            ecol: end.col,
        };
        let forward = Op::Insert {
            row,
            col,
            text: text.clone(),
        };
        // Coalescable only for a single-character, single-line insert.
        let coalescable = !text.contains('\n') && u16_len(&text) == 1;
        self.record(forward, inverse, (row, col), &end, coalescable);
        end
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn delete(&mut self, srow: usize, scol: usize, erow: usize, ecol: usize) -> CaretPos {
        self.revision = self.revision.wrapping_add(1);
        // Normalize so start <= end.
        let (srow, scol, erow, ecol) = if srow > erow || (srow == erow && scol > ecol) {
            (erow, ecol, srow, scol)
        } else {
            (srow, scol, erow, ecol)
        };
        let (removed, caret) = self.do_delete(srow, scol, erow, ecol);
        let forward = Op::Delete {
            srow,
            scol,
            erow,
            ecol,
        };
        let inverse = Op::Insert {
            row: srow,
            col: scol,
            text: removed,
        };
        self.record(forward, inverse, (srow, scol), &caret, false);
        caret
    }

    /// Break typing coalescing (call on caret moves, clicks, focus changes) so
    /// the next insert starts a fresh undo step.
    #[flutter_rust_bridge::frb(sync)]
    pub fn break_coalescing(&mut self) {
        if let Some(top) = self.undo.last_mut() {
            top.coalescable = false;
        }
    }

    /// Begin grouping subsequent mutations into a single undo step.
    #[flutter_rust_bridge::frb(sync)]
    pub fn begin_group(&mut self) {
        if self.group.is_none() {
            self.group = Some(UndoEntry {
                prims: Vec::new(),
                end_row: 0,
                end_col: 0,
                coalescable: false,
            });
        }
    }

    /// Finalize the current group.
    #[flutter_rust_bridge::frb(sync)]
    pub fn end_group(&mut self) {
        if let Some(group) = self.group.take() {
            if !group.prims.is_empty() {
                self.redo.clear();
                self.undo.push(group);
            }
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn undo(&mut self) -> Option<CaretPos> {
        self.revision = self.revision.wrapping_add(1);
        let entry = self.undo.pop()?;
        let mut caret = CaretPos::new(entry.end_row, entry.end_col);
        // Apply inverses in reverse order.
        for (_forward, inverse) in entry.prims.iter().rev() {
            caret = self.apply(inverse);
        }
        self.redo.push(entry);
        Some(caret)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn redo(&mut self) -> Option<CaretPos> {
        self.revision = self.revision.wrapping_add(1);
        let entry = self.redo.pop()?;
        let mut caret = CaretPos::new(entry.end_row, entry.end_col);
        for (forward, _inverse) in entry.prims.iter() {
            caret = self.apply(forward);
        }
        self.undo.push(entry);
        Some(caret)
    }

    /// Replace the entire document with `text`, recorded as a single undoable
    /// step (delete-all + insert). Used by transforms like the MIME tools that
    /// rewrite the whole buffer. Returns the caret past the inserted text.
    #[flutter_rust_bridge::frb(sync)]
    pub fn replace_all(&mut self, text: String) -> CaretPos {
        self.revision = self.revision.wrapping_add(1);
        self.begin_group();
        let last_row = self.line_count().saturating_sub(1);
        let last_col = u16_len(&self.get_line_visual(last_row));
        self.delete(0, 0, last_row, last_col);
        let caret = self.insert(0, 0, text);
        self.end_group();
        caret
    }

    // ---- saving -------------------------------------------------------------

    fn build_edits(&self) -> Vec<LineEdit> {
        self.overlay
            .iter()
            .map(|(row, lines)| LineEdit {
                row: *row,
                lines: lines.clone(),
            })
            .collect()
    }

    fn reset_after_save(&mut self) {
        self.overlay.clear();
        self.edited_rows.clear();
        self.added_lines = 0;
        self.undo.clear();
        self.redo.clear();
        self.group = None;
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save(&mut self) -> anyhow::Result<()> {
        let edits = self.build_edits();
        self.base.save_edits(edits)?;
        self.reset_after_save();
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save_as(&mut self, new_path: String) -> anyhow::Result<()> {
        self.revision = self.revision.wrapping_add(1);
        let edits = self.build_edits();
        self.base.save_edits_as(new_path, edits)?;
        self.reset_after_save();
        Ok(())
    }

    /// Find every match whose start row is in `[from_row, to_row)`.
    ///
    /// The scan itself reaches `SEARCH_WINDOW_OVERLAP_ROWS` rows past
    /// `to_row` so a multi-line match straddling the boundary is still found,
    /// but such a match is only returned by the window its *start* falls in.
    /// Consecutive windows therefore tile exactly, with no duplicates.
    ///
    /// When `scope` is given ("In selection"), only matches lying wholly
    /// inside it are returned — this is the single place scope filtering
    /// happens, so every caller (paging, viewport highlighting, counting,
    /// Replace All) agrees on what is in scope. The requested row range is
    /// also clamped to the scope's own rows, so paging towards a selection
    /// far down a large document does no per-window work before reaching it.
    pub fn find_in_rows(
        &self,
        query: crate::api::search::SearchQuery,
        from_row: usize,
        to_row: usize,
        scope: Option<crate::api::search::SpanScope>,
    ) -> anyhow::Result<Vec<crate::api::search::MatchSpan>> {
        use crate::api::search::{compile, MatchSpan, SEARCH_WINDOW_OVERLAP_ROWS};

        let total = self.line_count();
        // Nothing before the scope's first row, or starting after its last
        // row, can ever be in scope — so don't scan those rows at all.
        let (scope_lo, scope_hi) = Self::scope_row_bounds(&scope, total);
        let from = from_row.min(total).max(scope_lo);
        let to = to_row.min(total).min(scope_hi);
        if from >= to {
            return Ok(Vec::new());
        }
        let scan_to = (to + SEARCH_WINDOW_OVERLAP_ROWS).min(total);

        let re = compile(&query)?;

        // Join the scanned rows, remembering each row's byte offset in the
        // joined string so byte positions map back to (row, utf16 col).
        let mut text = String::new();
        let mut row_starts: Vec<usize> = Vec::with_capacity(scan_to - from);
        for row in from..scan_to {
            row_starts.push(text.len());
            text.push_str(&self.get_line_visual(row));
            if row + 1 < scan_to {
                text.push('\n');
            }
        }

        // Byte offset in `text` -> (absolute row, UTF-16 column).
        let locate = |byte: usize| -> (usize, usize) {
            // The last row whose start is <= byte.
            let idx = match row_starts.binary_search(&byte) {
                Ok(i) => i,
                Err(i) => i.saturating_sub(1),
            };
            let line = self.get_line_visual(from + idx);
            let within = byte - row_starts[idx];
            (from + idx, u16_len(&line[..within.min(line.len())]))
        };

        let mut out = Vec::new();
        let mut at = 0usize;
        while at <= text.len() {
            let Some(m) = re.find_at(&text, at) else {
                break;
            };
            let (srow, scol) = locate(m.start());
            if srow >= to {
                break;
            }
            let (erow, ecol) = locate(m.end());
            let span = MatchSpan {
                start_row: srow,
                start_col: scol,
                end_row: erow,
                end_col: ecol,
            };
            match &scope {
                Some(sc) if !span_in_scope(&span, sc) => {}
                _ => out.push(span),
            }
            // A zero-length match must advance, or this loops forever.
            at = if m.end() > m.start() {
                m.end()
            } else {
                let mut next = m.end() + 1;
                while next < text.len() && !text.is_char_boundary(next) {
                    next += 1;
                }
                next
            };
        }
        Ok(out)
    }

    /// Total matches in the document, or within `scope` when given. Pages the
    /// whole document one window at a time so peak memory stays bounded.
    pub fn count_matches(
        &self,
        query: crate::api::search::SearchQuery,
        scope: Option<crate::api::search::SpanScope>,
    ) -> anyhow::Result<usize> {
        use crate::api::search::{SearchQuery, SEARCH_WINDOW_ROWS};

        let total = self.line_count();
        let (mut row, end) = Self::scope_row_bounds(&scope, total);
        let mut count = 0usize;
        while row < end {
            let to = (row + SEARCH_WINDOW_ROWS).min(end);
            // SearchQuery is not Copy; rebuild it per window.
            let q = SearchQuery {
                pattern: query.pattern.clone(),
                mode: query.mode.clone(),
                match_case: query.match_case,
                whole_word: query.whole_word,
                dot_matches_newline: query.dot_matches_newline,
            };
            count += self.find_in_rows(q, row, to, scope.clone())?.len();
            row = to;
        }
        Ok(count)
    }

    /// Replace one match. `query` is needed so capture references in
    /// `replacement` can be expanded against that match. One undo step.
    pub fn replace_span(
        &mut self,
        query: crate::api::search::SearchQuery,
        span: crate::api::search::MatchSpan,
        replacement: String,
        preserve_case: bool,
    ) -> anyhow::Result<CaretPos> {
        self.revision = self.revision.wrapping_add(1);
        let text = self.expand_for_span(&query, &span, &replacement, preserve_case)?;
        self.begin_group();
        self.delete(span.start_row, span.start_col, span.end_row, span.end_col);
        let caret = self.insert(span.start_row, span.start_col, text);
        self.end_group();
        Ok(caret)
    }

    /// The `[from, to)` row range worth scanning for `scope` in a document of
    /// `total` rows. Without a scope that is the whole document.
    ///
    /// This is a performance narrowing, not a filter: `span_in_scope` still
    /// decides what counts. It is *nearly* output-neutral — everything the
    /// clamp skips would have been rejected anyway — with one exception. A
    /// greedy dot-all pattern's match extent depends on how much text was
    /// scanned, so scanning less can split what would have been one long match
    /// into several shorter ones that now fit inside the scope. The clamp can
    /// therefore add matches; it can never drop one.
    fn scope_row_bounds(
        scope: &Option<crate::api::search::SpanScope>,
        total: usize,
    ) -> (usize, usize) {
        match scope {
            Some(sc) => (
                sc.start_row.min(total),
                sc.end_row.saturating_add(1).min(total),
            ),
            None => (0, total),
        }
    }

    /// Replace every match (optionally limited to `scope`) as ONE undo step.
    /// Matches are collected first, then applied back-to-front so earlier
    /// spans stay valid as later ones change length. Returns the count.
    ///
    /// Known limitation: this is quadratic in the number of matches — the
    /// per-edit overlay bookkeeping in `prepare_edit`/`get_logical` costs more
    /// as the overlay grows, so 10k matches take ~0.6s, 20k ~2.1s and 40k
    /// ~7.3s in release. The cause is pre-existing `EditSession` machinery
    /// shared with all editing, not the search itself, and fixing it is
    /// deliberately deferred. See the "Known limitations" section of
    /// docs/superpowers/specs/2026-08-05-find-replace-panel-design.md.
    pub fn replace_all_in_rows(
        &mut self,
        query: crate::api::search::SearchQuery,
        replacement: String,
        scope: Option<crate::api::search::SpanScope>,
        preserve_case: bool,
    ) -> anyhow::Result<usize> {
        self.revision = self.revision.wrapping_add(1);
        use crate::api::search::{SearchQuery, SEARCH_WINDOW_ROWS};

        // Collect first: the document must not change while scanning.
        let total = self.line_count();
        let (mut row, end) = Self::scope_row_bounds(&scope, total);
        let mut found = Vec::new();
        while row < end {
            let to = (row + SEARCH_WINDOW_ROWS).min(end);
            let q = SearchQuery {
                pattern: query.pattern.clone(),
                mode: query.mode.clone(),
                match_case: query.match_case,
                whole_word: query.whole_word,
                dot_matches_newline: query.dot_matches_newline,
            };
            found.extend(self.find_in_rows(q, row, to, scope.clone())?);
            row = to;
        }

        // Expand replacements before mutating, for the same reason.
        //
        // A zero-length match replaced by empty text (e.g. `x*` over text with
        // no 'x') writes nothing, so recording it would mark the document
        // dirty and push an undo step for a change that did not happen. Drop
        // those here rather than applying them as no-op primitives.
        let mut spans = Vec::with_capacity(found.len());
        let mut texts = Vec::with_capacity(found.len());
        for span in found {
            let text = self.expand_for_span(&query, &span, &replacement, preserve_case)?;
            let empty_span = (span.start_row, span.start_col) == (span.end_row, span.end_col);
            if empty_span && text.is_empty() {
                continue;
            }
            spans.push(span);
            texts.push(text);
        }
        if spans.is_empty() {
            return Ok(0);
        }

        let n = spans.len();
        self.begin_group();
        for i in (0..n).rev() {
            let span = &spans[i];
            self.delete(span.start_row, span.start_col, span.end_row, span.end_col);
            self.insert(span.start_row, span.start_col, texts[i].clone());
        }
        self.end_group();
        Ok(n)
    }

    /// Re-run the pattern against the matched text so capture groups are
    /// available, then expand `replacement` against them.
    fn expand_for_span(
        &self,
        query: &crate::api::search::SearchQuery,
        span: &crate::api::search::MatchSpan,
        replacement: &str,
        preserve_case: bool,
    ) -> anyhow::Result<String> {
        use crate::api::search::{compile, expand_replacement};

        let mut matched = String::new();
        for row in span.start_row..=span.end_row {
            let line = self.get_line_visual(row);
            let start = if row == span.start_row {
                u16_to_byte(&line, span.start_col)
            } else {
                0
            };
            let end = if row == span.end_row {
                u16_to_byte(&line, span.end_col)
            } else {
                line.len()
            };
            matched.push_str(&line[start..end]);
            if row < span.end_row {
                matched.push('\n');
            }
        }
        let re = compile(query)?;
        let caps = re
            .captures(&matched)
            .ok_or_else(|| anyhow::anyhow!("match text no longer matches the pattern"))?;
        let expanded = expand_replacement(&query.mode, &caps, replacement)?;
        Ok(if preserve_case {
            crate::api::search::apply_case_pattern(&matched, expanded)
        } else {
            expanded
        })
    }
}

// ---- Markup: colouring, folding, validation --------------------------------

impl EditSession {
    /// Every row of the document, as the lexers want them.
    fn markup_rows(&self) -> Vec<String> {
        (0..self.line_count()).map(|i| self.line(i)).collect()
    }

    /// The checkpoints for `language`, rebuilding them if the document changed
    /// or a different language was asked for.
    fn markup_checkpoints(&mut self, language: crate::markup::MarkupLanguage) -> &[crate::markup::LexState] {
        let stale = match &self.markup_cache {
            Some(cache) => cache.language != language || cache.revision != self.revision,
            None => true,
        };
        if stale {
            let rows = self.markup_rows();
            self.markup_cache = Some(MarkupCache {
                language,
                revision: self.revision,
                checkpoints: crate::markup::checkpoints_for(&rows, language),
                pairs: crate::markup::analyse_rows(&rows, language).pairs,
                window: None,
            });
        }
        self.markup_cache
            .as_ref()
            .map(|c| c.checkpoints.as_slice())
            .unwrap_or_default()
    }

    /// Syntax tokens for the rows in `[from_row, to_row)`.
    ///
    /// The state the rows start in comes from the nearest stored checkpoint,
    /// warmed forward by at most `CHECKPOINT_ROWS` rows — so scrolling to the
    /// middle of a large document costs the same as scrolling to the top of it.
    ///
    /// A request smaller than [`TOKEN_WINDOW_ROWS`] lexes a whole window
    /// around it and keeps the result, because that warm-up is charged per
    /// call: asking for one row at a time — which a `ListView.builder` does
    /// naturally — otherwise pays it once per row. Larger requests are served
    /// directly, since they already amortise it and are not worth the memory.
    #[flutter_rust_bridge::frb(sync)]
    pub fn markup_tokens(
        &mut self,
        language: crate::api::structured::StructuredLanguage,
        from_row: usize,
        to_row: usize,
    ) -> Vec<crate::api::structured::StructuredRowTokens> {
        let language: crate::markup::MarkupLanguage = language.into();
        let count = self.line_count();
        let from = from_row.min(count);
        let to = to_row.clamp(from, count);
        if from == to || !language.is_structured() {
            return Vec::new();
        }

        if to - from >= TOKEN_WINDOW_ROWS {
            return crate::api::structured::wire_row_tokens(self.lex_range(language, from, to));
        }

        // `markup_checkpoints` drops the window whenever the document or the
        // language changed, so a hit here is never stale.
        self.markup_checkpoints(language);
        let hit = self
            .markup_cache
            .as_ref()
            .and_then(|c| c.window.as_ref())
            .is_some_and(|w| from >= w.start && to <= w.start + w.rows.len());

        if !hit {
            // Align the window to a checkpoint so its own warm-up is free, and
            // start it a little before the request so scrolling up also hits.
            let back = crate::markup::token::CHECKPOINT_ROWS;
            let start = from.saturating_sub(back);
            let start = start - (start % crate::markup::token::CHECKPOINT_ROWS);
            let end = (start + TOKEN_WINDOW_ROWS).max(to).min(count);
            let rows = self.lex_range(language, start, end);
            if let Some(cache) = self.markup_cache.as_mut() {
                cache.window = Some(TokenWindow { start, rows });
            }
        }

        let Some(window) = self.markup_cache.as_ref().and_then(|c| c.window.as_ref()) else {
            return crate::api::structured::wire_row_tokens(self.lex_range(language, from, to));
        };
        crate::api::structured::wire_row_tokens(
            window.rows[from - window.start..to - window.start].to_vec(),
        )
    }

    /// Lex `[from, to)` from the nearest checkpoint, with no caching.
    fn lex_range(
        &mut self,
        language: crate::markup::MarkupLanguage,
        from: usize,
        to: usize,
    ) -> Vec<crate::markup::RowTokens> {
        let (resume_row, mut state) = {
            let checkpoints = self.markup_checkpoints(language);
            crate::markup::lexer::resume_point(checkpoints, from as u32)
        };

        let Some(lexer) = crate::markup::lexer_for(language) else {
            return Vec::new();
        };
        let mut scratch = crate::markup::lexer::RowLexemes::new();
        for row in resume_row as usize..from {
            scratch.clear();
            state = lexer.lex_row(&self.line(row), state, &mut scratch);
        }

        let rows: Vec<String> = (from..to).map(|i| self.line(i)).collect();
        crate::markup::tokens_for(&rows, language, state, from as u32)
    }

    /// The delimiter pair the caret is on or inside, if any.
    ///
    /// Reads from the cached analysis, so dragging the caret through a large
    /// document does not re-lex it on every keystroke.
    #[flutter_rust_bridge::frb(sync)]
    pub fn markup_pair_at(
        &mut self,
        language: crate::api::structured::StructuredLanguage,
        row: usize,
        col: usize,
    ) -> Option<crate::api::structured::StructuredPair> {
        let language: crate::markup::MarkupLanguage = language.into();
        if !language.is_structured() {
            return None;
        }
        self.markup_checkpoints(language);
        let pairs = self
            .markup_cache
            .as_ref()
            .map(|c| c.pairs.as_slice())
            .unwrap_or_default();
        crate::markup::pair_at(pairs, row as u32, col as u32)
            .map(crate::api::structured::wire_pair_public)
    }

    /// Fold regions, bracket pairs and diagnostics for the whole document.
    #[flutter_rust_bridge::frb(sync)]
    pub fn markup_analysis(
        &mut self,
        language: crate::api::structured::StructuredLanguage,
    ) -> crate::api::structured::StructuredAnalysis {
        let rows = self.markup_rows();
        crate::api::structured::wire_analysis(crate::markup::analyse_rows(&rows, language.into()))
    }

    /// The document's effective format.
    ///
    /// A user-pinned `language_override` wins outright; otherwise the format is
    /// detected, sniffing the opening rows when the extension and content type
    /// say nothing useful. The precedence lives here rather than at the call
    /// site so that everything asking "what is this document?" — colouring,
    /// folding, validation, the Tools menu, the status bar — gets one answer.
    #[flutter_rust_bridge::frb(sync)]
    pub fn detect_markup_language(
        &self,
        extension: String,
        content_type: String,
        language_override: Option<crate::api::structured::StructuredLanguage>,
    ) -> crate::api::structured::StructuredLanguage {
        if let Some(pinned) = language_override {
            return pinned;
        }
        // A few dozen rows is plenty to recognise a format, and bounds the cost
        // for a very large file.
        let sample: Vec<String> = (0..self.line_count().min(64))
            .map(|i| self.line(i))
            .collect();
        crate::api::structured::detect_structured_language(
            extension,
            content_type,
            sample.join("\n"),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    /// Write `content` to a unique temp file and open an EditSession over it.
    fn session(content: &str) -> (EditSession, String) {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir()
            .join(format!(
                "textutilz_es_test_{}_{}.txt",
                std::process::id(),
                n
            ))
            .to_string_lossy()
            .to_string();
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(content.as_bytes()).unwrap();
        f.flush().unwrap();
        (EditSession::open(path.clone()).unwrap(), path)
    }

    /// The full document as visual lines joined by '\n'.
    fn doc(s: &EditSession) -> String {
        (0..s.line_count())
            .map(|i| s.line(i))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// `n` rows of the form "row0\n", "row1\n", ... "row{n-1}\n".
    fn n_row_document(n: usize) -> String {
        let mut content = String::new();
        for i in 0..n {
            content.push_str(&format!("row{}\n", i));
        }
        content
    }

    #[test]
    fn reads_base_lines() {
        let (s, _p) = session("alpha\nbeta\ngamma");
        assert_eq!(s.line_count(), 3);
        assert_eq!(s.line(0), "alpha");
        assert_eq!(s.line(2), "gamma");
    }

    #[test]
    fn detects_external_file_change_until_refresh() {
        let (mut s, path) = session("alpha\nbeta");
        assert!(!s.has_external_changes());

        std::fs::write(&path, "replacement\nwith\nmore\nrows").unwrap();
        assert!(s.has_external_changes());

        s.refresh().unwrap();
        assert!(!s.has_external_changes());
        assert_eq!(doc(&s), "replacement\nwith\nmore\nrows");
    }

    #[cfg(unix)]
    #[test]
    fn atomic_external_rewrite_keeps_indexed_version_coherent_until_refresh() {
        let (mut s, path) = session("old first\nold second");
        let replacement = format!("{}.replacement", path);
        std::fs::write(&replacement, "new\ncontent\nwith\nmore rows").unwrap();
        std::fs::rename(&replacement, &path).unwrap();

        assert!(s.has_external_changes());
        assert_eq!(
            doc(&s),
            "old first\nold second",
            "stale offsets must keep reading the exact file they indexed"
        );

        s.refresh().unwrap();
        assert_eq!(doc(&s), "new\ncontent\nwith\nmore rows");
    }

    #[test]
    fn in_session_edits_are_not_external_changes() {
        let (mut s, _path) = session("alpha");
        s.insert(0, 5, " beta".to_string());
        assert!(s.is_dirty());
        assert!(!s.has_external_changes());
    }

    #[test]
    fn insert_within_line() {
        let (mut s, _p) = session("hello\nworld");
        let c = s.insert(0, 5, "!".to_string());
        assert_eq!((c.row, c.col), (0, 6));
        assert_eq!(s.line(0), "hello!");
        assert_eq!(s.line_count(), 2);
    }

    #[test]
    fn insert_newline_splits() {
        let (mut s, _p) = session("abcd");
        let c = s.insert(0, 2, "\n".to_string());
        assert_eq!((c.row, c.col), (1, 0));
        assert_eq!(s.line_count(), 2);
        assert_eq!(s.line(0), "ab");
        assert_eq!(s.line(1), "cd");
    }

    #[test]
    fn insert_multiline_paste() {
        let (mut s, _p) = session("XY");
        let c = s.insert(0, 1, "1\n2\n3".to_string());
        assert_eq!((c.row, c.col), (2, 1));
        assert_eq!(doc(&s), "X1\n2\n3Y");
        assert_eq!(s.line_count(), 3);
    }

    #[test]
    fn delete_within_line() {
        let (mut s, _p) = session("hello");
        s.delete(0, 1, 0, 3);
        assert_eq!(s.line(0), "hlo");
    }

    #[test]
    fn delete_across_lines_joins() {
        let (mut s, _p) = session("abc\ndef\nghi");
        // Delete from (0,1) to (2,1): "bc\nde f\ng" removed, join.
        s.delete(0, 1, 2, 1);
        assert_eq!(s.line_count(), 1);
        assert_eq!(s.line(0), "ahi");
    }

    #[test]
    fn delete_normalizes_reversed_range() {
        let (mut s, _p) = session("hello");
        s.delete(0, 3, 0, 1); // reversed
        assert_eq!(s.line(0), "hlo");
    }

    #[test]
    fn undo_redo_insert() {
        let (mut s, _p) = session("cat");
        s.insert(0, 3, "s".to_string());
        assert_eq!(s.line(0), "cats");
        let c = s.undo().unwrap();
        assert_eq!(s.line(0), "cat");
        assert_eq!((c.row, c.col), (0, 3));
        let c = s.redo().unwrap();
        assert_eq!(s.line(0), "cats");
        assert_eq!((c.row, c.col), (0, 4));
    }

    #[test]
    fn undo_delete_restores_bytes() {
        let (mut s, _p) = session("abc\ndef\nghi");
        s.delete(0, 1, 2, 1);
        assert_eq!(doc(&s), "ahi");
        s.undo().unwrap();
        assert_eq!(doc(&s), "abc\ndef\nghi");
    }

    #[test]
    fn typing_coalesces_into_one_undo() {
        let (mut s, _p) = session("");
        // Type "abc" one char at a time, contiguous.
        let mut caret = CaretPos::new(0, 0);
        for ch in ["a", "b", "c"] {
            caret = s.insert(caret.row, caret.col, ch.to_string());
        }
        assert_eq!(s.line(0), "abc");
        assert!(s.can_undo());
        s.undo().unwrap();
        // One undo removes the whole coalesced run.
        assert_eq!(s.line(0), "");
        assert!(!s.can_undo());
    }

    #[test]
    fn break_coalescing_splits_undo_steps() {
        let (mut s, _p) = session("");
        let c = s.insert(0, 0, "a".to_string());
        s.break_coalescing();
        s.insert(c.row, c.col, "b".to_string());
        assert_eq!(s.line(0), "ab");
        s.undo().unwrap();
        assert_eq!(s.line(0), "a"); // only the second char undone
        s.undo().unwrap();
        assert_eq!(s.line(0), "");
    }

    #[test]
    fn group_is_atomic_undo() {
        let (mut s, _p) = session("one\ntwo");
        s.begin_group();
        s.delete(0, 0, 0, 3); // clear "one"
        s.insert(0, 0, "ONE".to_string());
        s.end_group();
        assert_eq!(s.line(0), "ONE");
        s.undo().unwrap();
        assert_eq!(s.line(0), "one"); // both ops undone together
    }

    #[test]
    fn new_edit_clears_redo() {
        let (mut s, _p) = session("x");
        s.insert(0, 1, "y".to_string());
        s.undo().unwrap();
        assert!(s.can_redo());
        s.insert(0, 1, "z".to_string());
        assert!(!s.can_redo());
        assert_eq!(s.line(0), "xz");
    }

    #[test]
    fn undo_to_checkpoint_clears_dirty() {
        let (mut s, _p) = session("hello");
        assert!(!s.is_dirty());
        s.insert(0, 5, "!".to_string());
        assert!(s.is_dirty());
        s.undo().unwrap();
        assert!(!s.is_dirty()); // back at the loaded checkpoint
        s.redo().unwrap();
        assert!(s.is_dirty());
    }

    #[test]
    fn save_persists_and_resets() {
        let (mut s, path) = session("hello\nworld");
        s.insert(0, 5, "!".to_string());
        assert!(s.is_dirty());
        s.save().unwrap();
        assert!(!s.is_dirty());
        assert!(!s.can_undo());
        let on_disk = std::fs::read_to_string(&path).unwrap();
        // The original had no trailing newline; save preserves that.
        assert_eq!(on_disk, "hello!\nworld");
        // Reopened view reflects saved content.
        assert_eq!(s.line(0), "hello!");
    }

    #[test]
    fn keep_blank_lines_composition() {
        // The "Ctrl+Delete keeps blank lines" behavior is composed in Dart from
        // primitives; verify that composition on the model. Selection (0,2)-(2,3)
        // over "hello/world/foobar" clears the span but leaves the lines in place.
        let (mut s, _p) = session("hello\nworld\nfoobar");
        let tail2 = s.line(2)[3..].to_string(); // "bar"
        s.begin_group();
        s.delete(0, 2, 0, 5);
        s.delete(1, 0, 1, 5);
        s.delete(2, 0, 2, 6);
        s.insert(0, 2, tail2);
        s.end_group();
        assert_eq!(s.line_count(), 3); // no gap closed
        assert_eq!(doc(&s), "hebar\n\n");
        // One undo reverts the whole group.
        s.undo().unwrap();
        assert_eq!(doc(&s), "hello\nworld\nfoobar");
    }

    #[test]
    fn edit_on_empty_file() {
        let (mut s, _p) = session("");
        assert_eq!(s.line_count(), 1);
        s.insert(0, 0, "first".to_string());
        assert_eq!(s.line(0), "first");
    }

    #[test]
    fn content_string_reflects_edits() {
        let (mut s, _p) = session("hello\nworld");
        assert_eq!(s.content_string(), "hello\nworld");
        s.insert(0, 5, "!".to_string());
        s.insert(1, 5, "\nmore".to_string());
        assert_eq!(s.content_string(), "hello!\nworld\nmore");
    }

    #[test]
    fn content_string_empty_file() {
        let (s, _p) = session("");
        assert_eq!(s.content_string(), "");
    }

    #[test]
    fn create_scratch_writes_and_opens() {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir()
            .join(format!(
                "textutilz_scratch_{}_{}.txt",
                std::process::id(),
                n
            ))
            .to_string_lossy()
            .to_string();
        let s = EditSession::create_scratch(path.clone(), "line1\nline2".to_string()).unwrap();
        assert_eq!(s.line_count(), 2);
        assert_eq!(s.line(1), "line2");
        // Round-trips through content_string.
        assert_eq!(s.content_string(), "line1\nline2");
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert_eq!(on_disk, "line1\nline2");
    }

    #[test]
    fn replace_all_swaps_content_and_undoes_in_one_step() {
        let (mut s, _p) = session("one\ntwo\nthree");
        let c = s.replace_all("A\nB".to_string());
        assert_eq!(doc(&s), "A\nB");
        assert_eq!((c.row, c.col), (1, 1));
        // A single undo restores the whole original document.
        s.undo();
        assert_eq!(doc(&s), "one\ntwo\nthree");
    }

    #[test]
    fn replace_all_on_empty_document() {
        let (mut s, _p) = session("");
        s.replace_all("hello world".to_string());
        assert_eq!(doc(&s), "hello world");
    }

    use crate::api::search::{SearchMode, SearchQuery, SEARCH_WINDOW_OVERLAP_ROWS};

    fn query(pattern: &str) -> SearchQuery {
        SearchQuery {
            pattern: pattern.to_string(),
            mode: SearchMode::Normal,
            match_case: true,
            whole_word: false,
            dot_matches_newline: false,
        }
    }

    fn regex_query(pattern: &str, dot_nl: bool) -> SearchQuery {
        SearchQuery {
            pattern: pattern.to_string(),
            mode: SearchMode::Regex,
            match_case: true,
            whole_word: false,
            dot_matches_newline: dot_nl,
        }
    }

    #[test]
    fn find_matches_at_document_start() {
        let (s, _p) = session("needle here\nother\n");
        let m = s.find_in_rows(query("needle"), 0, 10, None).unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!((m[0].start_row, m[0].start_col), (0, 0));
        assert_eq!((m[0].end_row, m[0].end_col), (0, 6));
    }

    #[test]
    fn find_matches_at_document_end() {
        let (s, _p) = session("alpha\nbeta needle");
        let m = s.find_in_rows(query("needle"), 0, 10, None).unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!((m[0].start_row, m[0].start_col), (1, 5));
        assert_eq!((m[0].end_row, m[0].end_col), (1, 11));
    }

    #[test]
    fn find_returns_matches_in_order() {
        let (s, _p) = session("x\nax\nbx\n");
        let m = s.find_in_rows(query("x"), 0, 10, None).unwrap();
        assert_eq!(m.len(), 3);
        assert_eq!(m[0].start_row, 0);
        assert_eq!(m[1].start_row, 1);
        assert_eq!(m[2].start_row, 2);
    }

    #[test]
    fn find_uses_utf16_columns() {
        // "😀" is 2 UTF-16 code units, so the match starts at column 2.
        let (s, _p) = session("😀needle\n");
        let m = s.find_in_rows(query("needle"), 0, 10, None).unwrap();
        assert_eq!(m[0].start_col, 2);
    }

    #[test]
    fn find_matches_multiline_pattern_inside_window() {
        let (s, _p) = session("alpha\nbeta\ngamma\n");
        let m = s
            .find_in_rows(regex_query("alpha.beta", true), 0, 10, None)
            .unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!((m[0].start_row, m[0].start_col), (0, 0));
        assert_eq!((m[0].end_row, m[0].end_col), (1, 4));
    }

    #[test]
    fn find_matches_multiline_pattern_straddling_window_boundary() {
        // Enough rows that `to_row + SEARCH_WINDOW_OVERLAP_ROWS` (10 + 64 =
        // 74) does NOT clamp to the document end -- otherwise the whole
        // document gets scanned regardless of the overlap constant's value,
        // and the test would pass vacuously. A match starting at row 9 (just
        // before `to_row`) and ending at row 73 -- the very LAST row the
        // scan reaches with the real overlap of 64 -- is only found because
        // the overlap is exactly that big: shrink it by even one row and
        // the scan no longer reaches row 73, and this match is lost.
        // Hardcoded to 73, NOT derived from SEARCH_WINDOW_OVERLAP_ROWS: the
        // point is to pin the test to the constant's current value (64) so
        // that shrinking the constant breaks this test instead of silently
        // moving the goalposts with it.
        assert_eq!(
            SEARCH_WINDOW_OVERLAP_ROWS, 64,
            "test rows below assume this"
        );
        let content = n_row_document(100);
        let (s, _p) = session(&content);
        let m = s
            .find_in_rows(regex_query("row9.*row73", true), 0, 10, None)
            .unwrap();
        assert_eq!(m.len(), 1, "overlap should catch the straddling match");
        assert_eq!((m[0].start_row, m[0].start_col), (9, 0));
        assert_eq!((m[0].end_row, m[0].end_col), (73, 5));
    }

    #[test]
    fn find_does_not_reach_past_the_overlap_window() {
        // A match starting at row 9 (still inside [from_row, to_row)) but
        // requiring text one row past what the overlap covers (row 74, since
        // the scan only reaches row 73 -- see the test above) must NOT be
        // found: it belongs to no window's scan text at all. This is the
        // documented limitation ("a match taller than this is not found")
        // and it bounds the overlap from above: growing the constant would
        // make this match appear.
        // Hardcoded to 74 (one past the 73 in the test above) for the same
        // reason: pinned to the constant's current value of 64, not derived
        // from it, so growing the constant would break this test.
        assert_eq!(
            SEARCH_WINDOW_OVERLAP_ROWS, 64,
            "test rows below assume this"
        );
        let content = n_row_document(100);
        let (s, _p) = session(&content);
        let m = s
            .find_in_rows(regex_query("row9.*row74", true), 0, 10, None)
            .unwrap();
        assert!(
            m.is_empty(),
            "a match reaching past the overlap window must not be found"
        );
    }

    #[test]
    fn find_excludes_matches_starting_at_or_after_to_row() {
        // Consecutive windows must tile exactly, with no duplicates.
        let (s, _p) = session("hit\nhit\nhit\nhit\n");
        let first = s.find_in_rows(query("hit"), 0, 2, None).unwrap();
        let second = s.find_in_rows(query("hit"), 2, 4, None).unwrap();
        assert_eq!(first.len(), 2);
        assert_eq!(second.len(), 2);
        assert_eq!(first[0].start_row, 0);
        assert_eq!(second[0].start_row, 2);
    }

    #[test]
    fn find_clamps_range_beyond_document() {
        let (s, _p) = session("only\n");
        let m = s.find_in_rows(query("only"), 0, 100_000, None).unwrap();
        assert_eq!(m.len(), 1);
        let none = s.find_in_rows(query("only"), 50, 100, None).unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn find_with_inverted_range_returns_empty() {
        let (s, _p) = session("hit\n");
        assert!(s.find_in_rows(query("hit"), 5, 2, None).unwrap().is_empty());
    }

    #[test]
    fn find_terminates_on_zero_length_match() {
        let (s, _p) = session("ab\n");
        // `x*` matches empty at every position; must advance, not loop.
        // The document is two rows ("ab" and the trailing empty row), scanned
        // as the joined text "ab\n" (3 bytes). A zero-length match occurs at
        // every byte offset 0..=3: before 'a', before 'b', before '\n' (still
        // row 0, since '\n' is the row separator, not row 1's content), and
        // at the start of the empty row 1.
        let m = s
            .find_in_rows(regex_query("x*", false), 0, 10, None)
            .unwrap();
        let spans: Vec<(usize, usize, usize, usize)> = m
            .iter()
            .map(|sp| (sp.start_row, sp.start_col, sp.end_row, sp.end_col))
            .collect();
        assert_eq!(
            spans,
            vec![(0, 0, 0, 0), (0, 1, 0, 1), (0, 2, 0, 2), (1, 0, 1, 0)],
            "zero-length matches must advance one position at a time and stop at document end"
        );
    }

    #[test]
    fn find_reports_error_for_invalid_regex() {
        let (s, _p) = session("anything\n");
        assert!(s
            .find_in_rows(regex_query("a(", false), 0, 10, None)
            .is_err());
    }

    use crate::api::search::{MatchSpan, SpanScope};

    #[test]
    fn count_matches_counts_whole_document() {
        let (s, _p) = session("hit\nmiss\nhit\nhit\n");
        assert_eq!(s.count_matches(query("hit"), None).unwrap(), 3);
    }

    #[test]
    fn count_matches_returns_zero_when_absent() {
        let (s, _p) = session("alpha\nbeta\n");
        assert_eq!(s.count_matches(query("gamma"), None).unwrap(), 0);
    }

    #[test]
    fn count_matches_spans_many_windows() {
        // More rows than one window, so the sweep must page.
        let mut content = String::new();
        for _ in 0..(crate::api::search::SEARCH_WINDOW_ROWS + 500) {
            content.push_str("hit\n");
        }
        let (s, _p) = session(&content);
        let expected = crate::api::search::SEARCH_WINDOW_ROWS + 500;
        assert_eq!(s.count_matches(query("hit"), None).unwrap(), expected);
    }

    #[test]
    fn count_matches_respects_scope() {
        let (s, _p) = session("hit\nhit\nhit\nhit\n");
        let scope = SpanScope {
            start_row: 1,
            start_col: 0,
            end_row: 3,
            end_col: 0,
        };
        assert_eq!(s.count_matches(query("hit"), Some(scope)).unwrap(), 2);
    }

    #[test]
    fn count_matches_scope_respects_columns() {
        // Scope starts mid-row 0, so row 0's match at col 0 is excluded.
        let (s, _p) = session("hit hit\n");
        let scope = SpanScope {
            start_row: 0,
            start_col: 4,
            end_row: 0,
            end_col: 7,
        };
        assert_eq!(s.count_matches(query("hit"), Some(scope)).unwrap(), 1);
    }

    #[test]
    fn count_matches_excludes_match_crossing_scope_end() {
        let (s, _p) = session("hit\n");
        let scope = SpanScope {
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 2,
        };
        assert_eq!(s.count_matches(query("hit"), Some(scope)).unwrap(), 0);
    }

    #[test]
    fn replace_all_scope_includes_later_row_with_smaller_column() {
        // scope starts at (1, 4). A match at (2, 0) has a numerically smaller
        // column than scope.start_col, but row 2 > row 1, so lexicographic
        // ordering (row, col) still includes it. A field-wise AND comparison
        // would wrongly exclude it.
        let (s, _p) = session("hit\nxxxx hit\nhit\n");
        let scope = SpanScope {
            start_row: 1,
            start_col: 4,
            end_row: 3,
            end_col: 0,
        };
        // Matches: row0 col0 (excluded, before scope start), row1 col9
        // (included), row2 col0 (included: (2,0) >= (1,4) lexicographically).
        assert_eq!(s.count_matches(query("hit"), Some(scope)).unwrap(), 2);
    }

    #[test]
    fn replace_span_replaces_one_match() {
        let (mut s, _p) = session("hit hit\n");
        let spans = s.find_in_rows(query("hit"), 0, 10, None).unwrap();
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        s.replace_span(query("hit"), first, "X".to_string(), false)
            .unwrap();
        // Trailing "\n" in the fixture makes the file end with a phantom
        // empty line, same as every other doc() assertion in this file.
        assert_eq!(doc(&s), "X hit\n");
    }

    #[test]
    fn replace_span_undoes_as_one_step() {
        let (mut s, _p) = session("hit hit\n");
        let spans = s.find_in_rows(query("hit"), 0, 10, None).unwrap();
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        s.replace_span(query("hit"), first, "LONGER".to_string(), false)
            .unwrap();
        s.undo();
        assert_eq!(doc(&s), "hit hit\n");
    }

    #[test]
    fn replace_span_expands_captures_in_regex_mode() {
        let (mut s, _p) = session("user@host\n");
        let q = regex_query(r"(\w+)@(\w+)", false);
        let spans = s
            .find_in_rows(regex_query(r"(\w+)@(\w+)", false), 0, 10, None)
            .unwrap();
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        s.replace_span(q, first, "$2:$1".to_string(), false)
            .unwrap();
        assert_eq!(doc(&s), "host:user\n");
    }

    #[test]
    fn replace_all_replaces_every_match() {
        let (mut s, _p) = session("hit\nmiss\nhit\n");
        let n = s
            .replace_all_in_rows(query("hit"), "X".to_string(), None, false)
            .unwrap();
        assert_eq!(n, 2);
        assert_eq!(doc(&s), "X\nmiss\nX\n");
    }

    #[test]
    fn replace_all_handles_longer_replacement() {
        // A backwards pass keeps earlier spans valid as later ones grow.
        let (mut s, _p) = session("a a a\n");
        s.replace_all_in_rows(query("a"), "LONG".to_string(), None, false)
            .unwrap();
        assert_eq!(doc(&s), "LONG LONG LONG\n");
    }

    #[test]
    fn replace_all_handles_shorter_replacement() {
        let (mut s, _p) = session("aaa aaa\n");
        s.replace_all_in_rows(query("aaa"), "b".to_string(), None, false)
            .unwrap();
        assert_eq!(doc(&s), "b b\n");
    }

    #[test]
    fn replace_all_undoes_and_redoes_as_one_step() {
        let (mut s, _p) = session("hit\nhit\nhit\n");
        s.replace_all_in_rows(query("hit"), "X".to_string(), None, false)
            .unwrap();
        assert_eq!(doc(&s), "X\nX\nX\n");
        s.undo();
        assert_eq!(doc(&s), "hit\nhit\nhit\n", "one undo must revert all");
        s.redo();
        assert_eq!(doc(&s), "X\nX\nX\n", "one redo must reapply all");
    }

    #[test]
    fn replace_all_preserves_case_per_match() {
        // One document, three casings, one replacement string. Each match
        // should come back wearing the case it had.
        let (mut s, _p) = session("traefik TRAEFIK Traefik traefikProxy\n");
        let mut q = query("traefik");
        q.match_case = false;
        let n = s
            .replace_all_in_rows(q, "nginx".to_string(), None, true)
            .unwrap();
        assert_eq!(n, 4);
        // The mixed-case "traefikProxy" keeps the typed replacement verbatim,
        // leaving the "Proxy" suffix untouched.
        assert_eq!(doc(&s), "nginx NGINX Nginx nginxProxy\n");
    }

    #[test]
    fn replace_all_without_preserve_case_writes_verbatim() {
        let (mut s, _p) = session("traefik TRAEFIK Traefik\n");
        let mut q = query("traefik");
        q.match_case = false;
        s.replace_all_in_rows(q, "nginx".to_string(), None, false)
            .unwrap();
        assert_eq!(doc(&s), "nginx nginx nginx\n");
    }

    #[test]
    fn replace_span_preserves_case_for_one_match() {
        let (mut s, _p) = session("TRAEFIK here\n");
        let mut q = query("traefik");
        q.match_case = false;
        let spans = {
            let mut q2 = query("traefik");
            q2.match_case = false;
            s.find_in_rows(q2, 0, 10, None).unwrap()
        };
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        s.replace_span(q, first, "nginx".to_string(), true).unwrap();
        assert_eq!(doc(&s), "NGINX here\n");
    }

    #[test]
    fn replace_all_respects_scope() {
        let (mut s, _p) = session("hit\nhit\nhit\n");
        let scope = SpanScope {
            start_row: 1,
            start_col: 0,
            end_row: 2,
            end_col: 3,
        };
        let n = s
            .replace_all_in_rows(query("hit"), "X".to_string(), Some(scope), false)
            .unwrap();
        assert_eq!(n, 2);
        assert_eq!(doc(&s), "hit\nX\nX\n");
    }

    #[test]
    fn replace_all_with_no_match_makes_no_undo_entry() {
        let (mut s, _p) = session("alpha\n");
        let n = s
            .replace_all_in_rows(query("zzz"), "X".to_string(), None, false)
            .unwrap();
        assert_eq!(n, 0);
        assert!(!s.can_undo(), "a no-op replace must not push an undo step");
    }

    #[test]
    fn replace_all_terminates_on_zero_length_match() {
        let (mut s, _p) = session("ab\n");
        let n = s
            .replace_all_in_rows(regex_query("x*", false), "".to_string(), None, false)
            .unwrap();
        // `x*` matches empty at every position and the replacement is empty,
        // so nothing is written. Reporting a count, or recording no-op
        // primitives, would mark the document dirty for a change that never
        // happened.
        assert_eq!(n, 0, "empty-for-empty replacements are not replacements");
        assert_eq!(doc(&s), "ab\n", "the document must be byte-identical");
        assert!(
            !s.can_undo(),
            "a replace that wrote nothing must not push an undo step"
        );
    }

    #[test]
    fn replace_all_still_replaces_a_zero_length_match_with_real_text() {
        // The zero-length skip must be conditional on the *replacement* being
        // empty too: inserting text at every position is a real edit.
        let (mut s, _p) = session("ab\n");
        let n = s
            .replace_all_in_rows(regex_query("x*", false), "-".to_string(), None, false)
            .unwrap();
        assert_eq!(n, 4);
        assert_eq!(doc(&s), "-a-b-\n-");
        assert!(s.can_undo());
    }

    // ---- scope-filtered find_in_rows ---------------------------------------

    #[test]
    fn find_in_rows_filters_by_scope() {
        let (s, _p) = session("hit\nhit\nhit\n");
        let scope = SpanScope {
            start_row: 1,
            start_col: 0,
            end_row: 2,
            end_col: 3,
        };
        let m = s.find_in_rows(query("hit"), 0, 10, Some(scope)).unwrap();
        assert_eq!(m.len(), 2, "the row-0 match is outside the scope");
        assert_eq!(m[0].start_row, 1);
        assert_eq!(m[1].start_row, 2);
    }

    #[test]
    fn find_in_rows_scope_respects_columns() {
        // Only the second "hit" on row 0 starts at or after column 4.
        let (s, _p) = session("hit hit\n");
        let scope = SpanScope {
            start_row: 0,
            start_col: 4,
            end_row: 0,
            end_col: 7,
        };
        let m = s.find_in_rows(query("hit"), 0, 10, Some(scope)).unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].start_col, 4);
    }

    #[test]
    fn find_in_rows_excludes_match_crossing_scope_end() {
        // The match starts inside the scope but ends past its end column.
        let (s, _p) = session("hit\n");
        let scope = SpanScope {
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 2,
        };
        let m = s.find_in_rows(query("hit"), 0, 10, Some(scope)).unwrap();
        assert!(m.is_empty());
    }

    #[test]
    fn scope_row_bounds_clamps_the_scan_range_to_the_scope() {
        // The clamping itself. `find_in_rows`, `count_matches` and
        // `replace_all_in_rows` all narrow their scan range through this, so
        // paging towards a selection far down a large document does no
        // per-window work before reaching it. It is pinned here, at the one
        // place the arithmetic lives, because an output assertion mostly
        // cannot tell a clamped scan from an unclamped one.
        //
        // Do not read that as "clamping changes no output" — see the
        // note on `scope_row_bounds`. For a greedy dot-all pattern the clamp
        // can *add* a match, because how much was scanned decides how far a
        // match extends. The behaviour is fine, and arguably better, since the
        // clamp can only add and never drop; the reason it is untestable here
        // is the arithmetic, not an equivalence that does not hold.
        let scope = SpanScope {
            start_row: 100,
            start_col: 3,
            end_row: 101,
            end_col: 6,
        };
        // end_row is inclusive, so the exclusive upper bound is end_row + 1.
        assert_eq!(
            EditSession::scope_row_bounds(&Some(scope.clone()), 200),
            (100, 102)
        );
        // Both ends clamp to the document.
        assert_eq!(
            EditSession::scope_row_bounds(&Some(scope), 50),
            (50, 50),
            "a scope past the document end must yield an empty range"
        );
        // Without a scope the whole document is in range.
        assert_eq!(EditSession::scope_row_bounds(&None, 200), (0, 200));
    }

    #[test]
    fn find_in_rows_returns_nothing_for_windows_outside_the_scope() {
        // `n_row_document` puts "rowN" on row N.
        let content = n_row_document(200);
        let (s, _p) = session(&content);
        let scope = SpanScope {
            start_row: 100,
            start_col: 0,
            end_row: 101,
            end_col: 6,
        };
        // Window [0, 50): entirely before the scope.
        let before = s
            .find_in_rows(regex_query("row1..", false), 0, 50, Some(scope.clone()))
            .unwrap();
        assert!(before.is_empty(), "a window before the scope must be empty");
        // Window [150, 200): entirely after the scope.
        let after = s
            .find_in_rows(regex_query("row1..", false), 150, 200, Some(scope.clone()))
            .unwrap();
        assert!(after.is_empty(), "a window after the scope must be empty");
        // A window spanning the whole document yields only the scoped rows.
        let all = s
            .find_in_rows(regex_query("row1..", false), 0, 200, Some(scope))
            .unwrap();
        let rows: Vec<usize> = all.iter().map(|m| m.start_row).collect();
        assert_eq!(rows, vec![100, 101]);
    }

    // ---- multi-row expand_for_span -----------------------------------------

    #[test]
    fn replace_span_expands_captures_across_two_rows() {
        // `expand_for_span` has to reassemble the matched text from two rows
        // (re-inserting the '\n') before the pattern can be re-run against it
        // for its capture groups.
        let (mut s, _p) = session("alpha\nbeta\ngamma\n");
        let q = regex_query(r"(\w+)\n(\w+)", true);
        let spans = s
            .find_in_rows(regex_query(r"(\w+)\n(\w+)", true), 0, 10, None)
            .unwrap();
        assert_eq!(spans.len(), 1, "one two-row match");
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        assert_eq!((first.start_row, first.end_row), (0, 1));
        s.replace_span(q, first, "$2-$1".to_string(), false)
            .unwrap();
        assert_eq!(doc(&s), "beta-alpha\ngamma\n");
    }

    #[test]
    fn replace_span_expands_captures_across_two_rows_with_multibyte_chars() {
        // Emoji on BOTH boundary rows: the start column is a UTF-16 column
        // into a row whose leading char is 2 code units / 4 bytes, and the end
        // column likewise -- so `u16_to_byte` must be right on both ends or
        // the reassembled text won't re-match the pattern.
        let (mut s, _p) = session("😀alpha\nbeta😀\ntail\n");
        let q = regex_query(r"(\w+)\n(\w+)", true);
        let spans = s
            .find_in_rows(regex_query(r"(\w+)\n(\w+)", true), 0, 10, None)
            .unwrap();
        assert_eq!(spans.len(), 1);
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        // "😀" is 2 UTF-16 units, so "alpha" starts at column 2 on row 0 and
        // "beta" ends at column 4 on row 1 (before that row's trailing emoji).
        assert_eq!((first.start_row, first.start_col), (0, 2));
        assert_eq!((first.end_row, first.end_col), (1, 4));
        s.replace_span(q, first, "$2-$1".to_string(), false)
            .unwrap();
        assert_eq!(doc(&s), "😀beta-alpha😀\ntail\n");
    }

    // ---- Markup ------------------------------------------------------------

    use crate::api::structured::{StructuredLanguage, StructuredTokenKind};

    fn json_doc(pairs: usize) -> String {
        let body = (0..pairs)
            .map(|i| format!("  \"k{i}\": {i},"))
            .collect::<Vec<_>>()
            .join("\n");
        format!("{{\n{body}\n  \"last\": 0\n}}")
    }

    /// The whole point of the checkpoint cache: tokens for a window deep in the
    /// document must equal what a full pass would produce there.
    #[test]
    fn markup_tokens_for_a_deep_window_match_a_full_pass() {
        let (mut s, _p) = session(&json_doc(600));
        let deep = s.markup_tokens(StructuredLanguage::Json, 500, 510);
        let all = s.markup_tokens(StructuredLanguage::Json, 0, s.line_count());
        assert_eq!(deep.len(), 10);
        for (i, row) in deep.iter().enumerate() {
            let full = &all[500 + i];
            assert_eq!(row.row, full.row);
            let kinds: Vec<_> = row.tokens.iter().map(|t| t.kind).collect();
            let expected: Vec<_> = full.tokens.iter().map(|t| t.kind).collect();
            assert_eq!(kinds, expected, "row {}", row.row);
        }
        // And keys are still keys that far down, which only the carried
        // container stack can establish.
        assert!(deep[0]
            .tokens
            .iter()
            .any(|t| t.kind == StructuredTokenKind::Key));
    }

    /// What Replace All costs as the match count grows.
    ///
    /// Ignored by default: it measures rather than asserts, and the numbers
    /// mean nothing in a debug build. Run it with
    /// `cargo test --release -- --ignored --nocapture replace_all_timing`.
    #[test]
    #[ignore]
    fn replace_all_timing() {
        for rows in [5_000usize, 10_000, 20_000, 40_000, 100_000, 200_000] {
            let doc: String = (0..rows)
                .map(|i| format!("line {i} needle here\n"))
                .collect();
            let (mut s, _p) = session(&doc);
            let query = crate::api::search::SearchQuery {
                pattern: "needle".to_string(),
                mode: crate::api::search::SearchMode::Normal,
                match_case: true,
                whole_word: false,
                dot_matches_newline: false,
            };
            let start = std::time::Instant::now();
            let n = s.replace_all_in_rows(query, "pin".to_string(), None, false).unwrap();
            println!(
                "{n:>7} matches  {:>9.2} ms",
                start.elapsed().as_secs_f64() * 1000.0
            );
        }
    }

    #[test]
    fn one_row_at_a_time_agrees_with_a_full_pass() {
        // The window cache serves these; a row taken from it must be identical
        // to the same row lexed in one sweep, including across the window's
        // own boundaries.
        let (mut s, _p) = session(&json_doc(600));
        let all = s.markup_tokens(StructuredLanguage::Json, 0, s.line_count());
        for row in 0..s.line_count() {
            let one = s.markup_tokens(StructuredLanguage::Json, row, row + 1);
            assert_eq!(one.len(), 1, "row {row}");
            let kinds: Vec<_> = one[0].tokens.iter().map(|t| t.kind).collect();
            let expected: Vec<_> = all[row].tokens.iter().map(|t| t.kind).collect();
            assert_eq!(kinds, expected, "row {row}");
        }
    }

    #[test]
    fn scrolling_backwards_through_a_document_stays_correct() {
        // Windows are extended backwards from the request, so descending row
        // order exercises a different boundary than ascending does.
        let (mut s, _p) = session(&json_doc(600));
        let all = s.markup_tokens(StructuredLanguage::Json, 0, s.line_count());
        for row in (0..s.line_count()).rev() {
            let one = s.markup_tokens(StructuredLanguage::Json, row, row + 1);
            let kinds: Vec<_> = one[0].tokens.iter().map(|t| t.kind).collect();
            let expected: Vec<_> = all[row].tokens.iter().map(|t| t.kind).collect();
            assert_eq!(kinds, expected, "row {row}");
        }
    }

    #[test]
    fn a_cached_window_does_not_outlive_a_language_change() {
        let (mut s, _p) = session(&json_doc(600));
        let as_json = s.markup_tokens(StructuredLanguage::Json, 300, 301);
        let as_xml = s.markup_tokens(StructuredLanguage::Xml, 300, 301);
        let back = s.markup_tokens(StructuredLanguage::Json, 300, 301);
        assert_ne!(
            as_json[0].tokens.iter().map(|t| t.kind).collect::<Vec<_>>(),
            as_xml[0].tokens.iter().map(|t| t.kind).collect::<Vec<_>>(),
            "the XML lexer should not return the JSON window"
        );
        assert_eq!(
            back[0].tokens.iter().map(|t| t.kind).collect::<Vec<_>>(),
            as_json[0].tokens.iter().map(|t| t.kind).collect::<Vec<_>>(),
        );
    }

    #[test]
    fn markup_tokens_reflect_an_edit_rather_than_a_stale_cache() {
        let (mut s, _p) = session("{\n  \"a\": 1\n}");
        let before = s.markup_tokens(StructuredLanguage::Json, 1, 2);
        assert!(before[0]
            .tokens
            .iter()
            .any(|t| t.kind == StructuredTokenKind::Key));
        // Open a string on row 0 so row 1 is now inside it.
        s.insert(0, 1, "\"".to_string());
        let after = s.markup_tokens(StructuredLanguage::Json, 1, 2);
        assert!(
            after[0]
                .tokens
                .iter()
                .all(|t| t.kind != StructuredTokenKind::Key),
            "row 1 is inside a string now, so it holds no key"
        );
    }

    #[test]
    fn markup_tokens_clamp_out_of_range_windows() {
        let (mut s, _p) = session("{\n}");
        assert!(s.markup_tokens(StructuredLanguage::Json, 99, 200).is_empty());
        assert!(s.markup_tokens(StructuredLanguage::Json, 1, 0).is_empty());
        assert!(s
            .markup_tokens(StructuredLanguage::PlainText, 0, 2)
            .is_empty());
    }

    #[test]
    fn markup_analysis_reports_folds_and_errors() {
        let (mut s, _p) = session("{\n  \"a\": 1\n}");
        let a = s.markup_analysis(StructuredLanguage::Json);
        assert_eq!(a.folds.len(), 1);
        assert!(a.diagnostics.is_empty());

        let (mut bad, _p2) = session("{\n  \"a\" 1\n}");
        let a = bad.markup_analysis(StructuredLanguage::Json);
        assert_eq!(a.diagnostics.len(), 1);
        assert_eq!(a.diagnostics[0].row, 1);
    }

    /// An unsaved scratch document has no meaningful extension, so the format
    /// has to come from the content.
    #[test]
    fn detection_sniffs_content_when_the_extension_says_nothing() {
        let (s, _p) = session("<?xml version=\"1.0\"?>\n<r/>");
        assert_eq!(
            s.detect_markup_language("txt".into(), "Plain Text".into(), None),
            StructuredLanguage::Xml
        );

        let (s, _p) = session("name: textutilz\nversion: 1");
        assert_eq!(
            s.detect_markup_language("txt".into(), "Plain Text".into(), None),
            StructuredLanguage::Yaml
        );

        let (s, _p) = session("just some notes\nnothing structured here");
        assert_eq!(
            s.detect_markup_language("txt".into(), "Plain Text".into(), None),
            StructuredLanguage::PlainText
        );
    }

    /// The point of the override: a document whose extension lies, or a scratch
    /// buffer with nothing in it yet, can still be pinned by hand.
    #[test]
    fn a_pinned_language_beats_every_detection_signal() {
        // Extension, content type and content all agree on XML; the pin wins.
        let (s, _p) = session("<?xml version=\"1.0\"?>\n<r/>");
        assert_eq!(
            s.detect_markup_language(
                "xml".into(),
                "application/xml".into(),
                Some(StructuredLanguage::Yaml),
            ),
            StructuredLanguage::Yaml
        );

        // An empty scratch buffer detects as plain text, but can be pinned.
        let (s, _p) = session("");
        assert_eq!(
            s.detect_markup_language("".into(), "".into(), Some(StructuredLanguage::Xml)),
            StructuredLanguage::Xml
        );
    }

    /// Pinning to plain text is a real choice — "stop colouring this" — and must
    /// not be confused with having no pin at all.
    #[test]
    fn pinning_plain_text_suppresses_detection() {
        let (s, _p) = session("{\n  \"a\": 1\n}");
        assert_eq!(
            s.detect_markup_language("json".into(), "".into(), None),
            StructuredLanguage::Json
        );
        assert_eq!(
            s.detect_markup_language(
                "json".into(),
                "".into(),
                Some(StructuredLanguage::PlainText),
            ),
            StructuredLanguage::PlainText
        );
    }

    /// The JSON5 dialect switch is now a pin, so it has to survive a document
    /// that detection would call strict JSON.
    #[test]
    fn pinning_json5_over_a_strict_json_document_holds() {
        let (s, _p) = session("{\n  \"a\": 1\n}");
        assert_eq!(
            s.detect_markup_language(
                "json".into(),
                "application/json".into(),
                Some(StructuredLanguage::Json5),
            ),
            StructuredLanguage::Json5
        );
    }
}
