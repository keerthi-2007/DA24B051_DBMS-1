-- =====================================================================
-- ScrollSense — schema.sql
-- SQLite 3.44+ required (uses ORDER BY inside group_concat downstream,
-- window functions, and STRICT tables here).
-- =====================================================================

PRAGMA foreign_keys = ON;   -- SQLite ignores every declared FK without this.
PRAGMA journal_mode = WAL;  -- required for the G.3 concurrency demonstration.

-- ---------------------------------------------------------------------
-- Timestamp representation (E.1 bullet 7)
-- Choice: ISO-8601 UTC text, always 'YYYY-MM-DDTHH:MM:SSZ'.
-- Consequence: lexicographic ordering == chronological ordering, so
-- BETWEEN / < / > work directly (used everywhere, incl. F3's window and
-- F9/F10's julianday()-based frames). The cost is that julianday() must
-- wrap every timestamp column before arithmetic (F9 streaks, F10 rolling
-- windows) since TEXT has no native date arithmetic. Epoch integers would
-- give free arithmetic but unreadable data and no protection against
-- someone inserting a value in the wrong unit (seconds vs. ms) — this
-- schema takes the readability/consistency trade. Every table below uses
-- this one representation; none mix epoch and ISO-8601.
-- ---------------------------------------------------------------------

-- All tables are declared STRICT. Every column here uses only INTEGER,
-- REAL, or TEXT (the STRICT-legal set), so this costs nothing: no table
-- needed DATETIME or NVARCHAR(160)-style declarations that STRICT would
-- have rejected. DECIMAL columns from the conceptual design (confidence,
-- rates, watch_seconds) are declared REAL, since STRICT has no DECIMAL.
-- Booleans are INTEGER with a CHECK (col IN (0,1)), since STRICT/SQLite
-- has no native boolean.

-- =====================================================================
-- Identity & account layer
-- =====================================================================

CREATE TABLE users (
  user_id           TEXT PRIMARY KEY,
  current_handle    TEXT NOT NULL,
  normalized_handle TEXT NOT NULL,
  display_name      TEXT,                    -- NULL = user never set one
  CHECK (length(trim(current_handle)) > 0)
) STRICT;

-- Handle uniqueness (E.1 bullet 6).
-- Q1: does COLLATE NOCASE work for a Tamil handle? No — SQLite's built-in
--   NOCASE collation only folds ASCII A-Z/a-z. A Tamil (or any non-ASCII)
--   handle differing only by script-specific case would NOT be caught by
--   any COLLATE NOCASE constraint; normalized_handle must be populated by
--   application code doing a real Unicode case-fold before it ever reaches
--   this column, not left to SQLite's collation.
-- Q2: a single declarative UNIQUE (normalized_handle COLLATE NOCASE) was
--   deliberately NOT used here, because it would be the wrong rule, not
--   just an incomplete one: it would forbid handle *reuse* once an
--   account deactivates or is deleted, and the brief's rule is unique
--   among ACTIVE accounts, i.e. handles must be freed up for reuse once an
--   account leaves that set. That restriction cannot be expressed as a
--   partial UNIQUE index either, because "active" lives on accounts, a
--   different table, and SQLite's partial-index WHERE clause can only
--   reference columns of the table being indexed. So this half of the
--   rule is enforced procedurally instead, by the two triggers below,
--   which consult accounts.status at write time.

CREATE TABLE accounts (
  account_id             TEXT PRIMARY KEY,
  user_id                TEXT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE CASCADE,
  phone_number           TEXT,   -- NULL = registered via Google instead
  gmail_id               TEXT,   -- NULL = registered via phone instead
  status                 TEXT NOT NULL CHECK (status IN ('active','deactivated','pending_deletion')),
  deletion_requested_at  TEXT,   -- NULL = deletion never requested
  recovery_expires_at    TEXT,   -- NULL = not currently in the recovery window
  created_at             TEXT NOT NULL,
  CHECK (phone_number IS NOT NULL OR gmail_id IS NOT NULL),
  CHECK ( (status = 'pending_deletion') = (deletion_requested_at IS NOT NULL AND recovery_expires_at IS NOT NULL) ),
  CHECK (recovery_expires_at IS NULL OR deletion_requested_at IS NOT NULL),
  CHECK (recovery_expires_at IS NULL OR recovery_expires_at > deletion_requested_at)
) STRICT;

CREATE INDEX ix_accounts_status ON accounts(status);

-- Cross-table half of handle uniqueness: no two ACTIVE accounts may share
-- a normalized handle (case-insensitive, ASCII-only fold — see note above).
-- Enforced on accounts because "active" is a fact about an account, and
-- an account only becomes active by being inserted-as-active or updated
-- into 'active' — both are covered below. (A trigger on users cannot do
-- this: at the moment a user row is inserted, the matching account row
-- does not exist yet, so there is nothing to check status against.)
CREATE TRIGGER trg_accounts_handle_unique_ins
BEFORE INSERT ON accounts
FOR EACH ROW
WHEN NEW.status = 'active'
AND EXISTS (
  SELECT 1
  FROM users u2
  JOIN accounts a2 ON a2.user_id = u2.user_id
  WHERE a2.status = 'active'
    AND u2.normalized_handle = (SELECT normalized_handle FROM users WHERE user_id = NEW.user_id) COLLATE NOCASE
)
BEGIN
  SELECT RAISE(ABORT, 'activating this account would collide with an active handle');
END;

CREATE TRIGGER trg_accounts_handle_unique_upd
BEFORE UPDATE OF status ON accounts
FOR EACH ROW
WHEN NEW.status = 'active'
AND EXISTS (
  SELECT 1
  FROM users u2
  JOIN accounts a2 ON a2.user_id = u2.user_id
  WHERE a2.status = 'active'
    AND a2.account_id <> NEW.account_id
    AND u2.normalized_handle = (SELECT normalized_handle FROM users WHERE user_id = NEW.user_id) COLLATE NOCASE
)
BEGIN
  SELECT RAISE(ABORT, 'reactivating this account would collide with an active handle');
END;

-- A user changing their (already-active) handle must also be checked
-- against other active accounts' handles.
CREATE TRIGGER trg_users_handle_unique_upd
BEFORE UPDATE OF normalized_handle ON users
FOR EACH ROW
WHEN EXISTS (SELECT 1 FROM accounts a WHERE a.user_id = NEW.user_id AND a.status = 'active')
AND EXISTS (
  SELECT 1
  FROM users u
  JOIN accounts a ON a.user_id = u.user_id
  WHERE a.status = 'active'
    AND u.user_id <> NEW.user_id
    AND u.normalized_handle = NEW.normalized_handle COLLATE NOCASE
)
BEGIN
  SELECT RAISE(ABORT, 'handle already in use by an active account');
END;

-- Append-only handle history (B.2: validity intervals).
CREATE TABLE handle_history (
  user_id           TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  handle            TEXT NOT NULL,
  normalized_handle TEXT NOT NULL,
  valid_from        TEXT NOT NULL,
  valid_to          TEXT,   -- NULL = this is the current handle
  PRIMARY KEY (user_id, valid_from),
  CHECK (length(trim(handle)) > 0),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
) STRICT;

CREATE INDEX ix_handle_history_current ON handle_history(user_id) WHERE valid_to IS NULL;

-- Same overlap bug as A2/creator_tiers applies here: two handle_history
-- rows for one user must not have overlapping validity intervals.
CREATE TRIGGER trg_handle_history_no_overlap_ins
BEFORE INSERT ON handle_history
FOR EACH ROW
WHEN EXISTS (
  SELECT 1 FROM handle_history h
  WHERE h.user_id = NEW.user_id
    AND h.valid_from < COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(h.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from
)
BEGIN
  SELECT RAISE(ABORT, 'overlapping handle validity interval for this user');
END;

CREATE TRIGGER trg_handle_history_no_overlap_upd
BEFORE UPDATE OF user_id, valid_from, valid_to ON handle_history
FOR EACH ROW
WHEN EXISTS (
  SELECT 1
  FROM handle_history h
  WHERE h.user_id = NEW.user_id
    AND h.rowid <> OLD.rowid
    AND h.valid_from <
        COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(h.valid_to, '9999-12-31T23:59:59Z')
        > NEW.valid_from
)
BEGIN
  SELECT RAISE(
    ABORT,
    'overlapping handle validity interval for this user'
  );
END;

-- Twice-a-year handle-change rule (A/E.2 trace: "not declarative" —
-- enforced here by a trigger that counts rows opened in the last 365 days).
CREATE TRIGGER trg_handle_history_rate_limit
BEFORE INSERT ON handle_history
FOR EACH ROW
WHEN (
  SELECT COUNT(*) FROM handle_history h
  WHERE h.user_id = NEW.user_id
    AND h.valid_from > (SELECT strftime('%Y-%m-%dT%H:%M:%SZ', NEW.valid_from, '-365 days'))
    AND h.valid_from < NEW.valid_from
) >= 2
BEGIN
  SELECT RAISE(ABORT, 'handle changed more than twice in the trailing 365 days');
END;

-- =====================================================================
-- Interests
-- =====================================================================

CREATE TABLE interest_categories (
  category_id   INTEGER PRIMARY KEY,
  category_name TEXT NOT NULL UNIQUE,
  CHECK (length(trim(category_name)) > 0)
) STRICT;

CREATE TABLE user_interests (
  user_id      TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  category_id  INTEGER NOT NULL REFERENCES interest_categories(category_id) ON DELETE CASCADE,
  type         TEXT NOT NULL CHECK (type IN ('declared','inferred')),
  confidence   REAL,        -- NULL = not applicable (declared interests have no ML confidence)
  assigned_at  TEXT,        -- NULL = not recorded for legacy declared rows
  refreshed_at TEXT,        -- NULL = never refreshed (declared interests, or inferred pre-first-refresh)
  PRIMARY KEY (user_id, category_id, type, assigned_at),
  CHECK (type = 'declared'  OR confidence IS NOT NULL),
  CHECK (type = 'inferred'  OR confidence IS NULL),
  CHECK (confidence IS NULL OR confidence BETWEEN 0.0 AND 1.0)
) STRICT;

-- Suppression must survive future weekly refreshes of user_interests, so it
-- is deliberately a separate, independently-keyed table (B.3, decision 3).
CREATE TABLE interest_suppression (
  user_id       TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  category_id   INTEGER NOT NULL REFERENCES interest_categories(category_id) ON DELETE CASCADE,
  suppressed_at TEXT NOT NULL,
  PRIMARY KEY (user_id, category_id)
) STRICT;

-- =====================================================================
-- Creators & monetisation tiers
-- =====================================================================

CREATE TABLE creators (
  creator_id TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE RESTRICT
  -- RESTRICT, not CASCADE: a creator with videos/history must not vanish
  -- silently because the underlying user row was deleted.
) STRICT;

CREATE TABLE tiers (
  tier_id   INTEGER PRIMARY KEY,
  tier_name TEXT NOT NULL UNIQUE
) STRICT;

CREATE TABLE creator_tiers (
  creator_id TEXT NOT NULL REFERENCES creators(creator_id) ON DELETE CASCADE,
  tier_id    INTEGER NOT NULL REFERENCES tiers(tier_id) ON DELETE RESTRICT,
  valid_from TEXT NOT NULL,
  valid_to   TEXT,     -- NULL = current tier
  PRIMARY KEY (creator_id, valid_from),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
) STRICT;

CREATE INDEX ix_creator_tiers_current ON creator_tiers(creator_id) WHERE valid_to IS NULL;



-- A2: a creator's tier validity intervals must not overlap. A CHECK
-- (valid_to IS NULL OR valid_to > valid_from) only rules out a
-- backwards interval on ONE row; it says nothing about a second row for
-- the same creator whose interval overlaps the first (e.g. Gold
-- 10:00-20:00 and Silver 15:00-25:00). SQLite has no declarative
-- EXCLUDE constraint (unlike PostgreSQL), so this is enforced by a
-- trigger, treating an open (NULL) valid_to as +infinity via COALESCE
-- against a sentinel date far beyond this schema's horizon.
CREATE TRIGGER trg_creator_tiers_no_overlap_ins
BEFORE INSERT ON creator_tiers
FOR EACH ROW
WHEN EXISTS (
  SELECT 1 FROM creator_tiers ct
  WHERE ct.creator_id = NEW.creator_id
    AND ct.valid_from < COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(ct.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from
)
BEGIN
  SELECT RAISE(ABORT, 'overlapping tier validity interval for this creator');
END;

CREATE TRIGGER trg_creator_tiers_no_overlap_upd
BEFORE UPDATE OF creator_id, valid_from, valid_to
ON creator_tiers
FOR EACH ROW
WHEN EXISTS (
  SELECT 1 FROM creator_tiers ct
  WHERE ct.creator_id = NEW.creator_id
    AND ct.rowid <> OLD.rowid
    AND ct.valid_from < COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(ct.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from
)
BEGIN
  SELECT RAISE(ABORT, 'overlapping tier validity interval for this creator');
END;

-- =====================================================================
-- Videos, hashtags, audio
-- =====================================================================

-- videos.audio_track_id <-> audio_tracks.source_video_id is a genuine
-- cross-reference cycle: a video can point at a shared track, and that
-- track can point back at the video that originated it. SQLite has no
-- ALTER TABLE ... ADD CONSTRAINT, so one of the two FKs must be declared
-- DEFERRABLE INITIALLY DEFERRED and both tables must be created before
-- either FK is checked. audio_tracks is created first with its FK
-- deferred; videos is created second with its FK checked immediately
-- (a video is never inserted before its track exists, since the track
-- may pre-exist as "no track yet" via NULL).
--
-- Correction note: the original DBML sketch declared source_video_id as a
-- plain varchar column with NO `Ref:` line to videos.video_id — so this
-- FK was not actually in the diagram the schema is meant to formalise.
-- It is added here anyway, deliberately, because the brief's prose (2.2:
-- "a track is either original to some video ... or licensed from a
-- catalogue") requires an original track to be traceable to the specific
-- video that originated it — an unenforced varchar column would let that
-- fact rot into a dangling ID with no integrity check. This is flagged
-- explicitly rather than silently kept, since inventing a foreign key
-- because a column name looks like one, without checking the source
-- diagram or brief, would be exactly the kind of error this review is
-- for.
CREATE TABLE audio_tracks (
  audio_track_id      TEXT PRIMARY KEY,
  source_type         TEXT NOT NULL CHECK (source_type IN ('original','licensed')),
  source_video_id     TEXT REFERENCES videos(video_id) DEFERRABLE INITIALLY DEFERRED,
  catalogue_reference TEXT,
  CHECK (
  (source_type = 'original'
   AND source_video_id IS NOT NULL
   AND catalogue_reference IS NULL)
  OR
  (source_type = 'licensed'
   AND source_video_id IS NULL
   AND catalogue_reference IS NOT NULL)
)
) STRICT;

CREATE TABLE videos (
  video_id          TEXT PRIMARY KEY,
  creator_id        TEXT NOT NULL REFERENCES creators(creator_id) ON DELETE RESTRICT,
  duration_seconds  REAL NOT NULL CHECK (duration_seconds BETWEEN 20 AND 90),
  caption           TEXT,     -- NULL = no caption given
  audio_track_id    TEXT REFERENCES audio_tracks(audio_track_id) ON DELETE SET NULL,
  -- ON DELETE SET NULL: a track being removed from the catalogue should
  -- not delete the videos that used it.
  moderation_state  TEXT NOT NULL CHECK (moderation_state IN
                        ('pending','live','age_restricted','demoted','taken_down'))
) STRICT;

CREATE INDEX ix_videos_creator ON videos(creator_id);
CREATE INDEX ix_videos_moderation_state ON videos(moderation_state);

CREATE TABLE hashtags (
  hashtag_id         INTEGER PRIMARY KEY,
  hashtag_text       TEXT NOT NULL,
  normalized_hashtag TEXT NOT NULL UNIQUE,
  CHECK (length(trim(hashtag_text)) > 0)
) STRICT;

CREATE TABLE video_hashtags (
  video_id   TEXT NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
  hashtag_id INTEGER NOT NULL REFERENCES hashtags(hashtag_id) ON DELETE CASCADE,
  PRIMARY KEY (video_id, hashtag_id)
) STRICT;

-- Moderation history: append-only, current state also cached on videos
-- (B.3, decision 4). The two writes below (history insert + videos update)
-- are the T2 failure mode from transactions.sql.
CREATE TABLE moderation_decisions (
  decision_id      TEXT PRIMARY KEY,
  video_id         TEXT NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
  moderation_state TEXT NOT NULL CHECK (moderation_state IN
                       ('pending','live','age_restricted','demoted','taken_down')),
  decided_at       TEXT NOT NULL,
  source_type      TEXT NOT NULL CHECK (source_type IN ('automated','human')),
  source_id        TEXT   -- NULL only if a system default with no attributable actor
) STRICT;

CREATE INDEX ix_moderation_decisions_video_time ON moderation_decisions(video_id, decided_at);

-- =====================================================================
-- Social graph
-- =====================================================================

CREATE TABLE follows (
  follower_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  followed_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  started_at  TEXT NOT NULL,
  PRIMARY KEY (follower_id, followed_id),
  CHECK (follower_id <> followed_id)
) STRICT;

CREATE TABLE blocks (
  blocker_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  blocked_at TEXT NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
) STRICT;

-- A block must break any existing follow in both directions (brief 2.3).
-- Not expressible declaratively (it is a cross-table delete triggered by
-- an insert) — enforced here, and traced as "not declarative" in E.2.
CREATE TRIGGER trg_block_breaks_follows
AFTER INSERT ON blocks
FOR EACH ROW
BEGIN
  DELETE FROM follows
  WHERE (follower_id = NEW.blocker_id AND followed_id = NEW.blocked_id)
     OR (follower_id = NEW.blocked_id AND followed_id = NEW.blocker_id);
END;

CREATE TABLE mutes (
  muter_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  muted_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  muted_at TEXT NOT NULL,
  PRIMARY KEY (muter_id, muted_id),
  CHECK (muter_id <> muted_id)
) STRICT;

-- =====================================================================
-- Watch telemetry (highest volume tables)
-- =====================================================================

CREATE TABLE impressions (
  impression_id          TEXT PRIMARY KEY,
  user_id                TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  video_id               TEXT NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
  occurred_at            TEXT NOT NULL,
  feed_position          INTEGER NOT NULL CHECK (feed_position > 0),
  ranking_model_version  TEXT NOT NULL
) STRICT;

CREATE INDEX ix_impressions_user_time ON impressions(user_id, occurred_at);
CREATE INDEX ix_impressions_video_time ON impressions(video_id, occurred_at);

CREATE TABLE viewing_segments (
  segment_id     TEXT PRIMARY KEY,
  impression_id  TEXT NOT NULL REFERENCES impressions(impression_id) ON DELETE CASCADE,
  started_at     TEXT NOT NULL,
  ended_at       TEXT,      -- NULL = segment still open / never closed out
  watch_seconds  REAL NOT NULL CHECK (watch_seconds >= 0),
  reached_end    INTEGER NOT NULL CHECK (reached_end IN (0,1)),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
) STRICT;

CREATE INDEX ix_viewing_segments_impression ON viewing_segments(impression_id);

CREATE TABLE signals (
  signal_id          TEXT PRIMARY KEY,
  impression_id      TEXT REFERENCES impressions(impression_id) ON DELETE SET NULL,
  -- nullable: a signal can in principle be logged without a live
  -- impression row (e.g. from a notification), so this is "not
  -- applicable" rather than "not yet known".
  user_id            TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  video_id           TEXT NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
  signal_type        TEXT NOT NULL CHECK (signal_type IN
                         ('like','like_retraction','share','comment',
                          'follow_from_feed','not_interested','report')),
  -- 'save' is deliberately NOT a signal_type here — see the `saves` table
  -- below and the A3 note in Deliverable_E_Physical_Implementation.md.
  -- The other seven really are one-shot events with no "current state" of
  -- their own (a like's current state is a separate row, per A5/A6/B.3);
  -- a save is a toggleable state ("in the bin" / "not in the bin"), which
  -- is a different grain and does not belong in an append-only event log.
  occurred_at        TEXT NOT NULL,
  share_destination  TEXT CHECK (share_destination IS NULL OR share_destination IN
                         ('whatsapp','instagram','copied_link')),
  CHECK ( (signal_type = 'share') = (share_destination IS NOT NULL) )
) STRICT;

CREATE INDEX ix_signals_user_video_time ON signals(user_id, video_id, occurred_at);
CREATE INDEX ix_signals_video_type ON signals(video_id, signal_type);

-- A3: "a user can have at most one active save for a given clip." This is
-- current-state, toggleable, existence-only data — the row IS the fact
-- ("this clip is in this user's save bin"); there is nothing to log
-- repeatedly. That is a different grain from signals (one-shot events),
-- so it gets its own table rather than overloading signal_type='save':
-- the primary key itself enforces A3, with no CHECK needed.
CREATE TABLE saves (
  user_id  TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  video_id TEXT NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
  saved_at TEXT NOT NULL,
  PRIMARY KEY (user_id, video_id)
  -- Unsaving is a DELETE of this row, not a state flag — the clip is
  -- either currently in the bin (row present) or it isn't (row absent).
  -- A user's save *history* (saved, unsaved, re-saved) is out of scope
  -- per A3 as written; if that history is later needed, it becomes an
  -- append-only saves_log table alongside this one, on the same pattern
  -- as likes/retractions in signals, without changing this table's job.
) STRICT;

CREATE INDEX ix_saves_video ON saves(video_id);

-- =====================================================================
-- Agent layer
-- =====================================================================

CREATE TABLE sessions (
  session_id TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  started_at TEXT NOT NULL,
  ended_at   TEXT,   -- NULL = session still open
  CHECK (ended_at IS NULL OR ended_at >= started_at)
) STRICT;

CREATE TABLE turns (
  turn_id     TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  turn_number INTEGER NOT NULL CHECK (turn_number > 0),
  UNIQUE (session_id, turn_number)
) STRICT;

CREATE TABLE user_messages (
  message_id   TEXT PRIMARY KEY,
  turn_id      TEXT NOT NULL UNIQUE REFERENCES turns(turn_id) ON DELETE CASCADE,
  message_text TEXT NOT NULL,
  CHECK (length(trim(message_text)) > 0)
) STRICT;

CREATE TABLE prompt_templates (
  template_id   TEXT PRIMARY KEY,
  template_name TEXT NOT NULL UNIQUE
) STRICT;

CREATE TABLE prompt_versions (
  prompt_version_id TEXT PRIMARY KEY,
  template_id       TEXT NOT NULL REFERENCES prompt_templates(template_id) ON DELETE CASCADE,
  version_number    INTEGER NOT NULL CHECK (version_number > 0),
  template_text     TEXT NOT NULL,
  valid_from        TEXT NOT NULL,
  valid_to          TEXT,   -- NULL = current version
  UNIQUE (template_id, version_number),
  CHECK (length(trim(template_text)) > 0),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
) STRICT;

CREATE INDEX ix_prompt_versions_current ON prompt_versions(template_id) WHERE valid_to IS NULL;

-- Same overlap bug as A2: two versions of the same template must not
-- have overlapping validity intervals (a response must resolve to
-- exactly one template_text at its timestamp).
CREATE TRIGGER trg_prompt_versions_no_overlap_ins
BEFORE INSERT ON prompt_versions
FOR EACH ROW
WHEN EXISTS (
  SELECT 1 FROM prompt_versions pv
  WHERE pv.template_id = NEW.template_id
    AND pv.valid_from < COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(pv.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from
)
BEGIN
  SELECT RAISE(ABORT, 'overlapping validity interval for this template');
END;

CREATE TRIGGER trg_prompt_versions_no_overlap_upd
BEFORE UPDATE OF template_id, valid_from, valid_to ON prompt_versions
FOR EACH ROW
WHEN EXISTS (
  SELECT 1
  FROM prompt_versions pv
  WHERE pv.template_id = NEW.template_id
    AND pv.rowid <> OLD.rowid
    AND pv.valid_from <
        COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(pv.valid_to, '9999-12-31T23:59:59Z')
        > NEW.valid_from
)
BEGIN
  SELECT RAISE(
    ABORT,
    'overlapping validity interval for this template'
  );
END;

CREATE TABLE assistant_messages (
  message_id         TEXT PRIMARY KEY,
  turn_id            TEXT NOT NULL UNIQUE REFERENCES turns(turn_id) ON DELETE CASCADE,
  prompt_version_id  TEXT NOT NULL REFERENCES prompt_versions(prompt_version_id) ON DELETE RESTRICT,
  -- RESTRICT: a prompt version must never be deletable out from under a
  -- historical response that cites it exactly (brief 2.5).
  model_name         TEXT NOT NULL,
  temperature        REAL NOT NULL CHECK (temperature >= 0),
  message_text       TEXT NOT NULL,
  CHECK (length(trim(message_text)) > 0)
) STRICT;

CREATE TABLE tool_calls (
  tool_call_id          TEXT PRIMARY KEY,
  assistant_message_id  TEXT NOT NULL REFERENCES assistant_messages(message_id) ON DELETE CASCADE,
  parent_tool_call_id    TEXT REFERENCES tool_calls(tool_call_id) ON DELETE CASCADE,
  -- NULL parent = top-level call; self-referencing FK models arbitrary nesting depth.
  tool_name             TEXT NOT NULL,
  arguments             TEXT,   -- the one deliberate JSON column, see E.4 note below
  result                TEXT,   -- plain text; NOT validated as JSON (see E.4)
  latency_ms            INTEGER CHECK (latency_ms IS NULL OR latency_ms >= 0),
  errored               INTEGER NOT NULL CHECK (errored IN (0,1)),
  CHECK (length(trim(tool_name)) > 0),
  CHECK (arguments IS NULL OR json_valid(arguments))
) STRICT;

CREATE INDEX ix_tool_calls_parent ON tool_calls(parent_tool_call_id);
CREATE INDEX ix_tool_calls_assistant_message ON tool_calls(assistant_message_id);

-- ---------------------------------------------------------------------
-- E.4 — JSON usage note
-- tool_calls.arguments is the ONE column in this schema that holds JSON,
-- guarded by CHECK(json_valid(arguments)) and read with json_extract().
-- Justification: the argument shape genuinely differs per tool
-- (search_videos(query, filters) vs. fetch_trending_audio(region) vs.
-- get_user_history(days)) — there is no fixed column set to normalise
-- into, and a new tool must not require a migration. tool_calls.result is
-- deliberately left as plain, unchecked TEXT rather than a second JSON
-- column: some tool results are not JSON-shaped at all (free text), and
-- the brief caps JSON at one considered place, not "wherever payloads are
-- shapeless." What is lost by choosing JSON for arguments: no foreign key
-- can point into it (e.g. a video_id embedded in a search filter is
-- invisible to the FK graph and to ON DELETE CASCADE), and no CHECK can
-- constrain its interior (a malformed filter value is only caught, if at
-- all, by application code that calls json_extract() before use).
-- ---------------------------------------------------------------------

CREATE TABLE pricing (
  pricing_id         TEXT PRIMARY KEY,
  model_name         TEXT NOT NULL,
  valid_from         TEXT NOT NULL,
  valid_to           TEXT,    -- NULL = current price
  input_rate         REAL NOT NULL CHECK (input_rate >= 0),
  output_rate        REAL NOT NULL CHECK (output_rate >= 0),
  cached_input_rate  REAL NOT NULL CHECK (cached_input_rate >= 0),
  UNIQUE (model_name, valid_from),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
) STRICT;

CREATE INDEX ix_pricing_model_current ON pricing(model_name) WHERE valid_to IS NULL;

-- Same overlap bug as A2: two pricing periods for the same model must not
-- overlap, or token_usage's FK to a single pricing_id stops meaning "the
-- price in force at this turn."
CREATE TRIGGER trg_pricing_no_overlap_ins
BEFORE INSERT ON pricing
FOR EACH ROW
WHEN EXISTS (
  SELECT 1 FROM pricing p
  WHERE p.model_name = NEW.model_name
    AND p.valid_from < COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(p.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from
)
BEGIN
  SELECT RAISE(ABORT, 'overlapping pricing validity interval for this model');
END;

CREATE TRIGGER trg_pricing_no_overlap_upd
BEFORE UPDATE OF model_name, valid_from, valid_to ON pricing
FOR EACH ROW
WHEN EXISTS (
  SELECT 1
  FROM pricing p
  WHERE p.model_name = NEW.model_name
    AND p.rowid <> OLD.rowid
    AND p.valid_from <
        COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
    AND COALESCE(p.valid_to, '9999-12-31T23:59:59Z')
        > NEW.valid_from
)
BEGIN
  SELECT RAISE(
    ABORT,
    'overlapping pricing validity interval for this model'
  );
END;

-- token_usage stores the pricing_id it was billed against, so a later
-- price change can never move a historical turn's reported cost
-- (this is the schema consequence the brief points at in 2.5: the FK
-- must be to the immutable pricing ROW, never resolved live by
-- model_name + "current price").
CREATE TABLE token_usage (
  turn_id              TEXT PRIMARY KEY REFERENCES turns(turn_id) ON DELETE CASCADE,
  pricing_id           TEXT NOT NULL REFERENCES pricing(pricing_id) ON DELETE RESTRICT,
  input_tokens         INTEGER NOT NULL CHECK (input_tokens >= 0),
  output_tokens        INTEGER NOT NULL CHECK (output_tokens >= 0),
  cached_input_tokens  INTEGER NOT NULL CHECK (cached_input_tokens >= 0)
) STRICT;

CREATE TABLE judge_scores (
  judge_id      TEXT PRIMARY KEY,
  turn_id       TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
  helpfulness   REAL CHECK (helpfulness IS NULL OR helpfulness BETWEEN 0 AND 5),
  groundedness  REAL CHECK (groundedness IS NULL OR groundedness BETWEEN 0 AND 5),
  safety        REAL CHECK (safety IS NULL OR safety BETWEEN 0 AND 5),
  judged_at     TEXT NOT NULL
) STRICT;

CREATE INDEX ix_judge_scores_turn ON judge_scores(turn_id);

CREATE TABLE user_ratings (
  rating_id  TEXT PRIMARY KEY,
  turn_id    TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
  rating     TEXT NOT NULL CHECK (rating IN ('thumbs_up','thumbs_down')),
  rated_at   TEXT NOT NULL
) STRICT;

CREATE INDEX ix_user_ratings_turn ON user_ratings(turn_id);

CREATE TABLE recommendations (
  recommendation_id  TEXT PRIMARY KEY,
  turn_id            TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
  video_id           TEXT NOT NULL REFERENCES videos(video_id) ON DELETE RESTRICT,
  -- RESTRICT: a recommended clip's outcome must remain traceable even if
  -- the video is later taken down; a takedown changes moderation_state,
  -- it does not delete the row.
  position           INTEGER NOT NULL CHECK (position > 0),
  UNIQUE (turn_id, position),  -- one clip per shelf slot
  UNIQUE (turn_id, video_id)   -- A11: a clip appears at most once per shelf
) STRICT;

CREATE INDEX ix_recommendations_video ON recommendations(video_id);
