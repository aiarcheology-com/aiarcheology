-- Immutable revisions for finding storage (AIA-0753, AIA-0754).
--
-- WHY THIS IS A MIGRATION AND NOT AN EDIT TO 0001. The revisioned schema first shipped by rewriting
-- `0001_init.sql` in place. That cannot work: wrangler records applied migrations by FILENAME in
-- each database's `d1_migrations` table and stores no content hash, so a rewritten 0001 is silently
-- skipped everywhere it has already run. Both live databases had already run it --
-- staging 2026-08-25, production 2026-08-26 -- and the new code would have met a schema with no
-- `finding_revision` table and no `object_bytes.revision`, failing every findings route with
-- "no such column". The rewrite is reverted; the schema change lives here, where it runs exactly
-- once per database and lands fresh and existing databases on the same shape.
--
-- WHAT IS DISCARDED, AND WHY THAT IS SAFE HERE. `objectKey()` now addresses
-- `findings/<user>/<finding>/<revision>/<kind>`; every object written before this migration lives at
-- the unrevisioned key and no revision value can name it. Carrying those rows forward would publish
-- index rows pointing at keys that 404 on read, so the pre-revision sync and storage state is
-- cleared instead. That is a deliberate one-time reset, sound only because no release has shipped
-- cloud sync: both databases held a single acceptance-pass finding each. It must not be repeated
-- once real findings exist.
--
-- WHAT SURVIVES. `user_state` is untouched: it carries the account-deletion fences (0002), which
-- are write-once, never cleared, and the reason a purge cannot be outrun by an in-flight upload.
-- Dropping them would silently reopen that hole for every account already erased.
--
-- R2 IS NOT TOUCHED BY THIS FILE. Objects under the old key layout become strays that no reaper
-- enumerates, because both reapers iterate `object_bytes`. They are erasable by account purge
-- (which deletes by prefix) and are otherwise reclaimed by hand -- see PROVISIONING.md.

-- The immutable R2 revisions selected by this row. Metadata is required for a live finding; image
-- is nullable because clients upload it separately and metadata-only findings are valid.
ALTER TABLE finding ADD COLUMN meta_revision INTEGER;
ALTER TABLE finding ADD COLUMN image_revision INTEGER;

-- Unreachable under the revisioned key layout (see above). Tombstones go too: a tombstone's only
-- job is to tell other devices about a delete, and no device has ever synced from these rows.
DELETE FROM finding;

-- A future-dated client revision is clamped once, when first seen. Retaining that mapping makes a
-- lost-response retry use the same last-write-wins value rather than becoming newer merely because
-- it arrived later. Ordinary revisions need no row: their timestamp is already deterministic.
CREATE TABLE finding_revision (
  user_id    TEXT    NOT NULL,
  finding_id TEXT    NOT NULL,
  revision   INTEGER NOT NULL,
  lww_at     INTEGER NOT NULL,
  PRIMARY KEY (user_id, finding_id, revision)
);

CREATE INDEX finding_revision_by_user ON finding_revision (user_id);

-- `object_bytes` gains `revision` in its primary key, so it is rebuilt rather than altered. Dropping
-- the table drops its indexes with it.
DROP TABLE object_bytes;

-- Storage truth, deliberately separate from sync truth. Each immutable R2 object has one row.
-- An image uploaded whose meta never commits leaves no `finding` row, but it does occupy bytes --
-- counting here rather than off the index is what stops an abandoned upload from being free
-- storage. `created_at` bounds that reservation; `reaping_at` is a cleanup lease.
CREATE TABLE object_bytes (
  user_id    TEXT    NOT NULL,
  finding_id TEXT    NOT NULL,
  revision   INTEGER NOT NULL,
  kind       TEXT    NOT NULL,
  bytes      INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  reaping_at INTEGER,
  reaping_token TEXT,
  PRIMARY KEY (user_id, finding_id, revision, kind)
);

CREATE INDEX object_bytes_by_user ON object_bytes (user_id);
CREATE INDEX object_bytes_reapable ON object_bytes (created_at) WHERE reaping_at IS NULL;

-- Per-user totals are a cache derived from `object_bytes`, which is now empty, so every one of them
-- is stale. They are deleted rather than zeroed: `RECOMPUTE_GLOBAL` sums `user:%` rows, and a
-- lingering zero row for a user who never returns is a row summed forever for nothing.
DELETE FROM counter WHERE key LIKE 'user:%';

-- `global_bytes` is updated, never inserted, by the same reasoning 0001 gives for seeding it: a
-- conditional UPDATE against a missing row changes nothing and reports no error, so an absent
-- counter would fail OPEN and the global ceiling would never trip.
UPDATE counter SET value = 0 WHERE key = 'global_bytes';
