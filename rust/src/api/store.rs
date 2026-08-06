//! Rust-owned session persistence for textutilz, backed by SQLite via Diesel.
//!
//! The store is the single source of truth for what tabs to restore on the next
//! launch. Transient (scratch) documents keep their *content* here so they
//! survive restarts; real opened files store only their path + view state (never
//! duplicating potentially huge mmap'd files into the DB). Auto-delete governs
//! cleanup, not restorability — see the design spec.

use std::sync::Mutex;

use diesel::prelude::*;
use diesel::sqlite::SqliteConnection;

use crate::schema::{documents, settings};

/// A persisted tab, mirrored across the frb boundary. Dart builds these from its
/// tab list; `scratch_content` is `Some` only for transient documents.
pub struct DocRecord {
    pub id: String,
    pub display_name: String,
    pub path: String,
    pub is_transient: bool,
    pub content_type: String,
    pub extension: String,
    /// One of "off" | "onAppClose" | "atMidnight" (matches the Dart enum name).
    pub auto_delete: String,
    pub view_mode: String,
    pub font_read: f64,
    pub font_tail: f64,
    pub font_edit: f64,
    pub scratch_content: Option<String>,
    /// Epoch day the doc was created (for the atMidnight purge). 0 for real files.
    pub created_day: i64,
    pub tab_order: i32,
    pub is_active: bool,
    /// Rows the user has collapsed, as fold start rows. Stored as one text
    /// column; see [`join_rows`].
    pub collapsed_folds: Vec<u32>,
    /// The format the user pinned this document to, or `None` to let detection
    /// decide. Persisted as the language's stable id, empty for `None`.
    pub language_override: Option<crate::api::structured::StructuredLanguage>,
}

/// Diesel row for the `documents` table. Booleans are stored as INTEGER; this
/// struct is the DB shape, `DocRecord` is the frb-facing shape.
#[derive(Queryable, Insertable)]
#[diesel(table_name = documents)]
struct DocRow {
    id: String,
    display_name: String,
    path: String,
    is_transient: i32,
    content_type: String,
    extension: String,
    auto_delete: String,
    view_mode: String,
    font_read: f64,
    font_tail: f64,
    font_edit: f64,
    scratch_content: Option<String>,
    created_day: i64,
    tab_order: i32,
    is_active: i32,
    collapsed_folds: String,
    language_override: String,
}

impl From<&DocRecord> for DocRow {
    fn from(r: &DocRecord) -> Self {
        DocRow {
            id: r.id.clone(),
            display_name: r.display_name.clone(),
            path: r.path.clone(),
            is_transient: r.is_transient as i32,
            content_type: r.content_type.clone(),
            extension: r.extension.clone(),
            auto_delete: r.auto_delete.clone(),
            view_mode: r.view_mode.clone(),
            font_read: r.font_read,
            font_tail: r.font_tail,
            font_edit: r.font_edit,
            scratch_content: r.scratch_content.clone(),
            created_day: r.created_day,
            tab_order: r.tab_order,
            is_active: r.is_active as i32,
            collapsed_folds: join_rows(&r.collapsed_folds),
            language_override: r
                .language_override
                .map(crate::api::structured::structured_language_id)
                .unwrap_or_default(),
        }
    }
}

impl From<DocRow> for DocRecord {
    fn from(r: DocRow) -> Self {
        DocRecord {
            id: r.id,
            display_name: r.display_name,
            path: r.path,
            is_transient: r.is_transient != 0,
            content_type: r.content_type,
            extension: r.extension,
            auto_delete: r.auto_delete,
            view_mode: r.view_mode,
            font_read: r.font_read,
            font_tail: r.font_tail,
            font_edit: r.font_edit,
            scratch_content: r.scratch_content,
            created_day: r.created_day,
            tab_order: r.tab_order,
            is_active: r.is_active != 0,
            collapsed_folds: split_rows(&r.collapsed_folds),
            language_override: crate::api::structured::structured_language_from_id(
                r.language_override,
            ),
        }
    }
}

