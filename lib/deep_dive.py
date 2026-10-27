"""The second layer of the Hevy dashboard: what the weekly overview does not say.

Everything is computed from the workouts that were already fetched for the
overview, so it costs no extra API calls. The numbers are plain counts and
ratios over the fetched window (16 weeks), and every observation states the
sample it rests on.
"""

from __future__ import annotations

from datetime import datetime, timedelta

# Muscle names Hevy attaches to an exercise template, grouped the way lifters
# talk about a split. Lower back counts as pull (it is trained by hinges and
# rows); calves and abductors stay with legs.
PUSH = {"chest", "shoulders", "triceps"}
PULL = {"lats", "upper_back", "traps", "biceps", "forearms", "lower_back"}
LEGS = {"quadriceps", "hamstrings", "glutes", "calves", "abductors", "adductors"}
CORE = {"abdominals"}

# Hevy files rear-delt and face-pull work under "shoulders", but those are pulling
# movements. Shoulder exercises are split by name; this list is what counts as pull.
PULL_SHOULDER_WORDS = ("face pull", "rear delt", "reverse fly", "reverse pec", "pull apart", "pull-apart",
                       "posterior", "tirón a la cara", "tiron a la cara", "reverse flye")

GROUP_ORDER = ("chest", "back", "shoulders", "arms", "legs", "core")
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
TOP_EXERCISES = 8
SERIES_POINTS = 12
WEEKS_SHOWN = 8


def e1rm(weight: float, reps: int) -> float:
    """Epley estimate, the same formula the overview uses for its records."""
    return weight * (1 + reps / 30.0)


def _working_sets(exercise: dict):
    for entry in exercise.get("sets") or []:
        if entry.get("type") == "warmup":
            continue
        yield float(entry.get("weight_kg") or 0), int(entry.get("reps") or 0)


def _bucket(reps: int) -> str:
    if reps <= 5:
        return "1–5"
    if reps <= 10:
        return "6–10"
    if reps <= 15:
        return "11–15"
    return "16+"


def _time_of_day(hour: int) -> str:
    if hour < 5:
        return "night"
    if hour < 11:
        return "morning"
    if hour < 15:
        return "midday"
    if hour < 19:
        return "afternoon"
    return "evening"


def parse_sessions(workouts, templates, parse_ts, to_local, groups, labels):
    """One flat row per workout, oldest first, with its exercises resolved."""
    sessions = []
    for workout in workouts:
        start = parse_ts(workout.get("start_time"))
        if not start:
            continue
        end = parse_ts(workout.get("end_time"))
        moment = to_local(start)
        exercises = []
        for exercise in workout.get("exercises") or []:
            muscle = templates.get(exercise.get("exercise_template_id") or "", "other")
            group = groups.get(muscle, "other")
            sets = list(_working_sets(exercise))
            if not sets:
                continue
            best = max(((e1rm(w, r), w, r) for w, r in sets if w > 0 and r > 0), default=None)
            exercises.append({
                "key": exercise.get("exercise_template_id") or exercise.get("title"),
                "title": exercise.get("title") or "Exercise",
                "muscle": muscle,
                "group": group,
                "group_label": labels.get(group, "Other"),
                "sets": sets,
                "best": best,
                "volume": sum(w * r for w, r in sets),
            })
        sessions.append({
            "id": workout.get("id"),
            "title": workout.get("title") or "Workout",
            "moment": moment,
            "duration_s": int((end - start).total_seconds()) if end and end > start else 0,
            "exercises": exercises,
        })
    sessions.sort(key=lambda s: s["moment"])
    return sessions


def progression(sessions, limit=TOP_EXERCISES):
    """Estimated 1RM per session for the lifts you actually repeat."""
    by_lift = {}
    for session in sessions:
        for exercise in session["exercises"]:
            if not exercise["best"]:
                continue
            row = by_lift.setdefault(exercise["key"], {"title": exercise["title"], "label": exercise["group_label"], "points": []})
            top, weight, reps = exercise["best"]
            row["points"].append({"date": session["moment"].date().isoformat(), "e1rm": top, "weight": weight, "reps": reps})
    lifts = []
    for row in by_lift.values():
        points = row["points"]
        if len(points) < 2:
            continue
        shown = points[-SERIES_POINTS:]
        first, last = shown[0]["e1rm"], shown[-1]["e1rm"]
        change = (last - first) / first * 100.0 if first else None
        lifts.append({
            "title": row["title"], "muscle": row["label"], "sessions": len(points),
            "series": [round(p["e1rm"], 1) for p in shown],
            "first_date": shown[0]["date"], "last_date": shown[-1]["date"],
            "last": {"weight_kg": round(shown[-1]["weight"], 1), "reps": shown[-1]["reps"]},
            "best_e1rm_kg": round(max(p["e1rm"] for p in points), 1),
            "change_pct": round(change, 1) if change is not None else None,
        })
    lifts.sort(key=lambda lift: lift["sessions"], reverse=True)
    return lifts[:limit]


