-- Sync truth: one row per finding the user has committed, tombstones included.
--
-- `received_at` is a per-user monotonic server clock, and it is what clients page on. It cannot be
-- `modified_at`: a finding created offline last week uploads today carrying last week's timestamp,
-- so a cursor over `modified_at` would place it behind a device's existing high-water mark and that
-- device would never see it. Receipt order is the only order every device agrees on.
CREATE TABLE finding (
  user_id     TEXT    NOT NULL,
  id          TEXT    NOT NULL,
  modified_at INTEGER NOT NULL,
  received_at INTEGER NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0,
  -- The immutable R2 revisions selected by this row.  Metadata is required for a live finding;
  -- image is nullable because clients upload it separately and metadata-only findings are valid.
  meta_revision  INTEGER,
  image_revision INTEGER,
  PRIMARY KEY (user_id, id)
);

CREATE INDEX finding_by_user_received ON finding (user_id, received_at);

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

-- Account-wide byte total. D1 meters rows read, so a SUM over every row on each upload is the
-- cost that would not stay cheap; one counter row is.
CREATE TABLE counter (
  key   TEXT    PRIMARY KEY,
  value INTEGER NOT NULL
);

-- Seeded here on purpose. A conditional `UPDATE counter ... WHERE key = 'global_bytes'` against a
-- missing row changes nothing and reports no error, so an unseeded counter would fail OPEN and the
-- global ceiling would never trip.
INSERT INTO counter (key, value) VALUES ('global_bytes', 0);
