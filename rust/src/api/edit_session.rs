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
    Insert { row: usize, col: usize, text: String },
    Delete { srow: usize, scol: usize, erow: usize, ecol: usize },
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
    dirty: bool,
}

// ---- UTF-16 column helpers (match Dart's code-unit columns) ----------------

fn u16_len(s: &str) -> usize {
    s.chars().map(|c| c.len_utf16()).sum()
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
            dirty: false,
        })
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
    pub fn selection_char_count(&self, mut r1: usize, mut c1: usize, mut r2: usize, mut c2: usize) -> usize {
        let line_count = self.line_count();
        if line_count == 0 {
            return 0;
        }
        if r1 >= line_count { r1 = line_count - 1; }
        if r2 >= line_count { r2 = line_count - 1; }
        
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
        self.dirty
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
        self.base.refresh()?;
        self.added_lines = 0;
        self.dirty = false;
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
            self.edited_rows.push(orow);
            self.edited_rows.sort_unstable();
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
        self.dirty = true;
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
            self.dirty = true;
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

        self.dirty = true;
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
        if coalescable {
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
        let entry = self.undo.pop()?;
        let mut caret = CaretPos::new(entry.end_row, entry.end_col);
        // Apply inverses in reverse order.
        for (_forward, inverse) in entry.prims.iter().rev() {
            caret = self.apply(inverse);
        }
        self.redo.push(entry);
        self.dirty = true;
        Some(caret)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn redo(&mut self) -> Option<CaretPos> {
        let entry = self.redo.pop()?;
        let mut caret = CaretPos::new(entry.end_row, entry.end_col);
        for (forward, _inverse) in entry.prims.iter() {
            caret = self.apply(forward);
        }
        self.undo.push(entry);
        self.dirty = true;
        Some(caret)
    }

    /// Replace the entire document with `text`, recorded as a single undoable
    /// step (delete-all + insert). Used by transforms like the MIME tools that
    /// rewrite the whole buffer. Returns the caret past the inserted text.
    #[flutter_rust_bridge::frb(sync)]
    pub fn replace_all(&mut self, text: String) -> CaretPos {
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
        self.dirty = false;
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
        let edits = self.build_edits();
        self.base.save_edits_as(new_path, edits)?;
        self.reset_after_save();
        Ok(())
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
            .join(format!("textutilz_es_test_{}_{}.txt", std::process::id(), n))
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

    #[test]
    fn reads_base_lines() {
        let (s, _p) = session("alpha\nbeta\ngamma");
        assert_eq!(s.line_count(), 3);
        assert_eq!(s.line(0), "alpha");
        assert_eq!(s.line(2), "gamma");
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
            .join(format!("textutilz_scratch_{}_{}.txt", std::process::id(), n))
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
}
