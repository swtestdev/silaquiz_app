"""Unit tests for WebSocket timer broadcast and connection stats."""

from __future__ import annotations

import asyncio
import json
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient

from main import ConnectionManager, app, manager


def test_broadcast_parallel_sends_to_all_connections() -> None:
    async def _run() -> None:
        mgr = ConnectionManager()
        ws1 = AsyncMock()
        ws2 = AsyncMock()
        mgr.active_connections = {"user_1_1": ws1, "user_2_2": ws2}
        mgr.user_connections = {1: "user_1_1", 2: "user_2_2"}

        payload = json.dumps({"type": "timer_trigger", "timer_action": "START_TIME"})
        await mgr.broadcast_to_all_players(payload)

        ws1.send_text.assert_awaited_once_with(payload)
        ws2.send_text.assert_awaited_once_with(payload)

    asyncio.run(_run())


def test_broadcast_removes_failed_connection() -> None:
    async def _run() -> None:
        mgr = ConnectionManager()
        ws_ok = AsyncMock()
        ws_bad = AsyncMock()
        ws_bad.send_text.side_effect = ConnectionResetError()
        mgr.active_connections = {"ok": ws_ok, "bad": ws_bad}
        mgr.user_connections = {1: "ok", 2: "bad"}

        await mgr.broadcast_to_all_players('{"type":"timer_trigger"}')

        assert "bad" not in mgr.active_connections
        assert 2 not in mgr.user_connections
        ws_ok.send_text.assert_awaited_once()

    asyncio.run(_run())


def test_broadcast_no_connections_is_noop() -> None:
    async def _run() -> None:
        mgr = ConnectionManager()
        await mgr.broadcast_to_all_players('{"type":"timer_trigger"}')

    asyncio.run(_run())


def test_manager_connection_stats_shape() -> None:
    stats = manager.get_connection_stats()
    assert set(stats.keys()) == {"total_connections", "connected_users", "user_connections"}


def test_connections_stats_endpoint() -> None:
    client = TestClient(app)
    response = client.get("/api/connections/stats")
    assert response.status_code == 200
    body = response.json()
    assert "total_connections" in body
    assert "connected_users" in body