def personal_records(sessions, limit=10):
    """Every time a lift beat its own best estimate, newest first."""
    best = {}
    events = []
    for session in sessions:
        for exercise in session["exercises"]:
            if not exercise["best"]:
                continue
            top, weight, reps = exercise["best"]
            previous = best.get(exercise["key"])
            if previous is not None and top > previous * 1.001:
                events.append({
                    "date": session["moment"].date().isoformat(), "title": exercise["title"],
                    "weight_kg": round(weight, 1), "reps": reps, "e1rm_kg": round(top, 1),
                    "previous_kg": round(previous, 1), "muscle": exercise["group_label"],
                })
            if previous is None or top > previous:
                best[exercise["key"]] = top
    events.sort(key=lambda e: e["date"], reverse=True)
    return events[:limit]


def patterns(sessions):
    weekday = [0] * 7
    weekday_volume = [0.0] * 7
    times = {"night": 0, "morning": 0, "midday": 0, "afternoon": 0, "evening": 0}
    reps = {"1–5": 0, "6–10": 0, "11–15": 0, "16+": 0}
    for session in sessions:
        index = session["moment"].weekday()
        weekday[index] += 1
        weekday_volume[index] += sum(e["volume"] for e in session["exercises"])
        times[_time_of_day(session["moment"].hour)] += 1
        for exercise in session["exercises"]:
            for _, count in exercise["sets"]:
                if count > 0:
                    reps[_bucket(count)] += 1
    return {
        "weekday": [{"label": WEEKDAYS[i], "workouts": weekday[i], "volume_kg": round(weekday_volume[i], 1)} for i in range(7)],
        "time_of_day": [{"key": key, "workouts": value} for key, value in times.items()],
        "rep_ranges": [{"range": key, "sets": value} for key, value in reps.items()],
    }


def weekly_sets(sessions, week_start_fn, now):
    """Working sets per muscle group for each of the last weeks, oldest first."""
    current = week_start_fn(now)
    starts = [current - timedelta(days=7 * offset) for offset in range(WEEKS_SHOWN - 1, -1, -1)]
    index = {start.date(): i for i, start in enumerate(starts)}
    rows = {group: [0] * WEEKS_SHOWN for group in GROUP_ORDER}
    for session in sessions:
        slot = index.get(week_start_fn(session["moment"]).date())
        if slot is None:
            continue
        for exercise in session["exercises"]:
            if exercise["group"] in rows:
                rows[exercise["group"]][slot] += len(exercise["sets"])
    return {
        "weeks": [start.date().isoformat() for start in starts],
        "rows": [{"key": group, "weeks": rows[group]} for group in GROUP_ORDER],
    }


def duration_by_week(sessions, week_start_fn, now, weeks=12):
    current = week_start_fn(now)
    out = []
    for offset in range(weeks - 1, -1, -1):
        start = (current - timedelta(days=7 * offset)).date()
        minutes = [s["duration_s"] / 60.0 for s in sessions
                   if week_start_fn(s["moment"]).date() == start and s["duration_s"] > 0]
        out.append({"start": start.isoformat(), "avg_min": round(sum(minutes) / len(minutes)) if minutes else None})
    return out


def side(exercise: dict) -> str:
    """push / pull / legs / core / other for one exercise."""
    muscle = exercise["muscle"]
    if muscle == "shoulders":
        title = exercise["title"].lower()
        return "pull" if any(word in title for word in PULL_SHOULDER_WORDS) else "push"
    if muscle in PUSH:
        return "push"
    if muscle in PULL:
        return "pull"
    if muscle in LEGS:
        return "legs"
    if muscle in CORE:
        return "core"
    return "other"


def balance(sessions, weeks=4, now=None, week_start_fn=None):
    """Push / pull / legs / core sets over the recent weeks."""
    cutoff = None
    if now is not None:
        cutoff = now - timedelta(days=7 * weeks)
    totals = {"push": 0, "pull": 0, "legs": 0, "core": 0}
    for session in sessions:
        if cutoff is not None and session["moment"] < cutoff:
            continue
        for exercise in session["exercises"]:
            kind = side(exercise)
            if kind in totals:
                totals[kind] += len(exercise["sets"])
    return {"weeks": weeks, **totals}


