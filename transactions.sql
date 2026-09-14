SELECT
    signal_id,
    user_id,
    video_id,
    occurred_at
FROM signals
WHERE signal_type = 'like'
LIMIT 1;

SELECT
    signal_id,
    user_id,
    video_id,
    signal_type,
    occurred_at
FROM signals
WHERE signal_id = 'sig_fc97f52a72bd';

ROLLBACK;

BEGIN TRANSACTION;

DELETE FROM signals
WHERE signal_id = 'sig_fc97f52a72bd';

-- Deliberate failure
INSERT INTO signals (
    signal_id,
    user_id,
    video_id,
    signal_type,
    occurred_at
)
VALUES (
    'sig_fc97f52a72bd',
    'u_c20815a04683',
    'v_0919f7e92130',
    'like_retraction',
    '2025-08-20T10:20:00Z'
);

SELECT signal_id, user_id, video_id, signal_type
FROM signals
WHERE signal_type = 'like'
LIMIT 2;

BEGIN TRANSACTION;

-- Step 1: remove the original like
DELETE FROM signals
WHERE signal_id = 'sig_fc97f52a72bd';

-- Step 2: deliberately fail using an existing signal_id
INSERT INTO signals (
    signal_id,
    user_id,
    video_id,
    signal_type,
    occurred_at
)
VALUES (
    'sig_67ebf7ea2d22',
    'u_c20815a04683',
    'v_0919f7e92130',
    'like_retraction',
    '2025-08-20T10:20:00Z'
);

SELECT *
FROM signals
WHERE signal_id = 'sig_fc97f52a72bd';

INSERT INTO signals (
    signal_id,
    user_id,
    video_id,
    signal_type,
    occurred_at
)
VALUES (
    'sig_67ebf7ea2d22',
    'u_c20815a04683',
    'v_0919f7e92130',
    'like_retraction',
    '2025-08-20T10:20:00Z'
);


SELECT
    signal_id,
    user_id,
    video_id,
    signal_type,
    occurred_at
FROM signals
WHERE user_id = 'u_c20815a04683'
  AND video_id = 'v_0919f7e92130'
  AND signal_type IN ('like', 'like_retraction')
ORDER BY occurred_at;

PRAGMA journal_mode;

SELECT *
FROM moderation_decisions
LIMIT 1;

BEGIN TRANSACTION;

INSERT INTO moderation_decisions (
    decision_id,
    video_id,
    moderation_state,
    decided_at,
    source_type
)
VALUES (
    'md_test_t2_001',
    'v_0e05d37991b8',
    'removed',
    '2026-09-14T15:00:00Z',
    'manual'
);