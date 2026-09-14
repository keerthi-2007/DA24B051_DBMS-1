

PRAGMA foreign_keys = ON;   
PRAGMA journal_mode = WAL;  

CREATE TABLE users (
  user_id           TEXT PRIMARY KEY,
  current_handle    TEXT NOT NULL,
  normalized_handle TEXT NOT NULL,
  display_name      TEXT,                    
  CHECK (length(trim(current_handle)) > 0)
) STRICT;

CREATE TABLE accounts (
  account_id             TEXT PRIMARY KEY,
  user_id                TEXT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE CASCADE,
  phone_number           TEXT,  
  gmail_id               TEXT,   
  status                 TEXT NOT NULL CHECK (status IN ('active','deactivated','pending_deletion')),
  deletion_requested_at  TEXT,   
  recovery_expires_at    TEXT,   
  created_at             TEXT NOT NULL,
  CHECK (phone_number IS NOT NULL OR gmail_id IS NOT NULL),
  CHECK ( (status = 'pending_deletion') = (deletion_requested_at IS NOT NULL AND recovery_expires_at IS NOT NULL) ),
  CHECK (recovery_expires_at IS NULL OR deletion_requested_at IS NOT NULL),
  CHECK (recovery_expires_at IS NULL OR recovery_expires_at > deletion_requested_at)
) STRICT;

CREATE INDEX ix_accounts_status ON accounts(status);

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



CREATE TABLE interest_categories (
  category_id   INTEGER PRIMARY KEY,
  category_name TEXT NOT NULL UNIQUE,
  CHECK (length(trim(category_name)) > 0)
) STRICT;

CREATE TABLE user_interests (
  user_id      TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  category_id  INTEGER NOT NULL REFERENCES interest_categories(category_id) ON DELETE CASCADE,
  type         TEXT NOT NULL CHECK (type IN ('declared','inferred')),
  confidence   REAL,       
  assigned_at  TEXT,        
  refreshed_at TEXT,        
  PRIMARY KEY (user_id, category_id, type, assigned_at),
  CHECK (type = 'declared'  OR confidence IS NOT NULL),
  CHECK (type = 'inferred'  OR confidence IS NULL),
  CHECK (confidence IS NULL OR confidence BETWEEN 0.0 AND 1.0)
) STRICT;


CREATE TABLE interest_suppression (
  user_id       TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  category_id   INTEGER NOT NULL REFERENCES interest_categories(category_id) ON DELETE CASCADE,
  suppressed_at TEXT NOT NULL,
  PRIMARY KEY (user_id, category_id)
) STRICT;

CREATE TABLE creators (
  creator_id TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE RESTRICT
 
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
 
  user_id            TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  video_id           TEXT NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
  signal_type        TEXT NOT NULL CHECK (signal_type IN
                         ('like','like_retraction','share','comment',
                          'follow_from_feed','not_interested','report')),

  occurred_at        TEXT NOT NULL,
  share_destination  TEXT CHECK (share_destination IS NULL OR share_destination IN
                         ('whatsapp','instagram','copied_link')),
  CHECK ( (signal_type = 'share') = (share_destination IS NOT NULL) )
) STRICT;

CREATE INDEX ix_signals_user_video_time ON signals(user_id, video_id, occurred_at);
CREATE INDEX ix_signals_video_type ON signals(video_id, signal_type);

CREATE TABLE saves (
  user_id  TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  video_id TEXT NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
  saved_at TEXT NOT NULL,
  PRIMARY KEY (user_id, video_id)

) STRICT;

CREATE INDEX ix_saves_video ON saves(video_id);



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
  
  model_name         TEXT NOT NULL,
  temperature        REAL NOT NULL CHECK (temperature >= 0),
  message_text       TEXT NOT NULL,
  CHECK (length(trim(message_text)) > 0)
) STRICT;

CREATE TABLE tool_calls (
  tool_call_id          TEXT PRIMARY KEY,
  assistant_message_id  TEXT NOT NULL REFERENCES assistant_messages(message_id) ON DELETE CASCADE,
  parent_tool_call_id    TEXT REFERENCES tool_calls(tool_call_id) ON DELETE CASCADE,
  
  tool_name             TEXT NOT NULL,
  arguments             TEXT,   
  result                TEXT,  
  latency_ms            INTEGER CHECK (latency_ms IS NULL OR latency_ms >= 0),
  errored               INTEGER NOT NULL CHECK (errored IN (0,1)),
  CHECK (length(trim(tool_name)) > 0),
  CHECK (arguments IS NULL OR json_valid(arguments))
) STRICT;

CREATE INDEX ix_tool_calls_parent ON tool_calls(parent_tool_call_id);
CREATE INDEX ix_tool_calls_assistant_message ON tool_calls(assistant_message_id);



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

  position           INTEGER NOT NULL CHECK (position > 0),
  UNIQUE (turn_id, position),  
  UNIQUE (turn_id, video_id)   
) STRICT;

CREATE INDEX ix_recommendations_video ON recommendations(video_id);
