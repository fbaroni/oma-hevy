#!/usr/bin/env python3
"""Hevy public API client and dashboard snapshot builder.

Everything here is local: the API key never leaves this machine and is only
sent to api.hevyapp.com. Used by bin/hevy-sync.py and bin/hevy-key.py.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import deep_dive as deeper

API_BASE = "https://api.hevyapp.com/v1"
API_TIMEOUT = 25
USER_AGENT = "omarchy-oma-hevy/0.1 (+https://omarchy.org)"

CONFIG_DIR = os.path.expanduser(os.environ.get("HEVY_CONFIG_DIR", "~/.config/omarchy/hevy"))
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "omarchy", "hevy"
)
SNAPSHOT_PATH = os.path.join(CACHE_DIR, "snapshot.json")
TEMPLATES_PATH = os.path.join(CACHE_DIR, "exercise-templates.json")

SNAPSHOT_TTL = 20 * 60          # cached dashboard is good for 20 minutes
TEMPLATES_TTL = 30 * 24 * 3600  # exercise catalogue barely changes
HISTORY_WEEKS = 16              # how far back we fetch workouts
CHART_WEEKS = 12                # weeks shown in the trend chart
MAX_PAGES = 12                  # 12 pages x 10 workouts, keeps API calls polite

MUSCLE_LABELS = {
    "chest": "Chest",
    "back": "Back",
    "shoulders": "Shoulders",
    "arms": "Arms",
    "legs": "Legs",
    "core": "Core",
    "other": "Other",
}

MUSCLE_GROUPS = {
    "chest": {"chest"},
    "back": {"lats", "upper_back", "traps", "lower_back"},
    "shoulders": {"shoulders"},
    "arms": {"biceps", "triceps", "forearms"},
    "legs": {"quadriceps", "hamstrings", "glutes", "calves", "abductors", "adductors"},
    "core": {"abdominals"},
}

MUSCLE_TO_GROUP = {muscle: group for group, muscles in MUSCLE_GROUPS.items() for muscle in muscles}


class HevyError(Exception):
    """Human-readable API failure."""


class HevyAuthError(HevyError):
    """The API key is missing, invalid, or not allowed."""


# --------------------------------------------------------------------------- #
# Config and cache
# --------------------------------------------------------------------------- #

def ensure_dirs() -> None:
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)


def load_config() -> dict:
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_config(config: dict) -> None:
    ensure_dirs()
    write_json_atomic(CONFIG_PATH, config, mode=0o600)


def api_key() -> str:
    return (os.environ.get("HEVY_API_KEY") or load_config().get("api_key") or "").strip()


def weekly_target() -> int:
    try:
        value = int(load_config().get("weekly_target", 4))
    except (TypeError, ValueError):
        value = 4
    return max(1, min(14, value))


def write_json_atomic(path: str, payload: dict, mode: int = 0o644) -> None:
    ensure_dirs()
    directory = os.path.dirname(path)
    tmp = os.path.join(directory, ".%s.tmp" % os.path.basename(path))
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"), ensure_ascii=False)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def read_json(path: str):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def clear_snapshot() -> None:
    try:
        os.unlink(SNAPSHOT_PATH)
    except OSError:
        pass


def cached_snapshot(max_age: float | None = None):
    data = read_json(SNAPSHOT_PATH)
    if not isinstance(data, dict) or data.get("error"):
        return None
    if max_age is not None:
        fetched = data.get("fetched_at") or 0
        if time.time() - fetched > max_age:
            return None
    return data


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

def api_get(path: str, params: dict | None = None, key: str | None = None):
    key = key or api_key()
    if not key:
        raise HevyAuthError("No Hevy API key configured.")

    url = API_BASE + path
    if params:
        url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})

    request = urllib.request.Request(
        url,
        headers={
            "api-key": key,
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
    )

    last_error = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=API_TIMEOUT) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            body = ""
            try:
                body = error.read().decode("utf-8", "replace")
            except OSError:
                pass
            if error.code in (401, 403):
                raise HevyAuthError("Hevy rejected the API key (HTTP %d)." % error.code) from None
            if error.code == 429 or 500 <= error.code < 600:
                last_error = "Hevy API is busy (HTTP %d)." % error.code
                time.sleep(1.5 * (attempt + 1))
                continue
            message = body.strip() or error.reason
            raise HevyError("Hevy API error %d: %s" % (error.code, message)) from None
        except urllib.error.URLError as error:
            last_error = "Can't reach Hevy: %s" % getattr(error, "reason", error)
            time.sleep(0.6 * (attempt + 1))
        except (ValueError, OSError) as error:
            last_error = "Unexpected response from Hevy: %s" % error
            break

    raise HevyError(last_error or "Hevy API request failed.")


# --------------------------------------------------------------------------- #
# Fetching
# --------------------------------------------------------------------------- #

def fetch_user(key: str) -> dict:
    data = api_get("/user/info", key=key).get("data") or {}
    return {
        "name": data.get("name") or data.get("username") or "Athlete",
        "username": data.get("username") or "",
        "url": data.get("url") or "",
        "weight_unit": "lbs" if data.get("weight_unit") == "lbs" else "kg",
        "is_pro": bool(data.get("is_pro")),
    }


def fetch_count(key: str) -> int:
    try:
        return int(api_get("/workouts/count", key=key).get("workout_count") or 0)
    except (HevyError, TypeError, ValueError):
        return 0


def fetch_workouts(key: str) -> list[dict]:
    cutoff = datetime.now(timezone.utc) - timedelta(weeks=HISTORY_WEEKS)
    workouts: list[dict] = []
    page = 1
    page_count = 1

    while page <= min(page_count, MAX_PAGES):
        data = api_get("/workouts", {"page": page, "pageSize": 10}, key=key)
        page_count = int(data.get("page_count") or 1)
        batch = data.get("workouts") or []
        workouts.extend(batch)

        oldest = None
        for workout in batch:
            parsed = parse_ts(workout.get("start_time"))
            if parsed and (oldest is None or parsed < oldest):
                oldest = parsed
        if not batch or (oldest and oldest < cutoff) or page >= page_count:
            break

        page += 1
        time.sleep(0.35)

    # Keep a single copy of each workout, newest first.
    unique = {}
    for workout in workouts:
        workout_id = workout.get("id")
        if workout_id and workout_id not in unique:
            unique[workout_id] = workout
    return sorted(
        unique.values(),
        key=lambda w: parse_ts(w.get("start_time")) or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )


def fetch_templates(key: str) -> dict:
    cached = read_json(TEMPLATES_PATH)
    if isinstance(cached, dict) and cached.get("templates"):
        if time.time() - (cached.get("fetched_at") or 0) < TEMPLATES_TTL:
            return cached["templates"]

    templates: dict[str, str] = {}
    page = 1
    page_count = 1
    try:
        while page <= min(page_count, 10):
            data = api_get("/exercise_templates", {"page": page, "pageSize": 100}, key=key)
            page_count = int(data.get("page_count") or 1)
            for template in data.get("exercise_templates") or []:
                template_id = template.get("id")
                if template_id:
                    templates[template_id] = template.get("primary_muscle_group") or "other"
            if page >= page_count:
                break
            page += 1
            time.sleep(0.2)
    except HevyError:
        if isinstance(cached, dict) and cached.get("templates"):
            return cached["templates"]
        return {}

    if templates:
        write_json_atomic(
            TEMPLATES_PATH, {"fetched_at": int(time.time()), "templates": templates}
        )
    return templates or (cached.get("templates", {}) if isinstance(cached, dict) else {})


def fetch_body(key: str):
    try:
        data = api_get("/body_measurements", {"page": 1, "pageSize": 1}, key=key)
        rows = data.get("body_measurements") or []
        if not rows:
            return None
        row = rows[0]
        return {
            "date": row.get("date"),
            "weight_kg": row.get("weight_kg"),
            "fat_percent": row.get("fat_percent"),
            "lean_mass_kg": row.get("lean_mass_kg"),
        }
    except HevyError:
        return None


# --------------------------------------------------------------------------- #
# Snapshot maths
# --------------------------------------------------------------------------- #

def parse_ts(value):
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def local(value):
    return value.astimezone() if value else None


def local_ts(timestamp: float) -> datetime:
    return datetime.fromtimestamp(timestamp).astimezone()


def week_start(value: datetime) -> datetime:
    value = local(value)
    start = value - timedelta(days=value.weekday())
    return start.replace(hour=0, minute=0, second=0, microsecond=0)


def workout_metrics(workout: dict, templates: dict) -> dict:
    volume = 0.0
    sets = 0
    reps = 0
    best = None
    groups: dict[str, float] = {}

    for exercise in workout.get("exercises") or []:
        title = exercise.get("title") or "Exercise"
        group = MUSCLE_TO_GROUP.get(
            templates.get(exercise.get("exercise_template_id") or "", "other"), "other"
        )
        for entry in exercise.get("sets") or []:
            if entry.get("type") == "warmup":
                continue
            weight = float(entry.get("weight_kg") or 0)
            count = int(entry.get("reps") or 0)
            set_volume = weight * count
            volume += set_volume
            sets += 1
            reps += count
            groups[group] = groups.get(group, 0.0) + set_volume
            if weight > 0 and count > 0:
                score = weight * (1 + count / 30.0)
                if best is None or score > best["score"]:
                    best = {
                        "score": score,
                        "title": title,
                        "weight_kg": weight,
                        "reps": count,
                        "exercise_template_id": exercise.get("exercise_template_id"),
                    }

    start = parse_ts(workout.get("start_time"))
    end = parse_ts(workout.get("end_time"))
    duration = 0
    if start and end and end > start:
        duration = int((end - start).total_seconds())

    return {
        "id": workout.get("id"),
        "title": workout.get("title") or "Workout",
        "start": local(start).isoformat() if start else None,
        "start_ts": start.timestamp() if start else 0,
        "duration_s": duration,
        "volume_kg": round(volume, 1),
        "sets": sets,
        "reps": reps,
        "exercise_count": len(workout.get("exercises") or []),
        "groups": groups,
        "best": (
            {
                "title": best["title"],
                "weight_kg": round(best["weight_kg"], 1),
                "reps": best["reps"],
                "e1rm_kg": round(best["score"], 1),
            }
            if best
            else None
        ),
    }


def deep_helpers() -> dict:
    return {
        "parse_ts": parse_ts, "to_local": local, "week_start": week_start,
        "groups": MUSCLE_TO_GROUP, "labels": MUSCLE_LABELS, "window_weeks": HISTORY_WEEKS,
    }


def safe_deep(workouts: list[dict], templates: dict, now: datetime):
    """The extra tabs must never be able to break the overview."""
    try:
        return deeper.deep_dive(workouts, templates, now, deep_helpers())
    except Exception as error:  # noqa: BLE001 - reported to the panel, not raised
        return {"error": str(error)[:200]}


def build_snapshot(workouts: list[dict], templates: dict, user: dict, count: int, body, target: int) -> dict:
    now = datetime.now().astimezone()
    metrics = [workout_metrics(workout, templates) for workout in workouts]
    metrics = [m for m in metrics if m["start_ts"]]
    metrics.sort(key=lambda m: m["start_ts"], reverse=True)

    current_week = week_start(now)
    week_metrics = [
        m for m in metrics if week_start(local_ts(m["start_ts"])).date() == current_week.date()
    ]

    def total(rows, field):
        return sum(row[field] for row in rows)

    prev_week = current_week - timedelta(days=7)
    # Compare the part of this week that has already happened with the same
    # slice of last week, so a Monday morning does not look like a collapse.
    prev_cutoff = prev_week + (now - current_week)
    prev_metrics = [
        m
        for m in metrics
        if week_start(local_ts(m["start_ts"])).date() == prev_week.date()
        and local_ts(m["start_ts"]) < prev_cutoff
    ]

    week_volume = total(week_metrics, "volume_kg")
    prev_volume = total(prev_metrics, "volume_kg")
    change_pct = None
    if prev_volume > 0:
        change_pct = round((week_volume - prev_volume) / prev_volume * 100.0, 1)

    days = []
    for offset in range(7):
        day = current_week + timedelta(days=offset)
        rows = [
            m for m in metrics if week_start(local_ts(m["start_ts"])).date() == current_week.date()
            and local_ts(m["start_ts"]).date() == day.date()
        ]
        days.append(
            {
                "date": day.date().isoformat(),
                "volume_kg": round(total(rows, "volume_kg"), 1),
                "workouts": len(rows),
                "is_today": day.date() == now.date(),
                "is_future": day.date() > now.date(),
            }
        )

    history = []
    for offset in range(CHART_WEEKS - 1, -1, -1):
        start = current_week - timedelta(days=7 * offset)
        rows = [
            m
            for m in metrics
            if week_start(local_ts(m["start_ts"])).date() == start.date()
        ]
        history.append(
            {
                "start": start.date().isoformat(),
                "workouts": len(rows),
                "volume_kg": round(total(rows, "volume_kg"), 1),
                "sets": total(rows, "sets"),
            }
        )

    by_day = {}
    for entry in metrics:
        by_day.setdefault(local_ts(entry["start_ts"]).date(), []).append(entry)

    calendar = []
    calendar_start = current_week - timedelta(days=7 * (CHART_WEEKS - 1))
    for weekday in range(7):
        for week in range(CHART_WEEKS):
            day = calendar_start + timedelta(days=week * 7 + weekday)
            rows = by_day.get(day.date(), [])
            calendar.append(
                {
                    "date": day.date().isoformat(),
                    "workouts": len(rows),
                    "volume_kg": round(total(rows, "volume_kg"), 1),
                    "future": day.date() > now.date(),
                }
            )

    # Consecutive weeks (current week included when it already has a session).
    streak = 0
    check = current_week
    if not week_metrics:
        check = current_week - timedelta(days=7)
    while True:
        rows = [
            m for m in metrics if week_start(local_ts(m["start_ts"])).date() == check.date()
        ]
        if not rows:
            break
        streak += 1
        check -= timedelta(days=7)

    muscle_volumes = {key: 0.0 for key in MUSCLE_LABELS}
    cutoff = now - timedelta(days=30)
    for entry in metrics:
        if local_ts(entry["start_ts"]) < cutoff:
            continue
        for group, volume in entry["groups"].items():
            muscle_volumes[group] = muscle_volumes.get(group, 0.0) + volume
    muscle_total = sum(muscle_volumes.values())
    muscles = []
    for key in ["chest", "back", "legs", "shoulders", "arms", "core", "other"]:
        volume = muscle_volumes.get(key, 0.0)
        if volume <= 0:
            continue
        muscles.append(
            {
                "key": key,
                "label": MUSCLE_LABELS[key],
                "volume_kg": round(volume, 1),
                "pct": round(volume / muscle_total * 100.0, 1) if muscle_total else 0,
            }
        )
    muscles.sort(key=lambda row: row["volume_kg"], reverse=True)

    # Best estimated 1RM per exercise inside the fetched window.
    best_by_exercise: dict[str, dict] = {}
    for workout in workouts:
        entry = workout_metrics(workout, templates)
        if not entry["start_ts"]:
            continue
        for exercise in workout.get("exercises") or []:
            for set_row in exercise.get("sets") or []:
                if set_row.get("type") == "warmup":
                    continue
                weight = float(set_row.get("weight_kg") or 0)
                reps = int(set_row.get("reps") or 0)
                if weight <= 0 or reps <= 0:
                    continue
                score = weight * (1 + reps / 30.0)
                key = (exercise.get("exercise_template_id"), exercise.get("title"))
                current = best_by_exercise.get(key)
                if current is None or score > current["e1rm_kg"]:
                    best_by_exercise[key] = {
                        "title": exercise.get("title") or "Exercise",
                        "weight_kg": round(weight, 1),
                        "reps": reps,
                        "e1rm_kg": round(score, 1),
                        "date": entry["start"][:10] if entry["start"] else None,
                        "muscle": MUSCLE_LABELS.get(
                            MUSCLE_TO_GROUP.get(
                                templates.get(exercise.get("exercise_template_id") or "", "other"),
                                "other",
                            ),
                            "Other",
                        ),
                    }
    records = sorted(best_by_exercise.values(), key=lambda row: row["e1rm_kg"], reverse=True)[:5]

    best_week = max(history, key=lambda row: row["volume_kg"]) if history else None
    recent = [
        {
            "id": entry["id"],
            "title": entry["title"],
            "start": entry["start"],
            "duration_s": entry["duration_s"],
            "volume_kg": entry["volume_kg"],
            "sets": entry["sets"],
            "reps": entry["reps"],
            "exercise_count": entry["exercise_count"],
            "best": entry["best"],
        }
        for entry in metrics[:4]
    ]
    last = metrics[0] if metrics else None
    days_since_last = None
    if last:
        days_since_last = max(0, (now.date() - local(datetime.fromtimestamp(last["start_ts"])).date()).days)

    return {
        "demo": False,
        "fetched_at": int(time.time()),
        "stale": False,
        "user": user,
        "total_workouts": count or len(metrics),
        "week": {
            "start": current_week.date().isoformat(),
            "target": target,
            "workouts": len(week_metrics),
            "volume_kg": round(week_volume, 1),
            "prev_volume_kg": round(prev_volume, 1),
            "change_pct": change_pct,
            "sets": total(week_metrics, "sets"),
            "reps": total(week_metrics, "reps"),
            "duration_s": total(week_metrics, "duration_s"),
            "days": days,
        },
        "streak_weeks": streak,
        "days_since_last": days_since_last,
        "last_workout": recent[0] if recent else None,
        "recent": recent,
        "history": history,
        "calendar": calendar,
        "muscles": muscles,
        "records": records,
        "body": body,
        "deep": safe_deep(workouts, templates, now),
        "totals": {
            "volume_kg": round(total(metrics, "volume_kg"), 1),
            "sets": total(metrics, "sets"),
            "duration_s": total(metrics, "duration_s"),
            "avg_week_volume_kg": round(
                total(metrics, "volume_kg") / max(1, len(history)), 1
            ),
            "best_week": best_week,
            "longest_session_s": max([m["duration_s"] for m in metrics] or [0]),
        },
    }


# --------------------------------------------------------------------------- #
# Public entry points
# --------------------------------------------------------------------------- #

def sync(force: bool = False) -> dict:
    key = api_key()
    if not key:
        return {"error": "not_authenticated", "fetched_at": int(time.time())}

    if not force:
        cached = cached_snapshot(SNAPSHOT_TTL)
        # A snapshot saved before the extra tabs existed has no "deep": refetch it.
        if cached and "deep" in cached:
            return cached

    try:
        user = fetch_user(key)
        count = fetch_count(key)
        workouts = fetch_workouts(key)
        templates = fetch_templates(key)
        body = fetch_body(key)
        snapshot = build_snapshot(workouts, templates, user, count, body, weekly_target())
        write_json_atomic(SNAPSHOT_PATH, snapshot)
        return snapshot
    except HevyAuthError as error:
        clear_snapshot()
        return {"error": "not_authenticated", "message": str(error), "fetched_at": int(time.time())}
    except HevyError as error:
        cached = cached_snapshot()
        if cached:
            cached = dict(cached)
            cached["stale"] = True
            cached["warning"] = str(error)
            return cached
        return {"error": "network", "message": str(error), "fetched_at": int(time.time())}


def demo_snapshot() -> dict:
    now = datetime.now().astimezone()
    current_week = week_start(now)
    volume = [14200, 16800, 9100, 18700, 12100, 20400, 17600, 15300, 21800, 19400, 16200, 0]
    workouts = [3, 4, 2, 4, 2, 5, 4, 3, 4, 4, 3, 0]
    history = []
    for index, start in enumerate(
        (current_week - timedelta(days=7 * (CHART_WEEKS - 1 - i)) for i in range(CHART_WEEKS))
    ):
        history.append(
            {
                "start": start.date().isoformat(),
                "workouts": workouts[index],
                "volume_kg": volume[index],
                "sets": workouts[index] * 14,
            }
        )

    week_volume = 5980
    days = []
    for offset in range(7):
        day = current_week + timedelta(days=offset)
        trained = offset in (0, 1)
        days.append(
            {
                "date": day.date().isoformat(),
                "volume_kg": [3120, 2860, 0, 0, 0, 0, 0][offset],
                "workouts": 1 if trained else 0,
                "is_today": day.date() == now.date(),
                "is_future": day.date() > now.date(),
            }
        )
    history[-1]["volume_kg"] = week_volume
    history[-1]["workouts"] = 2
    history[-1]["sets"] = 34

    calendar = []
    calendar_start = current_week - timedelta(days=7 * (CHART_WEEKS - 1))
    index = 0
    for weekday in range(7):
        for week in range(CHART_WEEKS):
            day = calendar_start + timedelta(days=week * 7 + weekday)
            trained = day.date() < now.date() and ((week * 7 + weekday) % 3 != 2)
            calendar.append(
                {
                    "date": day.date().isoformat(),
                    "workouts": 1 if trained else 0,
                    "volume_kg": (4200 + (index % 5) * 750) if trained else 0,
                    "future": day.date() > now.date(),
                }
            )
            index += 1

    recent = [
        {
            "id": "demo-1",
            "title": "Push Day",
            "start": (now - timedelta(hours=6)).isoformat(),
            "duration_s": 4380,
            "volume_kg": 3120,
            "sets": 18,
            "reps": 142,
            "exercise_count": 6,
            "best": {"title": "Bench Press (Barbell)", "weight_kg": 92.5, "reps": 6, "e1rm_kg": 111.0},
        },
        {
            "id": "demo-2",
            "title": "Pull Day",
            "start": (now - timedelta(days=1, hours=4)).isoformat(),
            "duration_s": 3960,
            "volume_kg": 2860,
            "sets": 16,
            "reps": 128,
            "exercise_count": 5,
            "best": {"title": "Deadlift (Barbell)", "weight_kg": 150, "reps": 4, "e1rm_kg": 170.0},
        },
        {
            "id": "demo-3",
            "title": "Leg Day",
            "start": (now - timedelta(days=5, hours=2)).isoformat(),
            "duration_s": 3480,
            "volume_kg": 2440,
            "sets": 15,
            "reps": 116,
            "exercise_count": 5,
            "best": {"title": "Squat (Barbell)", "weight_kg": 120, "reps": 5, "e1rm_kg": 140.0},
        },
    ]
    return {
        "demo": True,
        "fetched_at": int(time.time()),
        "stale": False,
        "user": {"name": "Sample Athlete", "username": "sample", "weight_unit": "kg", "is_pro": True},
        "total_workouts": 187,
        "week": {
            "start": current_week.date().isoformat(),
            "target": 4,
            "workouts": 2,
            "volume_kg": week_volume,
            "prev_volume_kg": 5400,
            "change_pct": 10.7,
            "sets": 34,
            "reps": 268,
            "duration_s": 7620,
            "days": days,
        },
        "streak_weeks": 7,
        "days_since_last": 0,
        "last_workout": recent[0],
        "recent": recent,
        "history": history,
        "calendar": calendar,
        "muscles": [
            {"key": "back", "label": "Back", "volume_kg": 24800, "pct": 27.4},
            {"key": "legs", "label": "Legs", "volume_kg": 22100, "pct": 24.4},
            {"key": "chest", "label": "Chest", "volume_kg": 18600, "pct": 20.5},
            {"key": "shoulders", "label": "Shoulders", "volume_kg": 11800, "pct": 13.0},
            {"key": "arms", "label": "Arms", "volume_kg": 8900, "pct": 9.8},
            {"key": "core", "label": "Core", "volume_kg": 4400, "pct": 4.9},
        ],
        "records": [
            {"title": "Deadlift (Barbell)", "weight_kg": 150, "reps": 4, "e1rm_kg": 170, "date": history[-2]["start"], "muscle": "Back"},
            {"title": "Squat (Barbell)", "weight_kg": 120, "reps": 5, "e1rm_kg": 140, "date": history[-3]["start"], "muscle": "Legs"},
            {"title": "Bench Press (Barbell)", "weight_kg": 92.5, "reps": 6, "e1rm_kg": 111, "date": history[-1]["start"], "muscle": "Chest"},
            {"title": "Overhead Press (Barbell)", "weight_kg": 55, "reps": 5, "e1rm_kg": 64.2, "date": history[-2]["start"], "muscle": "Shoulders"},
        ],
        "body": {"date": history[-1]["start"], "weight_kg": 78.4, "fat_percent": 14.2, "lean_mass_kg": 67.3},
        "deep": safe_deep(*deeper.demo_workouts(now), now),
        "totals": {
            "volume_kg": 192000,
            "sets": 1340,
            "duration_s": 420000,
            "avg_week_volume_kg": 16400,
            "best_week": {"start": history[-4]["start"], "volume_kg": 21800},
            "longest_session_s": 4860,
        },
    }
