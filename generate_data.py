#!/usr/bin/env python3


import argparse
import json
import os
import random
import sqlite3
import sys
import uuid
from datetime import datetime, timedelta, timezone


# ---------------------------------------------------------------
# E.3 parameters
# ---------------------------------------------------------------

SEED = 51

N_USERS = 5000
N_VIDEOS = 20000
N_IMPRESSIONS = 300000
N_AGENT_SESSIONS = 2000

SCALE = 1
START_DATE = datetime(2025, 1, 1, tzinfo=timezone.utc)
END_DATE = datetime(2026, 9, 13, tzinfo=timezone.utc)


def to_iso(dt):

    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def random_time(rng, start=START_DATE, end=END_DATE):

    total_seconds = (end - start).total_seconds()
    return start + timedelta(seconds=rng.uniform(0, total_seconds))


def random_time_of_day(rng, day):

    hour_weights = [
        1, 1, 1, 1, 1, 1,
        2, 3, 3, 3, 3, 4,
        4, 4, 4, 5, 6, 7,
        9, 10, 10, 8, 5, 2
    ]

    hour = rng.choices(range(24), weights=hour_weights, k=1)[0]
    minute = rng.randint(0, 59)
    second = rng.randint(0, 59)

    return day.replace(
        hour=hour,
        minute=minute,
        second=second,
        microsecond=0
    )

def make_id(prefix):
    return f"{prefix}_{uuid.uuid4().hex[:12]}"

