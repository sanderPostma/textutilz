//! Diesel table definitions for the textutilz session store. Kept at crate root
//! (outside `api/`) so flutter_rust_bridge does not scan the generated macro
//! internals. Tables are created at runtime via `CREATE TABLE IF NOT EXISTS`
//! (see `api::store`), so no diesel-CLI migrations are required.

diesel::table! {
    documents (id) {
        id -> Text,
        display_name -> Text,
        path -> Text,
        is_transient -> Integer,
        content_type -> Text,
        extension -> Text,
        auto_delete -> Text,
        view_mode -> Text,
        font_read -> Double,
        font_tail -> Double,
        font_edit -> Double,
        scratch_content -> Nullable<Text>,
        created_day -> BigInt,
        tab_order -> Integer,
        is_active -> Integer,
    }
}

diesel::table! {
    settings (key) {
        key -> Text,
        value -> Text,
    }
}
