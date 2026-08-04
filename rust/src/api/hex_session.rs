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

/// A primitive splice: at `offset`, remove `del_len` bytes and insert `ins`.
/// Both the forward and the inverse of an edit are expressed as an `Op`.
#[derive(Clone)]
struct Op {
    offset: usize,
    del_len: usize,
    ins: Vec<u8>,
}

/// One undo step: one or more primitives applied in order. Undo replays their
/// inverses in reverse; redo replays the forwards in order. Mirrors
/// `EditSession`'s `UndoEntry`, with the caret collapsed to a byte offset.
struct UndoEntry {
    prims: Vec<(Op /*forward*/, Op /*inverse*/)>,
    /// Caret after the last forward primitive — used to detect contiguous typing.
    end_offset: usize,
    /// True only for a lone single-byte edit that may absorb the next one.
    coalescable: bool,
}

/// An edited byte range, in absolute offsets. Returned by [`HexSession::modified_ranges`]
/// so the UI can highlight bytes that differ from the base file.
pub struct ByteRange {
    pub start: usize,
    pub len: usize,
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
    dirty: bool,
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
            dirty: false,
        }
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
        self.dirty
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

    /// Core splice: remove `del_len` bytes at `offset` and insert `ins`.
    /// Returns `(caret, removed)` where `caret` is `offset + ins.len()` and
    /// `removed` is the bytes deleted (for the inverse op). `del_len` is clamped
    /// to the bytes available from `offset`.
    fn apply_splice(
        &mut self,
        offset: usize,
        del_len: usize,
        ins: &[u8],
    ) -> anyhow::Result<(usize, Vec<u8>)> {
        let offset = offset.min(self.total_len);
        let del_len = del_len.min(self.total_len - offset);
        let removed = self.read_window(offset, del_len)?;

        let add_start = self.added.len();
        if !ins.is_empty() {
            self.added.extend_from_slice(ins);
        }

        let i = self.split_at(offset);
        let j = self.split_at(offset + del_len);
        self.pieces.drain(i..j);
        if !ins.is_empty() {
            self.pieces.insert(
                i,
                Piece {
                    source: Source::Add,
                    start: add_start,
                    len: ins.len(),
                },
            );
        }
        if i < self.pieces.len() {
            self.merge_around(i);
        } else if i > 0 {
            self.merge_around(i - 1);
        }

        self.total_len = self.total_len - del_len + ins.len();
        self.dirty = true;
        Ok((offset + ins.len(), removed))
    }

    /// Apply a primitive without recording undo; return the resulting caret.
    fn apply_op(&mut self, op: &Op) -> usize {
        let (caret, _removed) = self
            .apply_splice(op.offset, op.del_len, &op.ins)
            .unwrap_or((op.offset, Vec::new()));
        caret
    }

    // ---- undo recording -----------------------------------------------------

    fn record(&mut self, forward: Op, inverse: Op, start: usize, end: usize, coalescable: bool) {
        self.redo.clear();
        if let Some(group) = &mut self.group {
            group.prims.push((forward, inverse));
            group.end_offset = end;
            group.coalescable = false;
            return;
        }
        if coalescable {
            if let Some(top) = self.undo.last_mut() {
                if top.coalescable && top.end_offset == start {
                    top.prims.push((forward, inverse));
                    top.end_offset = end;
                    return;
                }
            }
        }
        self.undo.push(UndoEntry {
            prims: vec![(forward, inverse)],
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
        let del = bytes.len();
        let (caret, removed) = self.apply_splice(offset, del, &bytes)?;
        let coalescable = bytes.len() == 1;
        let forward = Op {
            offset,
            del_len: del,
            ins: bytes.clone(),
        };
        let inverse = Op {
            offset,
            del_len: bytes.len(),
            ins: removed,
        };
        self.record(forward, inverse, offset, caret, coalescable);
        Ok(caret)
    }

    /// Insert `bytes` at `offset`, shifting following bytes. Returns the caret
    /// offset just past the inserted bytes.
    #[flutter_rust_bridge::frb(sync)]
    pub fn insert_bytes(&mut self, offset: usize, bytes: Vec<u8>) -> anyhow::Result<usize> {
        let (caret, _removed) = self.apply_splice(offset, 0, &bytes)?;
        let coalescable = bytes.len() == 1;
        let forward = Op {
            offset,
            del_len: 0,
            ins: bytes.clone(),
        };
        let inverse = Op {
            offset,
            del_len: bytes.len(),
            ins: Vec::new(),
        };
        self.record(forward, inverse, offset, caret, coalescable);
        Ok(caret)
    }

    /// Delete `len` bytes at `offset` (clamped). Returns the caret offset, which
    /// stays at `offset`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn delete(&mut self, offset: usize, len: usize) -> anyhow::Result<usize> {
        let (_caret, removed) = self.apply_splice(offset, len, &[])?;
        let removed_len = removed.len();
        let forward = Op {
            offset,
            del_len: removed_len,
            ins: Vec::new(),
        };
        let inverse = Op {
            offset,
            del_len: 0,
            ins: removed,
        };
        self.record(forward, inverse, offset, offset, false);
        Ok(offset.min(self.total_len))
    }

    /// Break typing coalescing (call on caret moves, clicks, focus changes) so
    /// the next edit starts a fresh undo step.
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
        for (_forward, inverse) in entry.prims.iter().rev() {
            caret = self.apply_op(inverse);
        }
        self.redo.push(entry);
        self.dirty = true;
        Some(caret)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn redo(&mut self) -> Option<usize> {
        let entry = self.redo.pop()?;
        let mut caret = entry.end_offset;
        for (forward, _inverse) in entry.prims.iter() {
            caret = self.apply_op(forward);
        }
        self.undo.push(entry);
        self.dirty = true;
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
        self.dirty = false;
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
            .join(format!("textutilz_hex_test_{}_{}.bin", std::process::id(), n))
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
    fn single_byte_typing_coalesces() {
        let (mut s, _p) = session(b"");
        let mut c = 0usize;
        for b in [b'a', b'b', b'c'] {
            c = s.insert_bytes(c, vec![b]).unwrap();
        }
        assert_eq!(all(&s), b"abc");
        s.undo().unwrap();
        assert_eq!(all(&s), b""); // whole coalesced run
        assert!(!s.can_undo());
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
        assert!(sniff_binary(&[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]));
        assert!(!sniff_binary(b""));
    }
}