def generate_data(connection, rng, scale):
    user_count = N_USERS * scale
    video_count = N_VIDEOS * scale
    impression_count = N_IMPRESSIONS * scale
    session_count = N_AGENT_SESSIONS * scale

    cur = connection.cursor()
    print(f"Generating {user_count} users...")
    user_ids = []
    for i in range(user_count):
        user_id = make_id("u")
        user_ids.append(user_id)
        handle = f"user{i}_{rng.randint(100, 999)}"
        display_name = f"User {i}" if rng.random() > 0.10 else None

        cur.execute(
            """
            INSERT INTO users
            VALUES (?, ?, ?, ?)
            """,
            (
                user_id,
                handle,
                handle.lower(),
                display_name
            )
        )

        created_at = random_time(
            rng,
            START_DATE,
            END_DATE - timedelta(days=30)
        )

        status_roll = rng.random()

        if status_roll < 0.92:
            status = "active"
            deletion_requested = None
            recovery_expires = None

        elif status_roll < 0.97:
            status = "deactivated"
            deletion_requested = None
            recovery_expires = None

        else:
            requested_at = random_time(
                rng,
                created_at,
                END_DATE
            )

            status = "pending_deletion"
            deletion_requested = to_iso(requested_at)
            recovery_expires = to_iso(
                requested_at + timedelta(days=30)
            )
        uses_phone = rng.random() < 0.60
        phone = (
            f"+91{rng.randint(6000000000, 9999999999)}"
            if uses_phone
            else None
        )
        gmail = (
            None
            if uses_phone
            else f"user{i}@gmail.com"
        )
        cur.execute(
            """
            INSERT INTO accounts
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                make_id("acc"),
                user_id,
                phone,
                gmail,
                status,
                deletion_requested,
                recovery_expires,
                to_iso(created_at)
            )
        )
        cur.execute(
            """
            INSERT INTO handle_history
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                user_id,
                handle,
                handle.lower(),
                to_iso(created_at),
                None
            )
        )
    categories = [
        "comedy",
        "dance",
        "cooking",
        "sports",
        "gaming",
        "music",
        "pets",
        "travel",
        "fashion",
        "study_tips",
        "finance",
        "fitness"
    ]

    category_ids = []

    for i, category in enumerate(categories, start=1):
        cur.execute(
            """
            INSERT INTO interest_categories
            VALUES (?, ?)
            """,
            (i, category)
        )
        category_ids.append(i)
    print("Generating user interests...")
    for user_id in user_ids:
        declared = rng.sample(
            category_ids,
            k=rng.randint(1, 4)
        )
        for category_id in declared:
            cur.execute(
                """
                INSERT INTO user_interests
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    user_id,
                    category_id,
                    "declared",
                    None,
                    to_iso(random_time(rng)),
                    None
                )
            )
        inferred = rng.sample(
            category_ids,
            k=rng.randint(0, 5)
        )

        for category_id in inferred:

            if category_id in declared:
                continue

            assigned_at = random_time(
                rng,
                START_DATE,
                END_DATE - timedelta(days=7)
            )

            cur.execute(
                """
                INSERT INTO user_interests
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    user_id,
                    category_id,
                    "inferred",
                    round(rng.uniform(0.30, 0.99), 3),
                    to_iso(assigned_at),
                    to_iso(
                        assigned_at + timedelta(days=7)
                    )
                )
            )
            if rng.random() < 0.15:
                cur.execute(
                    """
                    INSERT INTO interest_suppression
                    VALUES (?, ?, ?)
                    """,
                    (
                        user_id,
                        category_id,
                        to_iso(
                            assigned_at + timedelta(days=1)
                        )
                    )
                )
    print("Generating creators and tiers...")
    tier_names = [
        "starter",
        "rising",
        "partner",
        "elite"
    ]
    for i, tier_name in enumerate(tier_names, start=1):
        cur.execute(
            """
            INSERT INTO tiers
            VALUES (?, ?)
            """,
            (i, tier_name)
        )
    creator_count = int(user_count * 0.15)
    creator_users = rng.sample(
        user_ids,
        k=creator_count
    )
    creator_ids = []
    for user_id in creator_users:
        creator_id = make_id("cr")
        creator_ids.append(creator_id)
        cur.execute(
            """
            INSERT INTO creators
            VALUES (?, ?)
            """,
            (
                creator_id,
                user_id
            )
        )
        period_count = rng.choices(
            [1, 2, 3],
            weights=[5, 3, 1]
        )[0]
        tier_start = random_time(
            rng,
            START_DATE,
            START_DATE + timedelta(days=60)
        )
        for period in range(period_count):
            tier_id = min(period + 1, 4)
            last_period = period == period_count - 1
            tier_end = (
                None
                if last_period
                else tier_start + timedelta(
                    days=rng.randint(30, 150)
                )
            )
            cur.execute(
                """
                INSERT INTO creator_tiers
                VALUES (?, ?, ?, ?)
                """,
                (
                    creator_id,
                    tier_id,
                    to_iso(tier_start),
                    to_iso(tier_end)
                    if tier_end
                    else None
                )
            )
            if tier_end:
                tier_start = tier_end
    print(
        f"Generating {video_count} videos, hashtags and audio tracks..."
    )
    hashtag_list = [
        "#fyp",
        "#cats",
        "#dance",
        "#recipe",
        "#studytok",
        "#gymtok",
        "#travel",
        "#funny",
        "#music",
        "#pets"
    ]
    hashtag_ids = {}
    for i, hashtag in enumerate(hashtag_list, start=1):
        hashtag_ids[hashtag] = i
        cur.execute(
            """
            INSERT INTO hashtags
            VALUES (?, ?, ?)
            """,
            (
                i,
                hashtag,
                hashtag.lower()
            )
        )
    moderation_states = [
        "pending",
        "live",
        "age_restricted",
        "demoted",
        "taken_down"
    ]
    moderation_weights = [
        3, 82, 3, 8, 4
    ]
    video_ids = []
    licensed_tracks = [
        make_id("trk")
        for _ in range(200)
    ]
    for track_id in licensed_tracks:
        cur.execute(
            """
            INSERT INTO audio_tracks
            VALUES (?, ?, ?, ?)
            """,
            (
                track_id,
                "licensed",
                None,
                f"catalogue-{rng.randint(1000, 9999)}"
            )
        )
    creator_for_video = {}
    for i in range(video_count):
        video_id = make_id("v")
        video_ids.append(video_id)
        creator_id = rng.choice(creator_ids)
        creator_for_video[video_id] = creator_id
        duration = round(
            rng.uniform(20, 90),
            1
        )
        tag_count = rng.randint(0, 3)
        chosen_tags = rng.sample(
            hashtag_list,
            k=tag_count
        )
        if chosen_tags:
            caption = (
                "check this out "
                + " ".join(chosen_tags)
            )
        else:
            caption = "check this out"
        moderation_state = rng.choices(
            moderation_states,
            weights=moderation_weights
        )[0]
        audio_track_id = None
        if rng.random() < 0.70:
            audio_track_id = rng.choice(
                licensed_tracks
            )
        elif rng.random() < 0.50:
            track_id = make_id("trk")
            cur.execute(
                """
                INSERT INTO audio_tracks
                VALUES (?, ?, ?, ?)
                """,
                (
                    track_id,
                    "original",
                    video_id,
                    None
                )
            )
            audio_track_id = track_id
        cur.execute(
            """
            INSERT INTO videos
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                video_id,
                creator_id,
                duration,
                caption,
                audio_track_id,
                moderation_state
            )
        )
        for hashtag in chosen_tags:
            cur.execute(
                """
                INSERT OR IGNORE INTO video_hashtags
                VALUES (?, ?)
                """,
                (
                    video_id,
                    hashtag_ids[hashtag]
                )
            )
        decision_count = rng.choices(
            [1, 2, 3],
            weights=[6, 3, 1]
        )[0]
        decision_states = rng.sample(
            moderation_states,
            k=min(
                decision_count,
                len(moderation_states)
            )
        )
        if decision_states[-1] != moderation_state:
            decision_states[-1] = moderation_state
        decision_time = random_time(rng)
        for state in decision_states:
            source_type = (
                "automated"
                if rng.random() < 0.80
                else "human"
            )
            if rng.random() < 0.80:
                source_id = (
                    f"classifier-v{rng.randint(1, 5)}"
                )
            else:
                source_id = (
                    f"reviewer_{rng.randint(1, 40)}"
                )
            cur.execute(
                """
                INSERT INTO moderation_decisions
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    make_id("md"),
                    video_id,
                    state,
                    to_iso(decision_time),
                    source_type,
                    source_id
                )
            )
            decision_time += timedelta(
                hours=rng.randint(1, 48)
            )
    print("Generating follows, blocks and mutes...")

    follower_weights = [
        rng.paretovariate(1.2)
        for _ in user_ids
    ]

    follow_pairs = set()

    follow_target_count = int(
        user_count * 8
    )

    attempts = 0

    while (
        len(follow_pairs) < follow_target_count
        and attempts < follow_target_count * 3
    ):

        attempts += 1

        follower = rng.choice(user_ids)

        followed = rng.choices(
            user_ids,
            weights=follower_weights,
            k=1
        )[0]

        if follower == followed:
            continue

        pair = (
            follower,
            followed
        )

        if pair in follow_pairs:
            continue

        follow_pairs.add(pair)

        cur.execute(
            """
            INSERT INTO follows
            VALUES (?, ?, ?)
            """,
            (
                follower,
                followed,
                to_iso(random_time(rng))
            )
        )

    for _ in range(int(user_count * 0.02)):

        first_user, second_user = rng.sample(
            user_ids,
            2
        )

        cur.execute(
            """
            INSERT OR IGNORE INTO blocks
            VALUES (?, ?, ?)
            """,
            (
                first_user,
                second_user,
                to_iso(random_time(rng))
            )
        )

    for _ in range(int(user_count * 0.03)):

        first_user, second_user = rng.sample(
            user_ids,
            2
        )

        cur.execute(
            """
            INSERT OR IGNORE INTO mutes
            VALUES (?, ?, ?)
            """,
            (
                first_user,
                second_user,
                to_iso(random_time(rng))
            )
        )

    print(
        f"Generating {impression_count} impressions "
        "with viewing segments and signals..."
    )
    reserved_creator_count = max(
        1,
        len(creator_ids) // 50
    )

    reserved_creators = set(
        creator_ids[:reserved_creator_count]
    )
    reserved_videos = {
        video_id
        for video_id, creator_id
        in creator_for_video.items()
        if creator_id in reserved_creators
    }
    available_videos = [
        video_id
        for video_id in video_ids
        if video_id not in reserved_videos
    ]
    video_weights = [
        rng.paretovariate(1.1)
        for _ in available_videos
    ]
    signal_types = [
        "like",
        "like_retraction",
        "comment",
        "follow_from_feed",
        "not_interested",
        "report"
    ]
    share_apps = [
        "whatsapp",
        "instagram",
        "copied_link"
    ]
    total_days = (
        END_DATE - START_DATE
    ).days
    for _ in range(impression_count):
        user_id = rng.choice(user_ids)
        video_id = rng.choices(
            available_videos,
            weights=video_weights,
            k=1
        )[0]
        day = (
            START_DATE
            + timedelta(
                days=rng.randint(
                    0,
                    total_days
                )
            )
        )
        occurred_at = random_time_of_day(
            rng,
            day
        )
        impression_id = make_id("imp")
        cur.execute(
            """
            INSERT INTO impressions
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                impression_id,
                user_id,
                video_id,
                to_iso(occurred_at),
                rng.randint(1, 50),
                f"rank-v{rng.randint(1, 14)}"
            )
        )
        if rng.random() < 0.35:
            segment_count = rng.choices(
                [1, 2, 3],
                weights=[7, 2, 1]
            )[0]
            segment_start = occurred_at
            for _ in range(segment_count):
                watch_time = min(
                    rng.expovariate(1 / 8),
                    120.0
                )

                reached_end = (
                    rng.random() < 0.25
                )

                segment_end = (
                    segment_start
                    + timedelta(
                        seconds=watch_time
                    )
                )

                cur.execute(
                    """
                    INSERT INTO viewing_segments
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        make_id("seg"),
                        impression_id,
                        to_iso(segment_start),
                        to_iso(segment_end),
                        round(watch_time, 2),
                        1 if reached_end else 0
                    )
                )

                segment_start = (
                    segment_end
                    + timedelta(
                        seconds=rng.randint(1, 300)
                    )
                )
            if rng.random() < 0.12:
                signal_type = rng.choice(
                    signal_types + ["share"]
                )
                destination = (
                    rng.choice(share_apps)
                    if signal_type == "share"
                    else None
                )
                cur.execute(
                    """
                    INSERT INTO signals
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        make_id("sig"),
                        impression_id,
                        user_id,
                        video_id,
                        signal_type,
                        to_iso(
                            segment_start
                            + timedelta(
                                seconds=rng.randint(0, 60)
                            )
                        ),
                        destination
                    )
                )
            if rng.random() < 0.03:

                cur.execute(
                    """
                    INSERT OR IGNORE INTO saves
                    VALUES (?, ?, ?)
                    """,
                    (
                        user_id,
                        video_id,
                        to_iso(
                            segment_start
                            + timedelta(
                                seconds=rng.randint(0, 60)
                            )
                        )
                    )
                )

    print(
        f"Generating {session_count} agent sessions..."
    )

    template_names = [
        "why_this_explainer",
        "conversational_search"
    ]

    template_ids = {}

    for name in template_names:

        template_id = make_id("tpl")
        template_ids[name] = template_id

        cur.execute(
            """
            INSERT INTO prompt_templates
            VALUES (?, ?)
            """,
            (
                template_id,
                name
            )
        )

    prompt_versions = {
        name: []
        for name in template_names
    }

    for name in template_names:

        template_id = template_ids[name]

        version_count = rng.randint(3, 8)
        version_start = START_DATE

        for version_number in range(
            1,
            version_count + 1
        ):

            prompt_id = make_id("pv")

            last_version = (
                version_number == version_count
            )

            version_end = (
                None
                if last_version
                else version_start + timedelta(
                    days=rng.randint(10, 40)
                )
            )

            cur.execute(
                """
                INSERT INTO prompt_versions
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    prompt_id,
                    template_id,
                    version_number,
                    (
                        f"{name} prompt template text, "
                        f"version {version_number}"
                    ),
                    to_iso(version_start),
                    to_iso(version_end)
                    if version_end
                    else None
                )
            )

            prompt_versions[name].append(
                (
                    prompt_id,
                    version_start,
                    version_end
                )
            )

            if version_end:
                version_start = version_end

    models = [
        "gpt-4o-mini",
        "llama-3.1-70b",
        "scrollsense-ft-v2"
    ]

    model_prices = {}

    for model in models:

        period_count = rng.randint(1, 3)
        price_start = START_DATE
        price_periods = []

        for period in range(period_count):

            last_period = (
                period == period_count - 1
            )

            price_end = (
                None
                if last_period
                else price_start + timedelta(
                    days=rng.randint(60, 200)
                )
            )

            price_id = make_id("price")

            cur.execute(
                """
                INSERT INTO pricing
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    price_id,
                    model,
                    to_iso(price_start),
                    to_iso(price_end)
                    if price_end
                    else None,
                    round(
                        rng.uniform(0.05, 0.50),
                        4
                    ),
                    round(
                        rng.uniform(0.10, 1.00),
                        4
                    ),
                    round(
                        rng.uniform(0.01, 0.10),
                        4
                    )
                )
            )

            price_periods.append(
                (
                    price_id,
                    price_start,
                    price_end
                )
            )

            if price_end:
                price_start = price_end

        model_prices[model] = price_periods

    def find_price(model, timestamp):
       
        for price_id, start, end in model_prices[model]:

            if (
                start <= timestamp
                and (
                    end is None
                    or timestamp < end
                )
            ):
                return price_id

        return model_prices[model][-1][0]

    def find_prompt_version(template_name, timestamp):
       
        for prompt_id, start, end in prompt_versions[template_name]:

            if (
                start <= timestamp
                and (
                    end is None
                    or timestamp < end
                )
            ):
                return prompt_id

        return prompt_versions[template_name][-1][0]

    tool_names = [
        "search_videos",
        "get_user_history",
        "fetch_trending_audio"
    ]

    for _ in range(session_count):

        user_id = rng.choice(user_ids)

        session_id = make_id("sess")
        session_start = random_time(rng)

        turn_count = rng.randint(1, 6)

        session_end = (
            session_start
            + timedelta(
                minutes=rng.randint(1, 30)
            )
        )

        cur.execute(
            """
            INSERT INTO sessions
            VALUES (?, ?, ?, ?)
            """,
            (
                session_id,
                user_id,
                to_iso(session_start),
                to_iso(session_end)
            )
        )

        turn_time = session_start

        for turn_number in range(
            1,
            turn_count + 1
        ):

            turn_id = make_id("turn")

            cur.execute(
                """
                INSERT INTO turns
                VALUES (?, ?, ?)
                """,
                (
                    turn_id,
                    session_id,
                    turn_number
                )
            )

            cur.execute(
                """
                INSERT INTO user_messages
                VALUES (?, ?, ?)
                """,
                (
                    make_id("umsg"),
                    turn_id,
                    (
                        "find me that clip about the cat "
                        "that thinks it's a dog"
                    )
                )
            )

            template_name = rng.choice(
                template_names
            )

            prompt_id = find_prompt_version(
                template_name,
                turn_time
            )

            model = rng.choice(models)

            assistant_message_id = make_id("amsg")

            cur.execute(
                """
                INSERT INTO assistant_messages
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    assistant_message_id,
                    turn_id,
                    prompt_id,
                    model,
                    round(
                        rng.uniform(0.0, 1.0),
                        2
                    ),
                    (
                        "Here is why this clip was surfaced / "
                        "here are your results."
                    )
                )
            )

            call_count = rng.randint(0, 2)

            for _ in range(call_count):

                tool_call_id = make_id("tc")
                tool_name = rng.choice(tool_names)

                if tool_name == "search_videos":

                    arguments = json.dumps(
                        {
                            "query": "cat dog",
                            "filters": {
                                "region": "IN"
                            }
                        }
                    )

                else:

                    arguments = json.dumps(
                        {
                            "days": rng.randint(
                                1,
                                30
                            )
                        }
                    )

                cur.execute(
                    """
                    INSERT INTO tool_calls
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        tool_call_id,
                        assistant_message_id,
                        None,
                        tool_name,
                        arguments,
                        json.dumps(
                            {
                                "result_count":
                                rng.randint(0, 20)
                            }
                        ),
                        rng.randint(20, 900),
                        (
                            1
                            if rng.random() < 0.05
                            else 0
                        )
                    )
                )
                if rng.random() < 0.30:

                    child_id = make_id("tc")

                    cur.execute(
                        """
                        INSERT INTO tool_calls
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            child_id,
                            assistant_message_id,
                            tool_call_id,
                            rng.choice(tool_names),
                            json.dumps(
                                {
                                    "nested": True
                                }
                            ),
                            json.dumps(
                                {
                                    "ok": True
                                }
                            ),
                            rng.randint(10, 300),
                            0
                        )
                    )

            price_id = find_price(
                model,
                turn_time
            )

            cur.execute(
                """
                INSERT INTO token_usage
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    turn_id,
                    price_id,
                    rng.randint(50, 800),
                    rng.randint(20, 400),
                    rng.randint(0, 200)
                )
            )
            if rng.random() < 0.10:

                cur.execute(
                    """
                    INSERT INTO judge_scores
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        make_id("judge"),
                        turn_id,
                        round(
                            rng.uniform(1, 5),
                            1
                        ),
                        round(
                            rng.uniform(1, 5),
                            1
                        ),
                        round(
                            rng.uniform(3, 5),
                            1
                        ),
                        to_iso(
                            turn_time
                            + timedelta(minutes=5)
                        )
                    )
                )
            if rng.random() < 0.05:

                rating = rng.choices(
                    [
                        "thumbs_up",
                        "thumbs_down"
                    ],
                    weights=[7, 3]
                )[0]

                cur.execute(
                    """
                    INSERT INTO user_ratings
                    VALUES (?, ?, ?, ?)
                    """,
                    (
                        make_id("rate"),
                        turn_id,
                        rating,
                        to_iso(
                            turn_time
                            + timedelta(seconds=30)
                        )
                    )
                )
            if template_name == "conversational_search":

                shelf_size = rng.randint(1, 5)

                recommended_videos = rng.sample(
                    video_ids,
                    k=min(
                        shelf_size,
                        len(video_ids)
                    )
                )

                for position, video_id in enumerate(
                    recommended_videos,
                    start=1
                ):

                    cur.execute(
                        """
                        INSERT INTO recommendations
                        VALUES (?, ?, ?, ?)
                        """,
                        (
                            make_id("rec"),
                            turn_id,
                            video_id,
                            position
                        )
                    )

            turn_time += timedelta(
                seconds=rng.randint(5, 120)
            )


