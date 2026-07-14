use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

#[flutter_rust_bridge::frb(opaque)]
pub struct FileBuffer {
    pub size: usize,
    pub path: String,
    pub line_offsets: Vec<usize>,
}

impl FileBuffer {
    fn scan_file(path: &str) -> anyhow::Result<(usize, Vec<usize>)> {
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
        Ok((current_offset, line_offsets))
    }

    fn read_bytes(&self, start: usize, end: usize) -> anyhow::Result<Vec<u8>> {
        if start >= end {
            return Ok(Vec::new());
        }
        let mut file = File::open(&self.path)?;
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
        let (size, line_offsets) = FileBuffer::scan_file(&path)?;
        Ok(FileBuffer {
            size,
            path,
            line_offsets,
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_line_count(&self) -> usize {
        self.line_offsets.len()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn read_line_chunk(&self, start_line: usize, count: usize) -> anyhow::Result<LineChunk> {
        if start_line >= self.line_offsets.len() {
            return Ok(LineChunk { content: String::new(), start_line, end_line: start_line, byte_start: self.size, byte_end: self.size });
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
        let (size, line_offsets) = FileBuffer::scan_file(&self.path)?;
        self.size = size;
        self.line_offsets = line_offsets;
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

    fn save_edits_impl(&mut self, new_path: Option<String>, edits: Vec<LineEdit>) -> anyhow::Result<()> {
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
