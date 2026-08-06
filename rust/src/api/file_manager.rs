use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::sync::Mutex;
use std::time::SystemTime;

#[derive(Clone, Debug, PartialEq, Eq)]
struct FileVersion {
    len: u64,
    modified: Option<SystemTime>,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}

impl FileVersion {
    fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;

        Self {
            len: metadata.len(),
            modified: metadata.modified().ok(),
            #[cfg(unix)]
            device: metadata.dev(),
            #[cfg(unix)]
            inode: metadata.ino(),
        }
    }

    fn read(path: &str) -> anyhow::Result<Self> {
        let metadata = std::fs::metadata(path)?;
        Ok(Self::from_metadata(&metadata))
    }
}

#[flutter_rust_bridge::frb(opaque)]
pub struct FileBuffer {
    pub size: usize,
    pub path: String,
    pub line_offsets: Vec<usize>,
    /// The exact file version whose bytes [line_offsets] index. Holding the
    /// handle keeps an atomically replaced file coherent until explicit reload.
    file: Mutex<File>,
    version: FileVersion,
}

impl FileBuffer {
    fn scan_file(path: &str) -> anyhow::Result<(File, usize, Vec<usize>, FileVersion)> {
        let mut file = File::open(path)?;
        let mut line_offsets = Vec::with_capacity(1024);
        line_offsets.push(0);

        let mut buffer = [0; 65536];
        let mut current_offset = 0;

        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            for i in 0..n {
                if buffer[i] == b'\n' {
                    line_offsets.push(current_offset + i + 1);
                }
            }
            current_offset += n;
        }
        // Capture the identity of the exact handle we scanned. If the path was
        // atomically replaced during the scan, this remains the old inode and
        // the next path check correctly reports an external change instead of
        // blessing new-path metadata alongside old offsets.
        let version = FileVersion::from_metadata(&file.metadata()?);
        Ok((file, current_offset, line_offsets, version))
    }

    pub(crate) fn read_bytes(&self, start: usize, end: usize) -> anyhow::Result<Vec<u8>> {
        if start >= end {
            return Ok(Vec::new());
        }
        let mut file = self
            .file
            .lock()
            .map_err(|_| anyhow::anyhow!("file buffer lock poisoned"))?;
        file.seek(SeekFrom::Start(start as u64))?;
        let mut buf = vec![0; end - start];
        file.read_exact(&mut buf)?;
        Ok(buf)
    }
}

pub struct LineChunk {
    pub content: String,
    pub start_line: usize,
    pub end_line: usize,
    pub byte_start: usize,
    pub byte_end: usize,
}

impl FileBuffer {
    #[flutter_rust_bridge::frb(sync)]
    pub fn open(path: String) -> anyhow::Result<FileBuffer> {
        let (file, size, line_offsets, version) = FileBuffer::scan_file(&path)?;
        Ok(FileBuffer {
            size,
            path,
            line_offsets,
            file: Mutex::new(file),
            version,
        })
    }

