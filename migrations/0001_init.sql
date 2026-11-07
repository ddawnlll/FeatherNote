-- FeatherNote schema v1 (SQLite 3.54.1)
CREATE TABLE owner (
    id            INTEGER PRIMARY KEY CHECK (id = 1),
    password_hash TEXT    NOT NULL,
    created_at    INTEGER NOT NULL
);

CREATE TABLE sessions (
    token_hash   TEXT    PRIMARY KEY,
    owner_id     INTEGER NOT NULL REFERENCES owner(id) ON DELETE CASCADE,
    csrf_token   TEXT    NOT NULL,
    issued_at    INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL,
    revoked      INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1))
);
CREATE INDEX sessions_expiry ON sessions(expires_at);

CREATE TABLE notes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    title      TEXT    NOT NULL DEFAULT '',
    body       TEXT    NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    version    INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    is_pinned  INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
    deleted_at INTEGER
);
CREATE INDEX notes_active_order
    ON notes(deleted_at, is_pinned DESC, updated_at DESC, id DESC);
CREATE INDEX notes_trash_order
    ON notes(deleted_at, updated_at DESC, id DESC);
