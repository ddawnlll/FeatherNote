-- FeatherNote schema v5: named checkpoints on immutable revisions.
--
-- A label is an annotation, not a new revision and not part of the content
-- checksum. Empty labels mean "not a checkpoint". The partial index keeps
-- checkpoint lookups cheap without indexing every revision row.
ALTER TABLE note_revisions ADD COLUMN label TEXT NOT NULL DEFAULT '' CHECK (length(label) <= 80);
CREATE INDEX note_revisions_checkpoint
    ON note_revisions(note_id, label) WHERE label <> '';
