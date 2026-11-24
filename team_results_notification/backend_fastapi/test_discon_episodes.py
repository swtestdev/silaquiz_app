"""Unit tests for DISCON episode aggregation helpers."""
import unittest
from datetime import datetime, timezone, timedelta

# Import helpers from main (same module path as other backend tests)
from main import (
    _compute_completed_discon_episodes,
    _format_team_discon_label,
)


def _ts(sec: int) -> datetime:
    base = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    return base + timedelta(seconds=sec)


class DisconEpisodeTests(unittest.TestCase):
    def test_blur_then_invisible_then_visible(self):
        """2s blur + 5s invisible -> 7s before visible+connected."""
        events = [
            {"reason": "blur", "timestamp": _ts(2)},
            {"reason": "invisible", "timestamp": _ts(2)},
            {"reason": "visible", "timestamp": _ts(9)},
            {"reason": "connection", "timestamp": _ts(9)},
        ]
        server_now = _ts(60)
        count_until = server_now
        eps = _compute_completed_discon_episodes(
            events, count_until=count_until, server_now=server_now
        )
        self.assertEqual([d for _, d in eps], [7])

    def test_merged_with_disconnect(self):
        events = [
            {"reason": "blur", "timestamp": _ts(0)},
            {"reason": "invisible", "timestamp": _ts(2)},
            {"reason": "disconnection", "timestamp": _ts(7)},
            {"reason": "blur", "timestamp": _ts(13)},
            {"reason": "visible", "timestamp": _ts(15)},
            {"reason": "connection", "timestamp": _ts(15)},
        ]
        server_now = _ts(100)
        eps = _compute_completed_discon_episodes(
            events, count_until=server_now, server_now=server_now
        )
        self.assertEqual([d for _, d in eps], [15])

    def test_timer_freeze_closes_episode(self):
        events = [
            {"reason": "blur", "timestamp": _ts(0)},
            {"reason": "invisible", "timestamp": _ts(2)},
            {"reason": "disconnection", "timestamp": _ts(7)},
        ]
        server_now = _ts(100)
        count_until = _ts(17)
        eps = _compute_completed_discon_episodes(
            events, count_until=count_until, server_now=server_now
        )
        self.assertEqual([d for _, d in eps], [17])

    def test_open_episode_omitted_while_timer_runs(self):
        events = [
            {"reason": "disconnection", "timestamp": _ts(5)},
        ]
        server_now = _ts(30)
        count_until = server_now
        eps = _compute_completed_discon_episodes(
            events, count_until=count_until, server_now=server_now
        )
        self.assertEqual(eps, [])

    def test_format_label_chronological(self):
        label = _format_team_discon_label([(_ts(20), 5), (_ts(5), 7)])
        self.assertEqual(label, "7s, 5s")


if __name__ == "__main__":
    unittest.main()
