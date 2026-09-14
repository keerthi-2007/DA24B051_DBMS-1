SELECT COUNT(*) AS users FROM users;

SELECT COUNT(*) AS videos FROM videos;

SELECT COUNT(*) AS impressions FROM impressions;

SELECT COUNT(*) AS sessions FROM sessions;

-- F1 · Top 10 audio tracks by distinct videos in the last 7 days.

SELECT
    v.audio_track_id,
    COUNT(DISTINCT v.video_id) AS distinct_videos
FROM impressions AS i
JOIN videos AS v
    ON v.video_id = i.video_id
WHERE v.audio_track_id IS NOT NULL
  AND i.occurred_at >= (
      SELECT datetime(
          MAX(occurred_at),
          '-7 days'
      )
      FROM impressions
  )
GROUP BY v.audio_track_id
ORDER BY distinct_videos DESC, v.audio_track_id
LIMIT 10;


-- F2 · Watch hours and mean completion rate per creator, live clips only.
-- F2 · Watch hours and mean completion rate per creator, live clips only.

SELECT
    c.creator_id,

    COALESCE(
        SUM(vs.watch_seconds) / 3600.0,
        0
    ) AS total_watch_hours,

    COALESCE(
        AVG(
            CASE
                WHEN vs.segment_id IS NOT NULL
                THEN vs.reached_end
            END
        ),
        0
    ) AS mean_completion_rate

FROM creators AS c

LEFT JOIN videos AS v
    ON v.creator_id = c.creator_id
   AND v.moderation_state = 'live'

LEFT JOIN impressions AS i
    ON i.video_id = v.video_id

LEFT JOIN viewing_segments AS vs
    ON vs.impression_id = i.impression_id

GROUP BY c.creator_id
ORDER BY total_watch_hours DESC, c.creator_id;

-- F3a · Videos with no audio track using NOT IN.

PRAGMA table_info(audio_tracks);


-- F3a · Videos with no audio track using NOT IN.

SELECT
    v.video_id
FROM videos AS v
WHERE v.audio_track_id NOT IN (
    SELECT a.audio_track_id
    FROM audio_tracks AS a
)
ORDER BY v.video_id;

-- F3b · Videos with no audio track using NOT EXISTS.

SELECT
    v.video_id
FROM videos AS v
WHERE NOT EXISTS (
    SELECT 1
    FROM audio_tracks AS a
    WHERE a.audio_track_id = v.audio_track_id
)
ORDER BY v.video_id;

SELECT DISTINCT signal_type
FROM signals
ORDER BY signal_type;

-- F4 · Users who liked and then retracted the like on the same clip within 60 seconds.

SELECT DISTINCT
    l.user_id,
    l.video_id
FROM signals AS l
JOIN signals AS r
    ON r.user_id = l.user_id
   AND r.video_id = l.video_id
   AND r.signal_type = 'like_retraction'
   AND r.occurred_at > l.occurred_at
   AND julianday(r.occurred_at) - julianday(l.occurred_at) <= 60.0 / 86400
WHERE l.signal_type = 'like'
ORDER BY l.user_id, l.video_id;

SELECT
    signal_type,
    COUNT(*) AS count
FROM signals
WHERE signal_type IN ('like', 'like_retraction')
GROUP BY signal_type;

SELECT DISTINCT
    l.user_id,
    l.video_id
FROM signals AS l
JOIN signals AS r
    ON r.user_id = l.user_id
   AND r.video_id = l.video_id
   AND r.signal_type = 'like_retraction'
   AND r.occurred_at > l.occurred_at
   AND julianday(r.occurred_at) - julianday(l.occurred_at)
       <= 60.0 / 86400
WHERE l.signal_type = 'like'
ORDER BY l.user_id, l.video_id;

SELECT
    COUNT(*) AS matching_pairs
