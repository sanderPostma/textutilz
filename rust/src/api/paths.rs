//! OS-correct per-user storage locations for textutilz.
//!
//! All app data lives under `<data_dir>/textutilz`, where `<data_dir>` is the
//! platform standard (Linux `~/.local/share`, macOS `~/Library/Application
//! Support`, Windows `%APPDATA%`). Dart uses these helpers instead of building
//! paths from `$HOME`, keeping path logic on the Rust side.

use std::path::PathBuf;

/// `<data_dir>/textutilz`. Falls back to the system temp dir if no data dir is
/// known (headless/unusual environments).
pub(crate) fn base_dir() -> PathBuf {
    let mut dir = dirs::data_dir().unwrap_or_else(std::env::temp_dir);
    dir.push("textutilz");
    dir
}

/// Path to the SQLite database file, ensuring its parent exists.
pub(crate) fn db_path() -> anyhow::Result<String> {
    let dir = base_dir();
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join("textutilz.db").to_string_lossy().to_string())
}

/// The app data directory, created if missing.
#[flutter_rust_bridge::frb(sync)]
pub fn app_data_dir() -> anyhow::Result<String> {
    let dir = base_dir();
    std::fs::create_dir_all(&dir)?;
    Ok(dir.to_string_lossy().to_string())
}

/// The scratch directory for transient documents, created if missing.
#[flutter_rust_bridge::frb(sync)]
pub fn scratch_dir() -> anyhow::Result<String> {
    let mut dir = base_dir();
    dir.push("scratch");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.to_string_lossy().to_string())
}
