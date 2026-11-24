"""Unit tests for tracking_episodes window + Q2 leading gap."""
import unittest
from datetime import datetime, timezone, timedelta

from tracking_episodes import (
    compute_discon_episodes_in_window,
    compute_discon_for_windows,
    format_discon_label,
)


def _ts(sec: int) -> datetime:
    base = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    return base + timedelta(seconds=sec)


class TrackingEpisodeWindowTests(unittest.TestCase):
    def test_leading_gap_when_late(self):
        """Unavailable at window start, visible at t=5 → 5s leading episode."""
        events = [
            {"reason": "visible", "timestamp": _ts(5)},
            {"reason": "connection", "timestamp": _ts(5)},
        ]
        eps = compute_discon_episodes_in_window(events, _ts(0), _ts(60))
        self.assertEqual([d for _, d in eps], [5])

    def test_never_available_whole_window_is_zero(self):
        events = [
            {"reason": "disconnection", "timestamp": _ts(1)},
        ]
        eps = compute_discon_episodes_in_window(events, _ts(0), _ts(60))
        self.assertEqual(eps, [])

    def test_open_at_window_end_not_counted(self):
        events = [
            {"reason": "visible", "timestamp": _ts(0)},
            {"reason": "disconnection", "timestamp": _ts(10)},
        ]
        eps = compute_discon_episodes_in_window(events, _ts(0), _ts(20))
        self.assertEqual(eps, [])

    def test_closed_episode_inside_window(self):
        events = [
            {"reason": "visible", "timestamp": _ts(0)},
            {"reason": "connection", "timestamp": _ts(0)},
            {"reason": "blur", "timestamp": _ts(10)},
            {"reason": "visible", "timestamp": _ts(15)},
            {"reason": "connection", "timestamp": _ts(15)},
        ]
        eps = compute_discon_episodes_in_window(events, _ts(0), _ts(60))
        self.assertEqual([d for _, d in eps], [5])

    def test_classic_two_windows(self):
        events = [
            {"reason": "visible", "timestamp": _ts(0)},
            {"reason": "connection", "timestamp": _ts(0)},
            {"reason": "blur", "timestamp": _ts(5)},
            {"reason": "visible", "timestamp": _ts(8)},
            {"reason": "connection", "timestamp": _ts(8)},
            {"reason": "blur", "timestamp": _ts(65)},
            {"reason": "visible", "timestamp": _ts(70)},
            {"reason": "connection", "timestamp": _ts(70)},
        ]
        windows = [(_ts(0), _ts(30)), (_ts(60), _ts(90))]
        eps = compute_discon_for_windows(events, windows)
        self.assertEqual([d for _, d in eps], [3, 5])
        self.assertEqual(format_discon_label(eps), "3s, 5s")


if __name__ == "__main__":
    unittest.main()
