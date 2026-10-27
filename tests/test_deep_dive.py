"""Tests for the Hevy deep-dive layer (no network, no account)."""

import os
import sys
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import deep_dive as dd  # noqa: E402
import hevy_api as api  # noqa: E402

NOW = datetime(2026, 10, 27, 12, 0).astimezone()


def workout(days_ago, exercises, hour=18, minutes=60):
    begin = (NOW - timedelta(days=days_ago)).replace(hour=hour, minute=0, second=0, microsecond=0)
    return {"id": "w%d" % days_ago, "title": "Session", "start_time": begin.isoformat(),
            "end_time": (begin + timedelta(minutes=minutes)).isoformat(), "exercises": exercises}


def lift(title, template, *sets):
    return {"title": title, "exercise_template_id": template,
            "sets": [{"type": "normal", "weight_kg": w, "reps": r} for w, r in sets]}


TEMPLATES = {"bench": "chest", "row": "lats", "facepull": "shoulders", "ohp": "shoulders", "squat": "quadriceps"}


def sessions(workouts):
    return dd.parse_sessions(workouts, TEMPLATES, api.parse_ts, api.local, api.MUSCLE_TO_GROUP, api.MUSCLE_LABELS)


class Basics(unittest.TestCase):
    def test_e1rm_matches_the_overview_formula(self):
        self.assertAlmostEqual(dd.e1rm(100, 6), 120.0)

    def test_warmups_never_count(self):
        w = workout(1, [{"title": "Bench", "exercise_template_id": "bench",
                         "sets": [{"type": "warmup", "weight_kg": 20, "reps": 10}, {"type": "normal", "weight_kg": 80, "reps": 5}]}])
        row = sessions([w])[0]["exercises"][0]
        self.assertEqual(row["sets"], [(80.0, 5)])

    def test_sessions_come_back_oldest_first(self):
        rows = sessions([workout(1, [lift("Bench", "bench", (80, 5))]), workout(9, [lift("Bench", "bench", (75, 5))])])
        self.assertLess(rows[0]["moment"], rows[1]["moment"])


class Progression(unittest.TestCase):
    def test_needs_two_sessions_and_reports_change(self):
        rows = sessions([workout(14, [lift("Bench", "bench", (60, 5))]), workout(7, [lift("Bench", "bench", (66, 5))]),
                         workout(2, [lift("Row", "row", (50, 8))])])
        lifts = dd.progression(rows)
        self.assertEqual([l["title"] for l in lifts], ["Bench"])
        self.assertAlmostEqual(lifts[0]["change_pct"], 10.0, places=1)
        self.assertEqual(lifts[0]["sessions"], 2)

    def test_series_is_capped(self):
        rows = sessions([workout(d, [lift("Bench", "bench", (60 + d, 5))]) for d in range(1, 30)])
        self.assertEqual(len(dd.progression(rows)[0]["series"]), dd.SERIES_POINTS)


class Records(unittest.TestCase):
    def test_first_session_is_not_a_record_but_a_beaten_best_is(self):
        rows = sessions([workout(20, [lift("Bench", "bench", (60, 5))]), workout(10, [lift("Bench", "bench", (60, 5))]),
                         workout(3, [lift("Bench", "bench", (70, 5))])])
        events = dd.personal_records(rows)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["weight_kg"], 70.0)
        self.assertGreater(events[0]["e1rm_kg"], events[0]["previous_kg"])

    def test_a_lighter_day_after_a_record_is_not_a_record(self):
        rows = sessions([workout(9, [lift("Bench", "bench", (60, 5))]), workout(6, [lift("Bench", "bench", (70, 5))]),
                         workout(3, [lift("Bench", "bench", (65, 5))])])
        self.assertEqual(len(dd.personal_records(rows)), 1)


