//! Embedded runtime assets. This file lives at the package root so files under
//! web/ and migrations/ can be embedded without leaving the package path.
pub const css = @embedFile("web/style.css");
pub const migration_0001 = @embedFile("migrations/0001_init.sql");
pub const migration_0002 = @embedFile("migrations/0002_fts.sql");
pub const migration_0003 = @embedFile("migrations/0003_themes_files.sql");