FROM signals AS l
JOIN signals AS r
    ON r.user_id = l.user_id
   AND r.video_id = l.video_id
   AND r.signal_type = 'like_retraction'
   AND r.occurred_at > l.occurred_at
WHERE l.signal_type = 'like';

SELECT caption
FROM videos
WHERE caption IS NOT NULL
  AND instr(lower(caption), '#') > 0
LIMIT 10;

-- F5 · Videos whose caption contains the hashtag #fyp.

SELECT
    video_id,
    caption
FROM videos
WHERE lower(
          trim(
              replace(
                  replace(caption, ',', ' '),
                  '!', ' '
              )
          )
      ) LIKE '%#fyp%'
ORDER BY video_id;

-- F5 · Videos whose caption carries the hashtag #fyp.

SELECT
    video_id,
    caption
FROM videos
WHERE
    lower(
        trim(
            replace(
                replace(
                    replace(
                        replace(caption, ',', ' '),
                        '!', ' '
                    ),
                    '.', ' '
                ),
                '?', ' '
            )
        )
    ) LIKE '%#fyp%'
AND instr(
    ' ' || lower(
        trim(
            replace(
                replace(
                    replace(
                        replace(caption, ',', ' '),
                        '!', ' '
                    ),
                    '.', ' '
                ),
                '?', ' '
            )
        )
    ) || ' ',
    ' #fyp '
) > 0
ORDER BY video_id;

-- F6a · Users shown a creator's clips but never engaged with them.

SELECT DISTINCT
    i.user_id
FROM impressions AS i
JOIN videos AS v
    ON v.video_id = i.video_id
WHERE v.creator_id = 'cr_e4bd2753bb75'

EXCEPT

SELECT DISTINCT
    s.user_id
FROM signals AS s
JOIN videos AS v
    ON v.video_id = s.video_id
WHERE v.creator_id = 'cr_e4bd2753bb75'

ORDER BY user_id;

-- F6b · Signal roll-up using UNION.

SELECT
    signal_type,
    COUNT(*) AS signal_count
FROM signals
GROUP BY signal_type

UNION

SELECT
    signal_type,
    COUNT(*) AS signal_count
FROM signals
GROUP BY signal_type

ORDER BY signal_type;

-- F6c · Signal roll-up using UNION ALL.

SELECT
    signal_type,
    COUNT(*) AS signal_count
FROM signals
GROUP BY signal_type

UNION ALL

SELECT
    signal_type,
    COUNT(*) AS signal_count
FROM signals
GROUP BY signal_type

ORDER BY signal_type;

SELECT name, sql
FROM sqlite_master
WHERE type = 'table'
  AND (
      name LIKE '%prompt%'
      OR name LIKE '%pricing%'
      OR name LIKE '%session%'
      OR name LIKE '%turn%'
  )
ORDER BY name;

PRAGMA table_info(pricing);

PRAGMA table_info(prompt_versions);

PRAGMA table_info(sessions);
PRAGMA table_info(turns);
SELECT name, sql
FROM sqlite_master
WHERE type = 'table'
  AND name IN (
      'turns',
      'user_messages',
      'assistant_messages',
      'tool_calls',
      'prompt_versions',
      'prompt_templates',
      'pricing'
  )
ORDER BY name;

-- F7 · Cost of each agent session last month by prompt template version.
-- Threshold: $0.005 per session.

WITH turn_cost AS (
    SELECT
        t.turn_id,
        t.session_id,
        pv.prompt_version_id,
        pt.template_name,
        pv.version_number,

        (
            (tu.input_tokens - tu.cached_input_tokens)
                * p.input_rate
            + tu.cached_input_tokens
                * p.cached_input_rate
            + tu.output_tokens
                * p.output_rate
        ) / 1000000.0 AS turn_cost

    FROM turns AS t

    JOIN assistant_messages AS am
        ON am.turn_id = t.turn_id

    JOIN prompt_versions AS pv
        ON pv.prompt_version_id = am.prompt_version_id

    JOIN prompt_templates AS pt
        ON pt.template_id = pv.template_id

    JOIN token_usage AS tu
        ON tu.turn_id = t.turn_id

    JOIN pricing AS p
        ON p.pricing_id = tu.pricing_id

    JOIN sessions AS s
        ON s.session_id = t.session_id

    WHERE s.started_at >= date('now', 'start of month', '-1 month')
      AND s.started_at < date('now', 'start of month')
),

