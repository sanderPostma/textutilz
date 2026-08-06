//! Byte-oriented editable document for the hex editor. This is the byte analog
//! of [`crate::api::edit_session::EditSession`]: an immutable [`FileBuffer`]
//! base plus a copy-on-write **piece table**, with undo/redo. Memory is
//! proportional to the edits, not the file size, and reads/saves stream from
//! the base file on demand so multi-GB files are never fully loaded.
//!
//! A piece table (rather than a per-page byte overlay) is used because it
//! models overwrite, insert, and delete uniformly as a single `splice`
//! primitive, and keeps memory proportional to the number of edits.

use std::io::Read;

use crate::api::file_manager::FileBuffer;

/// First N bytes sampled by the binary-content sniffer.
const SNIFF_BYTES: usize = 8192;

/// Where a run of bytes comes from.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    /// Bytes read from the immutable base file at `[start, start+len)`.
    Base,
    /// Bytes stored in the session's append-only `added` buffer.
    Add,
}

/// A contiguous run of bytes from one source.
#[derive(Clone, Copy)]
struct Piece {
    source: Source,
    start: usize,
    len: usize,
}

/// A piece-level edit: at `offset`, the pieces in `old` were replaced by the
/// pieces in `new`. Undo swaps `new` back to `old`; redo swaps `old` to `new`.
///
/// Storing the exact pieces (not raw bytes) is deliberate: undoing an overwrite
/// restores the original *base* piece, so a reverted byte is no longer flagged
/// as modified by [`HexSession::modified_ranges`] (an Add piece would be).
struct Edit {
    offset: usize,
    old: Vec<Piece>,
    new: Vec<Piece>,
    /// Caret after applying `new`.
    end_offset: usize,
}

/// One undo step: one or more edits applied in order (e.g. the two nibble
/// writes of a single hex byte, grouped). Undo reverses them; redo replays them.
struct UndoEntry {
    prims: Vec<Edit>,
    /// Caret after the last edit.
    end_offset: usize,
    /// True only for a lone single-byte edit that may absorb the next one (used
    /// when coalescing is enabled).
    coalescable: bool,
}

/// An edited byte range, in absolute offsets. Returned by [`HexSession::modified_ranges`]
/// so the UI can highlight bytes that differ from the base file.
pub struct ByteRange {
    pub start: usize,
    pub len: usize,
}

/// Matches returned by [`HexSession::find_bytes`]. `complete` is false when
/// the caller's result limit was reached, allowing the UI to stay bounded on
/// files containing millions of identical bytes.
pub struct ByteSearchResult {
    pub offsets: Vec<usize>,
    pub complete: bool,
}

/// The editable byte document. See the module docs.
#[flutter_rust_bridge::frb(opaque)]
pub struct HexSession {
    base: FileBuffer,
    /// The current document as a sequence of pieces. Starts as a single Base
    /// piece spanning the whole file (empty when the file is empty).
    pieces: Vec<Piece>,
    /// Append-only buffer holding inserted / overwritten bytes.
    added: Vec<u8>,
    /// Cached current total length in bytes.
    total_len: usize,
    undo: Vec<UndoEntry>,
    redo: Vec<UndoEntry>,
    /// While Some, edits append to this group instead of the undo stack.
    group: Option<UndoEntry>,
    /// When true, consecutive single-byte edits (e.g. typing in the character
    /// panel) merge into one undo step. When false, every edit is its own step.
    /// Shared app setting; matches EditSession so all editors behave alike.
    coalesce: bool,
}

impl HexSession {
    #[flutter_rust_bridge::frb(sync)]
    pub fn open(path: String) -> anyhow::Result<HexSession> {
        let base = FileBuffer::open(path)?;
        Ok(HexSession::from_file_buffer(base))
    }

    /// Build a session over an already-scanned base buffer. Not exposed to Dart.
    pub(crate) fn from_file_buffer(base: FileBuffer) -> HexSession {
        let size = base.size;
        let pieces = if size > 0 {
            vec![Piece {
                source: Source::Base,
                start: 0,
                len: size,
            }]
        } else {
            Vec::new()
        };
        HexSession {
            base,
            pieces,
            added: Vec::new(),
            total_len: size,
            undo: Vec::new(),
            redo: Vec::new(),
            group: None,
            coalesce: true,
        }
    }

