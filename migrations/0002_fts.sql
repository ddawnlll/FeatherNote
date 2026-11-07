-- FeatherNote schema v2: FTS5 index for bounded full-text search.
-- External-content FTS keeps body text in notes only; triggers maintain the index.
CREATE VIRTUAL TABLE notes_fts USING fts5(
    title,
    body,
    content='notes',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);

INSERT INTO notes_fts(rowid, title, body) SELECT id, title, body FROM notes;

CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;

CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body)
    VALUES ('delete', old.id, old.title, old.body);
END;

CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body)
    VALUES ('delete', old.id, old.title, old.body);
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