session_total AS (
    SELECT
        session_id,
        SUM(turn_cost) AS total_session_cost
    FROM turn_cost
    GROUP BY session_id
)

SELECT
    tc.session_id,
    tc.template_name,
    tc.version_number,
    ROUND(SUM(tc.turn_cost), 6) AS cost_for_template_version,
    ROUND(st.total_session_cost, 6) AS session_total_cost

FROM turn_cost AS tc

JOIN session_total AS st
    ON st.session_id = tc.session_id

WHERE st.total_session_cost > 0.005

GROUP BY
    tc.session_id,
    tc.template_name,
    tc.version_number,
    st.total_session_cost

ORDER BY
    session_total_cost DESC,
    tc.session_id,
    tc.template_name,
    tc.version_number;

SELECT
    MIN(started_at) AS first_session,
    MAX(started_at) AS last_session,
    COUNT(*) AS total_sessions
FROM sessions;

SELECT
    date(started_at) AS session_date,
    COUNT(*) AS sessions
FROM sessions
GROUP BY date(started_at)
ORDER BY session_date;

WITH turn_cost AS (
    SELECT
        t.turn_id,
        t.session_id,
        pv.prompt_version_id,
        pt.template_name,
        pv.version_number,

        (
            (tu.input_tokens - tu.cached_input_tokens) * p.input_rate
            + tu.cached_input_tokens * p.cached_input_rate
            + tu.output_tokens * p.output_rate
        ) / 1000000.0 AS turn_cost

    FROM turns AS t

    JOIN assistant_messages AS am
        ON am.turn_id = t.turn_id

    JOIN prompt_versions AS pv
        ON pv.prompt_version_id = am.prompt_version_id

    JOIN prompt_templates AS pt
        ON pt.template_id = pv.template_id

    JOIN token_usage AS tu
        ON tu.turn_id = t.turn_id

    JOIN pricing AS p
        ON p.pricing_id = tu.pricing_id

    JOIN sessions AS s
        ON s.session_id = t.session_id

    WHERE s.started_at >= '2026-08-01'
      AND s.started_at < '2026-09-01'
),

session_total AS (
    SELECT
        session_id,
        SUM(turn_cost) AS total_session_cost
    FROM turn_cost
    GROUP BY session_id
)

SELECT
    COUNT(*) AS sessions_in_august,
    MIN(total_session_cost) AS minimum_cost,
    MAX(total_session_cost) AS maximum_cost,
    AVG(total_session_cost) AS average_cost
FROM session_total;

-- F7 · Cost of each agent session last month by prompt template version.
-- Threshold: $0.001 per session.

WITH turn_cost AS (
    SELECT
        t.turn_id,
        t.session_id,
        pv.prompt_version_id,
        pt.template_name,
        pv.version_number,

        (
            (tu.input_tokens - tu.cached_input_tokens)
                * p.input_rate
            + tu.cached_input_tokens
                * p.cached_input_rate
            + tu.output_tokens
                * p.output_rate
        ) / 1000000.0 AS turn_cost

    FROM turns AS t

    JOIN assistant_messages AS am
        ON am.turn_id = t.turn_id

    JOIN prompt_versions AS pv
        ON pv.prompt_version_id = am.prompt_version_id

    JOIN prompt_templates AS pt
        ON pt.template_id = pv.template_id

    JOIN token_usage AS tu
        ON tu.turn_id = t.turn_id

    JOIN pricing AS p
        ON p.pricing_id = tu.pricing_id

    JOIN sessions AS s
        ON s.session_id = t.session_id

    WHERE s.started_at >= '2026-08-01'
      AND s.started_at < '2026-09-01'
),