class Balance(unittest.TestCase):
    def test_face_pulls_count_as_pull_not_push(self):
        ex = lambda title, muscle: {"title": title, "muscle": muscle}  # noqa: E731
        self.assertEqual(dd.side(ex("Face Pull", "shoulders")), "pull")
        self.assertEqual(dd.side(ex("Tirón a la Cara", "shoulders")), "pull")
        self.assertEqual(dd.side(ex("Vuelos Posteriores (Máquina)", "shoulders")), "pull")
        self.assertEqual(dd.side(ex("Overhead Press", "shoulders")), "push")
        self.assertEqual(dd.side(ex("Bench", "chest")), "push")
        self.assertEqual(dd.side(ex("Row", "lats")), "pull")
        self.assertEqual(dd.side(ex("Squat", "quadriceps")), "legs")

    def test_totals_use_only_the_recent_window(self):
        rows = sessions([workout(3, [lift("Bench", "bench", (80, 5), (80, 5))]),
                         workout(60, [lift("Bench", "bench", (80, 5))])])
        out = dd.balance(rows, 4, NOW, api.week_start)
        self.assertEqual(out["push"], 2)


class Patterns(unittest.TestCase):
    def test_weekday_time_and_rep_buckets(self):
        rows = sessions([workout(1, [lift("Bench", "bench", (80, 4), (60, 12), (40, 20))], hour=7)])
        out = dd.patterns(rows)
        self.assertEqual(sum(d["workouts"] for d in out["weekday"]), 1)
        self.assertEqual(next(t for t in out["time_of_day"] if t["key"] == "morning")["workouts"], 1)
        reps = {r["range"]: r["sets"] for r in out["rep_ranges"]}
        self.assertEqual((reps["1–5"], reps["11–15"], reps["16+"]), (1, 1, 1))

    def test_time_of_day_edges(self):
        self.assertEqual(dd._time_of_day(4), "night")
        self.assertEqual(dd._time_of_day(10), "morning")
        self.assertEqual(dd._time_of_day(11), "midday")
        self.assertEqual(dd._time_of_day(19), "evening")


class Weeks(unittest.TestCase):
    def test_weekly_sets_has_a_row_per_group_and_one_slot_per_week(self):
        rows = sessions([workout(1, [lift("Bench", "bench", (80, 5), (80, 5))])])
        grid = dd.weekly_sets(rows, api.week_start, NOW)
        self.assertEqual(len(grid["weeks"]), dd.WEEKS_SHOWN)
        chest = next(r for r in grid["rows"] if r["key"] == "chest")
        self.assertEqual(sum(chest["weeks"]), 2)
        self.assertEqual(len(chest["weeks"]), dd.WEEKS_SHOWN)

    def test_duration_is_none_for_weeks_without_sessions(self):
        rows = sessions([workout(1, [lift("Bench", "bench", (80, 5))], minutes=45)])
        out = dd.duration_by_week(rows, api.week_start, NOW)
        self.assertEqual(len(out), 12)
        self.assertEqual(out[-1]["avg_min"], 45)
        self.assertIsNone(out[0]["avg_min"])


class Whole(unittest.TestCase):
    def test_demo_runs_through_the_real_pipeline(self):
        workouts, templates = dd.demo_workouts(NOW)
        deep = dd.deep_dive(workouts, templates, NOW, api.deep_helpers())
        self.assertGreater(deep["sessions_in_window"], 20)
        self.assertTrue(deep["progression"] and deep["prs"] and deep["insights"])
        self.assertEqual(len(deep["weekly_sets"]["rows"]), len(dd.GROUP_ORDER))

    def test_empty_account_does_not_crash(self):
        deep = dd.deep_dive([], {}, NOW, api.deep_helpers())
        self.assertEqual(deep["sessions_in_window"], 0)
        self.assertEqual(deep["insights"], [])

    def test_safe_deep_reports_instead_of_raising(self):
        out = api.safe_deep([{"start_time": "2026-10-01T10:00:00Z", "exercises": [{"sets": "boom"}]}], {}, NOW)
        self.assertTrue("error" in out or out["sessions_in_window"] >= 0)


if __name__ == "__main__":
    unittest.main()