    /// Set whether consecutive single-byte edits coalesce into one undo step
    /// (true) or each edit is its own step (false).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_coalesce_undo(&mut self, on: bool) {
        self.coalesce = on;
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn path(&self) -> String {
        self.base.path.clone()
    }

    /// Current total document length, in bytes.
    #[flutter_rust_bridge::frb(sync)]
    #[allow(clippy::len_without_is_empty)]
    pub fn len(&self) -> usize {
        self.total_len
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_dirty(&self) -> bool {
        // The empty undo stack is the saved/loaded checkpoint (bytes equal the
        // file on disk), so undoing all the way back clears the dirty flag.
        !self.undo.is_empty()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    // ---- windowed reads -----------------------------------------------------

    /// The current (post-edit) bytes in `[offset, offset+len)`, clamped to the
    /// document end. Walks only the pieces overlapping the window; base pieces
    /// are read from disk on demand, so the whole file is never loaded.
    /// Bridged to Dart as `Uint8List`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn read_window(&self, offset: usize, len: usize) -> anyhow::Result<Vec<u8>> {
        let end = offset.saturating_add(len).min(self.total_len);
        if offset >= end {
            return Ok(Vec::new());
        }
        let mut out = Vec::with_capacity(end - offset);
        let mut acc = 0usize;
        for p in &self.pieces {
            if acc >= end {
                break;
            }
            let p_end = acc + p.len;
            if p_end > offset {
                let s = offset.max(acc) - acc;
                let e = end.min(p_end) - acc;
                match p.source {
                    Source::Base => {
                        out.extend(self.base.read_bytes(p.start + s, p.start + e)?);
                    }
                    Source::Add => {
                        out.extend_from_slice(&self.added[p.start + s..p.start + e]);
                    }
                }
            }
            acc = p_end;
        }
        Ok(out)
    }

    /// Absolute byte ranges within `[offset, offset+len)` that have been edited
    /// (i.e. come from the `added` buffer). Deletions leave no bytes and are not
    /// reported. Adjacent ranges are not coalesced across the window boundary.
    #[flutter_rust_bridge::frb(sync)]
    pub fn modified_ranges(&self, offset: usize, len: usize) -> Vec<ByteRange> {
        let end = offset.saturating_add(len).min(self.total_len);
        let mut ranges = Vec::new();
        let mut acc = 0usize;
        for p in &self.pieces {
            if acc >= end {
                break;
            }
            let p_end = acc + p.len;
            if p_end > offset && p.source == Source::Add {
                let s = offset.max(acc);
                let e = end.min(p_end);
                if e > s {
                    ranges.push(ByteRange {
                        start: s,
                        len: e - s,
                    });
                }
            }
            acc = p_end;
        }
        ranges
    }

    // ---- byte search -------------------------------------------------------

    /// Find non-overlapping occurrences of `pattern` at or after
    /// `from_offset`. The piece table is read in bounded windows, so searching
    /// a multi-GB base file never loads the whole document into memory.
    ///
    /// `max_results == 0` means unlimited. Otherwise scanning stops after one
    /// additional match proves the returned list was truncated.
    pub fn find_bytes(
        &self,
        pattern: Vec<u8>,
        from_offset: usize,
        max_results: usize,
    ) -> anyhow::Result<ByteSearchResult> {
        const SEARCH_CHUNK: usize = 256 * 1024;

        if pattern.is_empty() || from_offset >= self.total_len || pattern.len() > self.total_len {
            return Ok(ByteSearchResult {
                offsets: Vec::new(),
                complete: true,
            });
        }

        let mut offsets = Vec::new();
        let mut window_start = from_offset;
        let mut next_allowed = from_offset;
        while window_start < self.total_len {
            let primary_end = window_start
                .saturating_add(SEARCH_CHUNK)
                .min(self.total_len);
            let read_end = primary_end
                .saturating_add(pattern.len().saturating_sub(1))
                .min(self.total_len);
            let bytes = self.read_window(window_start, read_end - window_start)?;
            let mut i = next_allowed.saturating_sub(window_start);
            while i + pattern.len() <= bytes.len() {
                let absolute = window_start + i;
                // Starts in the overlap belong to the following window.
                if absolute >= primary_end {
                    break;
                }
                if bytes[i..i + pattern.len()] == pattern {
                    if max_results != 0 && offsets.len() == max_results {
                        return Ok(ByteSearchResult {
                            offsets,
                            complete: false,
                        });
                    }
                    offsets.push(absolute);
                    i += pattern.len();
                    next_allowed = absolute + pattern.len();
                } else {
                    i += 1;
                }
            }
            window_start = primary_end;
            next_allowed = next_allowed.max(window_start);
        }

        Ok(ByteSearchResult {
            offsets,
            complete: true,
        })
    }

    // ---- piece-table mutation (no undo bookkeeping) -------------------------

    /// Ensure a piece boundary exists exactly at `offset`; return the index of
    /// the piece that starts there (splitting one if necessary). `offset` must
    /// be `<= total_len`.
    fn split_at(&mut self, offset: usize) -> usize {
        let mut acc = 0usize;
        for i in 0..self.pieces.len() {
            if acc == offset {
                return i;
            }
            let plen = self.pieces[i].len;
            if offset < acc + plen {
                let left = offset - acc;
                let p = self.pieces[i];
                self.pieces[i].len = left;
                self.pieces.insert(
                    i + 1,
                    Piece {
                        source: p.source,
                        start: p.start + left,
                        len: p.len - left,
                    },
                );
                return i + 1;
            }
            acc += plen;
        }
        self.pieces.len()
    }

    /// Merge piece `i` with its immediate neighbours when they are contiguous
    /// runs of the same source, so sequential typing collapses to ~one piece.
    fn merge_around(&mut self, i: usize) {
        // Merge with the following piece first (indices before `i` stay valid).
        if i + 1 < self.pieces.len() && Self::contiguous(&self.pieces[i], &self.pieces[i + 1]) {
            self.pieces[i].len += self.pieces[i + 1].len;
            self.pieces.remove(i + 1);
        }
        if i > 0 && Self::contiguous(&self.pieces[i - 1], &self.pieces[i]) {
            self.pieces[i - 1].len += self.pieces[i].len;
            self.pieces.remove(i);
        }
    }

    fn contiguous(a: &Piece, b: &Piece) -> bool {
        a.source == b.source && a.start + a.len == b.start
    }

    /// Core splice: remove `del_len` bytes at `offset` and insert `ins`. Returns
    /// an [`Edit`] describing the piece-level change (the exact pieces removed
    /// and inserted) for undo/redo. `del_len` is clamped to the bytes available.
    fn apply_splice(&mut self, offset: usize, del_len: usize, ins: &[u8]) -> Edit {
        let offset = offset.min(self.total_len);
        let del_len = del_len.min(self.total_len - offset);

        let add_start = self.added.len();
        if !ins.is_empty() {
            self.added.extend_from_slice(ins);
        }

        let i = self.split_at(offset);
        let j = self.split_at(offset + del_len);
        let old: Vec<Piece> = self.pieces.drain(i..j).collect();
        let mut new: Vec<Piece> = Vec::new();
        if !ins.is_empty() {
            let p = Piece {
                source: Source::Add,
                start: add_start,
                len: ins.len(),
            };
            self.pieces.insert(i, p);
            new.push(p);
        }
        self.total_len = self.total_len - del_len + ins.len();
        if i < self.pieces.len() {
            self.merge_around(i);
        } else if i > 0 {
            self.merge_around(i - 1);
        }
        Edit {
            offset,
            old,
            new,
            end_offset: offset + ins.len(),
        }
    }

    fn piece_len(list: &[Piece]) -> usize {
        list.iter().map(|p| p.len).sum()
    }

    /// At `offset`, remove `remove_len` bytes and splice in `insert` verbatim.
    /// Used by undo/redo to restore exact pieces.
    fn swap(&mut self, offset: usize, remove_len: usize, insert: &[Piece]) {
        let i = self.split_at(offset);
        let j = self.split_at(offset + remove_len);
        self.pieces.drain(i..j);
        for (k, p) in insert.iter().enumerate() {
            self.pieces.insert(i + k, *p);
        }
        let insert_len = Self::piece_len(insert);
        self.total_len = self.total_len - remove_len + insert_len;
        if i < self.pieces.len() {
            self.merge_around(i);
        }
        let end = i + insert.len();
        if end > 0 && end <= self.pieces.len() {
            self.merge_around(end - 1);
        }
    }

    /// Reverse `edit`: remove its `new` pieces, restore its `old` pieces.
    fn undo_edit(&mut self, e: &Edit) -> usize {
        self.swap(e.offset, Self::piece_len(&e.new), &e.old);
        e.offset + Self::piece_len(&e.old)
    }

    /// Re-apply `edit`: remove its `old` pieces, restore its `new` pieces.
    fn redo_edit(&mut self, e: &Edit) -> usize {
        self.swap(e.offset, Self::piece_len(&e.old), &e.new);
        e.end_offset
    }

    // ---- undo recording -----------------------------------------------------

    fn record(&mut self, edit: Edit, coalescable: bool) {
        self.redo.clear();
        let end = edit.end_offset;
        let start = edit.offset;
        if let Some(group) = &mut self.group {
            group.prims.push(edit);
            group.end_offset = end;
            group.coalescable = false;
            return;
        }
        if coalescable && self.coalesce {
            if let Some(top) = self.undo.last_mut() {
                if top.coalescable && top.end_offset == start {
                    top.prims.push(edit);
                    top.end_offset = end;
                    return;
                }
            }
        }
        self.undo.push(UndoEntry {
            prims: vec![edit],
            end_offset: end,
            coalescable,
        });
    }

    // ---- public mutations ---------------------------------------------------

    /// Overwrite the bytes starting at `offset` with `bytes` (length unchanged
    /// where possible). Overwriting past the end appends. Returns the caret
    /// offset just past the written bytes.
    #[flutter_rust_bridge::frb(sync)]
    pub fn overwrite_bytes(&mut self, offset: usize, bytes: Vec<u8>) -> anyhow::Result<usize> {
        let coalescable = bytes.len() == 1;
        let edit = self.apply_splice(offset, bytes.len(), &bytes);
        let caret = edit.end_offset;
        self.record(edit, coalescable);
        Ok(caret)
    }

    /// Insert `bytes` at `offset`, shifting following bytes. Returns the caret
    /// offset just past the inserted bytes.
    #[flutter_rust_bridge::frb(sync)]
    pub fn insert_bytes(&mut self, offset: usize, bytes: Vec<u8>) -> anyhow::Result<usize> {
        let coalescable = bytes.len() == 1;
        let edit = self.apply_splice(offset, 0, &bytes);
        let caret = edit.end_offset;
        self.record(edit, coalescable);
        Ok(caret)
    }

    /// Delete `len` bytes at `offset` (clamped). Returns the caret offset, which
    /// stays at `offset`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn delete(&mut self, offset: usize, len: usize) -> anyhow::Result<usize> {
        let edit = self.apply_splice(offset, len, &[]);
        let caret = edit.offset;
        self.record(edit, false);
        Ok(caret)
    }