/// Row numbers as one comma-separated field. The schema has no list column and
/// no JSON blob anywhere, and a set of small integers does not earn a table of
/// its own — it is only ever read and written whole, with the document.
fn join_rows(rows: &[u32]) -> String {
    rows.iter()
        .map(|r| r.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

/// The inverse. Anything unparseable is dropped rather than failing the load:
/// a mangled fold list must not cost the user the whole session, and a missing
/// collapse is invisible.
fn split_rows(text: &str) -> Vec<u32> {
    text.split(',').filter_map(|p| p.trim().parse().ok()).collect()
}

const CREATE_DOCUMENTS: &str = "CREATE TABLE IF NOT EXISTS documents (\
    id TEXT PRIMARY KEY NOT NULL,\
    display_name TEXT NOT NULL,\
    path TEXT NOT NULL,\
    is_transient INTEGER NOT NULL,\
    content_type TEXT NOT NULL,\
    extension TEXT NOT NULL,\
    auto_delete TEXT NOT NULL,\
    view_mode TEXT NOT NULL,\
    font_read DOUBLE NOT NULL,\
    font_tail DOUBLE NOT NULL,\
    font_edit DOUBLE NOT NULL,\
    scratch_content TEXT,\
    created_day BIGINT NOT NULL,\
    tab_order INTEGER NOT NULL,\
    is_active INTEGER NOT NULL,\
    collapsed_folds TEXT NOT NULL DEFAULT '',\
    language_override TEXT NOT NULL DEFAULT ''\
)";

/// Create the tables if they are missing, then bring an existing database up
/// to the current shape.
///
/// The second half is the part that is easy to forget. `CREATE TABLE IF NOT
/// EXISTS` is a no-op on a database that already exists, so a column added to
/// [`CREATE_DOCUMENTS`] never appears on anyone's existing store — and
/// `load_session` then fails with "no such column", which Dart reports only as
/// a debug print, silently costing the user every tab. **A column added to the
/// DDL above must be added to the `ensure_column` list below in the same
/// change.**
fn init_schema(conn: &mut SqliteConnection) -> anyhow::Result<()> {
    diesel::sql_query(CREATE_DOCUMENTS).execute(conn)?;
    diesel::sql_query(CREATE_SETTINGS).execute(conn)?;
    ensure_column(conn, "documents", "collapsed_folds", "TEXT NOT NULL DEFAULT ''")?;
    ensure_column(conn, "documents", "language_override", "TEXT NOT NULL DEFAULT ''")?;
    Ok(())
}

/// Add a column unless it is already there.
///
/// SQLite has no `ADD COLUMN IF NOT EXISTS`, so the existing case is detected
/// from the error it raises. That wording is part of SQLite's stable
/// user-facing error set; the alternative, a `PRAGMA table_info` round trip,
/// needs a `QueryableByName` struct in this file, which the frb generator would
/// then try to mirror across the bridge as a wire type.
fn ensure_column(
    conn: &mut SqliteConnection,
    table: &str,
    column: &str,
    decl: &str,
) -> anyhow::Result<()> {
    let sql = format!("ALTER TABLE {table} ADD COLUMN {column} {decl}");
    match diesel::sql_query(sql).execute(conn) {
        Ok(_) => Ok(()),
        Err(e) if e.to_string().contains("duplicate column name") => Ok(()),
        Err(e) => Err(e.into()),
    }
}

const CREATE_SETTINGS: &str = "CREATE TABLE IF NOT EXISTS settings (\
    key TEXT PRIMARY KEY NOT NULL,\
    value TEXT NOT NULL\
)";

/// The session store. Holds an owned SQLite connection; methods take `&mut self`
/// like [`crate::api::edit_session::EditSession`]. The connection lives behind a
/// [`Mutex`] purely so the frb opaque wrapper's `Sync` bound is satisfied
/// (`SqliteConnection` is `Send` but not `Sync`); every method takes `&mut self`,
/// so access uses `get_mut()` with no locking cost.
#[flutter_rust_bridge::frb(opaque)]
pub struct AppStore {
    conn: Mutex<SqliteConnection>,
}

impl AppStore {
    /// Open (creating if needed) the store at the OS-correct data location and
    /// ensure the schema exists.
    #[flutter_rust_bridge::frb(sync)]
    pub fn open() -> anyhow::Result<AppStore> {
        let path = crate::api::paths::db_path()?;
        let mut conn = SqliteConnection::establish(&path)?;
        init_schema(&mut conn)?;
        Ok(AppStore {
            conn: Mutex::new(conn),
        })
    }

    /// Exclusive access to the connection. Cheap because `&mut self` guarantees
    /// no other borrow exists.
    fn c(&mut self) -> &mut SqliteConnection {
        self.conn.get_mut().expect("db mutex poisoned")
    }

    /// Replace the whole persisted tab set with `docs`, in the given order. The
    /// caller passes exactly the tabs it wants restored next launch (e.g.
    /// excluding onAppClose docs at shutdown).
    #[flutter_rust_bridge::frb(sync)]
    pub fn save_session(&mut self, docs: Vec<DocRecord>) -> anyhow::Result<()> {
        self.c().transaction::<(), anyhow::Error, _>(|conn| {
            diesel::delete(documents::table).execute(conn)?;
            for rec in &docs {
                let row = DocRow::from(rec);
                diesel::insert_into(documents::table)
                    .values(&row)
                    .execute(conn)?;
            }
            Ok(())
        })
    }

    /// Load the persisted tabs in tab order, after purging any atMidnight docs
    /// whose creation day is before `today_epoch_day` (a midnight has passed).
    #[flutter_rust_bridge::frb(sync)]
    pub fn load_session(&mut self, today_epoch_day: i64) -> anyhow::Result<Vec<DocRecord>> {
        diesel::delete(
            documents::table.filter(
                documents::auto_delete
                    .eq("atMidnight")
                    .and(documents::created_day.lt(today_epoch_day)),
            ),
        )
        .execute(self.c())?;

        let rows: Vec<DocRow> = documents::table
            .order(documents::tab_order.asc())
            .load(self.c())?;
        Ok(rows.into_iter().map(DocRecord::from).collect())
    }

    /// Fetch a setting value, or None if unset.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_setting(&mut self, key: String) -> anyhow::Result<Option<String>> {
        let value = settings::table
            .filter(settings::key.eq(&key))
            .select(settings::value)
            .first::<String>(self.c())
            .optional()?;
        Ok(value)
    }

    /// Upsert a setting value.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_setting(&mut self, key: String, value: String) -> anyhow::Result<()> {
        diesel::insert_into(settings::table)
            .values((settings::key.eq(&key), settings::value.eq(&value)))
            .on_conflict(settings::key)
            .do_update()
            .set(settings::value.eq(&value))
            .execute(self.c())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::structured::StructuredLanguage;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    /// An AppStore over a unique temp DB file.
    fn store() -> AppStore {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir()
            .join(format!("textutilz_store_{}_{}.db", std::process::id(), n))
            .to_string_lossy()
            .to_string();
        let mut conn = SqliteConnection::establish(&path).unwrap();
        // The same path `open()` takes, so a schema change cannot pass the
        // tests while breaking the real store.
        init_schema(&mut conn).unwrap();
        AppStore {
            conn: Mutex::new(conn),
        }
    }

    /// A temp DB path nobody else in this run will use.
    fn temp_db() -> String {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        std::env::temp_dir()
            .join(format!("textutilz_store_{}_{}.db", std::process::id(), n))
            .to_string_lossy()
            .to_string()
    }

    /// The `documents` table exactly as it shipped before `collapsed_folds`.
    const CREATE_DOCUMENTS_V1: &str = "CREATE TABLE IF NOT EXISTS documents (\
        id TEXT PRIMARY KEY NOT NULL,\
        display_name TEXT NOT NULL,\
        path TEXT NOT NULL,\
        is_transient INTEGER NOT NULL,\
        content_type TEXT NOT NULL,\
        extension TEXT NOT NULL,\
        auto_delete TEXT NOT NULL,\
        view_mode TEXT NOT NULL,\
        font_read DOUBLE NOT NULL,\
        font_tail DOUBLE NOT NULL,\
        font_edit DOUBLE NOT NULL,\
        scratch_content TEXT,\
        created_day BIGINT NOT NULL,\
        tab_order INTEGER NOT NULL,\
        is_active INTEGER NOT NULL\
    )";

    #[test]
    fn collapsed_rows_survive_a_save_and_load() {
        let mut s = store();
        let mut d = rec("a", 0, "off", 0);
        d.collapsed_folds = vec![1, 4, 90];
        s.save_session(vec![d]).unwrap();
        let back = s.load_session(0).unwrap();
        assert_eq!(back[0].collapsed_folds, vec![1, 4, 90]);
    }

    #[test]
    fn no_collapsed_rows_round_trips_as_empty_not_as_zero() {
        // `"".split(',')` yields one empty piece, so a naive parse would read
        // an unfolded document back as a collapse on row 0.
        let mut s = store();
        s.save_session(vec![rec("a", 0, "off", 0)]).unwrap();
        assert!(s.load_session(0).unwrap()[0].collapsed_folds.is_empty());
    }

    #[test]
    fn a_database_from_before_the_column_still_loads() {
        // The real upgrade path: `CREATE TABLE IF NOT EXISTS` will not touch
        // this table, so without `ensure_column` every query naming
        // `collapsed_folds` fails and the whole session is lost.
        let path = temp_db();
        let mut conn = SqliteConnection::establish(&path).unwrap();
        diesel::sql_query(CREATE_DOCUMENTS_V1)
            .execute(&mut conn)
            .unwrap();
        diesel::sql_query(CREATE_SETTINGS).execute(&mut conn).unwrap();
        drop(conn);

        let mut conn = SqliteConnection::establish(&path).unwrap();
        init_schema(&mut conn).unwrap();
        let mut s = AppStore {
            conn: Mutex::new(conn),
        };
        s.save_session(vec![rec("a", 0, "off", 0)]).unwrap();
        assert_eq!(s.load_session(0).unwrap().len(), 1);
    }

    /// The `documents` table as it shipped *with* `collapsed_folds` but before
    /// `language_override` — i.e. what is on disk for anyone running the
    /// current build. `CREATE_DOCUMENTS_V1` proves the first upgrade still
    /// works; this proves the second one does, from the state users are
    /// actually in.
    const CREATE_DOCUMENTS_V2: &str = "CREATE TABLE IF NOT EXISTS documents (\
        id TEXT PRIMARY KEY NOT NULL,\
        display_name TEXT NOT NULL,\
        path TEXT NOT NULL,\
        is_transient INTEGER NOT NULL,\
        content_type TEXT NOT NULL,\
        extension TEXT NOT NULL,\
        auto_delete TEXT NOT NULL,\
        view_mode TEXT NOT NULL,\
        font_read DOUBLE NOT NULL,\
        font_tail DOUBLE NOT NULL,\
        font_edit DOUBLE NOT NULL,\
        scratch_content TEXT,\
        created_day BIGINT NOT NULL,\
        tab_order INTEGER NOT NULL,\
        is_active INTEGER NOT NULL,\
        collapsed_folds TEXT NOT NULL DEFAULT ''\
    )";

    #[test]
    fn a_database_from_before_the_language_column_still_loads() {
        let path = temp_db();
        let mut conn = SqliteConnection::establish(&path).unwrap();
        diesel::sql_query(CREATE_DOCUMENTS_V2)
            .execute(&mut conn)
            .unwrap();
        diesel::sql_query(CREATE_SETTINGS).execute(&mut conn).unwrap();
        drop(conn);

        let mut conn = SqliteConnection::establish(&path).unwrap();
        init_schema(&mut conn).unwrap();
        let mut s = AppStore {
            conn: Mutex::new(conn),
        };
        s.save_session(vec![rec("a", 0, "off", 0)]).unwrap();
        let back = s.load_session(0).unwrap();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].language_override, None);
    }

    #[test]
    fn a_pinned_language_survives_a_save_and_load() {
        let mut s = store();
        let mut d = rec("a", 0, "off", 0);
        d.language_override = Some(StructuredLanguage::Json5);
        s.save_session(vec![d]).unwrap();
        assert_eq!(
            s.load_session(0).unwrap()[0].language_override,
            Some(StructuredLanguage::Json5)
        );
    }

    #[test]
    fn pinning_plain_text_round_trips_as_a_pin_not_as_no_pin() {
        // The empty string means "no pin", so plain text needs an id of its own
        // — otherwise "stop colouring this document" would not survive a
        // restart, which is exactly when the user would notice.
        let mut s = store();
        let mut d = rec("a", 0, "off", 0);
        d.language_override = Some(StructuredLanguage::PlainText);
        s.save_session(vec![d]).unwrap();
        assert_eq!(
            s.load_session(0).unwrap()[0].language_override,
            Some(StructuredLanguage::PlainText)
        );
    }

    #[test]
    fn no_pin_round_trips_as_none() {
        let mut s = store();
        s.save_session(vec![rec("a", 0, "off", 0)]).unwrap();
        assert_eq!(s.load_session(0).unwrap()[0].language_override, None);
    }

    #[test]
    fn a_language_id_this_build_does_not_know_falls_back_to_detection() {
        // Written by a newer build, or corrupted. Dropping to automatic
        // detection costs the user a preference; failing the load costs them
        // every tab.
        let mut s = store();
        s.save_session(vec![rec("a", 0, "off", 0)]).unwrap();
        {
            let mut conn = s.conn.lock().unwrap();
            diesel::sql_query("UPDATE documents SET language_override = 'toml'")
                .execute(&mut *conn)
                .unwrap();
        }
        assert_eq!(s.load_session(0).unwrap()[0].language_override, None);
    }

    #[test]
    fn opening_an_up_to_date_database_again_is_a_no_op() {
        let path = temp_db();
        for _ in 0..3 {
            let mut conn = SqliteConnection::establish(&path).unwrap();
            init_schema(&mut conn).unwrap();
        }
        let mut conn = SqliteConnection::establish(&path).unwrap();
        init_schema(&mut conn).unwrap();
        let mut s = AppStore {
            conn: Mutex::new(conn),
        };
        s.save_session(vec![rec("a", 0, "off", 0)]).unwrap();
        assert_eq!(s.load_session(0).unwrap().len(), 1);
    }

    fn rec(id: &str, order: i32, auto: &str, created_day: i64) -> DocRecord {
        DocRecord {
            id: id.to_string(),
            display_name: format!("doc {id}"),
            path: format!("/tmp/{id}.txt"),
            is_transient: auto != "off",
            content_type: "Plain Text".to_string(),
            extension: "txt".to_string(),
            auto_delete: auto.to_string(),
            view_mode: "Edit".to_string(),
            font_read: 14.0,
            font_tail: 14.0,
            font_edit: 16.0,
            scratch_content: if auto == "off" {
                None
            } else {
                Some(format!("body {id}"))
            },
            created_day,
            tab_order: order,
            is_active: order == 0,
            collapsed_folds: Vec::new(),
            language_override: None,
        }
    }

    #[test]
    fn round_trips_in_tab_order() {
        let mut s = store();
        s.save_session(vec![rec("b", 1, "off", 0), rec("a", 0, "off", 0)])
            .unwrap();
        let loaded = s.load_session(100).unwrap();
        assert_eq!(loaded.len(), 2);
        // Ordered by tab_order, not insertion order.
        assert_eq!(loaded[0].id, "a");
        assert_eq!(loaded[1].id, "b");
        assert!(loaded[0].is_active);
        assert_eq!(loaded[0].font_edit, 16.0);
    }

    #[test]
    fn save_session_replaces_all() {
        let mut s = store();
        s.save_session(vec![rec("a", 0, "off", 0), rec("b", 1, "off", 0)])
            .unwrap();
        s.save_session(vec![rec("c", 0, "off", 0)]).unwrap();
        let loaded = s.load_session(100).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id, "c");
    }

    #[test]
    fn scratch_content_persists_for_transient() {
        let mut s = store();
        s.save_session(vec![rec("scratch", 0, "onAppClose", 5)])
            .unwrap();
        let loaded = s.load_session(100).unwrap();
        assert!(loaded[0].is_transient);
        assert_eq!(loaded[0].scratch_content.as_deref(), Some("body scratch"));
    }

    #[test]
    fn at_midnight_purged_after_midnight() {
        let mut s = store();
        // Created on day 5.
        s.save_session(vec![
            rec("keep", 0, "off", 0),
            rec("expire", 1, "atMidnight", 5),
            rec("fresh", 2, "atMidnight", 10),
        ])
        .unwrap();
        // Today is day 10: the day-5 atMidnight doc is purged; day-10 survives.
        let loaded = s.load_session(10).unwrap();
        let ids: Vec<&str> = loaded.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, vec!["keep", "fresh"]);
    }

    #[test]
    fn settings_get_set_upsert() {
        let mut s = store();
        assert_eq!(s.get_setting("theme_mode".to_string()).unwrap(), None);
        s.set_setting("theme_mode".to_string(), "dark".to_string())
            .unwrap();
        assert_eq!(
            s.get_setting("theme_mode".to_string()).unwrap().as_deref(),
            Some("dark")
        );
        // Upsert overwrites.
        s.set_setting("theme_mode".to_string(), "light".to_string())
            .unwrap();
        assert_eq!(
            s.get_setting("theme_mode".to_string()).unwrap().as_deref(),
            Some("light")
        );
    }
}