def main():

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--out",
        default="scrollsense.db",
        help="Output SQLite database file"
    )

    parser.add_argument(
        "--schema",
        default="schema.sql",
        help="Path to schema.sql"
    )

    parser.add_argument(
        "--scale",
        type=int,
        default=SCALE,
        help="Multiplier for the default dataset size"
    )

    args = parser.parse_args()

    rng = random.Random(SEED)
    if os.path.exists(args.out):
        os.remove(args.out)

    connection = sqlite3.connect(
        args.out,
        isolation_level=None
    )
    connection.execute(
        "PRAGMA foreign_keys = ON;"
    )
    connection.execute(
        "PRAGMA journal_mode = WAL;"
    )
    with open(args.schema, "r") as schema_file:
        connection.executescript(
            schema_file.read()
        )
    connection.execute("BEGIN")

    try:

        generate_data(
            connection,
            rng,
            args.scale
        )

        connection.commit()

    except Exception:

        connection.rollback()
        raise

    print("\nDone. Row counts:")

    tables = connection.execute(
        """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
        ORDER BY name
        """
    ).fetchall()

    for (table_name,) in tables:

        count = connection.execute(
            f"SELECT COUNT(*) FROM {table_name}"
        ).fetchone()[0]

        print(
            f"  {table_name:28s} {count}"
        )

    connection.close()


if __name__ == "__main__":
    sys.exit(main())