    /// Replace one exact byte sequence. The expected bytes guard against a
    /// stale search result after the document has been edited.
    #[flutter_rust_bridge::frb(sync)]
    pub fn replace_bytes(
        &mut self,
        offset: usize,
        expected: Vec<u8>,
        replacement: Vec<u8>,
    ) -> anyhow::Result<usize> {
        if expected.is_empty() {
            anyhow::bail!("the search pattern cannot be empty");
        }
        if self.read_window(offset, expected.len())? != expected {
            anyhow::bail!("bytes at the match offset have changed");
        }
        if expected == replacement {
            return Ok(offset + expected.len());
        }
        let edit = self.apply_splice(offset, expected.len(), &replacement);
        let caret = edit.end_offset;
        self.record(edit, false);
        Ok(caret)
    }

    /// Replace every non-overlapping occurrence as one undo step. Edits are
    /// applied from the end backwards so earlier byte offsets remain valid.
    pub fn replace_all_bytes(
        &mut self,
        pattern: Vec<u8>,
        replacement: Vec<u8>,
    ) -> anyhow::Result<usize> {
        if pattern.is_empty() {
            anyhow::bail!("the search pattern cannot be empty");
        }
        let found = self.find_bytes(pattern.clone(), 0, 0)?;
        if found.offsets.is_empty() || pattern == replacement {
            return Ok(found.offsets.len());
        }

        self.begin_group();
        for offset in found.offsets.iter().rev().copied() {
            let edit = self.apply_splice(offset, pattern.len(), &replacement);
            self.record(edit, false);
        }
        self.end_group();
        Ok(found.offsets.len())
    }

