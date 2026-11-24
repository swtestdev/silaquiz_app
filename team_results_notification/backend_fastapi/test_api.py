#!/usr/bin/env python3
"""
Smoke-test script for the Quze FastAPI backend (main.py).

Usage:
  python test_api.py
  python test_api.py --base-url http://localhost:8000
  python test_api.py --write          # include mutating auth tests (register, logout)

Requires the server to be running. Read-only GET/POST checks run by default.
Mutating game/admin operations are not exercised automatically.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

import requests

DEFAULT_BASE_URL = os.environ.get("QUZE_API_BASE_URL", "http://localhost:8000")
ADMIN_EMAIL = "admin@silaquiz.com"
ADMIN_PASSWORD = "admin123"


@dataclass
class TestContext:
    base_url: str
    token: Optional[str] = None
    session_token: Optional[str] = None
    user_id: Optional[int] = None
    user_email: Optional[str] = None
    active_game_id: Optional[int] = None
    game_id: Optional[int] = None
    game_name: Optional[str] = None
    game_name_safe: Optional[str] = None
    round_name: Optional[str] = None
    question_id: Optional[int] = None
    team_id: Optional[int] = None
    results: List[Tuple[str, int, str]] = field(default_factory=list)

    def auth_headers(self) -> Dict[str, str]:
        if not self.token:
            return {"Content-Type": "application/json"}
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.token}",
        }


def _truncate(value: Any, limit: int = 240) -> str:
    text = json.dumps(value, default=str) if not isinstance(value, str) else value
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def _game_name_safe(name: str) -> str:
    return name.strip().lower().replace(" ", "_").replace("-", "_")


class ApiTester:
    def __init__(self, ctx: TestContext, write_mode: bool = False) -> None:
        self.ctx = ctx
        self.write_mode = write_mode
        self.session = requests.Session()

    def _record(self, label: str, response: requests.Response) -> None:
        ok = 200 <= response.status_code < 300
        marker = "OK" if ok else "FAIL"
        detail = ""
        try:
            detail = _truncate(response.json())
        except Exception:
            detail = _truncate(response.text)
        line = f"[{marker}] {label}: {response.status_code} {detail}"
        print(line)
        self.ctx.results.append((label, response.status_code, marker))

    def request(
        self,
        method: str,
        path: str,
        *,
        label: Optional[str] = None,
        auth: bool = False,
        json_body: Optional[dict] = None,
        params: Optional[dict] = None,
        expect: Optional[Callable[[requests.Response], bool]] = None,
    ) -> requests.Response:
        url = f"{self.ctx.base_url}{path}"
        headers = self.ctx.auth_headers() if auth else {"Content-Type": "application/json"}
        response = self.session.request(
            method,
            url,
            headers=headers,
            json=json_body,
            params=params,
            timeout=30,
        )
        test_label = label or f"{method} {path}"
        if expect is not None and not expect(response):
            print(f"[FAIL] {test_label}: unexpected response {response.status_code}")
            self.ctx.results.append((test_label, response.status_code, "FAIL"))
        else:
            self._record(test_label, response)
        return response

    def get(self, path: str, **kwargs: Any) -> requests.Response:
        return self.request("GET", path, **kwargs)

    def post(self, path: str, **kwargs: Any) -> requests.Response:
        return self.request("POST", path, **kwargs)

    def put(self, path: str, **kwargs: Any) -> requests.Response:
        return self.request("PUT", path, **kwargs)

    def delete(self, path: str, **kwargs: Any) -> requests.Response:
        return self.request("DELETE", path, **kwargs)

    # ------------------------------------------------------------------ #
    # Test groups
    # ------------------------------------------------------------------ #

    def test_public_endpoints(self) -> None:
        print("\n--- Public / unauthenticated ---")
        self.get("/", label="GET /")
        self.get("/api/health", label="GET /api/health")
        self.get("/api/app/version", label="GET /api/app/version")
        self.get("/api/rounds-info", label="GET /api/rounds-info")
        self.get("/api/connections/stats", label="GET /api/connections/stats")
        self.post("/api/connections/cleanup", label="POST /api/connections/cleanup")
        self.post("/api/admin/init-db", label="POST /api/admin/init-db")
        self.get("/api/active-games", label="GET /api/active-games")

    def test_admin_read_endpoints(self) -> None:
        print("\n--- Admin read-only ---")
        self.get("/api/admin/users", label="GET /api/admin/users")
        self.get("/api/admin/teams", label="GET /api/admin/teams")
        self.get("/api/admin/games", label="GET /api/admin/games")

        resp = self.get("/api/admin/active-games", label="GET /api/admin/active-games")
        try:
            payload = resp.json()
        except Exception:
            payload = {}
        games = payload.get("games") or []
        if games:
            first = games[0]
            self.ctx.active_game_id = first.get("id")
            self.ctx.game_id = first.get("game_id")
            self.ctx.game_name = first.get("game_name")
            if self.ctx.game_name:
                self.ctx.game_name_safe = _game_name_safe(self.ctx.game_name)
            round_names = first.get("round_names") or []
            if round_names:
                self.ctx.round_name = round_names[0]

        resp = self.get("/api/admin/games", label="GET /api/admin/games (discover game)")
        try:
            games_list = resp.json().get("games") or []
        except Exception:
            games_list = []
        if games_list and not self.ctx.game_id:
            g = games_list[0]
            self.ctx.game_id = g.get("id")
            self.ctx.game_name = g.get("game_name")
            if self.ctx.game_name:
                self.ctx.game_name_safe = _game_name_safe(self.ctx.game_name)

        if self.ctx.game_id and not self.ctx.round_name:
            rounds_resp = self.get(
                f"/api/admin/games/{self.ctx.game_id}/rounds",
                label="GET /api/admin/games/{game_id}/rounds (discover round)",
            )
            try:
                round_names = rounds_resp.json().get("round_names") or []
                if round_names:
                    self.ctx.round_name = round_names[0]
            except Exception:
                pass

        if self.ctx.game_id:
            structure_resp = self.get(
                f"/api/admin/games/{self.ctx.game_id}/structure",
                label="GET /api/admin/games/{game_id}/structure",
            )
            try:
                structure = structure_resp.json()
                questions = structure.get("questions") or []
                if questions:
                    self.ctx.question_id = questions[0].get("id")
            except Exception:
                pass

        if self.ctx.active_game_id:
            ag = self.ctx.active_game_id
            self.get(f"/api/active-games/{ag}", label="GET /api/active-games/{game_id}")
            self.get(
                f"/api/admin/active-games/{ag}/results-structure",
                label="GET /api/admin/active-games/{id}/results-structure",
            )
            self.get(
                f"/api/admin/active-games/{ag}/bonus-options",
                label="GET /api/admin/active-games/{id}/bonus-options",
            )
            self.get(
                f"/api/admin/active-games/{ag}/teams-start",
                label="GET /api/admin/active-games/{id}/teams-start",
            )
            self.get(
                f"/api/admin/active-games/{ag}/scoreboard",
                label="GET /api/admin/active-games/{id}/scoreboard",
            )
            self.get(
                f"/api/admin/active-games/{ag}/rounds/started-status",
                label="GET /api/admin/active-games/{id}/rounds/started-status",
            )
            self.get(
                f"/api/admin/active-games/{ag}/round-tracking",
                label="GET /api/admin/active-games/{id}/round-tracking",
            )

            if self.ctx.round_name:
                rn = self.ctx.round_name
                self.get(
                    f"/api/admin/active-games/{ag}/rounds/{rn}/grading-grid",
                    label="GET /api/admin/active-games/{id}/rounds/{round}/grading-grid",
                )
                self.get(
                    f"/api/admin/active-games/{ag}/rounds/{rn}/list-review",
                    label="GET /api/admin/active-games/{id}/rounds/{round}/list-review",
                )
                self.get(
                    f"/api/admin/active-games/{ag}/rounds/{rn}/app-tracking",
                    label="GET /api/admin/active-games/{id}/rounds/{round}/app-tracking",
                )
                if self.ctx.question_id:
                    qid = self.ctx.question_id
                    self.get(
                        f"/api/admin/active-games/{ag}/rounds/{rn}/questions/{qid}/review",
                        label="GET /api/admin/.../questions/{id}/review",
                    )

        teams_resp = self.session.get(
            f"{self.ctx.base_url}/api/admin/teams",
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        try:
            teams = teams_resp.json()
            if isinstance(teams, list) and teams:
                self.ctx.team_id = teams[0].get("id")
                if self.ctx.team_id:
                    self.get(
                        f"/api/admin/teams/{self.ctx.team_id}/members",
                        label="GET /api/admin/teams/{team_id}/members",
                    )
        except Exception:
            pass

    def test_auth_flow(self) -> bool:
        print("\n--- Authentication ---")
        if self.write_mode:
            unique = uuid.uuid4().hex[:8]
            self.post(
                "/api/auth/register",
                label="POST /api/auth/register",
                json_body={
                    "email": f"test_{unique}@example.com",
                    "password": "test12345",
                    "name": "API Test User",
                },
            )

        resp = self.post(
            "/api/auth/login",
            label="POST /api/auth/login (admin)",
            json_body={"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD},
        )
        if resp.status_code != 200:
            print("Cannot continue authenticated tests without login.")
            return False

        try:
            data = resp.json()
        except Exception:
            print("Login response is not JSON.")
            return False

        self.ctx.token = data.get("access_token")
        self.ctx.session_token = data.get("session_token")
        user = data.get("user") or {}
        self.ctx.user_id = user.get("id")
        self.ctx.user_email = user.get("email")
        return bool(self.ctx.token)

    def test_authenticated_endpoints(self) -> None:
        print("\n--- Authenticated user ---")
        if not self.ctx.token:
            print("Skipped (no token).")
            return

        self.get("/api/users/me", label="GET /api/users/me", auth=True)
        self.get("/api/auth/validate-session", label="GET /api/auth/validate-session", auth=True)
        self.get("/api/auth/check-login", label="GET /api/auth/check-login", auth=True)
        self.get("/api/timer/active", label="GET /api/timer/active", auth=True)
        self.get("/api/timer/last-setting", label="GET /api/timer/last-setting", auth=True)

        if self.ctx.session_token:
            self.post(
                "/api/auth/echo",
                label="POST /api/auth/echo",
                auth=True,
                json_body={
                    "session_token": self.ctx.session_token,
                    "app_visible": True,
                    "source": "periodic",
                },
            )

        if self.ctx.user_id:
            self.get(
                f"/api/player/active-games/{self.ctx.user_id}",
                label="GET /api/player/active-games/{user_id}",
            )

        if self.ctx.game_name and self.ctx.round_name:
            self.get(
                f"/api/games/{self.ctx.game_name}/round/{self.ctx.round_name}",
                label="GET /api/games/{game_name}/round/{round_name}",
                auth=True,
            )
            self.get(
                f"/api/games/{self.ctx.game_name}/rounds",
                label="GET /api/games/{game_name}/rounds",
                auth=True,
            )
            if self.ctx.game_name_safe:
                self.get(
                    f"/api/action-game-control/{self.ctx.game_name_safe}/round/{self.ctx.round_name}",
                    label="GET /api/action-game-control/{game}/round/{round}",
                    auth=True,
                )
            if self.ctx.question_id:
                self.get(
                    f"/api/games/{self.ctx.game_name}/question-by-id/{self.ctx.question_id}",
                    label="GET /api/games/{game_name}/question-by-id/{id}",
                    auth=True,
                )

        if self.ctx.team_id:
            self.post(
                "/api/teams/get_team_name",
                label="POST /api/teams/get_team_name",
                json_body={"team_id": self.ctx.team_id},
            )

        if (
            self.ctx.active_game_id
            and self.ctx.game_name_safe
            and self.ctx.team_id
        ):
            self.get(
                f"/api/active-games/team-answers/{self.ctx.game_name_safe}/{self.ctx.team_id}",
                label="GET /api/active-games/team-answers/{game}/{team_id}",
                auth=True,
            )

        if self.ctx.user_id and self.ctx.round_name and self.ctx.active_game_id:
            self.get(
                f"/api/admin/active-games/{self.ctx.active_game_id}/rounds/{self.ctx.round_name}/app-tracking/players/{self.ctx.user_id}",
                label="GET /api/admin/.../app-tracking/players/{user_id}",
            )

        if self.write_mode:
            self.post("/api/auth/logout", label="POST /api/auth/logout", auth=True)

    def test_documented_but_skipped(self) -> None:
        print("\n--- Not covered by HTTP smoke tests ---")
        skipped = [
            "WebSocket /ws/timer/{user_id}",
            "POST /api/admin/games/load-excel (requires file upload)",
            "POST /api/admin/active-games (creates game state)",
            "POST /api/admin/active-games/{id}/start|pause|resume|run|stop",
            "POST /api/admin/active-games/{id}/grade",
            "POST /api/admin/active-games/{id}/export-results",
            "POST /api/timer/trigger",
            "POST /api/be_ready_to_start",
            "POST /api/team/toggle-writer",
            "POST /api/player/select-bonus-option",
            "POST /api/player/select-default-option",
            "PUT /api/active-games/team-answers/{game}/{team_id}",
            "POST review-batch / list-review-batch (mutating admin review)",
        ]
        for item in skipped:
            print(f"  - {item}")

    def run(self) -> int:
        print("Quze FastAPI API smoke tests")
        print("=" * 60)
        print(f"Base URL: {self.ctx.base_url}")
        print(f"Write mode: {self.write_mode}")

        try:
            self.session.get(self.ctx.base_url, timeout=5)
        except requests.RequestException as exc:
            print(f"\nServer unreachable at {self.ctx.base_url}: {exc}")
            print("Start the backend first (e.g. python main.py).")
            return 1

        self.test_public_endpoints()
        self.test_admin_read_endpoints()
        logged_in = self.test_auth_flow()
        if logged_in:
            self.test_authenticated_endpoints()
        self.test_documented_but_skipped()

        passed = sum(1 for _, _, m in self.ctx.results if m == "OK")
        failed = sum(1 for _, _, m in self.ctx.results if m == "FAIL")
        print("\n" + "=" * 60)
        print(f"Results: {passed} passed, {failed} failed, {len(self.ctx.results)} total")
        if self.ctx.active_game_id:
            print(
                f"Context: active_game_id={self.ctx.active_game_id}, "
                f"game={self.ctx.game_name!r}, round={self.ctx.round_name!r}"
            )
        return 1 if failed else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Smoke-test Quze FastAPI endpoints")
    parser.add_argument(
        "--base-url",
        default=DEFAULT_BASE_URL,
        help=f"API base URL (default: {DEFAULT_BASE_URL})",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Run mutating auth tests (register, logout)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    ctx = TestContext(base_url=args.base_url.rstrip("/"))
    tester = ApiTester(ctx, write_mode=args.write)
    sys.exit(tester.run())


if __name__ == "__main__":
    main()