    /// Whether the path now points at different file contents than the
    /// version whose line offsets this buffer scanned. A missing/inaccessible
    /// file also counts as changed so the UI can surface the problem instead
    /// of continuing to render with stale offsets.
    pub(crate) fn has_external_changes(&self) -> bool {
        FileVersion::read(&self.path)
            .map(|current| current != self.version)
            .unwrap_or(true)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_line_count(&self) -> usize {
        self.line_offsets.len()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn read_line_chunk(&self, start_line: usize, count: usize) -> anyhow::Result<LineChunk> {
        if start_line >= self.line_offsets.len() {
            return Ok(LineChunk {
                content: String::new(),
                start_line,
                end_line: start_line,
                byte_start: self.size,
                byte_end: self.size,
            });
        }

        let end_line = std::cmp::min(start_line + count, self.line_offsets.len());

        let byte_start = self.line_offsets[start_line];
        let byte_end = if end_line < self.line_offsets.len() {
            self.line_offsets[end_line]
        } else {
            self.size
        };

        let bytes = self.read_bytes(byte_start, byte_end)?;
        let content = String::from_utf8_lossy(&bytes).into_owned();

        Ok(LineChunk {
            content,
            start_line,
            end_line,
            byte_start,
            byte_end,
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn read_line(&self, index: usize) -> anyhow::Result<String> {
        if index >= self.line_offsets.len() {
            return Ok(String::new());
        }

        let byte_start = self.line_offsets[index];
        let byte_end = if index + 1 < self.line_offsets.len() {
            self.line_offsets[index + 1]
        } else {
            self.size
        };

        let mut bytes = self.read_bytes(byte_start, byte_end)?;

        if bytes.last() == Some(&b'\n') {
            bytes.pop();
        }
        if bytes.last() == Some(&b'\r') {
            bytes.pop();
        }

        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn refresh(&mut self) -> anyhow::Result<()> {
        let (file, size, line_offsets, version) = FileBuffer::scan_file(&self.path)?;
        self.size = size;
        self.line_offsets = line_offsets;
        self.file = Mutex::new(file);
        self.version = version;
        Ok(())
    }
}

pub struct LineEdit {
    pub row: usize,
    pub lines: Vec<String>,
}

impl FileBuffer {
    #[flutter_rust_bridge::frb(sync)]
    pub fn save_edits(&mut self, edits: Vec<LineEdit>) -> anyhow::Result<()> {
        self.save_edits_impl(None, edits)
    }

    /// Write the edited document to a new path, rebinding this buffer to it.
    #[flutter_rust_bridge::frb(sync)]
    pub fn save_edits_as(&mut self, new_path: String, edits: Vec<LineEdit>) -> anyhow::Result<()> {
        self.save_edits_impl(Some(new_path), edits)
    }

    fn save_edits_impl(
        &mut self,
        new_path: Option<String>,
        edits: Vec<LineEdit>,
    ) -> anyhow::Result<()> {
        use std::io::Write;
        let mut edits_map = std::collections::HashMap::new();
        for edit in edits {
            edits_map.insert(edit.row, edit.lines);
        }

        let target = new_path.clone().unwrap_or_else(|| self.path.clone());
        let temp_path = format!("{}.tmp", target);
        {
            let mut file = std::io::BufWriter::new(std::fs::File::create(&temp_path)?);
            let total_lines = self.line_offsets.len();
            for i in 0..total_lines {
                if let Some(repl_lines) = edits_map.get(&i) {
                    for line in repl_lines {
                        file.write_all(line.as_bytes())?;
                        file.write_all(b"\n")?;
                    }
                } else {
                    let byte_start = self.line_offsets[i];
                    let byte_end = if i + 1 < self.line_offsets.len() {
                        self.line_offsets[i + 1]
                    } else {
                        self.size
                    };

                    if byte_end > byte_start {
                        let bytes = self.read_bytes(byte_start, byte_end)?;
                        if !bytes.is_empty() {
                            let mut end_idx = bytes.len();
                            if end_idx > 0 && bytes[end_idx - 1] == b'\n' {
                                end_idx -= 1;
                            }
                            if end_idx > 0 && bytes[end_idx - 1] == b'\r' {
                                end_idx -= 1;
                            }
                            file.write_all(&bytes[..end_idx])?;
                            if bytes.last() == Some(&b'\n') || i + 1 < total_lines {
                                file.write_all(b"\n")?;
                            }
                        }
                    } else if i + 1 < total_lines {
                        file.write_all(b"\n")?;
                    }
                }
            }
            file.flush()?;
        }

        std::fs::rename(&temp_path, &target)?;
        if let Some(p) = new_path {
            self.path = p;
        }
        self.refresh()?;
        Ok(())
    }
}

/// Copy arbitrary text to the system clipboard. Keeps clipboard access on the
/// Rust side (used by "Copy file name" / "Copy file path").
#[flutter_rust_bridge::frb(sync)]
pub fn copy_text_to_clipboard(text: String) -> anyhow::Result<()> {
    let mut ctx = arboard::Clipboard::new()
        .map_err(|e| anyhow::anyhow!("Failed to initialize clipboard: {}", e))?;
    ctx.set_text(text)
        .map_err(|e| anyhow::anyhow!("Failed to set clipboard text: {}", e))?;
    Ok(())
}

/// The final path component (file name with extension), e.g. `/a/b/c.txt` -> `c.txt`.
#[flutter_rust_bridge::frb(sync)]
pub fn base_name(path: String) -> String {
    match std::path::Path::new(&path).file_name() {
        Some(s) => s.to_string_lossy().into_owned(),
        None => path.clone(),
    }
}

pub async fn pick_file() -> Option<String> {
    rfd::AsyncFileDialog::new()
        .pick_file()
        .await
        .map(|f| f.path().to_string_lossy().to_string())
}

/// Save-as dialog. Returns the chosen path, or None if cancelled.
pub async fn pick_save_file(default_name: String) -> Option<String> {
    rfd::AsyncFileDialog::new()
        .set_file_name(&default_name)
        .save_file()
        .await
        .map(|f| f.path().to_string_lossy().to_string())
}
