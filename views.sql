SELECT status, COUNT(*) AS count
FROM accounts
GROUP BY status;

CREATE VIEW v_public_profile AS
SELECT
    u.user_id,
    u.current_handle AS handle,
    u.display_name,
    COUNT(f.follower_id) AS follower_count
FROM users AS u
JOIN accounts AS a
    ON a.user_id = u.user_id
LEFT JOIN follows AS f
    ON f.followed_id = u.user_id
WHERE a.status = 'active'
GROUP BY
    u.user_id,
    u.current_handle,
    u.display_name;

SELECT *
FROM v_public_profile
LIMIT 10;

SELECT COUNT(*) AS rows_in_view
FROM v_public_profile;

SELECT COUNT(*) AS active_accounts
FROM accounts
WHERE status = 'active';

CREATE VIEW v_video_current_state AS
SELECT
    md.video_id,
    md.moderation_state AS current_moderation_state
FROM moderation_decisions AS md
WHERE md.decided_at = (
    SELECT MAX(md2.decided_at)
    FROM moderation_decisions AS md2
    WHERE md2.video_id = md.video_id
);

SELECT *
FROM v_video_current_state
LIMIT 10;

SELECT COUNT(*) AS rows_in_view
FROM v_video_current_state;

SELECT
    ct.creator_id,
    ct.tier_id,
    ct.valid_from,
    ct.valid_to
FROM creator_tiers AS ct
ORDER BY ct.creator_id, ct.valid_from
LIMIT 10;

CREATE VIEW v_creator_tier_current AS
SELECT
    ct.creator_id,
    t.tier_name AS current_tier
FROM creator_tiers AS ct
JOIN tiers AS t
    ON t.tier_id = ct.tier_id
WHERE ct.valid_to IS NULL;

SELECT *
FROM v_creator_tier_current
LIMIT 10;

SELECT COUNT(*) AS rows_in_view
FROM v_creator_tier_current;

CREATE VIEW v_video_daily_engagement AS
WITH impression_days AS (
    SELECT
        video_id,
        DATE(occurred_at) AS day,
        COUNT(*) AS impressions
    FROM impressions
    GROUP BY
        video_id,
        DATE(occurred_at)
),

daily_views AS (
    SELECT
        i.video_id,
        DATE(i.occurred_at) AS day,
        COUNT(vs.segment_id) AS views,
        COALESCE(SUM(vs.watch_seconds), 0) AS watch_seconds
    FROM impressions AS i
    LEFT JOIN viewing_segments AS vs
        ON vs.impression_id = i.impression_id
    GROUP BY
        i.video_id,
        DATE(i.occurred_at)
),

daily_likes AS (
    SELECT
        video_id,
        DATE(occurred_at) AS day,
        SUM(
            CASE
                WHEN signal_type = 'like' THEN 1
                WHEN signal_type = 'like_retraction' THEN -1
                ELSE 0
            END
        ) AS net_likes
    FROM signals
    WHERE signal_type IN ('like', 'like_retraction')
    GROUP BY
        video_id,
        DATE(occurred_at)
)

SELECT
    d.video_id,
    d.day,
    d.impressions,
    COALESCE(v.views, 0) AS views,
    COALESCE(v.watch_seconds, 0) AS watch_seconds,
    COALESCE(l.net_likes, 0) AS net_likes
FROM impression_days AS d
LEFT JOIN daily_views AS v
    ON v.video_id = d.video_id
   AND v.day = d.day
LEFT JOIN daily_likes AS l
    ON l.video_id = d.video_id
   AND l.day = d.day;

SELECT *
FROM v_video_daily_engagement
LIMIT 10;

SELECT COUNT(*) AS rows_in_view
FROM v_video_daily_engagement;

SELECT *
FROM v_video_daily_engagement
WHERE views = 0
   OR watch_seconds = 0
   OR net_likes = 0
LIMIT 10;

SELECT *
FROM pricing
LIMIT 10;

SELECT *
FROM turns
LIMIT 5;

SELECT *
FROM token_usage
LIMIT 5;

CREATE VIEW v_turn_cost AS
SELECT
    tu.turn_id,
    p.model_name,
    tu.input_tokens,
    tu.output_tokens,
    tu.cached_input_tokens,
    (
        ((tu.input_tokens - tu.cached_input_tokens) * p.input_rate)
        + (tu.cached_input_tokens * p.cached_input_rate)
        + (tu.output_tokens * p.output_rate)
    ) / 1000.0 AS turn_cost
FROM token_usage AS tu
JOIN pricing AS p
    ON p.pricing_id = tu.pricing_id;

SELECT *
FROM v_turn_cost
LIMIT 10;

SELECT COUNT(*) AS rows_in_view
FROM v_turn_cost;

SELECT COUNT(*) FROM users;

SELECT COUNT(*) FROM v_public_profile;

SELECT COUNT(*) FROM v_video_current_state;

SELECT COUNT(*) FROM v_creator_tier_current;

SELECT COUNT(*) FROM v_video_daily_engagement;

SELECT COUNT(*) FROM v_turn_cost;

INSERT INTO v_public_profile
    (user_id, handle, display_name, follower_count)
VALUES
    ('test_user', 'test_handle', 'Test User', 0);