def recent_sessions(sessions, limit=10):
    out = []
    for session in reversed(sessions[-limit:]):
        lifts = sorted(session["exercises"], key=lambda e: e["volume"], reverse=True)
        out.append({
            "title": session["title"], "start": session["moment"].isoformat(), "duration_s": session["duration_s"],
            "volume_kg": round(sum(e["volume"] for e in session["exercises"]), 1),
            "sets": sum(len(e["sets"]) for e in session["exercises"]),
            "exercises": [{
                "title": e["title"], "sets": len(e["sets"]),
                "top": {"weight_kg": round(e["best"][1], 1), "reps": e["best"][2]} if e["best"] else None,
            } for e in lifts[:6]],
        })
    return out


def averages(sessions, now):
    if not sessions:
        return {}
    first = sessions[0]["moment"]
    weeks = max(1.0, (now - first).days / 7.0)
    durations = [s["duration_s"] for s in sessions if s["duration_s"] > 0]
    sets = [sum(len(e["sets"]) for e in s["exercises"]) for s in sessions]
    volume = [sum(e["volume"] for e in s["exercises"]) for s in sessions]
    days = sorted({s["moment"].date() for s in sessions})
    gaps = [(b - a).days for a, b in zip(days, days[1:])]
    return {
        "sessions": len(sessions), "span_weeks": round(weeks, 1),
        "per_week": round(len(sessions) / weeks, 1),
        "duration_min": round(sum(durations) / len(durations) / 60) if durations else None,
        "sets": round(sum(sets) / len(sets)), "volume_kg": round(sum(volume) / len(volume)),
        "longest_gap_days": max(gaps) if gaps else 0,
        "current_gap_days": (now.date() - days[-1]).days,
    }


def observations(deep):
    """A few honest sentences. Each one carries the count it rests on."""
    out = []
    avg, pat, bal = deep.get("averages") or {}, deep.get("patterns") or {}, deep.get("balance") or {}
    lifts, prs, grid = deep.get("progression") or [], deep.get("prs") or [], deep.get("weekly_sets") or {}

    if avg.get("sessions", 0) >= 6:
        days = pat.get("weekday") or []
        ranked = sorted(days, key=lambda d: d["workouts"], reverse=True)
        top = [d["label"] for d in ranked[:3] if d["workouts"] > 0]
        empty = [d["label"] for d in days if d["workouts"] == 0]
        text = "You average %.1f sessions a week over %d sessions; most of them land on %s." % (
            avg["per_week"], avg["sessions"], ", ".join(top))
        if empty:
            text += " You never trained on %s." % ", ".join(empty)
        out.append({"tone": "flat", "title": "Your rhythm", "text": text})

    push, pull = bal.get("push", 0), bal.get("pull", 0)
    if push + pull >= 20:
        ratio = push / pull if pull else None
        tone = "flat"
        if ratio is None or ratio > 1.5 or ratio < 0.67:
            tone = "bad"
        elif 0.8 <= ratio <= 1.25:
            tone = "good"
        out.append({"tone": tone, "title": "Push vs pull",
                    "text": "%d pushing sets against %d pulling sets in the last %d weeks%s (shoulder work is split by exercise name)." % (
                        push, pull, bal.get("weeks", 4),
                        " — %.1f to 1" % ratio if ratio is not None else "")})

    movers = [lift for lift in lifts if lift.get("change_pct") is not None]
    if len(movers) >= 3:
        up = sum(1 for lift in movers if lift["change_pct"] > 2)
        down = sum(1 for lift in movers if lift["change_pct"] < -2)
        out.append({"tone": "good" if up > down else "bad" if down > up else "flat", "title": "Strength trend",
                    "text": "Of your %d most repeated lifts, %d are up and %d are down (estimated 1RM, first vs latest session shown)." % (
                        len(movers), up, down)})

    recent_prs = [p for p in prs if p["date"] >= (datetime.now() - timedelta(days=30)).date().isoformat()]
    if prs:
        out.append({"tone": "good" if recent_prs else "flat", "title": "Personal records",
                    "text": "%d new estimated-1RM records in the last 30 days. Latest: %s, %.0f kg × %d (%s)." % (
                        len(recent_prs), prs[0]["title"], prs[0]["weight_kg"], prs[0]["reps"], prs[0]["date"])})

    rows = grid.get("rows") or []
    if rows:
        # The four finished weeks: the one in progress would drag every average down.
        recent = {row["key"]: sum(row["weeks"][-5:-1]) / 4.0 for row in rows if row["key"] != "core"}
        low = min(recent, key=recent.get)
        # Only meaningful when you have actually been training.
        if sum(recent.values()) * 4 >= 24 and recent[low] < 6:
            out.append({"tone": "bad", "title": "Least trained", "text": "%s gets %.0f working sets a week on average over the last 4 full weeks; 10 or more is a common starting point for growth." % (
                low.capitalize(), recent[low])})

    if avg.get("current_gap_days", 0) >= 4 and avg.get("longest_gap_days"):
        out.append({"tone": "bad" if avg["current_gap_days"] > avg["longest_gap_days"] else "flat", "title": "Time off",
                    "text": "%d days since your last session; your longest gap in this window was %d." % (
                        avg["current_gap_days"], avg["longest_gap_days"])})
    return out