    /// Break typing coalescing (call on caret moves, clicks, focus changes) so
    /// the next edit starts a fresh undo step.
    #[flutter_rust_bridge::frb(sync)]
    pub fn break_coalescing(&mut self) {
        if let Some(top) = self.undo.last_mut() {
            top.coalescable = false;
        }
    }

    /// Begin grouping subsequent mutations into a single undo step (e.g. the two
    /// nibble writes that make up one hex byte).
    #[flutter_rust_bridge::frb(sync)]
    pub fn begin_group(&mut self) {
        if self.group.is_none() {
            self.group = Some(UndoEntry {
                prims: Vec::new(),
                end_offset: 0,
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
    pub fn undo(&mut self) -> Option<usize> {
        let entry = self.undo.pop()?;
        let mut caret = entry.end_offset;
        for e in entry.prims.iter().rev() {
            caret = self.undo_edit(e);
        }
        self.redo.push(entry);
        Some(caret)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn redo(&mut self) -> Option<usize> {
        let entry = self.redo.pop()?;
        let mut caret = entry.end_offset;
        for e in entry.prims.iter() {
            caret = self.redo_edit(e);
        }
        self.undo.push(entry);
        Some(caret)
    }

    // ---- saving -------------------------------------------------------------

    /// Rebind the piece table to a single Base piece over the freshly-saved file
    /// and clear all edit state.
    fn reset_after_save(&mut self) {
        self.pieces = if self.base.size > 0 {
            vec![Piece {
                source: Source::Base,
                start: 0,
                len: self.base.size,
            }]
        } else {
            Vec::new()
        };
        self.added.clear();
        self.total_len = self.base.size;
        self.undo.clear();
        self.redo.clear();
        self.group = None;
    }

    fn save_impl(&mut self, new_path: Option<String>) -> anyhow::Result<()> {
        use std::io::{BufWriter, Seek, SeekFrom, Write};
        let target = new_path.clone().unwrap_or_else(|| self.base.path.clone());
        let temp = format!("{}.tmp", target);
        {
            let mut w = BufWriter::new(std::fs::File::create(&temp)?);
            // Open the base file once; seek per base piece.
            let mut src = std::fs::File::open(&self.base.path)?;
            let mut buf = vec![0u8; 65536];
            for p in &self.pieces {
                match p.source {
                    Source::Add => {
                        w.write_all(&self.added[p.start..p.start + p.len])?;
                    }
                    Source::Base => {
                        src.seek(SeekFrom::Start(p.start as u64))?;
                        let mut left = p.len;
                        while left > 0 {
                            let take = left.min(buf.len());
                            let n = src.read(&mut buf[..take])?;
                            if n == 0 {
                                break;
                            }
                            w.write_all(&buf[..n])?;
                            left -= n;
                        }
                    }
                }
            }
            w.flush()?;
        }
        std::fs::rename(&temp, &target)?;
        if let Some(p) = new_path {
            self.base.path = p;
        }
        self.base.refresh()?;
        self.reset_after_save();
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save(&mut self) -> anyhow::Result<()> {
        self.save_impl(None)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save_as(&mut self, new_path: String) -> anyhow::Result<()> {
        self.save_impl(Some(new_path))
    }
}

// ---- binary-content detection ----------------------------------------------

/// Heuristic: does this byte sample look like binary (non-text) content? A NUL
/// byte is a strong signal (git's own heuristic); otherwise a high ratio of
/// control bytes outside the usual text whitespace/escape set marks it binary.
fn sniff_binary(sample: &[u8]) -> bool {
    if sample.is_empty() {
        return false;
    }
    if sample.contains(&0) {
        return true;
    }
    let suspicious = sample
        .iter()
        .filter(|&&b| {
            // Allow tab, LF, CR, FF, ESC and everything >= 0x20.
            !(b == 9 || b == 10 || b == 13 || b == 12 || b == 27 || b >= 0x20)
        })
        .count();
    suspicious * 100 / sample.len() > 30
}

/// Sniff the first ~8 KB of `path` and report whether it looks binary. Drives
/// the "open binary files in hex mode" behavior on the Dart side.
#[flutter_rust_bridge::frb(sync)]
pub fn is_binary_file(path: String) -> anyhow::Result<bool> {
    let mut f = std::fs::File::open(&path)?;
    let mut buf = vec![0u8; SNIFF_BYTES];
    let n = f.read(&mut buf)?;
    Ok(sniff_binary(&buf[..n]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn session(content: &[u8]) -> (HexSession, String) {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir()
            .join(format!(
                "textutilz_hex_test_{}_{}.bin",
                std::process::id(),
                n
            ))
            .to_string_lossy()
            .to_string();
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(content).unwrap();
        f.flush().unwrap();
        (HexSession::open(path.clone()).unwrap(), path)
    }

    fn all(s: &HexSession) -> Vec<u8> {
        s.read_window(0, s.len()).unwrap()
    }

    #[test]
    fn reads_base_bytes() {
        let (s, _p) = session(b"hello world");
        assert_eq!(s.len(), 11);
        assert_eq!(all(&s), b"hello world");
        // Window in the middle.
        assert_eq!(s.read_window(6, 5).unwrap(), b"world");
        // Clamped past the end.
        assert_eq!(s.read_window(9, 100).unwrap(), b"ld");
    }

    #[test]
    fn overwrite_keeps_length() {
        let (mut s, _p) = session(b"hello");
        let c = s.overwrite_bytes(1, vec![b'A', b'B']).unwrap();
        assert_eq!(c, 3);
        assert_eq!(all(&s), b"hABlo");
        assert_eq!(s.len(), 5);
    }

    #[test]
    fn overwrite_past_end_appends() {
        let (mut s, _p) = session(b"ab");
        s.overwrite_bytes(2, vec![b'c', b'd']).unwrap();
        assert_eq!(all(&s), b"abcd");
        assert_eq!(s.len(), 4);
    }

    #[test]
    fn insert_shifts() {
        let (mut s, _p) = session(b"hello");
        let c = s.insert_bytes(2, vec![b'X', b'Y']).unwrap();
        assert_eq!(c, 4);
        assert_eq!(all(&s), b"heXYllo");
        assert_eq!(s.len(), 7);
    }

    #[test]
    fn insert_at_start_and_end() {
        let (mut s, _p) = session(b"mid");
        s.insert_bytes(0, vec![b'>']).unwrap();
        s.insert_bytes(s.len(), vec![b'<']).unwrap();
        assert_eq!(all(&s), b">mid<");
    }

    #[test]
    fn delete_removes() {
        let (mut s, _p) = session(b"hello");
        let c = s.delete(1, 2).unwrap();
        assert_eq!(c, 1);
        assert_eq!(all(&s), b"hlo");
        assert_eq!(s.len(), 3);
    }

    #[test]
    fn delete_clamps() {
        let (mut s, _p) = session(b"abc");
        s.delete(1, 100).unwrap();
        assert_eq!(all(&s), b"a");
    }

    #[test]
    fn mixed_edits_read_window() {
        let (mut s, _p) = session(b"0123456789");
        s.overwrite_bytes(0, vec![b'A']).unwrap(); // A123456789
        s.insert_bytes(5, vec![b'-', b'-']).unwrap(); // A1234--56789
        s.delete(8, 2).unwrap(); // A1234--589
        assert_eq!(all(&s), b"A1234--589");
        // Windowed read across piece boundaries matches the whole read.
        for start in 0..s.len() {
            for len in 0..=(s.len() - start) {
                assert_eq!(
                    s.read_window(start, len).unwrap(),
                    &all(&s)[start..start + len]
                );
            }
        }
    }

    #[test]
    fn finds_bytes_across_search_window_and_piece_boundaries() {
        const CHUNK: usize = 256 * 1024;
        let mut content = vec![b'x'; CHUNK + 20];
        content[CHUNK - 2..CHUNK + 2].copy_from_slice(b"ABCD");
        let (mut s, _p) = session(&content);
        // Split the searched sequence across Add/Base pieces as well as the
        // internal search window boundary.
        s.overwrite_bytes(CHUNK - 1, vec![b'B', b'C']).unwrap();

        let found = s.find_bytes(b"ABCD".to_vec(), 0, 10).unwrap();
        assert_eq!(found.offsets, vec![CHUNK - 2]);
        assert!(found.complete);
    }

    #[test]
    fn find_bytes_is_non_overlapping_and_reports_truncation() {
        let (s, _p) = session(b"aaaaa");
        let all = s.find_bytes(b"aa".to_vec(), 0, 0).unwrap();
        assert_eq!(all.offsets, vec![0, 2]);
        assert!(all.complete);

        let limited = s.find_bytes(vec![b'a'], 0, 2).unwrap();
        assert_eq!(limited.offsets, vec![0, 1]);
        assert!(!limited.complete);
    }

    #[test]
    fn replace_bytes_rejects_stale_match() {
        let (mut s, _p) = session(b"abc");
        assert!(s.replace_bytes(1, vec![b'x'], vec![b'B']).is_err());
        assert_eq!(all(&s), b"abc");
        assert!(!s.is_dirty());
    }

    #[test]
    fn replace_all_bytes_is_one_undo_step() {
        let (mut s, _p) = session(b"one two one");
        assert_eq!(
            s.replace_all_bytes(b"one".to_vec(), b"1".to_vec()).unwrap(),
            2
        );
        assert_eq!(all(&s), b"1 two 1");
        s.undo().unwrap();
        assert_eq!(all(&s), b"one two one");
        assert!(!s.can_undo());
    }

    #[test]
    fn undo_redo_roundtrip() {
        let (mut s, _p) = session(b"hello");
        s.overwrite_bytes(0, vec![b'J']).unwrap();
        s.insert_bytes(5, vec![b'!']).unwrap();
        s.delete(1, 2).unwrap();
        let edited = all(&s);
        assert_eq!(edited, b"Jlo!");
        while s.can_undo() {
            s.undo().unwrap();
        }
        assert_eq!(all(&s), b"hello");
        while s.can_redo() {
            s.redo().unwrap();
        }
        assert_eq!(all(&s), b"Jlo!");
    }

    #[test]
    fn per_char_undo_when_coalescing_off() {
        let (mut s, _p) = session(b"");
        s.set_coalesce_undo(false);
        let mut c = 0usize;
        for b in [b'a', b'b', b'c'] {
            c = s.insert_bytes(c, vec![b]).unwrap();
        }
        assert_eq!(all(&s), b"abc");
        // Each keystroke undoes one at a time.
        s.undo().unwrap();
        assert_eq!(all(&s), b"ab");
        s.undo().unwrap();
        assert_eq!(all(&s), b"a");
        s.undo().unwrap();
        assert_eq!(all(&s), b"");
        assert!(!s.can_undo());
    }

    #[test]
    fn coalesced_typing_undoes_as_one_step_when_on() {
        let (mut s, _p) = session(b"");
        s.set_coalesce_undo(true); // also the default
        let mut c = 0usize;
        for b in [b'a', b'b', b'c'] {
            c = s.insert_bytes(c, vec![b]).unwrap();
        }
        assert_eq!(all(&s), b"abc");
        s.undo().unwrap();
        assert_eq!(all(&s), b""); // whole coalesced run at once
        assert!(!s.can_undo());
    }

    #[test]
    fn undo_releases_modified_flag() {
        // Overwriting a base byte flags it modified; undo restores the base
        // piece, so it is no longer reported as modified (highlight releases).
        let (mut s, _p) = session(b"0123456789");
        s.overwrite_bytes(2, vec![b'A']).unwrap();
        assert_eq!(s.modified_ranges(0, s.len()).len(), 1);
        s.undo().unwrap();
        assert_eq!(all(&s), b"0123456789");
        assert!(s.modified_ranges(0, s.len()).is_empty());
        // Redo re-flags it.
        s.redo().unwrap();
        assert_eq!(s.modified_ranges(0, s.len()).len(), 1);
    }

    #[test]
    fn grouped_byte_edit_undoes_as_one_step() {
        // Two nibble writes wrapped in a group (how the hex panel types a byte)
        // undo together, and the highlight releases.
        let (mut s, _p) = session(b"0123456789");
        s.begin_group();
        s.overwrite_bytes(2, vec![0xA0]).unwrap(); // high nibble
        s.overwrite_bytes(2, vec![0xAB]).unwrap(); // low nibble
        s.end_group();
        assert_eq!(s.read_window(2, 1).unwrap(), vec![0xAB]);
        s.undo().unwrap();
        assert_eq!(all(&s), b"0123456789");
        assert!(s.modified_ranges(0, s.len()).is_empty());
    }

    #[test]
    fn break_coalescing_splits_steps() {
        let (mut s, _p) = session(b"");
        let c = s.insert_bytes(0, vec![b'a']).unwrap();
        s.break_coalescing();
        s.insert_bytes(c, vec![b'b']).unwrap();
        s.undo().unwrap();
        assert_eq!(all(&s), b"a");
        s.undo().unwrap();
        assert_eq!(all(&s), b"");
    }

    #[test]
    fn group_is_atomic() {
        let (mut s, _p) = session(b"one");
        s.begin_group();
        s.delete(0, 3).unwrap();
        s.insert_bytes(0, b"ONE".to_vec()).unwrap();
        s.end_group();
        assert_eq!(all(&s), b"ONE");
        s.undo().unwrap();
        assert_eq!(all(&s), b"one");
    }

    #[test]
    fn new_edit_clears_redo() {
        let (mut s, _p) = session(b"x");
        s.insert_bytes(1, vec![b'y']).unwrap();
        s.undo().unwrap();
        assert!(s.can_redo());
        s.insert_bytes(1, vec![b'z']).unwrap();
        assert!(!s.can_redo());
        assert_eq!(all(&s), b"xz");
    }

    #[test]
    fn modified_ranges_flags_added() {
        let (mut s, _p) = session(b"0123456789");
        s.overwrite_bytes(2, vec![b'A', b'B']).unwrap();
        let r = s.modified_ranges(0, s.len());
        assert_eq!(r.len(), 1);
        assert_eq!((r[0].start, r[0].len), (2, 2));
    }

    #[test]
    fn undo_to_checkpoint_clears_dirty() {
        let (mut s, _p) = session(b"hello");
        assert!(!s.is_dirty());
        s.overwrite_bytes(0, vec![b'H']).unwrap();
        assert!(s.is_dirty());
        s.undo().unwrap();
        assert!(!s.is_dirty()); // back at the loaded checkpoint
        s.redo().unwrap();
        assert!(s.is_dirty());
    }

    #[test]
    fn save_roundtrips() {
        let (mut s, path) = session(b"hello world");
        s.overwrite_bytes(0, vec![b'H']).unwrap();
        s.insert_bytes(s.len(), vec![b'!']).unwrap();
        assert!(s.is_dirty());
        s.save().unwrap();
        assert!(!s.is_dirty());
        assert!(!s.can_undo());
        let on_disk = std::fs::read(&path).unwrap();
        assert_eq!(on_disk, b"Hello world!");
        assert_eq!(all(&s), b"Hello world!");
    }

    #[test]
    fn save_noop_is_identical() {
        let (mut s, path) = session(b"unchanged bytes");
        s.save().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"unchanged bytes");
    }

    #[test]
    fn empty_file_edits() {
        let (mut s, _p) = session(b"");
        assert_eq!(s.len(), 0);
        s.insert_bytes(0, b"first".to_vec()).unwrap();
        assert_eq!(all(&s), b"first");
    }

    #[test]
    fn sniff_detects_binary() {
        assert!(!sniff_binary(b"plain ascii text\nwith newlines\t"));
        assert!(sniff_binary(b"has a \0 nul"));
        assert!(sniff_binary(&[
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
        ]));
        assert!(!sniff_binary(b""));
    }
}