session_total AS (
    SELECT
        session_id,
        SUM(turn_cost) AS total_session_cost
    FROM turn_cost
    GROUP BY session_id
)

SELECT
    tc.session_id,
    tc.template_name,
    tc.version_number,
    ROUND(SUM(tc.turn_cost), 8) AS cost_for_template_version,
    ROUND(st.total_session_cost, 8) AS session_total_cost

FROM turn_cost AS tc

JOIN session_total AS st
    ON st.session_id = tc.session_id

WHERE st.total_session_cost > 0.001

GROUP BY
    tc.session_id,
    tc.template_name,
    tc.version_number,
    st.total_session_cost

ORDER BY
    session_total_cost DESC,
    tc.session_id,
    tc.template_name,
    tc.version_number;

SELECT name, sql
FROM sqlite_master
WHERE type = 'table'
  AND (
      name LIKE '%moder%'
      OR name LIKE '%state%'
      OR name LIKE '%history%'
      OR name LIKE '%transition%'
  )
ORDER BY name;


-- F8 · Videos whose moderation state changed more than twice.
-- SQLite version: 3.53.2, so ordered group_concat is supported.

WITH ordered_decisions AS (
    SELECT
        video_id,
        moderation_state,
        decided_at,
        LAG(moderation_state) OVER (
            PARTITION BY video_id
            ORDER BY decided_at
        ) AS previous_state
    FROM moderation_decisions
),

changed_states AS (
    SELECT
        video_id,
        moderation_state,
        decided_at
    FROM ordered_decisions
    WHERE previous_state IS NULL
       OR moderation_state <> previous_state
),

change_counts AS (
    SELECT
        video_id,
        COUNT(*) - 1 AS change_count
    FROM changed_states
    GROUP BY video_id
)

SELECT
    cs.video_id,
    cc.change_count,
    group_concat(
        cs.moderation_state,
        ' -> '
        ORDER BY cs.decided_at
    ) AS transition_sequence
FROM changed_states AS cs
JOIN change_counts AS cc
    ON cc.video_id = cs.video_id
WHERE cc.change_count > 2
GROUP BY
    cs.video_id,
    cc.change_count
ORDER BY
    cc.change_count DESC,
    cs.video_id;

SELECT
    video_id,
    COUNT(*) AS decision_count
FROM moderation_decisions
GROUP BY video_id
ORDER BY decision_count DESC
LIMIT 10;

-- F9 · Each user's longest streak of consecutive active days.

WITH active_days AS (
    SELECT DISTINCT
        user_id,
        date(occurred_at) AS active_date
    FROM signals
),

numbered AS (
    SELECT
        user_id,
        active_date,
        julianday(active_date)
          - ROW_NUMBER() OVER (
                PARTITION BY user_id
                ORDER BY active_date
            ) AS grp
    FROM active_days
),

streaks AS (
    SELECT
        user_id,
        grp,
        COUNT(*) AS streak_length,
        MIN(active_date) AS streak_start,
        MAX(active_date) AS streak_end
    FROM numbered
    GROUP BY user_id, grp
),

longest AS (
    SELECT
        user_id,
        streak_length,
        streak_start,
        streak_end,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY streak_length DESC,
                     streak_end DESC
        ) AS rn
    FROM streaks
)

SELECT
    user_id,
    streak_length,
    streak_start,
    streak_end
FROM longest
WHERE rn = 1
ORDER BY user_id;

-- F10 · Creator 7-day rolling watch time and week-over-week change.
-- "7 days" means seven calendar days, including days with zero activity.

WITH RECURSIVE

