# Quze Game API Reference

Base URL: `{BASE_URL}/api` (e.g. `http://localhost:8000/api`)

Authentication: Bearer token in `Authorization` header for protected routes.

---

## General

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | No | API info and version |
| GET | `/api/health` | No | Health check |

---

## Auth

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/auth/register` | No | Register new user. Body: `{email, password, name}` |
| POST | `/api/auth/login` | No | Login. Body: `{email, password}`. Returns `user`, `access_token`, `session_token` |
| POST | `/api/auth/logout` | Yes | Logout, invalidate session |
| GET | `/api/auth/validate-session` | Yes | Validate token, return user data |
| GET | `/api/auth/check-login` | Yes | Simple login check |
| POST | `/api/auth/echo` | Yes | Echo/keepalive. Body: `{session_token, app_visible}`. Updates `visible_connected` |

---

## Users

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/users/me` | Yes | Get current user |
| PUT | `/api/users/{user_id}/profile` | Yes | Update own profile. Body: `{name?, email?, password?, playing_in_team_id?}` |

---

## Teams

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/teams/get_team_name` | No | Lookup team by code or id. Body: `{team_code? or team_id?}` |

---

## Active Games (Public)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/active-games` | No | List all active games |
| GET | `/api/active-games/{game_id}` | No | Get one active game |
| PUT | `/api/active-games/{game_id}` | Yes | Update active game. Body: `{teams_ids?, question_id?, round_id?, is_started?, timer_on_at, timer_off_at, team_ids_finished?}` |

---

## Player

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/player/active-games/{user_id}` | No | Get active games for player (based on team) |
| POST | `/api/player/select-bonus-option` | No | Select bonus score option. Body: `{user_id, active_game_id, question_id, team_id, correct_score, wrong_score}` |
| POST | `/api/player/select-default-option` | No | Select default score option. Body: `{user_id, active_game_id, question_id, team_id}` |

---

## Games & Rounds

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/games/{game_name}/rounds` | No | List rounds for a game |
| GET | `/api/games/{game_name}/round/{round_name}` | No | Get questions for a round |
| GET | `/api/active-games/team-answers/{game_name_safe}/{team_id}` | No | Get team answers for a game |
| GET | `/api/action-game-control/{game_name_safe}/round/{round_name}` | No | Get timer/slide control for round |

---

## Timer

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/timer/trigger` | No | Trigger timer from external source (e.g. PowerPoint VBA). Body: `{trigger_data}`. Format: `Slide#N#START_TIMER#round_X#at#datetime#time#...` or `Slide#N#STOP_TIMER#...#at#datetime` |
| GET | `/api/timer/last-setting` | Yes | Get last timer setting (for reconnection) |
| GET | `/api/rounds-info` | No | Get rounds info (names, slides, timestamps) |

---

## Team Controls

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/team/toggle-writer` | Yes | Toggle writer status. Body: `{action: "on"|"off"}` |
| POST | `/api/be_ready_to_start` | No | Mark team ready. Body: `{user_id, active_game_id, team_id}` |

---

## Admin – Init

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/admin/init-db` | No | Initialize DB with sample admin users |

---

## Admin – Users

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/admin/users` | Yes (admin) | List all users |
| PUT | `/api/admin/users/{user_id}` | Yes (admin) | Update user (role, team, etc.) |

---

## Admin – Teams

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/admin/teams` | Yes (admin) | List all teams |
| POST | `/api/admin/teams` | Yes (admin) | Create team. Body: `{team_name, team_city}` |
| PUT | `/api/admin/teams/{team_id}` | Yes (admin) | Update team |
| GET | `/api/admin/teams/{team_id}/members` | Yes (admin) | Get team members |

---

## Admin – Games

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/admin/games` | Yes (admin) | List all games |
| GET | `/api/admin/games/{game_id}/structure` | Yes (admin) | Get game structure (rounds, questions) |
| POST | `/api/admin/games/load-excel` | Yes (admin) | Load game from Excel. Body: `{game_name, game_description?, base64_excel_data}` |

---

## Admin – Active Games

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/admin/active-games` | Yes (admin) | List active games with details |
| POST | `/api/admin/active-games` | Yes (admin) | Create active game |
| PUT | `/api/admin/active-games/{active_game_id}` | Yes (admin) | Update active game |
| DELETE | `/api/admin/active-games/{active_game_id}` | Yes (admin) | Delete active game |
| POST | `/api/admin/active-games/{active_game_id}/start` | Yes (admin) | Start game |
| POST | `/api/admin/active-games/{active_game_id}/pause` | Yes (admin) | Pause game |
| POST | `/api/admin/active-games/{active_game_id}/resume` | Yes (admin) | Resume game |
| POST | `/api/admin/active-games/{active_game_id}/stop` | Yes (admin) | Stop game |
| POST | `/api/admin/active-games/{active_game_id}/run` | Yes (admin) | Set game to running |
| GET | `/api/admin/active-games/{active_game_id}/results-structure` | Yes (admin) | Get results structure |
| GET | `/api/admin/active-games/{active_game_id}/bonus-options` | Yes (admin) | Get bonus options for questions |

---

## Connections

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/connections/stats` | No | WebSocket connection stats |
| POST | `/api/connections/disconnect/{user_id}` | Yes (admin) | Force disconnect user |
| POST | `/api/connections/cleanup` | No | Clean orphaned connections |

---

## App

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/app/version` | No | App version info |
| GET | `/api/round/{round_id}` | No | Test/dev rounds query |

---

## WebSocket

| Path | Description |
|------|-------------|
| `/ws/timer/{user_id}` | Real-time timer sync. Clients receive timer messages (START_TIMER, STOP_TIMER, etc.) |

---

## Auth Flow

1. `POST /api/auth/login` → receive `access_token`, `session_token`
2. Use `Authorization: Bearer {access_token}` on protected routes
3. Send `POST /api/auth/echo` periodically with `session_token` and `app_visible` to keep session alive and update visibility