def deep_dive(workouts, templates, now, helpers):
    """Everything the extra tabs need, from the workouts already in memory."""
    sessions = parse_sessions(workouts, templates, helpers["parse_ts"], helpers["to_local"],
                              helpers["groups"], helpers["labels"])
    deep = {
        "window_weeks": helpers["window_weeks"],
        "sessions_in_window": len(sessions),
        "progression": progression(sessions),
        "prs": personal_records(sessions),
        "patterns": patterns(sessions),
        "weekly_sets": weekly_sets(sessions, helpers["week_start"], now),
        "duration_weeks": duration_by_week(sessions, helpers["week_start"], now),
        "balance": balance(sessions, 4, now, helpers["week_start"]),
        "recent": recent_sessions(sessions),
        "averages": averages(sessions, now),
    }
    deep["insights"] = observations(deep)
    return deep


# --------------------------------------------------------------------------
# Sample data
# --------------------------------------------------------------------------

def demo_workouts(now):
    """Sixteen weeks of a push / pull / legs split in the API's own shape, so
    the preview runs through the same code as a real account."""
    import random
    rng = random.Random(11)
    catalogue = {
        "bench": ("Bench Press (Barbell)", "chest", 62.5, 1.2),
        "ohp": ("Overhead Press (Barbell)", "shoulders", 40.0, 0.6),
        "dips": ("Triceps Dip", "triceps", 0.0, 0.0),
        "pushdown": ("Triceps Pushdown", "triceps", 27.5, 0.4),
        "row": ("Bent Over Row (Barbell)", "lats", 60.0, 1.0),
        "pullup": ("Pull Up", "lats", 0.0, 0.0),
        "curl": ("Bicep Curl (Dumbbell)", "biceps", 14.0, 0.25),
        "squat": ("Squat (Barbell)", "quadriceps", 85.0, 1.8),
        "rdl": ("Romanian Deadlift (Barbell)", "hamstrings", 90.0, 1.5),
        "legpress": ("Leg Press (Machine)", "quadriceps", 160.0, 3.0),
        "plank": ("Plank", "abdominals", 0.0, 0.0),
    }
    templates = {key: spec[1] for key, spec in catalogue.items()}
    split = {
        0: ("Push Day", ["bench", "ohp", "pushdown", "dips"]),
        2: ("Pull Day", ["row", "pullup", "curl", "plank"]),
        4: ("Leg Day", ["squat", "rdl", "legpress", "plank"]),
    }
    start_week = now - timedelta(days=now.weekday() + 7 * (WEEKS_SHOWN * 2 - 1))
    workouts = []
    for week in range(WEEKS_SHOWN * 2):
        for weekday, (title, lifts) in split.items():
            if rng.random() < 0.12:
                continue
            day = start_week + timedelta(days=7 * week + weekday)
            begin = day.replace(hour=rng.choice([7, 18, 18, 19]), minute=rng.choice([0, 15, 30]), second=0, microsecond=0)
            if begin > now:
                continue
            exercises = []
            for lift in lifts:
                name, muscle, base, gain = catalogue[lift]
                weight = round((base + gain * week + rng.choice([0, 0, 2.5, -2.5])) / 2.5) * 2.5 if base else 0
                reps = rng.choice([5, 6, 8, 8, 10, 12]) if base else rng.choice([8, 10, 12])
                sets = [{"type": "warmup", "weight_kg": weight * 0.5, "reps": 10}]
                sets += [{"type": "normal", "weight_kg": weight, "reps": max(3, reps - (i % 2))} for i in range(rng.choice([3, 3, 4]))]
                exercises.append({"title": name, "exercise_template_id": lift, "sets": sets})
            minutes = rng.randint(52, 88)
            workouts.append({
                "id": "demo-%d-%d" % (week, weekday), "title": title,
                "start_time": begin.astimezone().isoformat(),
                "end_time": (begin + timedelta(minutes=minutes)).astimezone().isoformat(),
                "exercises": exercises,
            })
    return workouts, templates