date_bounds AS (
    SELECT
        date(MIN(occurred_at)) AS min_date,
        date(MAX(occurred_at)) AS max_date
    FROM impressions
),

calendar(activity_date) AS (
    SELECT min_date
    FROM date_bounds

    UNION ALL

    SELECT date(activity_date, '+1 day')
    FROM calendar, date_bounds
    WHERE activity_date < max_date
),

daily_watch AS (
    SELECT
        v.creator_id,
        date(i.occurred_at) AS activity_date,
        SUM(vs.watch_seconds) / 3600.0 AS watch_hours
    FROM impressions AS i
    JOIN videos AS v
        ON v.video_id = i.video_id
    JOIN viewing_segments AS vs
        ON vs.impression_id = i.impression_id
    GROUP BY
        v.creator_id,
        date(i.occurred_at)
),

creator_calendar AS (
    SELECT
        c.creator_id,
        cal.activity_date,
        COALESCE(dw.watch_hours, 0) AS watch_hours
    FROM creators AS c
    CROSS JOIN calendar AS cal
    LEFT JOIN daily_watch AS dw
        ON dw.creator_id = c.creator_id
       AND dw.activity_date = cal.activity_date
),

rolling AS (
    SELECT
        creator_id,
        activity_date,
        SUM(watch_hours) OVER (
            PARTITION BY creator_id
            ORDER BY julianday(activity_date)
            RANGE BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7d_watch_hours
    FROM creator_calendar
),

with_wow AS (
    SELECT
        creator_id,
        activity_date,
        rolling_7d_watch_hours,
        LAG(rolling_7d_watch_hours, 7) OVER (
            PARTITION BY creator_id
            ORDER BY activity_date
        ) AS previous_7d_watch_hours
    FROM rolling
)

SELECT
    creator_id,
    activity_date,
    ROUND(rolling_7d_watch_hours, 4) AS rolling_7d_watch_hours,
    ROUND(
        rolling_7d_watch_hours - previous_7d_watch_hours,
        4
    ) AS wow_change_hours,
    ROUND(
        100.0 *
        (rolling_7d_watch_hours - previous_7d_watch_hours)
        / NULLIF(previous_7d_watch_hours, 0),
        2
    ) AS wow_change_percent
FROM with_wow
WHERE activity_date = (
    SELECT max_date
    FROM date_bounds
)
ORDER BY
    rolling_7d_watch_hours DESC,
    creator_id;



-- F10 · Creator 7-day rolling watch time and week-over-week change.
-- "7 days" means seven calendar days, including days with zero activity.

WITH RECURSIVE

date_bounds AS (
    SELECT
        date(MIN(occurred_at)) AS min_date,
        date(MAX(occurred_at)) AS max_date
    FROM impressions
),

calendar(activity_date) AS (
    SELECT min_date
    FROM date_bounds

    UNION ALL

    SELECT date(activity_date, '+1 day')
    FROM calendar, date_bounds
    WHERE activity_date < max_date
),

daily_watch AS (
    SELECT
        v.creator_id,
        date(i.occurred_at) AS activity_date,
        SUM(vs.watch_seconds) / 3600.0 AS watch_hours
    FROM impressions AS i
    JOIN videos AS v
        ON v.video_id = i.video_id
    JOIN viewing_segments AS vs
        ON vs.impression_id = i.impression_id
    GROUP BY
        v.creator_id,
        date(i.occurred_at)
),

creator_calendar AS (
    SELECT
        c.creator_id,
        cal.activity_date,
        COALESCE(dw.watch_hours, 0) AS watch_hours
    FROM creators AS c
    CROSS JOIN calendar AS cal
    LEFT JOIN daily_watch AS dw
        ON dw.creator_id = c.creator_id
       AND dw.activity_date = cal.activity_date
),

rolling AS (
    SELECT
        creator_id,
        activity_date,
        SUM(watch_hours) OVER (
            PARTITION BY creator_id
            ORDER BY julianday(activity_date)
            RANGE BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7d_watch_hours
    FROM creator_calendar
),

with_wow AS (
    SELECT
        creator_id,
        activity_date,
        rolling_7d_watch_hours,
        LAG(rolling_7d_watch_hours, 7) OVER (
            PARTITION BY creator_id
            ORDER BY activity_date
        ) AS previous_7d_watch_hours
    FROM rolling
),

latest AS (
    SELECT
        creator_id,
        activity_date,
        rolling_7d_watch_hours,
        previous_7d_watch_hours,
        rolling_7d_watch_hours - previous_7d_watch_hours
            AS wow_change_hours,
        100.0 *
        (rolling_7d_watch_hours - previous_7d_watch_hours)
        / NULLIF(previous_7d_watch_hours, 0)
            AS wow_change_percent
    FROM with_wow
    WHERE activity_date = (
        SELECT max_date
        FROM date_bounds
    )
)

SELECT
    RANK() OVER (
        ORDER BY rolling_7d_watch_hours DESC
    ) AS creator_rank,
    creator_id,
    activity_date,
    ROUND(rolling_7d_watch_hours, 4) AS rolling_7d_watch_hours,
    ROUND(previous_7d_watch_hours, 4) AS previous_7d_watch_hours,
    ROUND(wow_change_hours, 4) AS wow_change_hours,
    ROUND(wow_change_percent, 2) AS wow_change_percent
FROM latest
ORDER BY
    creator_rank,
    creator_id;





WITH RECURSIVE

date_bounds AS (
    SELECT
        date(MIN(occurred_at)) AS min_date,
        date(MAX(occurred_at)) AS max_date
    FROM impressions
),

calendar(activity_date) AS (
    SELECT min_date
    FROM date_bounds

    UNION ALL

    SELECT date(activity_date, '+1 day')
    FROM calendar, date_bounds
    WHERE activity_date < max_date
),

daily_watch AS (
    SELECT
        v.creator_id,
        date(i.occurred_at) AS activity_date,
        SUM(vs.watch_seconds) / 3600.0 AS watch_hours
    FROM impressions AS i
    JOIN videos AS v
        ON v.video_id = i.video_id
    JOIN viewing_segments AS vs
        ON vs.impression_id = i.impression_id
    GROUP BY
        v.creator_id,
        date(i.occurred_at)
),

creator_calendar AS (
    SELECT
        c.creator_id,
        cal.activity_date,
        COALESCE(dw.watch_hours, 0) AS watch_hours
    FROM creators AS c
    CROSS JOIN calendar AS cal
    LEFT JOIN daily_watch AS dw
        ON dw.creator_id = c.creator_id
       AND dw.activity_date = cal.activity_date
),

rolling AS (
    SELECT
        creator_id,
        activity_date,
        SUM(watch_hours) OVER (
            PARTITION BY creator_id
            ORDER BY julianday(activity_date)
            RANGE BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7d_watch_hours
    FROM creator_calendar
),

with_wow AS (
    SELECT
        creator_id,
        activity_date,
        rolling_7d_watch_hours,
        LAG(rolling_7d_watch_hours, 7) OVER (
            PARTITION BY creator_id
            ORDER BY activity_date
        ) AS previous_7d_watch_hours
    FROM rolling
),

latest AS (
    SELECT
        creator_id,
        activity_date,
        rolling_7d_watch_hours,
        previous_7d_watch_hours,
        rolling_7d_watch_hours - previous_7d_watch_hours
            AS wow_change_hours,
        100.0 *
        (rolling_7d_watch_hours - previous_7d_watch_hours)
        / NULLIF(previous_7d_watch_hours, 0)
            AS wow_change_percent
    FROM with_wow
    WHERE activity_date = (
        SELECT max_date
        FROM date_bounds
    )
)

SELECT
    RANK() OVER (
        ORDER BY rolling_7d_watch_hours DESC
    ) AS creator_rank,
    creator_id,
    activity_date,
    ROUND(rolling_7d_watch_hours, 4) AS rolling_7d_watch_hours,
    ROUND(previous_7d_watch_hours, 4) AS previous_7d_watch_hours,
    ROUND(wow_change_hours, 4) AS wow_change_hours,
    ROUND(wow_change_percent, 2) AS wow_change_percent
FROM latest
ORDER BY
    creator_rank,
    creator_id
LIMIT 5;


-- F11 · Full nesting tree for an agent session's tool calls.

WITH RECURSIVE

selected_session AS (
    SELECT
        t.session_id
    FROM tool_calls AS tc
    JOIN assistant_messages AS am
        ON am.message_id = tc.assistant_message_id
    JOIN turns AS t
        ON t.turn_id = am.turn_id
    GROUP BY t.session_id
    ORDER BY t.session_id
    LIMIT 1
),

tool_tree AS (
    -- Top-level tool calls
    SELECT
        tc.tool_call_id,
        tc.assistant_message_id,
        tc.parent_tool_call_id,
        tc.tool_name,
        tc.arguments,
        tc.result,
        tc.latency_ms,
        tc.errored,
        ss.session_id,
        0 AS depth,
        tc.tool_call_id AS tree_path
    FROM tool_calls AS tc
    JOIN assistant_messages AS am
        ON am.message_id = tc.assistant_message_id
    JOIN turns AS t
        ON t.turn_id = am.turn_id
    JOIN selected_session AS ss
        ON ss.session_id = t.session_id
    WHERE tc.parent_tool_call_id IS NULL

    UNION ALL

    -- Nested child tool calls
    SELECT
        child.tool_call_id,
        child.assistant_message_id,
        child.parent_tool_call_id,
        child.tool_name,
        child.arguments,
        child.result,
        child.latency_ms,
        child.errored,
        parent.session_id,
        parent.depth + 1,
        parent.tree_path || '/' || child.tool_call_id
    FROM tool_calls AS child
    JOIN tool_tree AS parent
        ON child.parent_tool_call_id = parent.tool_call_id
)

SELECT
    session_id,
    depth,
    tool_call_id,
    parent_tool_call_id,
    tool_name,
    latency_ms,
    errored,
    arguments
FROM tool_tree
ORDER BY tree_path;


-- F12 · Sessions where the agent recommended a clip
-- that the user subsequently watched to completion.

SELECT DISTINCT
    s.session_id,
    s.user_id,
    r.video_id,
    r.position AS shelf_position
FROM sessions AS s

JOIN turns AS t
    ON t.session_id = s.session_id

JOIN recommendations AS r
    ON r.turn_id = t.turn_id

JOIN impressions AS i
    ON i.user_id = s.user_id
   AND i.video_id = r.video_id
   AND i.occurred_at >= s.started_at

JOIN viewing_segments AS vs
    ON vs.impression_id = i.impression_id
   AND vs.reached_end = 1

ORDER BY
    s.session_id,
    r.position,
    r.video_id;


SELECT
    name,
    sql
FROM sqlite_master
WHERE type = 'table'
  AND (
      name LIKE '%rating%'
      OR name LIKE '%judge%'
      OR name LIKE '%feedback%'
  )
ORDER BY name;

-- F13 · Turns where the LLM judge scored above 4
-- but the user gave a thumbs-down.

SELECT
    t.turn_id,
    t.session_id,
    js.helpfulness AS judge_helpfulness,
    ur.rating AS user_rating,
    js.judged_at,
    ur.rated_at
FROM turns AS t

JOIN judge_scores AS js
    ON js.turn_id = t.turn_id

JOIN user_ratings AS ur
    ON ur.turn_id = t.turn_id

WHERE js.helpfulness > 4
  AND ur.rating = 'thumbs_down'

ORDER BY
    t.session_id,
    t.turn_number;