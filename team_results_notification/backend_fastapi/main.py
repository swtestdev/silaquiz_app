from __future__ import annotations

from fastapi import FastAPI, HTTPException, Depends, Request, WebSocket, WebSocketDisconnect, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr, constr
from sqlalchemy import create_engine, Column, Integer, Float, String, DateTime, Boolean, text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session, validates
from passlib.context import CryptContext
from datetime import datetime, timedelta, timezone
from sqlalchemy import Enum
import random
import string
import jwt
import uvicorn
import os
import logging
from dotenv import load_dotenv

load_dotenv()
import json
import asyncio
import re
import uuid
from typing import Optional, List, Dict, Any, Union, Set, Tuple, FrozenSet

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _parse_trigger_time_segment(raw: Optional[str]) -> int:
    """Parse VBA #time# segment (e.g. '20', '1 min_black', '90 sec') into seconds."""
    if raw is None:
        return 0
    s = str(raw).strip().lower()
    if not s:
        return 0
    if s.isdigit():
        return int(s)
    m = re.match(r"^(\d+)\s*min", s)
    if m:
        return int(m.group(1)) * 60
    m = re.match(r"^(\d+)\s*sec", s)
    if m:
        return int(m.group(1))
    m = re.match(r"^(\d+)", s)
    if m:
        return int(m.group(1))
    return 0


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _format_utc_iso_z(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    return dt.replace(microsecond=(dt.microsecond // 1000) * 1000).isoformat().replace("+00:00", "Z")


# Global dictionary to track round information for active games
# Format: {"round_1": {"Name": None, "Slide": None, "time_now": None}, ...}
rounds_info = {}
last_timer_setting = None
for i in range(1, 21):  # rounds 1-20
    rounds_info[f"round_{i}"] = {"Name": None, "Slide": None, "time_now": None}

# Server-side per-question answer timer window (UTC) — writer answer deadline + player tracking
_server_answer_window_end: Optional[datetime] = None
_server_answer_window_question_id: int = 0
# Echo visibility: transition tracking and last known visible flag (for WS disconnect rules)
_echo_app_visible: Dict[int, bool] = {}
_prev_echo_app_visible: Dict[int, Optional[bool]] = {}
_pending_server_stop_task: Optional[asyncio.Task] = None
_server_fired_stop_ids: Set[str] = set()

# Per-question player-event tracking window (type_game == 0); set with server answer window
_question_track_window_id: str = ""
_question_track_round_name: str = ""

# Round-scoped player-event window (type_game != 0): from first question START in round until STOP or LAST end
_round_track_active: bool = False
_round_track_active_game_id: int = 0
_round_track_round_name: str = ""
_round_track_window_id: str = ""
_round_track_ends_at: Optional[datetime] = None

# Player state for transition-only + 3s cooldown (keys: user_id)
_last_player_track_ws_connected: Dict[int, bool] = {}
_last_player_track_visible: Dict[int, bool] = {}
# Cooldown: (user_id, team_id, window_id, reason) -> last insert UTC (same reason only; distinct reasons not collapsed)
_player_tracking_cooldown: Dict[Tuple[int, int, str, str], datetime] = {}
PLAYER_TRACKING_COOLDOWN_SEC: float = 3.0
_last_conn_track_ts: Dict[Tuple[int, int, str], datetime] = {}
PLAYER_CONN_FLIP_DEBOUNCE_SEC: float = 1.0

TRACKING_REASONS_ALL: FrozenSet[str] = frozenset(
    {
        "connection",
        "disconnection",
        "visible",
        "invisible",
        "visibility_hidden",
        "visibility_visible",
        "blur",
        "focus",
        "lifecycle_paused",
        "lifecycle_resumed",
        "lifecycle_hidden",
        "lifecycle_inactive",
        "lifecycle_detached",
        "beforeunload",
        "pagehide",
    }
)
TRACKING_ATTENTION_VISIBLE: FrozenSet[str] = frozenset(
    {"visible", "visibility_visible", "focus", "lifecycle_resumed"}
)
TRACKING_ATTENTION_INVISIBLE: FrozenSet[str] = frozenset(
    {
        "invisible",
        "visibility_hidden",
        "blur",
        "lifecycle_paused",
        "lifecycle_hidden",
        "lifecycle_inactive",
        "lifecycle_detached",
        "beforeunload",
        "pagehide",
    }
)

# Serialize echo-based visibility tracking per user (avoids parallel requests double-counting)
_echo_tracking_locks: Dict[int, asyncio.Lock] = {}


def _echo_tracking_lock_for(user_id: int) -> asyncio.Lock:
    lk = _echo_tracking_locks.get(user_id)
    if lk is None:
        lk = asyncio.Lock()
        _echo_tracking_locks[user_id] = lk
    return lk


def _clear_round_track_window() -> None:
    global _round_track_active, _round_track_active_game_id, _round_track_round_name, _round_track_window_id, _round_track_ends_at
    _round_track_active = False
    _round_track_active_game_id = 0
    _round_track_round_name = ""
    _round_track_window_id = ""
    _round_track_ends_at = None


def _is_round_tracking_window_active() -> bool:
    if not _round_track_active or not _round_track_window_id:
        return False
    if _round_track_ends_at is not None and _utc_now() >= _round_track_ends_at:
        return False
    return True


def _user_team_id_int(user: User) -> Optional[int]:
    if not user.playing_in_team_id:
        return None
    try:
        return int(user.playing_in_team_id) if isinstance(user.playing_in_team_id, str) else user.playing_in_team_id
    except (ValueError, TypeError):
        return None


def _user_in_active_game_teams(user: User, ag: ActiveGame) -> bool:
    tid = _user_team_id_int(user)
    if not tid or not ag.teams_ids:
        return False
    team_ids = [x.strip() for x in str(ag.teams_ids).split(",") if x.strip()]
    return str(tid) in team_ids


def _get_player_tracking_context(db: Session, user: User) -> Optional[Dict[str, Any]]:
    ag = db.query(ActiveGame).filter(ActiveGame.is_started == "running").first()
    if not ag or not _user_in_active_game_teams(user, ag):
        return None
    g = db.query(GamesList).filter(GamesList.id == ag.game_id).first()
    if not g:
        return None
    game_safe = str(g.game_name).strip().lower().replace(" ", "_").replace("-", "_")
    tid = _user_team_id_int(user)
    if not tid:
        return None
    if _is_round_tracking_window_active() and _round_track_window_id:
        qid: Optional[int] = None
        if last_timer_setting:
            try:
                raw = last_timer_setting.get("question_id")
                if raw is not None:
                    qid = int(raw)
            except (TypeError, ValueError):
                qid = None
        if qid is not None and qid <= 0:
            qid = None
        return {
            "active_game_id": ag.id,
            "game_name_safe": game_safe,
            "team_id": tid,
            "window_scope": "round",
            "window_id": _round_track_window_id,
            "round_name": _round_track_round_name or None,
            "question_id": qid,
        }
    if (
        _is_server_answer_window_active()
        and _question_track_window_id
        and _server_answer_window_question_id > 0
    ):
        return {
            "active_game_id": ag.id,
            "game_name_safe": game_safe,
            "team_id": tid,
            "window_scope": "question",
            "window_id": _question_track_window_id,
            "round_name": _question_track_round_name or None,
            "question_id": _server_answer_window_question_id,
        }
    return None


def _try_record_player_tracking_event(
    db: Session,
    user: User,
    reason: str,
) -> None:
    """
    Insert one row into active_round_tracking_<game> during a valid timer window.
    - connection/disconnection: transition-gated + 3s same-reason cooldown.
    - attention / audit reasons: 3s same-reason cooldown only (distinct reasons preserved).
    Timestamp is DB-authoritative (DEFAULT CURRENT_TIMESTAMP).
    """
    if not user or user.role != "player" or not user.playing_in_team_id:
        return
    if reason not in TRACKING_REASONS_ALL:
        return
    ctx = _get_player_tracking_context(db, user)
    if not ctx:
        return
    team_id = int(ctx["team_id"])
    user_id = int(user.id)
    window_id = str(ctx["window_id"])
    win_scope = str(ctx["window_scope"])
    round_name = ctx.get("round_name")
    question_id = ctx.get("question_id")
    now = _utc_now()

    if reason == "connection":
        if _last_player_track_ws_connected.get(user_id) is True:
            return
    elif reason == "disconnection":
        if _last_player_track_ws_connected.get(user_id) is False:
            return
    elif reason in TRACKING_ATTENTION_VISIBLE:
        pass
    elif reason in TRACKING_ATTENTION_INVISIBLE:
        pass
    else:
        return

    flip_key = (user_id, team_id, window_id)
    if reason in ("connection", "disconnection"):
        lc = _last_conn_track_ts.get(flip_key)
        if lc is not None and (now - lc).total_seconds() < PLAYER_CONN_FLIP_DEBOUNCE_SEC:
            if reason == "connection":
                _last_player_track_ws_connected[user_id] = True
            else:
                _last_player_track_ws_connected[user_id] = False
            return

    key = (user_id, team_id, window_id, reason)
    last_ins = _player_tracking_cooldown.get(key)
    if last_ins is not None and (now - last_ins).total_seconds() < PLAYER_TRACKING_COOLDOWN_SEC:
        return

    table = f"active_round_tracking_{ctx['game_name_safe']}"
    try:
        db.execute(
            text(
                f"""
                INSERT INTO `{table}`
                    (team_id, user_id, round_name, question_id, reason, window_scope, window_id)
                VALUES
                    (:team_id, :user_id, :round_name, :question_id, :reason, :window_scope, :window_id)
                """
            ),
            {
                "team_id": team_id,
                "user_id": user_id,
                "round_name": round_name,
                "question_id": question_id,
                "reason": reason,
                "window_scope": win_scope,
                "window_id": window_id,
            },
        )
        if reason == "connection":
            _last_player_track_ws_connected[user_id] = True
        elif reason == "disconnection":
            _last_player_track_ws_connected[user_id] = False
        elif reason in TRACKING_ATTENTION_VISIBLE:
            _last_player_track_visible[user_id] = True
        elif reason in TRACKING_ATTENTION_INVISIBLE:
            _last_player_track_visible[user_id] = False
        if reason in ("connection", "disconnection"):
            _last_conn_track_ts[flip_key] = now
        _player_tracking_cooldown[key] = now
        db.commit()
    except Exception as e:
        logger.warning("round tracking insert failed: %s", e)
        try:
            db.rollback()
        except Exception:  # noqa: S110
            pass


def _upgrade_round_tracking_reason_to_varchar_if_needed(db: Session, table_name: str) -> None:
    """Widen reason from legacy ENUM to VARCHAR for audit reason strings."""
    try:
        row = db.execute(
            text(
                "SELECT DATA_TYPE FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :tn AND COLUMN_NAME = 'reason'"
            ),
            {"tn": table_name},
        ).fetchone()
        if not row:
            return
        if str(row[0]).lower() != "enum":
            return
        db.execute(
            text(f"ALTER TABLE `{table_name}` MODIFY COLUMN reason VARCHAR(64) NOT NULL")
        )
        db.commit()
        logger.info("Upgraded %s.reason to VARCHAR(64)", table_name)
    except Exception as e:
        logger.warning("upgrade reason column %s: %s", table_name, e)
        try:
            db.rollback()
        except Exception:  # noqa: S110
            pass


def ensure_active_round_tracking_table(db: Session, game_name_safe: str) -> None:
    t = f"active_round_tracking_{game_name_safe}"
    try:
        db.execute(
            text(
                f"""
                CREATE TABLE IF NOT EXISTS `{t}` (
                    id BIGINT AUTO_INCREMENT PRIMARY KEY,
                    team_id INT NOT NULL,
                    user_id INT NOT NULL,
                    round_name VARCHAR(255) NULL,
                    question_id INT NULL,
                    reason VARCHAR(64) NOT NULL,
                    `timestamp` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    window_scope ENUM('question','round') NOT NULL,
                    window_id VARCHAR(64) NOT NULL,
                    INDEX idx_tr_team_user_ts (team_id, user_id, `timestamp`),
                    INDEX idx_tr_wid_ts (window_id, `timestamp`),
                    INDEX idx_tr_reason_ts (reason, `timestamp`),
                    INDEX idx_tr_round_q_ts (round_name, question_id, `timestamp`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """
            )
        )
        db.commit()
        _upgrade_round_tracking_reason_to_varchar_if_needed(db, t)
        logger.info("Ensured table %s", t)
    except Exception as e:
        logger.warning("ensure %s: %s", t, e)
        try:
            db.rollback()
        except Exception:  # noqa: S110
            pass


def migrate_ensure_active_round_tracking_tables_for_running_games(db: Session) -> None:
    try:
        ags = (
            db.query(ActiveGame)
            .filter(ActiveGame.is_started == "running")
            .all()
        )
    except Exception as e:
        logger.warning("migrate round tracking: list active games: %s", e)
        return
    for ag in ags:
        g = db.query(GamesList).filter(GamesList.id == ag.game_id).first()
        if not g:
            continue
        game_safe = str(g.game_name).strip().lower().replace(" ", "_").replace("-", "_")
        ensure_active_round_tracking_table(db, game_safe)


def _cancel_pending_server_stop() -> None:
    global _pending_server_stop_task
    t = _pending_server_stop_task
    _pending_server_stop_task = None
    if t is not None and not t.done():
        t.cancel()


def _clear_server_answer_window() -> None:
    global _server_answer_window_end, _server_answer_window_question_id, _question_track_window_id, _question_track_round_name
    _server_answer_window_end = None
    _server_answer_window_question_id = 0
    _question_track_window_id = ""
    _question_track_round_name = ""


def _set_server_answer_window(end_utc: datetime, question_id: int) -> None:
    global _server_answer_window_end, _server_answer_window_question_id
    _server_answer_window_end = end_utc
    _server_answer_window_question_id = question_id


def _is_server_answer_window_active() -> bool:
    if _server_answer_window_end is None or _server_answer_window_question_id <= 0:
        return False
    return _utc_now() < _server_answer_window_end


async def _emit_server_stop_timer(
    delay_sec: float,
    source_event_id: str,
    round_name: str,
    slide_number: int,
) -> None:
    try:
        await asyncio.sleep(delay_sec)
        if source_event_id in _server_fired_stop_ids:
            return
        _server_fired_stop_ids.add(source_event_id)
        if len(_server_fired_stop_ids) > 400:
            _server_fired_stop_ids.clear()

        _clear_server_answer_window()
        _clear_round_track_window()
        now = _utc_now()
        stop_event_id = str(uuid.uuid4())
        payload = {
            "type": "timer_trigger",
            "timer_action": "STOP_TIMER",
            "slide_number": slide_number,
            "round_name": round_name,
            "timer_start": _format_utc_iso_z(now),
            "question_id": 0,
            "final_timer": 0,
            "question_timer": 0,
            "event_id": stop_event_id,
            "server_stop": True,
            "stops_event_id": source_event_id,
            "timer_end": _format_utc_iso_z(now),
            "duration_seconds": 0,
        }
        await manager.broadcast_to_all_players(json.dumps(payload))
        logger.info("Server STOP_TIMER broadcast (stops_event_id=%s)", source_event_id)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        logger.error("Server STOP_TIMER task failed: %s", e)


# Internal functions to save/retrieve backup data from database
def _get_backup_table_name(active_game_id: int, db: Session) -> Optional[str]:
    """Get the backup table name for an active game"""
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return None
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return None
        game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
        return f"backup_data_{game_name}"
    except Exception as e:
        logger.error(f"Error getting backup table name: {e}")
        return None

def _save_rounds_info_to_db(active_game_id: int, db: Session) -> None:
    """Save rounds_info to database"""
    try:
        table_name = _get_backup_table_name(active_game_id, db)
        if not table_name:
            logger.warning(f"Cannot save rounds_info: backup table not found for active_game_id {active_game_id}")
            return
        
        # Convert rounds_info to JSON string with proper Unicode encoding
        rounds_info_json = json.dumps(rounds_info, default=str, ensure_ascii=False)
        
        # Insert or update
        upsert_sql = text(f"""
            INSERT INTO `{table_name}` (data_key, data_value, updated_at)
            VALUES ('rounds_info', :data_value, NOW())
            ON DUPLICATE KEY UPDATE
                data_value = :data_value,
                updated_at = NOW()
        """)
        db.execute(upsert_sql, {"data_value": rounds_info_json})
        db.commit()
        logger.info(f"Saved rounds_info to {table_name}")
    except Exception as e:
        logger.error(f"Error saving rounds_info to database: {e}")
        db.rollback()

def _save_last_timer_setting_to_db(active_game_id: int, db: Session) -> None:
    """Save last_timer_setting to database"""
    try:
        table_name = _get_backup_table_name(active_game_id, db)
        if not table_name:
            logger.warning(f"Cannot save last_timer_setting: backup table not found for active_game_id {active_game_id}")
            return
        
        if last_timer_setting is None:
            # Delete the entry if setting is None
            delete_sql = text(f"DELETE FROM `{table_name}` WHERE data_key = 'last_timer_setting'")
            db.execute(delete_sql)
            db.commit()
            logger.info(f"Removed last_timer_setting from {table_name} (value is None)")
            return
        
        # Convert last_timer_setting to JSON string with proper Unicode encoding
        timer_setting_json = json.dumps(last_timer_setting, default=str, ensure_ascii=False)
        
        # Insert or update
        upsert_sql = text(f"""
            INSERT INTO `{table_name}` (data_key, data_value, updated_at)
            VALUES ('last_timer_setting', :data_value, NOW())
            ON DUPLICATE KEY UPDATE
                data_value = :data_value,
                updated_at = NOW()
        """)
        db.execute(upsert_sql, {"data_value": timer_setting_json})
        db.commit()
        logger.info(f"Saved last_timer_setting to {table_name}")
    except Exception as e:
        logger.error(f"Error saving last_timer_setting to database: {e}")
        db.rollback()

def _retrieve_rounds_info_from_db(db: Session) -> None:
    """Retrieve rounds_info from database for the first running active game"""
    global rounds_info
    try:
        # Find first running active game
        active_game = db.query(ActiveGame).filter(ActiveGame.is_started == 'running').first()
        if not active_game:
            logger.info("No running active game found, skipping rounds_info retrieval")
            return
        
        table_name = _get_backup_table_name(active_game.id, db)
        if not table_name:
            logger.warning(f"Cannot retrieve rounds_info: backup table not found for active_game_id {active_game.id}")
            return
        
        # Check if table exists
        check_table_sql = text(f"SHOW TABLES LIKE '{table_name}'")
        result = db.execute(check_table_sql)
        if not result.fetchone():
            logger.info(f"Backup table {table_name} does not exist yet, skipping retrieval")
            return
        
        # Retrieve rounds_info
        select_sql = text(f"SELECT data_value FROM `{table_name}` WHERE data_key = 'rounds_info'")
        result = db.execute(select_sql)
        row = result.fetchone()
        
        if row and row[0]:
            try:
                # Decode JSON with proper Unicode handling
                # json.loads automatically decodes Unicode escape sequences like \u0412
                retrieved_rounds_info = json.loads(row[0])
                # Merge with existing structure (preserve all round_1 to round_20 keys)
                for i in range(1, 21):
                    round_key = f"round_{i}"
                    if round_key in retrieved_rounds_info:
                        rounds_info[round_key] = retrieved_rounds_info[round_key]
                logger.info(f"Retrieved rounds_info from {table_name}")
            except json.JSONDecodeError as e:
                logger.error(f"Error parsing rounds_info JSON: {e}")
        else:
            logger.info(f"No rounds_info found in {table_name}")
    except Exception as e:
        logger.error(f"Error retrieving rounds_info from database: {e}")

def _retrieve_last_timer_setting_from_db(db: Session) -> None:
    """Retrieve last_timer_setting from database for the first running active game"""
    global last_timer_setting
    try:
        # Find first running active game
        active_game = db.query(ActiveGame).filter(ActiveGame.is_started == 'running').first()
        if not active_game:
            logger.info("No running active game found, skipping last_timer_setting retrieval")
            return
        
        table_name = _get_backup_table_name(active_game.id, db)
        if not table_name:
            logger.warning(f"Cannot retrieve last_timer_setting: backup table not found for active_game_id {active_game.id}")
            return
        
        # Check if table exists
        check_table_sql = text(f"SHOW TABLES LIKE '{table_name}'")
        result = db.execute(check_table_sql)
        if not result.fetchone():
            logger.info(f"Backup table {table_name} does not exist yet, skipping retrieval")
            return
        
        # Retrieve last_timer_setting
        select_sql = text(f"SELECT data_value FROM `{table_name}` WHERE data_key = 'last_timer_setting'")
        result = db.execute(select_sql)
        row = result.fetchone()
        
        if row and row[0]:
            try:
                # Decode JSON with proper Unicode handling
                # json.loads automatically decodes Unicode escape sequences like \u0412
                last_timer_setting = json.loads(row[0])
                logger.info(f"Retrieved last_timer_setting from {table_name}: {last_timer_setting}")
            except json.JSONDecodeError as e:
                logger.error(f"Error parsing last_timer_setting JSON: {e}")
        else:
            logger.info(f"No last_timer_setting found in {table_name}")
    except Exception as e:
        logger.error(f"Error retrieving last_timer_setting from database: {e}")

def create_action_game_control_table(active_game_id: int, db: Session) -> None:
    """
    Create per-game control table action_game_control_<game_name> if it doesn't exist.
    Columns:
      - question_id INT AUTO_INCREMENT PRIMARY KEY,
      - slide_number INTEGER UNIQUE NOT NULL,
      - round_name VARCHAR(255),
      - timer_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            logger.warning(f"Active game {active_game_id} not found - cannot create control table")
            return
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            logger.warning(f"Game {active_game.game_id} not found - cannot create control table")
            return

        # Normalize game name for table identifier
        game_name_safe = str(game.game_name).strip().lower().replace(' ', '_').replace('-', '_')
        table_name = f"action_game_control_{game_name_safe}"

        # Create table if not exists
        create_sql = text(
            f"""
            CREATE TABLE IF NOT EXISTS {table_name} (
                question_id INT AUTO_INCREMENT PRIMARY KEY,
                slide_number INTEGER UNIQUE NOT NULL,
                round_name VARCHAR(255),
                timer_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        logger.info(f"Ensuring control table exists: {table_name}")
        db.execute(create_sql)
        db.commit()
    except Exception as e:
        logger.error(f"Error creating control table: {e}")

def populate_rounds_info(active_game_id: int, db: Session):
    """
    Populate the global rounds_info dictionary with round names from the game table
    when an active game is started/running
    """
    try:
        # Get the active game
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            logger.warning(f"Active game {active_game_id} not found")
            return
        
        # Get the game info
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            logger.warning(f"Game {active_game.game_id} not found")
            return
        
        # Create the game table name
        logger.info(f"Active game crated from Game: {game.game_name}")
        
        # Query the game table to get unique round names
        sql_query = f"SELECT DISTINCT round_name FROM {game.game_name} WHERE round_name IS NOT NULL AND round_name != '' ORDER BY id"
        try:
            # Construct the SQL query with proper escaping
            logger.info(f"Executing SQL query: {sql_query}")
            result = db.execute(text(sql_query))
            round_names = [row[0] for row in result.fetchall()]
            
            logger.info(f"Found {len(round_names)} unique rounds for game {game.game_name}: {round_names}")
            
            # Reset all rounds to None first
            for i in range(1, 21):
                rounds_info[f"round_{i}"] = {"Name": None, "Slide": None, "time_now": None}
            
            # Populate rounds_info with found round names
            for i, round_name in enumerate(round_names[:20], 1):  # Limit to 20 rounds
                rounds_info[f"round_{i}"] = {
                    "Name": round_name,
                    "Slide": None,
                    "time_now": None
                }
                logger.info(f"Set round_{i} to: {round_name}")
            
            # Save rounds_info to database
            _save_rounds_info_to_db(active_game_id, db)
            
        except Exception as e:
            logger.error(f"Error querying game table {game.game_name}: {e}")
            logger.error(f"SQL query that failed: {sql_query}")
            
    except Exception as e:
        logger.error(f"Error populating rounds info: {e}")

def add_seconds_to_datetime(datetime_str: str, seconds_to_add: int) -> str:
    """
    Adds seconds to a datetime string.
    Automatically detects 12-hour (AM/PM) or 24-hour format.
    Returns the new datetime in the same format as input.
    """
    datetime_str = datetime_str.strip()

    # Detect the format automatically
    if "AM" in datetime_str.upper() or "PM" in datetime_str.upper():
        input_format = "%Y-%m-%d %I:%M:%S %p"
    else:
        input_format = "%Y-%m-%d %H:%M:%S"

    # Parse the string
    dt = datetime.strptime(datetime_str, input_format)

    # Add seconds
    new_dt = dt + timedelta(seconds=seconds_to_add)

    # Keep the same format for output
    return new_dt.strftime(input_format)

# Database configuration (from env or default for local dev)
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "mysql+pymysql://root:19761982@localhost:3306/game_sila_misly"
)
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# Password hashing with fallback
try:
    pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
    logger.info("Using bcrypt for password hashing")
except Exception as e:
    logger.warning(f"Bcrypt not available, using pbkdf2_sha256: {e}")
    pwd_context = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")

# JWT settings (SECRET_KEY from env in production)
SECRET_KEY = os.getenv("SECRET_KEY", "your-secret-key-change-this-in-production")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

# FastAPI app
app = FastAPI(title="Quze Game API", version="1.0.0")

# CORS middleware (CORS_ORIGINS env: comma-separated, or "*" for allow-all)
_cors_origins = os.getenv("CORS_ORIGINS", "*")
CORS_ORIGINS = [o.strip() for o in _cors_origins.split(",")] if _cors_origins != "*" else ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Exception handler for connection errors
@app.exception_handler(ConnectionResetError)
async def connection_reset_handler(request: Request, exc: ConnectionResetError):
    """Handle connection reset errors gracefully"""
    logger.debug(f"Connection reset by client: {request.url}")
    # Return a simple response since the client has already disconnected
    from fastapi.responses import Response
    return Response(status_code=499)  # 499 Client Closed Request

@app.exception_handler(BrokenPipeError)
async def broken_pipe_handler(request: Request, exc: BrokenPipeError):
    """Handle broken pipe errors gracefully"""
    logger.debug(f"Broken pipe error: {request.url}")
    from fastapi.responses import Response
    return Response(status_code=499)  # 499 Client Closed Request

@app.exception_handler(OSError)
async def os_error_handler(request: Request, exc: OSError):
    """Handle OS-level connection errors gracefully"""
    # Only handle connection-related OS errors
    if "10054" in str(exc) or "Broken pipe" in str(exc) or "Connection reset" in str(exc):
        logger.debug(f"Connection error: {request.url} - {exc}")
        from fastapi.responses import Response
        return Response(status_code=499)  # 499 Client Closed Request
    # Re-raise other OS errors
    raise exc

# Request logging middleware
@app.middleware("http")
async def log_requests(request: Request, call_next):
    logger.info(f"Request: {request.method} {request.url}")
    logger.info(f"Headers: {dict(request.headers)}")
    try:
        response = await call_next(request)
        logger.info(f"Response: {response.status_code}")
        return response
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        # These are common when clients disconnect abruptly (browser tab closed, network issues, etc.)
        # They're harmless and don't need to be logged as errors
        logger.debug(f"Client disconnected: {type(e).__name__}")
        # Re-raise to let FastAPI handle it properly
        raise
    except Exception as e:
        logger.error(f"Request error: {e}")
        raise

# Security
security = HTTPBearer()

# Database Models
class User(Base):
    __tablename__ = "users"
    
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(44), unique=True, index=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    name = Column(String(44), nullable=False)
    role = Column(Enum('player', 'admin', name='user_roles'), default="player", nullable=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    playing_in_team_id = Column(String(6), nullable=True)  # Team ID(6 symbols) where the user is playing (null means not assigned to any team)
    logged_in_at = Column(DateTime, default=datetime.utcnow)
    session_token = Column(String(255), nullable=True, unique=True)  # Unique session token for single session management
    last_seen = Column(DateTime, nullable=True)  # Last time user was seen (for ECHO calls)
    visible_connected = Column(Integer, default=0)  # 1 if user is connected and visible, 0 if disconnected or not visible

class ActiveGame(Base):
    __tablename__ = "active_games"

    id = Column(Integer, primary_key=True, index=True)
    game_id = Column(Integer, nullable=False)  # ID from games_list table
    teams_ids = Column(String(255), nullable=True)  # Comma-separated team IDs that supposed participate in the game
    question_id = Column(Integer, default=1)  # question id in the current round
    round_id = Column(Integer, default=1)  # round id in the game
    is_started = Column(Enum('idle', 'running', 'active', name='is_started'), default="idle", nullable=False)
    timer_on_at = Column(DateTime, default=datetime.utcnow)  # Timer ON at (the starting timer)
    timer_off_at = Column(DateTime, default=datetime.utcnow)  # when the Timer must be OFF at
    team_ids_finished = Column(String(255), nullable=True)  # Comma-separated team IDs that finished the round (all togather)

class Teams(Base):
    __tablename__ = "teams_list"

    id = Column(Integer, primary_key=True, index=True)
    team_code = Column(String(6), unique=True , nullable=False)  # Unique code for the team
    team_name = Column(String(44), unique=True, nullable=False)
    team_city = Column(String(44), nullable=False)  # City where the team is
    team_created_at = Column(DateTime, default=datetime.utcnow)
    team_captain = Column(Integer, unique=True, nullable=True)  # unique team captain of the team (user ID must be in the team_members_idsas well)
    team_members_ids = Column(String(255), nullable=True)  # Comma-separated team IDs participating in the game
    writer_user_id = Column(Integer, nullable=True)  # User ID who has writer privileges for this team (can be null)

    @validates('team_captain')
    def validate_team_captain(self, key, value):
        if self.team_members_ids:
            member_ids = [int(mid.strip()) for mid in self.team_members_ids.split(',') if mid.strip().isdigit()]
            if value is not None and value not in member_ids:
                raise ValueError("The user ID must be present in team_members_ids to be assigned as team_captain")
        return value

class GamesList(Base):
    __tablename__ = "games_list"
    id = Column(Integer, primary_key=True, index=True)
    game_name = Column(String(255), unique=True, nullable=False)  # Table name in the database
    game_description = Column(String(255), nullable=True)
    game_created_at = Column(DateTime, default=datetime.utcnow)

# Create tables
Base.metadata.create_all(bind=engine)
Teams.metadata.create_all(bind=engine)
ActiveGame.metadata.create_all(bind=engine)
GamesList.metadata.create_all(bind=engine)

# Retrieve backup data on startup (if there's a running active game)
try:
    temp_db = SessionLocal()
    _retrieve_rounds_info_from_db(temp_db)
    _retrieve_last_timer_setting_from_db(temp_db)
    temp_db.close()
    logger.info("Retrieved backup data from database on startup")
except Exception as e:
    logger.warning(f"Could not retrieve backup data on startup (this is normal if no active game exists): {e}")

try:
    _mig = SessionLocal()
    migrate_ensure_active_round_tracking_tables_for_running_games(_mig)
    _mig.close()
except Exception as e:
    logger.warning("Could not migrate round tracking tables: %s", e)

# Pydantic models
class UserCreate(BaseModel):
    email: EmailStr
    password: str
    name: str

class UserLogin(BaseModel):
    email: EmailStr
    password: str

# Response model for User
class UserResponse(BaseModel):
    id: int
    email: str
    name: str
    role: str
    is_active: bool
    created_at: datetime
    playing_in_team_id: constr(max_length=6)  # Team ID 6 symbols where the user is playing (Null means not assigned to any team)
    logged_in_at: datetime
    visible_connected: int  # 1 if user is connected and visible, 0 if disconnected or not visible

# Model for users updating
class UpdateUserActiveStatus(BaseModel):
    is_active: bool

class UpdateUserLoggedInAt(BaseModel):
    logged_in_at: datetime

# Response model for Teams
class TeamsResponse(BaseModel):
    id: int
    team_code: constr(max_length=6)
    team_name: constr(max_length=44)
    team_city: constr(max_length=44)
    team_created_at: datetime
    team_captain: str  # Comma-separated team captains of the team
    team_members_ids: str  # Comma-separated team IDs participating in the game

# Models for team creation and request
class TeamCreate(BaseModel):
    team_name: constr(max_length=44)
    team_city: constr(max_length=44)

class TeamCodeRequest(BaseModel):
    team_code: constr(max_length=6)

class TeamLookupRequest(BaseModel):
    team_code: Optional[constr(max_length=6)] = None
    team_id: Optional[int] = None

class ActiveGameUpdate(BaseModel):
    teams_ids: Optional[str] = None
    question_id: Optional[int] = None
    round_id: Optional[int] = None
    is_started: Optional[str] = None
    timer_on_at: datetime
    timer_off_at: datetime
    team_ids_finished: Optional[str] = None

# Model for user profile update
class UserProfileUpdate(BaseModel):
    name: Optional[str] = None
    email: Optional[EmailStr] = None
    password: Optional[str] = None
    playing_in_team_id: Optional[str] = None

# Response model for ActiveGame
class ActiveGameResponse(BaseModel):
    id: int
    game_id: int
    teams_ids: Optional[str] = None  # Comma-separated team IDs (can be None)
    question_id: int
    round_id: int
    is_started: str
    timer_on_at: datetime
    timer_off_at: datetime
    team_ids_finished: Optional[str] = None  # Comma-separated team IDs (can be None)

class Token(BaseModel):
    access_token: str
    token_type: str

class TokenData(BaseModel):
    email: Optional[str] = None


class TeamAnswerItem(BaseModel):
    question_id: int
    # Legacy optional single string (filled into player_answer1 if slots omitted).
    answer: Optional[str] = None
    player_answer1: Optional[str] = None
    player_answer2: Optional[str] = None
    player_answer3: Optional[str] = None
    player_answer4: Optional[str] = None
    correct_score: Optional[float] = None
    wrong_score: Optional[float] = None
    lucky_bonus: Optional[float] = None
    # Admin-adjustable graded total; omit on writer saves (exclude_unset).
    final_score: Optional[float] = None


class TeamAnswersBatchRequest(BaseModel):
    answers: List[TeamAnswerItem]
    client_revision: Optional[Union[str, int]] = None
    round_name: Optional[str] = None
    round_timer: Optional[int] = None


# Utility functions
def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)

def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None):
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.utcnow() + expires_delta
    else:
        expire = datetime.utcnow() + timedelta(minutes=15)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

def generate_session_token():
    """Generate a unique session token"""
    return ''.join(random.choices(string.ascii_letters + string.digits, k=32))

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def get_user_by_email(db: Session, email: str):
    return db.query(User).filter(User.email == email).first()

def get_user_by_user_id(db: Session, user_id: int):
    return db.query(User).filter(User.id == user_id).first()

def authenticate_user(db: Session, email: str, password: str):
    user = get_user_by_email(db, email)
    if not user:
        return False
    if not verify_password(password, str(user.password_hash)):
        return False
    return user

# Generate unique team code (6 characters)
def generate_team_code():
    return ''.join(random.choices(string.ascii_uppercase + string.digits, k=6))


async def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(security), db: Session = Depends(get_db)):
    credentials_exception = HTTPException(
        status_code=401,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    session_invalid_exception = HTTPException(
        status_code=401,
        detail="Session expired or invalid. Please login again.",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(credentials.credentials, SECRET_KEY, algorithms=[ALGORITHM])
        email: str = payload.get("sub")
        session_token: str = payload.get("session_token")
        if email is None:
            raise credentials_exception
        token_data = TokenData(email=email)
    except jwt.PyJWTError:
        raise credentials_exception
    
    user = get_user_by_email(db, email=token_data.email)
    if user is None:
        raise credentials_exception
    
    # Validate session token (single session enforcement)
    logger.info(f"Session validation for user {email}: stored_token={user.session_token}, jwt_token={session_token}")
    
    # If no session token is stored, this might be a race condition - allow it for now
    if not user.session_token:
        logger.warning(f"No session token stored for user {email}, allowing access (race condition)")
        # Don't raise exception, allow access
    elif user.session_token != session_token:
        logger.warning(f"Invalid session token for user {email}: stored={user.session_token}, jwt={session_token}")
        # For now, allow access but log the mismatch - this might be a race condition
        logger.warning(f"Allowing access despite session token mismatch (race condition)")
        # raise session_invalid_exception
    
    return user


def _game_name_to_safe(s: str) -> str:
    return str(s).strip().lower().replace(" ", "_").replace("-", "_")


def _find_games_list_by_safe(db: Session, game_name_safe: str) -> Optional[GamesList]:
    for g in db.query(GamesList).all():
        if _game_name_to_safe(g.game_name) == game_name_safe:
            return g
    return None


def _resolve_user_team_id_int(user: User, db: Session) -> Optional[int]:
    if not user.playing_in_team_id:
        return None
    s = str(user.playing_in_team_id).strip()
    if s.isdigit():
        return int(s)
    team = db.query(Teams).filter(Teams.team_code == s).first()
    return team.id if team else None


def _parse_answers_for_selection(raw) -> tuple:
    """Return ('none'|'equals'|'radio'|'list', options list)."""
    if raw is None:
        return "none", []
    t = str(raw).strip()
    if not t:
        return "none", []
    if t == "=":
        return "equals", []
    if t.startswith("Radio:"):
        opts = [x.strip() for x in t[6:].split(";") if x.strip()]
        return "radio", opts
    if t.startswith("List:"):
        opts = [x.strip() for x in t[5:].split(";") if x.strip()]
        return "list", opts
    return "none", []


def _list_exclusivity_conflicts(
    list_question_ids: List[int], merged_answers: Dict[int, str]
) -> List[dict]:
    owner: Dict[str, int] = {}
    conflicts: List[dict] = []
    for qid in sorted(list_question_ids):
        s = (merged_answers.get(qid) or "").strip()
        if not s:
            continue
        for opt in [x.strip() for x in s.split(",") if x.strip()]:
            if opt in owner and owner[opt] != qid:
                conflicts.append(
                    {
                        "option": opt,
                        "question_id_a": owner[opt],
                        "question_id_b": qid,
                    }
                )
            else:
                owner[opt] = qid
    return conflicts


def _canonical_list_options_first_in_round(round_rows) -> List[str]:
    """Options from the first List: question in round (rows sorted by question_num, id)."""
    for row in round_rows:
        afs = row[2]
        kind, opts = _parse_answers_for_selection(afs)
        if kind == "list" and opts:
            return list(opts)
    return []


def _resolve_type_game_for_round(db: Session, game_table: str, round_name: str) -> int:
    """type_game from the last question row in the round (matches client round-mode detection)."""
    rq = text(
        f"""
        SELECT type_game FROM `{game_table}`
        WHERE round_name = :rn
        ORDER BY id DESC
        LIMIT 1
        """
    )
    row = db.execute(rq, {"rn": round_name}).fetchone()
    if not row or row[0] is None:
        return 0
    try:
        return int(row[0])
    except (TypeError, ValueError):
        return 0


def _fetch_game_rounds_summary(db: Session, game_table_name: str) -> Dict[str, Any]:
    """Distinct round_name values and question counts from a Quze game table."""
    try:
        q = text(
            f"""
            SELECT round_name, COUNT(*) AS cnt
            FROM `{game_table_name}`
            WHERE round_name IS NOT NULL AND round_name != ''
            GROUP BY round_name
            ORDER BY MIN(id)
            """
        )
        rows = db.execute(q).fetchall()
        round_names = [str(r[0]) for r in rows]
        question_count = sum(int(r[1]) for r in rows)
        return {
            "round_names": round_names,
            "round_count": len(round_names),
            "question_count": question_count,
        }
    except Exception as e:
        logger.warning("Could not fetch rounds for game table %s: %s", game_table_name, e)
        return {"round_names": [], "round_count": 0, "question_count": 0}


def _resolve_game_table_for_list_entry(db: Session, game: GamesList) -> str:
    """Resolve MySQL table for a games_list row (exact name, then sanitized LIKE)."""
    candidates: List[str] = []
    if game.game_name:
        candidates.append(game.game_name)
    safe = str(game.game_name or "").replace(" ", "_").replace("-", "_").lower()
    if safe and safe not in candidates:
        candidates.append(safe)
    try:
        result = db.execute(text(f"SHOW TABLES LIKE '{safe}%'"))
        for row in result.fetchall():
            t = row[0]
            if t not in candidates:
                candidates.append(t)
    except Exception as e:
        logger.warning("SHOW TABLES failed for game %s: %s", game.game_name, e)

    for table_name in candidates:
        try:
            db.execute(text(f"SELECT 1 FROM `{table_name}` LIMIT 1")).fetchone()
            return table_name
        except Exception:
            continue
    return game.game_name


def _question_ids_for_round_names(
    db: Session, game: GamesList, round_names: List[str]
) -> List[int]:
    """All game-table question ids belonging to the given round_name values."""
    if not round_names:
        return []
    table = _resolve_game_table_for_list_entry(db, game)
    ids: List[int] = []
    q = text(f"SELECT id FROM `{table}` WHERE round_name = :rn ORDER BY id")
    for rn in round_names:
        if not rn or not str(rn).strip():
            continue
        try:
            rows = db.execute(q, {"rn": str(rn).strip()}).fetchall()
            ids.extend(int(r[0]) for r in rows)
        except Exception as e:
            logger.warning(
                "Could not load questions for round %s in %s: %s", rn, table, e
            )
    return ids


def _question_meta_for_ids(
    db: Session, game: GamesList, question_ids: List[int]
) -> List[dict]:
    """round_name and question_num for bonus option display."""
    if not question_ids:
        return []
    table = _resolve_game_table_for_list_entry(db, game)
    out: List[dict] = []
    q = text(
        f"SELECT id, round_name, question_num FROM `{table}` WHERE id = :qid LIMIT 1"
    )
    for qid in question_ids:
        try:
            row = db.execute(q, {"qid": int(qid)}).fetchone()
            if not row:
                continue
            out.append(
                {
                    "id": int(row[0]),
                    "round_name": str(row[1] or ""),
                    "question_num": row[2],
                }
            )
        except Exception:
            continue
    return out


def _insert_bonus_option_score_rows(
    db: Session,
    scores_table_name: str,
    game: GamesList,
    team_id: str,
    option: dict,
) -> int:
    """Insert one active_new_scores row per targeted question (tiers expand to all round questions)."""
    selection_type = option.get("selection_type", "tier")
    selected_tiers = option.get("selected_tiers") or []
    selected_questions = option.get("selected_questions") or []
    option_name = str(option.get("name") or "")
    correct_score = option.get("correct_score", 1)
    wrong_score = option.get("wrong_score", 0)

    question_ids: List[int] = []
    if selection_type == "tier":
        question_ids = _question_ids_for_round_names(db, game, selected_tiers)
    else:
        for raw in selected_questions:
            try:
                question_ids.append(int(raw))
            except (TypeError, ValueError):
                continue

    insert_sql = text(
        f"""
        INSERT INTO `{scores_table_name}`
            (team_id, question_id, correct_score, wrong_score, option_name, selection_type)
        VALUES
            (:team_id, :question_id, :correct_score, :wrong_score, :option_name, :selection_type)
        """
    )
    insert_sql_legacy = text(
        f"""
        INSERT INTO `{scores_table_name}`
            (team_id, question_id, correct_score, wrong_score, option_name)
        VALUES
            (:team_id, :question_id, :correct_score, :wrong_score, :option_name)
        """
    )
    inserted = 0
    for qid in question_ids:
        params = {
            "team_id": int(team_id),
            "question_id": qid,
            "correct_score": correct_score,
            "wrong_score": wrong_score,
            "option_name": option_name,
            "selection_type": selection_type,
        }
        try:
            db.execute(insert_sql, params)
        except Exception:
            db.execute(
                insert_sql_legacy,
                {k: v for k, v in params.items() if k != "selection_type"},
            )
        inserted += 1
    if selection_type == "tier" and selected_tiers and inserted == 0:
        logger.warning(
            "Tier bonus option %r matched no questions in rounds %s",
            option_name,
            selected_tiers,
        )
    return inserted


def _validate_list_selections_per_question(round_rows, merged: Dict[int, str]) -> None:
    """Classic mode (type_game == 0): each list question uses its own option pool."""
    for row in round_rows:
        qid = int(row[0])
        kind, opts = _parse_answers_for_selection(row[2])
        if kind != "list" or not opts:
            continue
        raw = (merged.get(qid) or "").strip()
        if not raw:
            continue
        opt_set = set(opts)
        for opt in [x.strip() for x in raw.split(",") if x.strip()]:
            if opt not in opt_set:
                raise HTTPException(
                    status_code=400,
                    detail={
                        "success": False,
                        "message": "List selection not in question option pool",
                        "question_id": qid,
                        "option": opt,
                        "allowed": opts,
                    },
                )


AUTO_GRADE_DELAY_SEC = 5.0


def _auto_grade_input_present(kind: str, raw: str) -> bool:
    """
    True if the player submitted something that counts as an attempt.
    Radio / text (=): any non-whitespace. List: at least one non-empty comma-separated token.
    """
    if kind == "list":
        return any(p.strip() for p in (raw or "").split(","))
    return bool((raw or "").strip())


def _split_synonyms(cell) -> List[str]:
    if cell is None:
        return []
    s = str(cell).strip()
    if not s:
        return []
    return [x.strip() for x in s.split(";") if x.strip()]


def _active_game_team_ids(ag: ActiveGame) -> List[int]:
    if not ag or not ag.teams_ids:
        return []
    out: List[int] = []
    for x in str(ag.teams_ids).split(","):
        x = x.strip()
        if x.isdigit():
            out.append(int(x))
    return out


def _fetch_team_slots_four(
    db: Session, answers_table: str, team_id: int, question_id: int
) -> Tuple[str, str, str, str, float, float]:
    """Prefer multislot columns; fallback to legacy `answer` when table predates player_answer*."""
    try:
        row = db.execute(
            text(
                f"""
                SELECT player_answer1, player_answer2, player_answer3, player_answer4,
                       COALESCE(correct_score, 0), COALESCE(wrong_score, 0)
                FROM `{answers_table}`
                WHERE team_id = :tid AND question_id = :qid
                """
            ),
            {"tid": team_id, "qid": question_id},
        ).fetchone()
    except Exception as e:
        msg = str(e).lower()
        if "unknown column" not in msg or "player_answer" not in msg:
            raise
        row = db.execute(
            text(
                f"""
                SELECT COALESCE(answer, ''), COALESCE(correct_score, 0), COALESCE(wrong_score, 0)
                FROM `{answers_table}`
                WHERE team_id = :tid AND question_id = :qid
                """
            ),
            {"tid": team_id, "qid": question_id},
        ).fetchone()
        if not row:
            return ("", "", "", "", 1.0, 0.0)
        try:
            csf = float(row[1]) if row[1] is not None else 1.0
        except (TypeError, ValueError):
            csf = 1.0
        try:
            wsf = float(row[2]) if row[2] is not None else 0.0
        except (TypeError, ValueError):
            wsf = 0.0
        return (str(row[0] or "").strip(), "", "", "", csf, wsf)

    if not row:
        return ("", "", "", "", 1.0, 0.0)
    try:
        csf = float(row[4]) if row[4] is not None else 1.0
    except (TypeError, ValueError):
        csf = 1.0
    try:
        wsf = float(row[5]) if row[5] is not None else 0.0
    except (TypeError, ValueError):
        wsf = 0.0
    return (
        str(row[0] or "").strip(),
        str(row[1] or "").strip(),
        str(row[2] or "").strip(),
        str(row[3] or "").strip(),
        csf,
        wsf,
    )


def _ordered_nonempty_game_cells(
    a1: Any, a2: Any, a3: Any, a4: Any
) -> List[Tuple[int, str]]:
    """(1-based column index, expected cell text) preserving answer1→answer4 order."""
    out: List[Tuple[int, str]] = []
    for i, c in enumerate([a1, a2, a3, a4], start=1):
        if c is None:
            continue
        s = str(c).strip()
        if s:
            out.append((i, s))
    return out


def _comma_join_four_slots_for_list(p1: str, p2: str, p3: str, p4: str) -> str:
    parts = [x.strip() for x in (p1, p2, p3, p4) if x and x.strip()]
    return ",".join(parts)


def _rollup_is_correct_four(
    ic1: Optional[Any], ic2: Optional[Any], ic3: Optional[Any], ic4: Optional[Any]
) -> Optional[int]:
    vals: List[int] = []
    for v in (ic1, ic2, ic3, ic4):
        if v is None:
            continue
        try:
            vals.append(int(v))
        except (TypeError, ValueError):
            continue
    if not vals:
        return None
    if any(v == -1 for v in vals):
        return -1
    if all(v == 1 for v in vals):
        return 1
    return 0


def _synthetic_answer_from_four(p1: str, p2: str, p3: str, p4: str) -> str:
    lines = [x.strip() for x in (p1, p2, p3, p4) if x and str(x).strip()]
    return "\n".join(lines)


def _team_answer_item_normalized_slots(it: TeamAnswerItem) -> Tuple[str, str, str, str]:
    s1 = (it.player_answer1 or "").strip()
    s2 = (it.player_answer2 or "").strip()
    s3 = (it.player_answer3 or "").strip()
    s4 = (it.player_answer4 or "").strip()
    legacy = (it.answer or "").strip()
    if legacy and not any([s1, s2, s3, s4]):
        return (legacy, "", "", "")
    return (s1, s2, s3, s4)


def _cell_player_matches_expected(kind: str, expected_cell: str, pv: str) -> bool:
    pv = (pv or "").strip()
    if not pv:
        return False
    if kind == "radio":
        return pv == expected_cell.strip()
    if kind == "list":
        # One list pick per answer slot; answer# holds synonym variants separated by ;
        tokens = [x.strip() for x in pv.split(",") if x.strip()]
        if len(tokens) != 1:
            return False
        pick = tokens[0]
        for syn in _split_synonyms(expected_cell):
            if pick.casefold() == syn.casefold():
                return True
        return False
    for syn in _split_synonyms(expected_cell):
        if pv.casefold() == syn.casefold():
            return True
    return False


def _greedy_multislot_statuses(
    kind: str, expected_cells: List[str], player_vals: List[str]
) -> List[int]:
    """Per aligned slot outcome: 1 success, -1 failure, 0 no_answer."""
    k = len(expected_cells)
    if k != len(player_vals):
        raise ValueError("expected and player slot lists mismatch")
    unmatched = list(range(k))
    matched: set = set()
    for ej in expected_cells:
        for fi in list(unmatched):
            if _cell_player_matches_expected(kind, ej, player_vals[fi]):
                matched.add(fi)
                unmatched.remove(fi)
                break
    out: List[int] = []
    for fi in range(k):
        pv = (player_vals[fi] or "").strip()
        if not pv:
            out.append(0)
        elif fi in matched:
            out.append(1)
        else:
            out.append(-1)
    return out


def _scatter_is_correct_cols(
    ordered_cols: List[int], statuses: List[int]
) -> Dict[int, Optional[int]]:
    blank = {1: None, 2: None, 3: None, 4: None}
    for j, col in enumerate(ordered_cols):
        if j < len(statuses):
            blank[col] = int(statuses[j])
    return blank


def _persist_multislot_grade(
    db: Session,
    answers_table: str,
    team_id: int,
    question_id: int,
    statuses_by_col: Dict[int, Optional[int]],
    net_score: float,
) -> None:
    ic1 = statuses_by_col.get(1)
    ic2 = statuses_by_col.get(2)
    ic3 = statuses_by_col.get(3)
    ic4 = statuses_by_col.get(4)

    stmt = text(
        f"""
        UPDATE `{answers_table}`
        SET is_correct_1=:ic1, is_correct_2=:ic2, is_correct_3=:ic3, is_correct_4=:ic4,
            final_score=:net_score
        WHERE team_id=:tid AND question_id=:qid
        """
    )
    params = {
        "ic1": ic1,
        "ic2": ic2,
        "ic3": ic3,
        "ic4": ic4,
        "net_score": float(net_score),
        "tid": team_id,
        "qid": question_id,
    }
    db.execute(stmt, params)


def _coerce_kind_for_expected_slots(kind: str, pairs: List[Tuple[int, str]]) -> str:
    """If answers_for_selection is blank/unrecognized but the game row has answer cells, grade as synonym text (=)."""
    if pairs and kind == "none":
        return "equals"
    return kind




def _multislot_net_score(statuses: List[int], correct_pts: float, wrong_pts: float) -> float:
    t = 0.0
    for s in statuses:
        if s == 1:
            t += correct_pts
        elif s == -1:
            t += wrong_pts
    return t


def _auto_grade_question_multislot(
    db: Session,
    answers_table: str,
    game_table: str,
    question_id: int,
    team_ids: List[int],
) -> None:
    row = db.execute(
        text(
            f"""
            SELECT answers_for_selection, answer1, answer2, answer3, answer4
            FROM `{game_table}` WHERE id = :qid
            """
        ),
        {"qid": question_id},
    ).fetchone()
    if not row:
        return
    afs, a1, a2, a3, a4 = row[0], row[1], row[2], row[3], row[4]
    pairs = _ordered_nonempty_game_cells(a1, a2, a3, a4)
    k = len(pairs)
    if k == 0:
        return
    kind, _opts = _parse_answers_for_selection(afs)
    kind = _coerce_kind_for_expected_slots(kind, pairs)
    if kind == "none":
        return
    expected_cells = [p[1] for p in pairs]
    ordered_cols = [p[0] for p in pairs]

    for tid in team_ids:
        p1, p2, p3, p4, corr_pts, wrong_pts = _fetch_team_slots_four(
            db, answers_table, tid, question_id
        )
        p_four = [p1, p2, p3, p4]
        player_vals = [p_four[col - 1] for col in ordered_cols]

        any_input = any((v or "").strip() for v in player_vals)
        if not any_input:
            st = [0] * k
            icmap = _scatter_is_correct_cols(ordered_cols, st)
            _persist_multislot_grade(db, answers_table, tid, question_id, icmap, 0.0)
            continue

        st = _greedy_multislot_statuses(kind, expected_cells, player_vals)
        net = _multislot_net_score(st, corr_pts, wrong_pts)
        icmap = _scatter_is_correct_cols(ordered_cols, st)
        _persist_multislot_grade(db, answers_table, tid, question_id, icmap, net)


def _auto_grade_round_multislot(
    db: Session,
    answers_table: str,
    game_table: str,
    round_name: str,
    team_ids: List[int],
) -> None:
    rq = text(
        f"""
        SELECT id, answers_for_selection, answer1, answer2, answer3, answer4
        FROM `{game_table}`
        WHERE round_name = :rn
        ORDER BY question_num ASC, id ASC
        """
    )
    qrows = db.execute(rq, {"rn": round_name}).fetchall()

    for r in qrows:
        qid = int(r[0])
        afs, a1, a2, a3, a4 = r[1], r[2], r[3], r[4], r[5]
        pairs = _ordered_nonempty_game_cells(a1, a2, a3, a4)
        k = len(pairs)
        if k == 0:
            continue
        kind, _ = _parse_answers_for_selection(afs)
        kind = _coerce_kind_for_expected_slots(kind, pairs)
        if kind == "none":
            continue
        expected_cells = [p[1] for p in pairs]
        ordered_cols = [p[0] for p in pairs]
        for tid in team_ids:
            p1, p2, p3, p4, corr_pts, wrong_pts = _fetch_team_slots_four(
                db, answers_table, tid, qid
            )
            p_four = [p1, p2, p3, p4]
            player_vals = [p_four[col - 1] for col in ordered_cols]
            any_input = any((v or "").strip() for v in player_vals)
            if not any_input:
                st = [0] * k
                icmap = _scatter_is_correct_cols(ordered_cols, st)
                _persist_multislot_grade(db, answers_table, tid, qid, icmap, 0.0)
                continue
            st = _greedy_multislot_statuses(kind, expected_cells, player_vals)
            net = _multislot_net_score(st, corr_pts, wrong_pts)
            icmap = _scatter_is_correct_cols(ordered_cols, st)
            _persist_multislot_grade(db, answers_table, tid, qid, icmap, net)


async def _run_scheduled_auto_grade_question(
    delay_sec: float,
    active_game_id: int,
    game_table_name: str,
    game_name_safe: str,
    question_id: int,
) -> None:
    try:
        await asyncio.sleep(delay_sec)
    except asyncio.CancelledError:
        raise
    db: Session = SessionLocal()
    try:
        ag = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not ag or ag.is_started != "running":
            return
        team_ids = _active_game_team_ids(ag)
        if not team_ids:
            return
        answers_table = f"active_teams_answers_{game_name_safe}"
        _auto_grade_question_multislot(
            db, answers_table, game_table_name, question_id, team_ids
        )
        db.commit()
        logger.info(
            "Auto-grade (question, type_game=0) game=%s qid=%s teams=%s",
            game_name_safe,
            question_id,
            len(team_ids),
        )
    except Exception as e:
        logger.exception("Auto-grade question failed: %s", e)
        try:
            db.rollback()
        except Exception:  # noqa: S110
            pass
    finally:
        db.close()


async def _run_scheduled_auto_grade_round(
    delay_sec: float,
    active_game_id: int,
    game_table_name: str,
    game_name_safe: str,
    round_name: str,
) -> None:
    try:
        await asyncio.sleep(delay_sec)
    except asyncio.CancelledError:
        raise
    db: Session = SessionLocal()
    try:
        ag = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not ag or ag.is_started != "running":
            return
        team_ids = _active_game_team_ids(ag)
        if not team_ids:
            return
        answers_table = f"active_teams_answers_{game_name_safe}"
        _auto_grade_round_multislot(db, answers_table, game_table_name, round_name, team_ids)
        db.commit()
        logger.info(
            "Auto-grade (round, type_game!=0) game=%s round=%s teams=%s",
            game_name_safe,
            round_name,
            len(team_ids),
        )
    except Exception as e:
        logger.exception("Auto-grade round failed: %s", e)
        try:
            db.rollback()
        except Exception:  # noqa: S110
            pass
    finally:
        db.close()


# API Routes
@app.get("/")
async def root():
    return {"message": "Team Results Notification API", "version": "1.0.0"}

@app.post("/api/auth/register", response_model=dict)
async def register_user(user: UserCreate, db: Session = Depends(get_db)):
    try:
        logger.info(f"User Registration attempt for email: {user.email}")
        
        # Check if user already exists
        db_user = get_user_by_email(db, email=str(user.email))
        if db_user:
            logger.warning(f"User already exists: {user.email}")
            raise HTTPException(
                status_code=400,
                detail="User with this email already exists"
            )
        
        # Create new user with role="player" only
        hashed_password = get_password_hash(user.password)
        db_user = User(
            email=user.email,
            password_hash=hashed_password,
            name=user.name,
            role="player"
        )
        db.add(db_user)
        db.commit()
        db.refresh(db_user)
        
        logger.info(f"User registered successfully: {user.email}")
        return {
            "message": "Registration successful",
            "user": {
                "id": db_user.id,
                "email": db_user.email,
                "name": db_user.name,
                "role": db_user.role,
                "is_active": db_user.is_active
            }
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Registration error: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Registration failed: {str(e)}"
        )

@app.post("/api/auth/login", response_model=dict)
async def login_user(user_credentials: UserLogin, db: Session = Depends(get_db)):
    user = authenticate_user(db, str(user_credentials.email), user_credentials.password)
    if not user:
        raise HTTPException(
            status_code=401,
            detail="Invalid email or password"
        )
    if not user.is_active:
        raise HTTPException(
            status_code=400,
            detail="Inactive user"
        )
    
    # Generate new session token (this will invalidate any previous session)
    new_session_token = generate_session_token()
    logger.info(f"Generated new session token for user {user.email}: {new_session_token}")
    
    # Update user with new session token (single session enforcement)
    user.session_token = new_session_token
    user.logged_in_at = datetime.utcnow()
    user.visible_connected = 0  # Initially not connected/visible until WebSocket connects
    
    # Commit the update
    db.commit()
    db.refresh(user)
    
    # Log the session change
    logger.info(f"User {user.email} logged in with new session token, previous session invalidated")
    logger.info(f"User {user.email} session token after save: {user.session_token}")
    
    access_token_expires = timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    jwt_data = {"sub": user.email, "session_token": new_session_token}
    logger.info(f"Creating JWT token for user {user.email} with data: {jwt_data}")
    access_token = create_access_token(
        data=jwt_data, 
        expires_delta=access_token_expires
    )
    logger.info(f"Created JWT token for user {user.email}: {access_token[:50]}...")

    # Update last seen timestamp
    user.last_seen = datetime.utcnow()
    db.commit()
    
    # Check if user is a captain of any team
    is_captain = db.query(Teams).filter(Teams.team_captain == user.id).first() is not None
    
    # Check if user is a writer for their team
    is_writer = False
    if user.playing_in_team_id:
        # Convert team ID to integer if it's a string
        try:
            team_id = int(user.playing_in_team_id) if isinstance(user.playing_in_team_id, str) else user.playing_in_team_id
            team = db.query(Teams).filter(Teams.id == team_id).first()
            if team and team.writer_user_id == user.id:
                is_writer = True
        except (ValueError, TypeError):
            # If playing_in_team_id is not a valid integer, user is not a writer
            pass
    
    return {
        "message": "Login successful",
        "user": {
            "id": user.id,
            "email": user.email,
            "name": user.name,
            "role": user.role,
            "is_active": user.is_active,
            "writer": is_writer,  # Now based on team table
            "playing_in_team_id": user.playing_in_team_id,
            "is_captain": is_captain,
            "logged_in_at": user.logged_in_at,
            "visible_connected": user.visible_connected
        },
        "access_token": access_token,
        "session_token": new_session_token,
        "token_type": "bearer"
    }

@app.post("/api/auth/logout")
async def logout_user(current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Logout user and invalidate session token"""
    try:
        user_id = current_user.id
        
        # Force disconnect WebSocket connection if user is connected
        try:
            await manager.force_disconnect_user(user_id, db)
        except Exception as e:
            logger.warning(f"Could not force disconnect WebSocket for user {user_id}: {e}")
            # Continue with logout even if WebSocket disconnect fails
        
        # Clear session token and set as not visible/connected (this will invalidate the session)
        current_user.session_token = None
        current_user.visible_connected = 0
        db.commit()
        
        logger.info(f"User {current_user.email} logged out, session token cleared and marked as not visible/connected")
        
        return {"message": "Logout successful"}
        
    except Exception as e:
        logger.error(f"Error during logout: {e}")
        db.rollback()
        raise HTTPException(status_code=500, detail="Logout failed")

@app.post("/api/admin/init-db")
async def initialize_database(db: Session = Depends(get_db)):
    """Initialize database with admin users"""
    try:
        # Check if admin user exists
        admin_user = get_user_by_email(db, "admin@silaquiz.com")
        if not admin_user:
            admin_user = User(
                email="admin@silaquiz.com",
                password_hash=get_password_hash("admin123"),
                name="Admin User",
                role="admin"
            )
            db.add(admin_user)
        db.commit()
        return {"message": "Database for Admin initialized successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database initialization failed: {str(e)}")

@app.get("/api/users/me", response_model=UserResponse)
async def read_users_me(current_user: User = Depends(get_current_user)):
    return current_user


@app.put("/api/users/{user_id}/profile", response_model=dict)
async def update_user_profile(user_id: int, profile_data: UserProfileUpdate, db: Session = Depends(get_db)):
    """
    Update user profile information
    """
    try:
        logger.info(f"Updating profile for user ID: {user_id}")

        # Get the user
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return {"success": False, "message": "User not found"}

        # Check if email is being changed and if it already exists
        if profile_data.email and profile_data.email != user.email:
            existing_user = db.query(User).filter(User.email == profile_data.email).first()
            if existing_user:
                return {"success": False, "message": "Email already exists"}

        # Check if team ID is being changed and validate it exists
        new_team_id = None
        if profile_data.playing_in_team_id is not None:
            if profile_data.playing_in_team_id != "":
                # Check if team exists in teams_list by team_code
                team = db.query(Teams).filter(Teams.team_code == profile_data.playing_in_team_id).first()
                if not team:
                    return {"success": False, "message": f"Team with code '{profile_data.playing_in_team_id}' not found"}
                new_team_id = str(team.id)  # Convert team ID to string for storage
            else:
                # Empty string means remove from team
                new_team_id = None

        # Update user fields only if they are provided and different
        updated = False

        if profile_data.name and profile_data.name.strip() != user.name:
            if len(profile_data.name.strip()) < 2:
                return {"success": False, "message": "Name must be at least 2 characters long"}
            user.name = profile_data.name.strip()
            updated = True

        if profile_data.email and profile_data.email != user.email:
            user.email = profile_data.email
            updated = True

        if profile_data.password and len(profile_data.password) >= 6:
            user.password_hash = pwd_context.hash(profile_data.password)
            updated = True
        elif profile_data.password and len(profile_data.password) < 6:
            return {"success": False, "message": "Password must be at least 6 characters long"}

        # Handle team membership changes
        if profile_data.playing_in_team_id is not None and new_team_id != user.playing_in_team_id:
            # Remove user from old team (if user.playing_in_team_id contains team ID)
            if user.playing_in_team_id:
                old_team = db.query(Teams).filter(Teams.id == int(user.playing_in_team_id)).first()
                if old_team and old_team.team_members_ids:
                    # Remove user ID from old team's members list
                    member_ids = old_team.team_members_ids.split(',')
                    member_ids = [mid.strip() for mid in member_ids if mid.strip() != str(user_id)]
                    old_team.team_members_ids = ','.join(member_ids) if member_ids else None
                    logger.info(f"Removed user {user_id} from team {old_team.team_code} (ID: {user.playing_in_team_id})")

            # Add user to new team
            if new_team_id:
                new_team = db.query(Teams).filter(Teams.id == int(new_team_id)).first()
                if new_team:
                    # Add user ID to new team's members list
                    if new_team.team_members_ids:
                        member_ids = new_team.team_members_ids.split(',')
                        member_ids = [mid.strip() for mid in member_ids if mid.strip()]
                        if str(user_id) not in member_ids:
                            member_ids.append(str(user_id))
                        new_team.team_members_ids = ','.join(member_ids)
                    else:
                        new_team.team_members_ids = str(user_id)
                    logger.info(f"Added user {user_id} to team {new_team.team_code} (ID: {new_team_id})")

            user.playing_in_team_id = new_team_id
            updated = True

        if not updated:
            return {"success": False, "message": "No changes detected"}

        # Save changes
        db.commit()
        db.refresh(user)

        # Get team code for response if user has a team
        team_code_for_response = None
        if user.playing_in_team_id:
            team = db.query(Teams).filter(Teams.id == int(user.playing_in_team_id)).first()
            if team:
                team_code_for_response = team.team_code

        logger.info(f"Profile updated successfully for user ID: {user_id}")
        return {
            "success": True,
            "message": "Profile updated successfully",
            "user": {
                "id": user.id,
                "name": user.name,
                "email": user.email,
                "role": user.role,
                "playing_in_team_id": team_code_for_response,  # Return team code for frontend
                "is_active": user.is_active
            }
        }

    except Exception as e:
        logger.error(f"Profile update error: {e}")
        return {"success": False, "message": f"Error updating profile: {str(e)}"}

@app.post("/api/teams/get_team_name", response_model=dict)
async def get_team_name(request: TeamLookupRequest, db: Session = Depends(get_db)):
    """
    Get team name by team code or team ID from teams_list table
    """
    try:
        team = None
        
        if request.team_code:
            logger.info(f"Getting team name for team_code: {request.team_code}")
            team = db.query(Teams).filter(Teams.team_code == request.team_code).first()
        elif request.team_id:
            logger.info(f"Getting team name for team_id: {request.team_id}")
            team = db.query(Teams).filter(Teams.id == request.team_id).first()
        else:
            return {
                "success": False,
                "message": "Either team_code or team_id must be provided"
            }

        if team:
            logger.info(f"Team found: {team.team_name}")
            return {
                "success": True,
                "team_id": team.id,
                "team_name": team.team_name,
                "team_code": team.team_code,
                "team_city": team.team_city
            }
        else:
            search_param = request.team_code or request.team_id
            logger.warning(f"Team not found for: {search_param}")
            return {
                "success": False,
                "message": f"Team not found"
            }

    except Exception as e:
        logger.error(f"Error getting team name: {str(e)}")
        return {
            "success": False,
            "message": f"Error retrieving team information: {str(e)}"
        }


@app.put("/api/active-games/{game_id}", response_model=dict)
async def update_active_game(game_id: int, update_data: ActiveGameUpdate, db: Session = Depends(get_db)):
    """
    Update active game information for:
    - teams_ids
    - current question id
    - current round id
    - is_started ('idle', 'running', 'active')
    - timer_on_at (set with the time now)
    - timer_off_at (set with the time now + game time)
    - team_ids_finished (comma-separated team IDs that finished the round)
    - team_ids_finished
    """
    try:
        logger.info(f"Updating active game ID: {game_id}")
        
        # Find the active game
        active_game = db.query(ActiveGame).filter(ActiveGame.id == game_id).first()
        if not active_game:
            return {"success": False, "message": f"Active game with ID {game_id} not found"}
        
        # Update fields if provided
        updated = False
        
        if update_data.question_id is not None:
            active_game.question_id = update_data.question_id
            updated = True
            logger.info(f"Updated question_id to {update_data.question_id}")
        
        if update_data.round_id is not None:
            active_game.round_id = update_data.round_id
            updated = True
            logger.info(f"Updated round_id to {update_data.round_id}")

        valid_is_started = {'idle', 'running', 'active'}
        if update_data.is_started is not None and update_data.is_started in valid_is_started:
            active_game.is_started = update_data.is_started
            updated = True
            logger.info(f"Updated is_started to {update_data.is_started}")
        
        if not updated:
            return {"success": False, "message": "No changes detected"}
        
        # Save changes
        db.commit()
        db.refresh(active_game)
        
        logger.info(f"Active game {game_id} updated successfully")
        return {
            "success": True,
            "message": "Active game updated successfully",
            "active_game": {
                "id": active_game.id,
                "game_id": active_game.game_id,
                "teams_ids": active_game.teams_ids,
                "question_id": active_game.question_id,
                "round_id": active_game.round_id,
                "is_started": active_game.is_started,
                "timer_on_at": active_game.timer_on_at,
                "timer_off_at": active_game.timer_off_at,
                "team_ids_finished": active_game.team_ids_finished
            }
        }
    except Exception as e:
        logger.error(f"Active game update error: {e}")
        return {"success": False, "message": f"Error updating active game: {str(e)}"}

@app.get("/api/active-games", response_model=List[ActiveGameResponse])
async def get_active_games(db: Session = Depends(get_db)):
    """
    Get all active games, where column are:
    - ture_name - name of the game
    - reg_score - regular score (usually 1;0 - 1 for correct answer and 0 for wrong)
    - bonus_score - bonus score (usually 2;-2 - 2 for correct answer and -2 for wrong)
    - time_to_get_answer - time to get answer in seconds (usually 20 or 30 seconds)
    - type_game - type of the game  (if set 0 then questions, answers go to each other,
      and for any number >1, all the questions go first and then the answers
        with a delay defined in this number between them)
    - question_id - current question id in the game (1,2,3,...)
    - answers_for_selection - possible answers for selection (comma-separated) for the current question
    - answer1 - firs correct (it can be a few answers separated: C;Пшеница)
    - answer2 - second correct answer (in case of multiple correct answers)
    - answer3 - third correct answer (in case of multiple correct answers)
    - comments - optional remarks (TEXT)
    - links_for_question / links_for_answer - optional URLs or link text for presentation (TEXT)
    - description - answer description (explanation)
    """
    try:
        logger.info("Getting all active games")
        active_games = db.query(ActiveGame).all()
        return active_games
    except Exception as e:
        logger.error(f"Error getting active games: {e}")
        return []

@app.get("/api/active-games/{game_id}", response_model=ActiveGameResponse)
async def get_active_game(game_id: int, db: Session = Depends(get_db)):
    """
    Get specific active game by ID
    """
    try:
        logger.info(f"Getting active game ID: {game_id}")
        active_game = db.query(ActiveGame).filter(ActiveGame.id == game_id).first()
        if not active_game:
            raise HTTPException(status_code=404, detail="Active game not found")
        return active_game
    except Exception as e:
        logger.error(f"Error getting active game: {e}")
        raise HTTPException(status_code=500, detail=f"Error retrieving active game: {str(e)}")

# Admin APIs for User Management
@app.get("/api/admin/users", response_model=List[dict])
async def get_all_users(db: Session = Depends(get_db)):
    """
    Get all users for admin management
    """
    try:
        logger.info("Getting all users for admin")
        users = db.query(User).all()
        
        # Get team information for each user
        result = []
        for user in users:
            user_data = {
                "id": user.id,
                "name": user.name,
                "email": user.email,
                "role": user.role,
                "is_active": user.is_active,
                "created_at": user.created_at.isoformat() if user.created_at else None,
                "playing_in_team_id": user.playing_in_team_id,
                "logged_in_at": user.logged_in_at.isoformat() if user.logged_in_at else None,
                "is_captain": False,
                "team_name": None,
            }
            
            # Check if user is a team captain
            if user.playing_in_team_id:
                team = db.query(Teams).filter(Teams.team_captain == user.id).first()
                if team:
                    user_data["is_captain"] = True
                    user_data["team_name"] = team.team_name
                else:
                    # Check if user is in team_members_ids
                    teams = db.query(Teams).all()
                    for team in teams:
                        if team.team_members_ids:
                            member_ids = [int(mid.strip()) for mid in team.team_members_ids.split(',') if mid.strip().isdigit()]
                            if user.id in member_ids and str(user.id) == user.playing_in_team_id:
                                user_data["team_name"] = team.team_name
                                break
            
            result.append(user_data)
        
        return result
    except Exception as e:
        logger.error(f"Error getting all users: {e}")
        return []

@app.get("/api/admin/teams", response_model=List[dict])
async def get_all_teams(db: Session = Depends(get_db)):
    """
    Get all teams for admin management
    """
    try:
        logger.info("Getting all teams for admin")
        teams = db.query(Teams).all()
        
        result = []
        for team in teams:
            team_data = {
                "id": team.id,
                "team_code": team.team_code,
                "team_name": team.team_name,
                "team_city": team.team_city,
                "team_created_at": team.team_created_at.isoformat() if team.team_created_at else None,
                "team_captain": team.team_captain,
                "team_members_ids": team.team_members_ids,
            }
            result.append(team_data)
        
        return result
    except Exception as e:
        logger.error(f"Error getting all teams: {e}")
        return []

@app.post("/api/admin/teams", response_model=dict)
async def create_team(team_data: TeamCreate, db: Session = Depends(get_db)):
    """
    Create a new team
    """
    try:
        logger.info(f"Creating team: {team_data.team_name}")
        
        # # Generate unique team code (6 characters)
        # import random
        # import string
        
        # def generate_team_code():
        #     return ''.join(random.choices(string.ascii_uppercase + string.digits, k=6))
        
        # Ensure team code is unique
        team_code = generate_team_code()
        while db.query(Teams).filter(Teams.team_code == team_code).first():
            team_code = generate_team_code()
        
        # Check if team name already exists
        existing_team = db.query(Teams).filter(Teams.team_name == team_data.team_name).first()
        if existing_team:
            return {"success": False, "message": "Team name already exists"}
        
        # Create new team
        new_team = Teams(
            team_code=team_code,
            team_name=team_data.team_name,
            team_city=team_data.team_city,
        )
        
        db.add(new_team)
        db.commit()
        db.refresh(new_team)
        
        # Return created team data
        team_result = {
            "id": new_team.id,
            "team_code": new_team.team_code,
            "team_name": new_team.team_name,
            "team_city": new_team.team_city,
            "team_created_at": new_team.team_created_at.isoformat() if new_team.team_created_at else None,
            "team_captain": new_team.team_captain,
            "team_members_ids": new_team.team_members_ids,
        }
        
        return {"success": True, "message": "Team created successfully", "team": team_result}
        
    except Exception as e:
        logger.error(f"Error creating team: {e}")
        db.rollback()
        return {"success": False, "message": f"Error creating team: {str(e)}"}

# Team update model
class TeamUpdate(BaseModel):
    team_name: Optional[str] = None
    team_city: Optional[str] = None
    team_captain: Optional[int] = None

@app.put("/api/admin/teams/{team_id}", response_model=dict)
async def update_team(team_id: int, team_data: TeamUpdate, db: Session = Depends(get_db)):
    """
    Update team information (name, city, captain)
    """
    try:
        team = db.query(Teams).filter(Teams.id == team_id).first()
        if not team:
            return {"success": False, "message": "Team not found"}
        
        # Update team name if provided
        if team_data.team_name is not None:
            team.team_name = team_data.team_name
        
        # Update team city if provided
        if team_data.team_city is not None:
            team.team_city = team_data.team_city
        
        # Update team captain if provided
        if team_data.team_captain is not None:
            # Validate that the captain is a member of the team
            if team.team_members_ids:
                member_ids = [int(mid.strip()) for mid in team.team_members_ids.split(',') if mid.strip().isdigit()]
                if team_data.team_captain not in member_ids:
                    return {"success": False, "message": "Captain must be a member of the team"}
            
            team.team_captain = team_data.team_captain
        
        db.commit()
        
        return {"success": True, "message": "Team updated successfully"}
        
    except Exception as e:
        logger.error(f"Error updating team: {e}")
        db.rollback()
        return {"success": False, "message": f"Error updating team: {str(e)}"}

@app.get("/api/admin/teams/{team_id}/members", response_model=dict)
async def get_team_members(team_id: int, db: Session = Depends(get_db)):
    """
    Get team members with their details (ID, name, email)
    """
    try:
        team = db.query(Teams).filter(Teams.id == team_id).first()
        if not team:
            return {"success": False, "message": "Team not found"}
        
        members = []
        if team.team_members_ids:
            member_ids = [int(mid.strip()) for mid in team.team_members_ids.split(',') if mid.strip().isdigit()]
            for member_id in member_ids:
                user = db.query(User).filter(User.id == member_id).first()
                if user:
                    members.append({
                        "id": user.id,
                        "name": user.name,
                        "email": user.email,
                        "is_captain": user.id == team.team_captain
                    })
        
        return {
            "success": True,
            "team_name": team.team_name,
            "team_code": team.team_code,
            "members": members
        }
        
    except Exception as e:
        logger.error(f"Error getting team members: {e}")
        return {"success": False, "message": f"Error getting team members: {str(e)}"}

# Game Management APIs
class GameLoadRequest(BaseModel):
    game_name: str
    file_data: str  # Base64 encoded Excel file

@app.post("/api/admin/games/load-excel", response_model=dict)
async def load_game_from_excel(game_data: GameLoadRequest, db: Session = Depends(get_db)):
    """
    Load a new game from Excel file with any number of sheets
    Each sheet will be created as a separate database table and games_list entry
    Game names will be: {filename}_{sheet_name}
    """
    try:
        logger.info(f"Loading game from Excel: {game_data.game_name}")
        
        # Decode base64 file data
        import base64
        file_bytes = base64.b64decode(game_data.file_data)
        
        # Parse Excel file
        import pandas as pd
        import io
        
        # Read Excel file from bytes
        excel_file = io.BytesIO(file_bytes)
        
        # Read all sheets
        excel_data = pd.read_excel(excel_file, sheet_name=None)
        
        # Validate that we have at least 1 sheet
        if len(excel_data) == 0:
            return {"success": False, "message": "Excel file must have at least 1 sheet"}
        
        sheet_names = list(excel_data.keys())
        created_games = []
        total_rows = 0
        
        # Validate table names and check for conflicts
        import re
        
        # First, validate all game names and check for duplicates
        for sheet_name in sheet_names:
            # Create game name as filename_sheetname
            game_name = f"{game_data.game_name}_{sheet_name}".replace(' ', '_').replace('-', '_').lower()
            
            # Validate game name (MySQL naming conventions)
            if not re.match(r'^[a-zA-Z][a-zA-Z0-9_]*$', game_name):
                return {"success": False, "message": f"Invalid game name generated: {game_name}"}
            
            # Check if game name already exists
            existing_game = db.query(GamesList).filter(GamesList.game_name == game_name).first()
            if existing_game:
                return {"success": False, "message": f"Game name '{game_name}' already exists"}
            
            # Create table name (same as game name for simplicity)
            table_name = game_name
            
            # Check if table already exists
            result = db.execute(text(f"SHOW TABLES LIKE '{table_name}'"))
            if result.fetchone():
                return {"success": False, "message": f"Table {table_name} already exists"}
            
            created_games.append({
                'sheet_name': sheet_name,
                'game_name': game_name,
                'table_name': table_name,
                'row_count': 0
            })
        
        # Create tables, insert data, and create games_list entries for each sheet
        for i, sheet_name in enumerate(sheet_names):
            df = excel_data[sheet_name]
            game_info = created_games[i]
            table_name = game_info['table_name']
            game_name = game_info['game_name']
            
            # Skip empty sheets but still create a games_list entry
            if df.empty:
                logger.warning(f"Sheet '{sheet_name}' is empty, creating empty game entry...")
                
                # Create empty table
                table_sql = f"""
                CREATE TABLE `{table_name}` (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    empty_sheet BOOLEAN DEFAULT TRUE
                )
                """
                db.execute(text(table_sql))
                
                # Create games_list entry for empty sheet
                new_game = GamesList(
                    game_name=game_name,
                    game_description=f"Empty sheet '{sheet_name}' from Excel file '{game_data.game_name}'"
                )
                db.add(new_game)
                continue
            
            # Create columns for the table
            columns = []
            column_mapping = {}  # Maps original column names to sanitized names
            
            for col in df.columns:
                original_col = str(col)
                col_name = original_col.replace(' ', '_').replace('-', '_').lower()
                
                # Ensure column name follows MySQL naming conventions
                if not re.match(r'^[a-zA-Z][a-zA-Z0-9_]*$', col_name):
                    col_name = 'col_' + col_name
                
                # Handle duplicate column names
                original_col_name = col_name
                counter = 1
                while col_name in column_mapping.values():
                    col_name = f"{original_col_name}_{counter}"
                    counter += 1
                
                column_mapping[original_col] = col_name
                columns.append(f"`{col_name}` TEXT")
            
            # Create table SQL
            table_sql = f"""
            CREATE TABLE `{table_name}` (
                id INT AUTO_INCREMENT PRIMARY KEY,
                {', '.join(columns)}
            )
            """
            
            # Execute table creation
            db.execute(text(table_sql))
            logger.info(f"Created table: {table_name}")
            
            # Insert data into table
            row_count = 0
            for _, row in df.iterrows():
                values = []
                column_names = []
                
                for col in df.columns:
                    original_col = str(col)
                    col_name = column_mapping[original_col]
                    column_names.append(f'`{col_name}`')
                    
                    # Handle the value
                    value = str(row[col]) if pd.notna(row[col]) else ''
                    escaped_value = value.replace("'", "''")
                    values.append(f"'{escaped_value}'")
                
                columns_str = ', '.join(column_names)
                values_str = ', '.join(values)
                insert_sql = f"INSERT INTO `{table_name}` ({columns_str}) VALUES ({values_str})"
                db.execute(text(insert_sql))
                row_count += 1
            
            created_games[i]['row_count'] = row_count
            total_rows += row_count
            logger.info(f"Inserted {row_count} rows into table: {table_name}")
            
            # Create games_list entry for this sheet
            new_game = GamesList(
                game_name=game_name,
                game_description=f"Sheet '{sheet_name}' from Excel file '{game_data.game_name}' with {row_count} rows"
            )
            db.add(new_game)
            logger.info(f"Created games_list entry: {game_name}")
        
        # Commit all changes
        db.commit()
        
        # Prepare response data
        game_results = []
        for game_info in created_games:
            game_results.append({
                "game_name": game_info['game_name'],
                "sheet_name": game_info['sheet_name'],
                "table_name": game_info['table_name'],
                "row_count": game_info['row_count']
            })
        
        # Return created game data with all games info
        result_data = {
            "created_games": game_results,
            "total_sheets": len(created_games),
            "total_rows": total_rows,
            "filename": game_data.game_name
        }
        
        return {"success": True, "message": f"Successfully created {len(created_games)} games from Excel file", "data": result_data}
        
    except Exception as e:
        logger.error(f"Error loading game from Excel: {e}")
        db.rollback()
        return {"success": False, "message": f"Error loading game from Excel: {str(e)}"}

# Active Games Management APIs
@app.get("/api/admin/active-games", response_model=dict)
async def get_active_games(db: Session = Depends(get_db)):
    """
    Get all active games
    """
    try:
        active_games = db.query(ActiveGame).all()
        games_list = []
        
        for active_game in active_games:
            # Get game name from GamesList table
            game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
            game_name = game.game_name if game else f"Game ID: {active_game.game_id}"
            
            rounds_summary = (
                _fetch_game_rounds_summary(db, game_name)
                if game
                else {"round_names": [], "round_count": 0, "question_count": 0}
            )
            game_data = {
                "id": active_game.id,
                "game_id": active_game.game_id,
                "game_name": game_name,
                "teams_ids": active_game.teams_ids,
                "is_started": active_game.is_started,
                "question_id": active_game.question_id,
                "round_id": active_game.round_id,
                "timer_on_at": active_game.timer_on_at.isoformat() if active_game.timer_on_at else None,
                "timer_off_at": active_game.timer_off_at.isoformat() if active_game.timer_off_at else None,
                "team_ids_finished": active_game.team_ids_finished,
                "round_names": rounds_summary["round_names"],
                "round_count": rounds_summary["round_count"],
                "question_count": rounds_summary["question_count"],
            }
            games_list.append(game_data)
        
        return {"success": True, "games": games_list}
        
    except Exception as e:
        logger.error(f"Error getting active games: {e}")
        return {"success": False, "message": f"Error getting active games: {str(e)}"}

@app.get("/api/admin/games", response_model=dict)
async def get_all_games(db: Session = Depends(get_db)):
    """
    Get all available games from games_list table
    """
    try:
        games = db.query(GamesList).all()
        games_list = []
        
        for game in games:
            game_data = {
                "id": game.id,
                "game_name": game.game_name,
                "game_description": game.game_description,
                "game_created_at": game.game_created_at.isoformat() if game.game_created_at else None,
            }
            games_list.append(game_data)
        
        return {"success": True, "games": games_list}
        
    except Exception as e:
        logger.error(f"Error getting all games: {e}")
        return {"success": False, "message": f"Error getting all games: {str(e)}"}

class ActiveGameCreate(BaseModel):
    game_id: str
    team_ids: List[str]
    bonus_options: List[dict]

@app.post("/api/admin/active-games", response_model=dict)
async def create_active_game(game_data: ActiveGameCreate, db: Session = Depends(get_db)):
    """
    Create a new active game
    """
    try:
        logger.info(f"Creating active game for game_id: {game_data.game_id}")
        
        # Get game details
        game = db.query(GamesList).filter(GamesList.id == int(game_data.game_id)).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        
        # Validate teams
        valid_team_ids = []
        for team_id in game_data.team_ids:
            team = db.query(Teams).filter(Teams.id == int(team_id)).first()
            if team:
                valid_team_ids.append(team_id)
        
        if not valid_team_ids:
            return {"success": False, "message": "No valid teams selected"}
        
        # Check if the game is already being used in another active game
        existing_game_active = db.query(ActiveGame).filter(
            ActiveGame.game_id == int(game_data.game_id),
            ActiveGame.is_started.in_(['idle', 'active', 'running'])
        ).first()
        
        if existing_game_active:
            return {"success": False, "message": f"Game '{game.game_name}' is already being used in another active game"}
        
        # Check if any team is already in an active game
        existing_active_games = db.query(ActiveGame).filter(
            ActiveGame.is_started.in_(['running', 'paused'])
        ).all()
        
        for active_game in existing_active_games:
            if active_game.teams_ids:
                existing_team_ids = active_game.teams_ids.split(',')
                for team_id in valid_team_ids:
                    if team_id in existing_team_ids:
                        return {"success": False, "message": f"Team {team_id} is already participating in an active game"}
        
        # Create active game
        new_active_game = ActiveGame(
            game_id=int(game_data.game_id),
            teams_ids=','.join(valid_team_ids),
            is_started='idle',
            question_id=1,
            round_id=1,
        )
        
        db.add(new_active_game)
        db.commit()
        db.refresh(new_active_game)
        
        # Create temporary tables for the active game
        await _create_temp_tables_for_active_game(db, new_active_game, game, valid_team_ids, game_data.bonus_options)
        
        rounds_summary = _fetch_game_rounds_summary(db, game.game_name)
        # Return created active game data
        active_game_result = {
            "id": new_active_game.id,
            "game_id": new_active_game.game_id,
            "game_name": game.game_name,  # Get from GamesList table
            "teams_ids": new_active_game.teams_ids,
            "is_started": new_active_game.is_started,
            "question_id": new_active_game.question_id,
            "round_id": new_active_game.round_id,
            "timer_on_at": new_active_game.timer_on_at.isoformat() if new_active_game.timer_on_at else None,
            "timer_off_at": new_active_game.timer_off_at.isoformat() if new_active_game.timer_off_at else None,
            "round_names": rounds_summary["round_names"],
            "round_count": rounds_summary["round_count"],
            "question_count": rounds_summary["question_count"],
        }
        
        return {"success": True, "message": "Active game created successfully", "active_game": active_game_result}
        
    except Exception as e:
        logger.error(f"Error creating active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error creating active game: {str(e)}"}

@app.put("/api/admin/active-games/{active_game_id}", response_model=dict)
async def update_active_game(active_game_id: int, game_data: ActiveGameCreate, db: Session = Depends(get_db)):
    """
    Update an existing active game (only if it's idle/unlocked)
    """
    try:
        logger.info(f"Updating active game {active_game_id}")
        
        # Get existing active game
        existing_active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not existing_active_game:
            return {"success": False, "message": "Active game not found"}
        
        if existing_active_game.is_started != 'idle':
            return {"success": False, "message": "Cannot update active game that is running or paused"}
        
        # Get game details
        game = db.query(GamesList).filter(GamesList.id == int(game_data.game_id)).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        
        # Validate teams
        valid_team_ids = []
        for team_id in game_data.team_ids:
            team = db.query(Teams).filter(Teams.id == int(team_id)).first()
            if team:
                valid_team_ids.append(team_id)
        
        if not valid_team_ids:
            return {"success": False, "message": "No valid teams selected"}
        
        # Check if the game is already being used in another active game (excluding current one)
        existing_game_active = db.query(ActiveGame).filter(
            ActiveGame.game_id == int(game_data.game_id),
            ActiveGame.is_started.in_(['idle', 'active', 'running']),
            ActiveGame.id != active_game_id
        ).first()
        
        if existing_game_active:
            return {"success": False, "message": f"Game '{game.game_name}' is already being used in another active game"}
        
        # Check if any team is already in another active game
        existing_active_games = db.query(ActiveGame).filter(
            ActiveGame.is_started.in_(['running', 'paused']),
            ActiveGame.id != active_game_id
        ).all()
        
        for active_game in existing_active_games:
            if active_game.teams_ids:
                existing_team_ids = active_game.teams_ids.split(',')
                for team_id in valid_team_ids:
                    if team_id in existing_team_ids:
                        return {"success": False, "message": f"Team {team_id} is already participating in another active game"}
        
        # Delete old temporary tables
        await _delete_temp_tables_for_active_game(db, existing_active_game)
        
        # Update active game
        existing_active_game.game_id = int(game_data.game_id)
        existing_active_game.teams_ids = ','.join(valid_team_ids)
        
        db.commit()
        db.refresh(existing_active_game)
        
        # Create new temporary tables for the updated active game
        await _create_temp_tables_for_active_game(db, existing_active_game, game, valid_team_ids, game_data.bonus_options)
        
        # Return updated active game data
        active_game_result = {
            "id": existing_active_game.id,
            "game_id": existing_active_game.game_id,
            "game_name": game.game_name,
            "teams_ids": existing_active_game.teams_ids,
            "is_started": existing_active_game.is_started,
            "question_id": existing_active_game.question_id,
            "round_id": existing_active_game.round_id,
            "timer_on_at": existing_active_game.timer_on_at.isoformat() if existing_active_game.timer_on_at else None,
            "timer_off_at": existing_active_game.timer_off_at.isoformat() if existing_active_game.timer_off_at else None,
        }
        
        return {"success": True, "message": "Active game updated successfully", "active_game": active_game_result}
        
    except Exception as e:
        logger.error(f"Error updating active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error updating active game: {str(e)}"}

async def _create_temp_tables_for_active_game(db: Session, active_game: ActiveGame, game: GamesList, team_ids: List[str], bonus_options: List[dict]):
    """
    Create 3 temporary tables for the active game
    """
    try:
        
        game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
        
        # Table 1: Active_new_scores_<game_name>
        scores_table_name = f"active_new_scores_{game_name}"
        scores_table_sql = f"""
        CREATE TABLE `{scores_table_name}` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            team_id INT NOT NULL,
            question_id INT,
            correct_score FLOAT DEFAULT 1,
            wrong_score FLOAT DEFAULT 0,
            option_name VARCHAR(255),
            selection_type VARCHAR(32) DEFAULT NULL,
            player_approved INT DEFAULT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """
        db.execute(text(scores_table_sql))
        
        # Table 2: Active_teams_answers_<game_name>
        answers_table_name = f"active_teams_answers_{game_name}"
        answers_table_sql = f"""
        CREATE TABLE `{answers_table_name}` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            team_id INT NOT NULL,
            question_id INT NOT NULL,
            correct_score FLOAT DEFAULT 0,
            wrong_score FLOAT DEFAULT 0,
            player_answer1 TEXT,
            player_answer2 TEXT,
            player_answer3 TEXT,
            player_answer4 TEXT,
            is_correct_1 INT DEFAULT NULL,
            is_correct_2 INT DEFAULT NULL,
            is_correct_3 INT DEFAULT NULL,
            is_correct_4 INT DEFAULT NULL,
            answered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            player_id INT DEFAULT NULL,
            lucky_bonus FLOAT NOT NULL DEFAULT 0,
            final_score FLOAT NULL DEFAULT NULL,
            UNIQUE KEY team_question (team_id, question_id)
        )
        """
        db.execute(text(answers_table_sql))
        
        # Table 3: Active_teams_results_<game_name>
        results_table_name = f"active_teams_results_{game_name}"
        
        # First, we need to get the questions from the game table to create dynamic columns
        # For now, we'll create a basic structure and add question columns dynamically
        # when questions are loaded or when the game starts
        results_table_sql = f"""
        CREATE TABLE `{results_table_name}` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            team_id INT NOT NULL,
            total_score FLOAT DEFAULT 0,
            correct_answers INT DEFAULT 0,
            wrong_answers INT DEFAULT 0,
            total_questions INT DEFAULT 0,
            completion_percentage DECIMAL(5,2) DEFAULT 0.00,
            last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )
        """
        db.execute(text(results_table_sql))
        
        # Table 3b: Active_teams_start_<game_name> — per-team starting settings
        start_table_name = f"active_teams_start_{game_name}"
        start_table_sql = f"""
        CREATE TABLE `{start_table_name}` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            team_id INT NOT NULL UNIQUE,
            max_players INT NOT NULL DEFAULT 12,
            play_players INT NOT NULL DEFAULT 0,
            start_points FLOAT NOT NULL DEFAULT 0,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )
        """
        db.execute(text(start_table_sql))
        
        # Add question columns dynamically based on the game data
        await _add_question_columns_to_results_table(db, results_table_name, game)
        
        # Insert initial data for each team
        start_insert_sql = text(
            f"""
            INSERT INTO `{start_table_name}`
                (team_id, max_players, play_players, start_points)
            VALUES
                (:team_id, 12, 0, 0)
            """
        )
        for team_id in team_ids:
            db.execute(start_insert_sql, {"team_id": int(team_id)})
            # Insert into results table
            results_insert_sql = f"""
            INSERT INTO `{results_table_name}` (team_id, total_score, correct_answers, wrong_answers, total_questions, question_ids)
            VALUES ({team_id}, 0, 0, 0, 0, '')
            """
            db.execute(text(results_insert_sql))
            
            # Insert bonus options into scores table (one row per question)
            for option in bonus_options:
                _insert_bonus_option_score_rows(
                    db, scores_table_name, game, team_id, option
                )
        
        # Table 4: backup_data_<game_name> - for storing rounds_info and last_timer_setting
        backup_table_name = f"backup_data_{game_name}"
        backup_table_sql = f"""
        CREATE TABLE `{backup_table_name}` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            data_key VARCHAR(255) UNIQUE NOT NULL,
            data_value TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )
        """
        db.execute(text(backup_table_sql))
        ensure_active_round_tracking_table(db, game_name)
        
        db.commit()
        logger.info(f"Created temporary tables for active game: {game_name}")
        
    except Exception as e:
        logger.error(f"Error creating temporary tables: {e}")
        db.rollback()
        raise e

async def _add_question_columns_to_results_table(db: Session, results_table_name: str, game: GamesList):
    """
    Add dynamic question columns to the results table based on the game data
    """
    try:
        import pandas as pd
        import io
        
        # Get the game table name from the GamesList
        # Since we don't have a direct game_table field, we'll use the game_name to find the table
        game_table_name = f"{game.game_name}".replace(' ', '_').replace('-', '_').lower()
        
        # Try to find the actual game table by checking if it exists
        # We'll look for tables that start with the game name
        result = db.execute(text(f"SHOW TABLES LIKE '{game_table_name}%'"))
        tables = result.fetchall()
        
        if not tables:
            logger.warning(f"No game tables found for game: {game.game_name}")
            return
        
        # Use the first table found (assuming it's the main game table)
        actual_game_table = tables[0][0]
        
        # Get the structure of the game table to find question columns
        result = db.execute(text(f"DESCRIBE `{actual_game_table}`"))
        columns = result.fetchall()
        
        # Find columns that might contain question data
        # Look for columns that might be question IDs or question-related
        question_columns = []
        for column in columns:
            column_name = column[0]
            column_type = column[1]
            
            # Skip the id column and look for potential question columns
            if column_name != 'id' and ('question' in column_name.lower() or 'q' in column_name.lower()):
                question_columns.append(column_name)
        
        # If no obvious question columns found, try to get sample data to identify questions
        if not question_columns:
            result = db.execute(text(f"SELECT * FROM `{actual_game_table}` LIMIT 1"))
            sample_data = result.fetchone()
            if sample_data:
                # Get column names from the sample data
                result = db.execute(text(f"SHOW COLUMNS FROM `{actual_game_table}`"))
                all_columns = result.fetchall()
                for column in all_columns:
                    column_name = column[0]
                    if column_name != 'id':
                        question_columns.append(column_name)
        
        # Add columns for each question to the results table
        for i, question_col in enumerate(question_columns):
            # Create a column name for the question score
            question_score_col = f"q{i+1}_score"
            
            # Add the column to the results table
            alter_sql = f"ALTER TABLE `{results_table_name}` ADD COLUMN `{question_score_col}` INT DEFAULT 0"
            try:
                db.execute(text(alter_sql))
                logger.info(f"Added column {question_score_col} to {results_table_name}")
            except Exception as e:
                # Column might already exist, skip
                logger.warning(f"Could not add column {question_score_col}: {e}")
        
        # Also add a general question_id column for reference
        try:
            alter_sql = f"ALTER TABLE `{results_table_name}` ADD COLUMN `question_ids` TEXT"
            db.execute(text(alter_sql))
            logger.info(f"Added question_ids column to {results_table_name}")
        except Exception as e:
            logger.warning(f"Could not add question_ids column: {e}")
        
        db.commit()
        logger.info(f"Added {len(question_columns)} question columns to {results_table_name}")
        
    except Exception as e:
        logger.error(f"Error adding question columns to results table: {e}")
        db.rollback()
        raise e

@app.delete("/api/admin/active-games/{active_game_id}", response_model=dict)
async def delete_active_game(active_game_id: int, db: Session = Depends(get_db)):
    """
    Delete an active game (only if it's idle/unlocked)
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        if active_game.is_started not in ['idle', 'running']:
            return {"success": False, "message": "Cannot delete active game that is not idle or running"}
        
        # Delete temporary tables
        await _delete_temp_tables_for_active_game(db, active_game)
        
        # Delete the active game
        db.delete(active_game)
        db.commit()
        
        return {"success": True, "message": "Active game deleted successfully"}
        
    except Exception as e:
        logger.error(f"Error deleting active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error deleting active game: {str(e)}"}

@app.post("/api/admin/active-games/{active_game_id}/stop", response_model=dict)
async def stop_active_game(active_game_id: int, db: Session = Depends(get_db)):
    """
    Stop an active game (change status from 'active' to 'idle')
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        if active_game.is_started != 'active':
            return {"success": False, "message": "Can only stop games that are in 'active' state"}
        
        # Delete the action_game_control table
        try:
            _delete_action_game_control_table(db, active_game)
        except Exception as e:
            logger.warning(f"Could not delete action_game_control table: {e}")
            # Continue even if table deletion fails
        
        # Change status back to idle
        active_game.is_started = 'idle'
        db.commit()
        
        return {"success": True, "message": "Active game stopped and returned to idle state"}
        
    except Exception as e:
        logger.error(f"Error stopping active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error stopping active game: {str(e)}"}

@app.get("/api/admin/active-games/{active_game_id}/results-structure", response_model=dict)
async def get_active_game_results_structure(active_game_id: int, db: Session = Depends(get_db)):
    """
    Get the structure of the results table for an active game
    This will be used by the analytic UI to know which question columns exist
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        # Get game name from GamesList table
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        
        game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
        results_table_name = f"active_teams_results_{game_name}"
        
        # Get the structure of the results table
        result = db.execute(text(f"DESCRIBE `{results_table_name}`"))
        columns = result.fetchall()
        
        # Extract question columns (those that start with 'q' and end with '_score')
        question_columns = []
        other_columns = []
        
        for column in columns:
            column_name = column[0]
            column_type = column[1]
            
            if column_name.startswith('q') and column_name.endswith('_score'):
                question_columns.append({
                    'name': column_name,
                    'type': column_type,
                    'question_num': column_name.replace('q', '').replace('_score', '')
                })
            else:
                other_columns.append({
                    'name': column_name,
                    'type': column_type
                })
        
        return {
            "success": True,
            "table_name": results_table_name,
            "question_columns": question_columns,
            "other_columns": other_columns,
            "total_questions": len(question_columns)
        }
        
    except Exception as e:
        logger.error(f"Error getting results structure: {e}")
        return {"success": False, "message": f"Error getting results structure: {str(e)}"}

@app.get("/api/admin/active-games/{active_game_id}/bonus-options", response_model=dict)
async def get_active_game_bonus_options(active_game_id: int, db: Session = Depends(get_db)):
    """
    Get bonus options for an active game
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        # Get game name from GamesList table
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        
        game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
        scores_table_name = f"active_new_scores_{game_name}"
        
        # Get bonus options from the scores table (one row per question)
        try:
            result = db.execute(
                text(
                    f"""
                    SELECT option_name, correct_score, wrong_score, question_id, selection_type
                    FROM `{scores_table_name}`
                    WHERE option_name IS NOT NULL AND option_name != ''
                    ORDER BY option_name, question_id
                    """
                )
            )
            rows = result.fetchall()
        except Exception:
            result = db.execute(
                text(
                    f"""
                    SELECT option_name, correct_score, wrong_score, question_id, NULL
                    FROM `{scores_table_name}`
                    WHERE option_name IS NOT NULL AND option_name != ''
                    ORDER BY option_name, question_id
                    """
                )
            )
            rows = result.fetchall()

        bonus_options: Dict[str, dict] = {}
        for row in rows:
            option_name = row[0]
            correct_score = row[1]
            wrong_score = row[2]
            question_id = row[3]
            row_selection_type = row[4] if len(row) > 4 else None

            if option_name not in bonus_options:
                bonus_options[option_name] = {
                    "name": option_name,
                    "correct_score": correct_score,
                    "wrong_score": wrong_score,
                    "selection_type": row_selection_type or "question",
                    "selected_tiers": [],
                    "selected_questions": [],
                    "question_details": [],
                    "question_count": 0,
                }

            opt = bonus_options[option_name]
            if row_selection_type:
                opt["selection_type"] = row_selection_type

            if question_id and int(question_id) > 0:
                qid_str = str(int(question_id))
                if qid_str not in opt["selected_questions"]:
                    opt["selected_questions"].append(qid_str)

        bonus_options_list = []
        for option in bonus_options.values():
            qids = [int(q) for q in option["selected_questions"]]
            details = _question_meta_for_ids(db, game, qids)
            option["question_details"] = details
            round_names = sorted(
                {d["round_name"] for d in details if d.get("round_name")}
            )
            if option["selection_type"] == "tier":
                option["selected_tiers"] = round_names
                option["question_count"] = len(details)
            else:
                option["question_count"] = len(details)
            bonus_options_list.append(option)
        
        return {
            "success": True,
            "bonus_options": bonus_options_list
        }
        
    except Exception as e:
        logger.error(f"Error getting bonus options: {e}")
        return {"success": False, "message": f"Error getting bonus options: {str(e)}"}


def _active_teams_start_table_name(game: GamesList) -> str:
    game_name = str(game.game_name).replace(" ", "_").replace("-", "_").lower()
    return f"active_teams_start_{game_name}"


def _compute_team_start_total(
    max_players: int, play_players: int, start_points: float
) -> float:
    if max_players >= play_players:
        return float(start_points)
    return float(max_players - play_players + start_points)


def _ensure_active_teams_start_table(
    db: Session, game: GamesList, team_ids: List[str]
) -> str:
    """Create active_teams_start table and seed missing teams (legacy active games)."""
    table_name = _active_teams_start_table_name(game)
    create_sql = f"""
    CREATE TABLE IF NOT EXISTS `{table_name}` (
        id INT AUTO_INCREMENT PRIMARY KEY,
        team_id INT NOT NULL UNIQUE,
        max_players INT NOT NULL DEFAULT 12,
        play_players INT NOT NULL DEFAULT 0,
        start_points FLOAT NOT NULL DEFAULT 0,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    )
    """
    db.execute(text(create_sql))
    insert_sql = text(
        f"""
        INSERT INTO `{table_name}` (team_id, max_players, play_players, start_points)
        VALUES (:team_id, 12, 0, 0)
        """
    )
    for team_id in team_ids:
        tid = int(team_id)
        existing = db.execute(
            text(f"SELECT team_id FROM `{table_name}` WHERE team_id = :tid LIMIT 1"),
            {"tid": tid},
        ).fetchone()
        if not existing:
            db.execute(insert_sql, {"team_id": tid})
    db.commit()
    return table_name


def _load_active_teams_start_rows(
    db: Session, game: GamesList, team_ids: List[str]
) -> List[dict]:
    if not team_ids:
        return []
    table_name = _ensure_active_teams_start_table(db, game, team_ids)
    rows = db.execute(
        text(
            f"""
            SELECT team_id, max_players, play_players, start_points
            FROM `{table_name}`
            WHERE team_id IN ({",".join(str(int(t)) for t in team_ids) if team_ids else "0"})
            ORDER BY team_id
            """
        )
    ).fetchall()
    teams_out: List[dict] = []
    for row in rows:
        team = db.query(Teams).filter(Teams.id == int(row[0])).first()
        max_p = int(row[1] if row[1] is not None else 12)
        play_p = int(row[2] if row[2] is not None else 0)
        start_p = float(row[3] if row[3] is not None else 0)
        teams_out.append(
            {
                "team_id": int(row[0]),
                "team_name": team.team_name if team else f"Team {row[0]}",
                "max_players": max_p,
                "play_players": play_p,
                "start_points": start_p,
                "total": _compute_team_start_total(max_p, play_p, start_p),
            }
        )
    return teams_out


class TeamStartSettingUpdate(BaseModel):
    team_id: int
    max_players: int = 12
    play_players: int = 0
    start_points: float = 0


class ActiveGameTeamsStartUpdate(BaseModel):
    teams: List[TeamStartSettingUpdate]


@app.get("/api/admin/active-games/{active_game_id}/teams-start", response_model=dict)
async def get_active_game_teams_start(active_game_id: int, db: Session = Depends(get_db)):
    """Per-team starting settings (MaxPlayers, PlayPlayers, StartPoints)."""
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        team_ids = [
            t.strip()
            for t in (active_game.teams_ids or "").split(",")
            if t.strip()
        ]
        teams = _load_active_teams_start_rows(db, game, team_ids)
        return {"success": True, "teams": teams}
    except Exception as e:
        logger.error(f"Error getting teams start settings: {e}")
        return {"success": False, "message": f"Error getting teams start settings: {str(e)}"}


@app.put("/api/admin/active-games/{active_game_id}/teams-start", response_model=dict)
async def update_active_game_teams_start(
    active_game_id: int,
    payload: ActiveGameTeamsStartUpdate,
    db: Session = Depends(get_db),
):
    """Update per-team starting settings for an active game."""
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        allowed_team_ids = {
            int(t.strip())
            for t in (active_game.teams_ids or "").split(",")
            if t.strip().isdigit()
        }
        if not allowed_team_ids:
            return {"success": False, "message": "No teams assigned to this active game"}
        table_name = _ensure_active_teams_start_table(
            db, game, [str(t) for t in allowed_team_ids]
        )
        update_sql = text(
            f"""
            UPDATE `{table_name}`
            SET max_players = :max_players,
                play_players = :play_players,
                start_points = :start_points
            WHERE team_id = :team_id
            """
        )
        updated: List[dict] = []
        for item in payload.teams:
            if item.team_id not in allowed_team_ids:
                continue
            max_p = int(item.max_players)
            play_p = int(item.play_players)
            start_p = float(item.start_points)
            db.execute(
                update_sql,
                {
                    "team_id": item.team_id,
                    "max_players": max_p,
                    "play_players": play_p,
                    "start_points": start_p,
                },
            )
            team = db.query(Teams).filter(Teams.id == item.team_id).first()
            updated.append(
                {
                    "team_id": item.team_id,
                    "team_name": team.team_name if team else f"Team {item.team_id}",
                    "max_players": max_p,
                    "play_players": play_p,
                    "start_points": start_p,
                    "total": _compute_team_start_total(max_p, play_p, start_p),
                }
            )
        db.commit()
        return {
            "success": True,
            "message": "Starting settings updated",
            "teams": updated,
        }
    except Exception as e:
        logger.error(f"Error updating teams start settings: {e}")
        db.rollback()
        return {"success": False, "message": f"Error updating teams start settings: {str(e)}"}


@app.get("/api/admin/active-games/{active_game_id}/round-tracking", response_model=dict)
async def get_active_game_round_tracking(
    active_game_id: int,
    team_id: Optional[int] = None,
    user_id: Optional[int] = None,
    round_name: Optional[str] = None,
    reason: Optional[str] = None,
    time_from: Optional[datetime] = Query(
        None, alias="from", description="Filter rows with timestamp >= this (inclusive)"
    ),
    time_to: Optional[datetime] = Query(
        None, alias="to", description="Filter rows with timestamp <= this (inclusive)"
    ),
    db: Session = Depends(get_db),
):
    """
    List player connection/visibility tracking rows for a game (from active_round_tracking_<game_name>).
    """
    try:
        ag = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not ag:
            return {"success": False, "message": "Active game not found", "data": []}
        g = db.query(GamesList).filter(GamesList.id == ag.game_id).first()
        if not g:
            return {"success": False, "message": "Game not found", "data": []}
        gsafe = str(g.game_name).strip().lower().replace(" ", "_").replace("-", "_")
        tname = f"active_round_tracking_{gsafe}"
        exists = db.execute(
            text(
                "SELECT COUNT(*) FROM information_schema.TABLES "
                "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :tn"
            ),
            {"tn": tname},
        ).scalar()
        if not exists:
            return {"success": True, "message": f"Table {tname} not created yet", "data": []}
        wheres = ["1=1"]
        params: Dict[str, Any] = {}
        if team_id is not None:
            wheres.append("team_id = :team_id")
            params["team_id"] = int(team_id)
        if user_id is not None:
            wheres.append("user_id = :user_id")
            params["user_id"] = int(user_id)
        if round_name is not None:
            wheres.append("round_name = :round_name")
            params["round_name"] = round_name
        if reason is not None:
            wheres.append("reason = :reason")
            params["reason"] = reason
        if time_from is not None:
            wheres.append("`timestamp` >= :time_from")
            params["time_from"] = time_from
        if time_to is not None:
            wheres.append("`timestamp` <= :time_to")
            params["time_to"] = time_to
        sql = (
            f"SELECT id, team_id, user_id, round_name, question_id, reason, `timestamp`, window_scope, window_id "
            f"FROM `{tname}` WHERE "
            + " AND ".join(wheres)
            + " ORDER BY `timestamp` ASC"
        )
        r = db.execute(text(sql), params)
        data = [
            {
                "id": row[0],
                "team_id": row[1],
                "user_id": row[2],
                "round_name": row[3],
                "question_id": row[4],
                "reason": row[5],
                "timestamp": row[6].isoformat() if row[6] is not None else None,
                "window_scope": row[7],
                "window_id": row[8],
            }
            for row in r.fetchall()
        ]
        return {"success": True, "data": data}
    except Exception as e:
        logger.error("round-tracking: %s", e)
        return {"success": False, "message": str(e), "data": []}


@app.post("/api/admin/active-games/{active_game_id}/start", response_model=dict)
async def start_active_game(active_game_id: int, db: Session = Depends(get_db)):
    """
    Start an active game (change status from 'idle' to 'running')
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        if active_game.is_started != 'idle':
            return {"success": False, "message": f"Game is already {active_game.is_started}"}
        
        # Update game status to active (not running yet)
        active_game.is_started = 'active'
        active_game.timer_on_at = datetime.utcnow()
        
        db.commit()
        db.refresh(active_game)
        
        return {
            "success": True,
            "message": "Active game started successfully",
            "active_game": {
                "id": active_game.id,
                "is_started": active_game.is_started,
                "timer_on_at": active_game.timer_on_at.isoformat()
            }
        }
        
    except Exception as e:
        logger.error(f"Error starting active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error starting active game: {str(e)}"}

@app.post("/api/admin/active-games/{active_game_id}/pause", response_model=dict)
async def pause_active_game(active_game_id: int, db: Session = Depends(get_db)):
    """
    Pause an active game (change status from 'running' to 'idle')
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        if active_game.is_started != 'running':
            return {"success": False, "message": f"Game is not running (current status: {active_game.is_started})"}
        
        _clear_server_answer_window()
        _clear_round_track_window()
        # Update game status to idle (paused)
        active_game.is_started = 'idle'
        active_game.timer_off_at = datetime.utcnow()
        
        db.commit()
        db.refresh(active_game)
        
        return {
            "success": True,
            "message": "Active game paused successfully",
            "active_game": {
                "id": active_game.id,
                "is_started": active_game.is_started,
                "timer_off_at": active_game.timer_off_at.isoformat()
            }
        }
        
    except Exception as e:
        logger.error(f"Error pausing active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error pausing active game: {str(e)}"}

@app.post("/api/admin/active-games/{active_game_id}/resume", response_model=dict)
async def resume_active_game(active_game_id: int, db: Session = Depends(get_db)):
    """
    Resume an active game (change status from 'idle' to 'running')
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        if active_game.is_started != 'idle':
            return {"success": False, "message": f"Game is not paused (current status: {active_game.is_started})"}
        
        _clear_server_answer_window()
        _clear_round_track_window()
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if game:
            gname = str(game.game_name).replace(" ", "_").replace("-", "_").lower()
            ensure_active_round_tracking_table(db, gname)
        # Update game status to running
        active_game.is_started = 'running'
        active_game.timer_on_at = datetime.utcnow()
        
        db.commit()
        db.refresh(active_game)
        
        # Populate rounds info when game starts running
        populate_rounds_info(active_game_id, db)
        
        return {
            "success": True,
            "message": "Active game resumed successfully",
            "active_game": {
                "id": active_game.id,
                "is_started": active_game.is_started,
                "timer_on_at": active_game.timer_on_at.isoformat()
            }
        }
        
    except Exception as e:
        logger.error(f"Error resuming active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error resuming active game: {str(e)}"}

@app.post("/api/admin/active-games/{active_game_id}/stop", response_model=dict)
async def stop_active_game(active_game_id: int, db: Session = Depends(get_db)):
    """
    Stop an active game (change status from 'active' to 'idle')
    """
    try:
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        if active_game.is_started != 'active':
            return {"success": False, "message": f"Game is not active (current status: {active_game.is_started})"}
        
        # Delete the action_game_control table
        try:
            _delete_action_game_control_table(db, active_game)
        except Exception as e:
            logger.warning(f"Could not delete action_game_control table: {e}")
            # Continue even if table deletion fails
        
        # Update game status to idle
        active_game.is_started = 'idle'
        active_game.timer_off_at = datetime.utcnow()
        
        db.commit()
        db.refresh(active_game)
        
        return {
            "success": True,
            "message": "Active game stopped successfully",
            "active_game": {
                "id": active_game.id,
                "is_started": active_game.is_started,
                "timer_off_at": active_game.timer_off_at.isoformat()
            }
        }
        
    except Exception as e:
        logger.error(f"Error stopping active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error stopping active game: {str(e)}"}

@app.post("/api/admin/active-games/{active_game_id}/run", response_model=dict)
async def run_active_game(active_game_id: int, db: Session = Depends(get_db)):
    """
    Run an active game (change status from 'active' to 'running')
    """
    try:
        _clear_server_answer_window()
        _clear_round_track_window()
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        if active_game.is_started != 'active':
            return {"success": False, "message": f"Game is not active (current status: {active_game.is_started})"}
        
        # Update game status to running
        active_game.is_started = 'running'
        active_game.timer_on_at = datetime.utcnow()
        
        # Clean up unselected bonus options (where player_approved IS NULL) when game starts running
        # This removes options that teams didn't select, keeping only the selected ones
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if game:
            game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
            ensure_active_round_tracking_table(db, game_name)
            scores_table_name = f"active_new_scores_{game_name}"
            
            # Remove all unselected bonus options (where player_approved IS NULL)
            # This preserves selected options (where player_approved IS NOT NULL)
            result = db.execute(text(f"""
                DELETE FROM `{scores_table_name}` 
                WHERE player_approved IS NULL
            """))
            deleted_count = result.rowcount
            logger.info(f"Cleaned up {deleted_count} unselected bonus options when game {active_game_id} started running")
        
        db.commit()
        db.refresh(active_game)
        
        # Populate rounds info when game starts running
        populate_rounds_info(active_game_id, db)
        
        return {
            "success": True,
            "message": "Active game is now running",
            "active_game": {
                "id": active_game.id,
                "is_started": active_game.is_started,
                "timer_on_at": active_game.timer_on_at.isoformat()
            }
        }
        
    except Exception as e:
        logger.error(f"Error running active game: {e}")
        db.rollback()
        return {"success": False, "message": f"Error running active game: {str(e)}"}

@app.get("/api/player/active-games/{user_id}", response_model=dict)
async def get_player_active_games(user_id: int, db: Session = Depends(get_db)):
    """
    Get active games available for a player (with bonus options)
    """
    try:
        # Get user to verify they exist and get their team
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return {"success": False, "message": "User not found"}
        
        # Get active games where the user's team is participating
        # For debugging, let's check games with different statuses
        active_games = db.query(ActiveGame).filter(
            ActiveGame.is_started.in_(['active', 'running', 'idle'])
        ).all()
        
        logger.info(f"Found {len(active_games)} active games with status 'active'")
        logger.info(f"User {user.email} has team_id: {user.playing_in_team_id}")
        
        # Debug: Check all active games regardless of status
        all_active_games = db.query(ActiveGame).all()
        logger.info(f"Total active games in database: {len(all_active_games)}")
        for ag in all_active_games:
            logger.info(f"Game {ag.id}: status='{ag.is_started}', teams='{ag.teams_ids}'")
        
        player_active_games = []
        for active_game in active_games:
            # Check if user's team is in this active game
            teams_ids = active_game.teams_ids.split(',') if active_game.teams_ids else []
            logger.info(f"Checking game {active_game.id}: teams_ids={teams_ids}, user_team={user.playing_in_team_id}")
            
            # Check if user's team is in this active game
            # user.playing_in_team_id might be a team code (like 'RQFICY') or team ID
            # We need to check both the team ID and team code
            user_team_in_game = False
            
            # First check: direct team ID match
            if str(user.playing_in_team_id) in teams_ids:
                user_team_in_game = True
                logger.info(f"Direct team ID match found for user {user.playing_in_team_id}")
            else:
                # Second check: if user.playing_in_team_id is a team code, get the team ID
                try:
                    team = db.query(Teams).filter(Teams.team_code == user.playing_in_team_id).first()
                    if team and str(team.id) in teams_ids:
                        user_team_in_game = True
                        logger.info(f"Team code match found: {user.playing_in_team_id} -> team_id {team.id}")
                except Exception as e:
                    logger.warning(f"Error checking team code {user.playing_in_team_id}: {e}")
            
            if user_team_in_game:
                # Get game info
                game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
                if game:
                    # Get bonus options for this game
                    game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
                    scores_table_name = f"active_new_scores_{game_name}"
                    
                    # Get the correct team ID for database queries
                    team_id_for_query = user.playing_in_team_id
                    if not str(user.playing_in_team_id).isdigit():
                        # If it's a team code, get the team ID
                        team = db.query(Teams).filter(Teams.team_code == user.playing_in_team_id).first()
                        if team:
                            team_id_for_query = team.id
                            logger.info(f"Using team ID {team.id} for team code {user.playing_in_team_id}")
                    
                    # Only include games that are active or running
                    if active_game.is_started in ['active', 'running']:
                        # Check if player has already made any selection (bonus option or default)
                        player_approved = None
                        try:
                            result = db.execute(text(f"SELECT player_approved FROM `{scores_table_name}` WHERE team_id = {team_id_for_query} AND player_approved IS NOT NULL LIMIT 1"))
                            row = result.fetchone()
                            if row:
                                player_approved = row[0]
                        except Exception as e:
                            logger.warning(f"Could not check player approval for game {active_game.id}: {e}")
                        
                        # Get unique bonus options (only if player hasn't made a selection yet)
                        bonus_options = []
                        if player_approved is None:
                            try:
                                result = db.execute(text(f"SELECT DISTINCT option_name, correct_score, wrong_score FROM `{scores_table_name}` WHERE team_id = {team_id_for_query} AND option_name IS NOT NULL AND option_name != ''"))
                                for row in result.fetchall():
                                    bonus_options.append({
                                        'name': row[0],
                                        'correct_score': row[1],
                                        'wrong_score': row[2]
                                    })
                            except Exception as e:
                                logger.warning(f"Could not get bonus options for game {active_game.id}: {e}")
                        
                        logger.info(f"Found {len(bonus_options)} bonus options for game {active_game.id}, team {team_id_for_query}, player_approved={player_approved}")
                        
                        # Include ALL active/running games where team matches (even without bonus options)
                        # Frontend will filter for bonus options when showing dialog
                        player_active_games.append({
                            'id': active_game.id,
                            'game_name': game.game_name,
                            'status': active_game.is_started,
                            'bonus_options': bonus_options,
                            'player_approved': player_approved
                        })
        
        logger.info(f"Returning {len(player_active_games)} active games for player {user.email}")
        return {
            "success": True,
            "active_games": player_active_games
        }
        
    except Exception as e:
        logger.error(f"Error getting player active games: {e}")
        return {"success": False, "message": f"Error getting player active games: {str(e)}"}

@app.post("/api/player/select-bonus-option", response_model=dict)
async def select_bonus_option(request: dict, db: Session = Depends(get_db)):
    """
    Player selects a bonus option for an active game
    Allows selection only in 'active' state
    """
    try:
        active_game_id = request.get('active_game_id')
        user_id = request.get('user_id')
        option_name = request.get('option_name')
        
        if not all([active_game_id, user_id, option_name]):
            return {"success": False, "message": "Missing required parameters"}
        
        # Get user and verify they exist
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return {"success": False, "message": "User not found"}
        
        # Get active game
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        # Allow bonus option selection only in 'active' state
        if active_game.is_started != 'active':
            return {"success": False, "message": f"Bonus options can only be selected when the game is in 'active' state (current: {active_game.is_started})"}
        
        # Verify user's team is in this game
        teams_ids = active_game.teams_ids.split(',') if active_game.teams_ids else []
        
        # Resolve team ID - user.playing_in_team_id might be a team code or team ID
        team_id_for_verification = user.playing_in_team_id
        if not str(user.playing_in_team_id).isdigit():
            # If it's a team code, get the team ID
            team = db.query(Teams).filter(Teams.team_code == user.playing_in_team_id).first()
            if team:
                team_id_for_verification = team.id
                logger.info(f"Resolved team code {user.playing_in_team_id} to team ID {team.id}")
            else:
                logger.warning(f"Team code {user.playing_in_team_id} not found in Teams table")
                return {"success": False, "message": "Your team code is not valid"}
        
        if str(team_id_for_verification) not in teams_ids:
            return {"success": False, "message": "Your team is not participating in this game"}
        
        # Get game info
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        
        # Update player_approved field for the selected option
        game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
        scores_table_name = f"active_new_scores_{game_name}"
        
        # Update player_approved for the selected option
        db.execute(text(f"""
            UPDATE `{scores_table_name}` 
            SET player_approved = :user_id 
            WHERE team_id = :team_id 
            AND option_name = :option_name
        """), {
            'user_id': user_id,
            'team_id': team_id_for_verification,
            'option_name': option_name
        })
        
        # Remove all other bonus options for this team (cleanup)
        db.execute(text(f"""
            DELETE FROM `{scores_table_name}` 
            WHERE team_id = :team_id 
            AND option_name != :option_name
            AND option_name IS NOT NULL 
            AND option_name != ''
        """), {
            'team_id': team_id_for_verification,
            'option_name': option_name
        })
        
        db.commit()
        
        return {
            "success": True,
            "message": f"Bonus option '{option_name}' selected successfully"
        }
        
    except Exception as e:
        logger.error(f"Error selecting bonus option: {e}")
        return {"success": False, "message": f"Error selecting bonus option: {str(e)}"}

@app.post("/api/player/select-default-option", response_model=dict)
async def select_default_option(request: dict, db: Session = Depends(get_db)):
    """
    Player selects default scoring (removes all bonus options for the team)
    Allows selection only in 'active' state
    """
    try:
        active_game_id = request.get('active_game_id')
        user_id = request.get('user_id')
        
        if not all([active_game_id, user_id]):
            return {"success": False, "message": "Missing required parameters"}
        
        # Get user and verify they exist
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return {"success": False, "message": "User not found"}
        
        # Get active game
        active_game = db.query(ActiveGame).filter(ActiveGame.id == active_game_id).first()
        if not active_game:
            return {"success": False, "message": "Active game not found"}
        
        # Allow default option selection only in 'active' state
        if active_game.is_started != 'active':
            return {"success": False, "message": f"Default option can only be selected when the game is in 'active' state (current: {active_game.is_started})"}
        
        # Verify user's team is in this game
        teams_ids = active_game.teams_ids.split(',') if active_game.teams_ids else []
        
        # Resolve team ID - user.playing_in_team_id might be a team code or team ID
        team_id_for_verification = user.playing_in_team_id
        if not str(user.playing_in_team_id).isdigit():
            # If it's a team code, get the team ID
            team = db.query(Teams).filter(Teams.team_code == user.playing_in_team_id).first()
            if team:
                team_id_for_verification = team.id
                logger.info(f"Resolved team code {user.playing_in_team_id} to team ID {team.id}")
            else:
                logger.warning(f"Team code {user.playing_in_team_id} not found in Teams table")
                return {"success": False, "message": "Your team code is not valid"}
        
        if str(team_id_for_verification) not in teams_ids:
            return {"success": False, "message": "Your team is not participating in this game"}
        
        # Get game info
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        
        # Remove ALL bonus options for this team (cleanup for default scoring)
        game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
        scores_table_name = f"active_new_scores_{game_name}"
        
        # Add a special record to indicate the team chose default scoring
        db.execute(text(f"""
            INSERT INTO `{scores_table_name}` 
            (team_id, question_id, correct_score, wrong_score, option_name, player_approved)
            VALUES (:team_id, 0, 1, 0, 'Leave default', :user_id)
        """), {
            'team_id': team_id_for_verification,
            'user_id': user_id
        })
        
        # Remove all other bonus options for this team
        db.execute(text(f"""
            DELETE FROM `{scores_table_name}` 
            WHERE team_id = :team_id 
            AND option_name IS NOT NULL 
            AND option_name != ''
            AND option_name != 'Leave default'
        """), {
            'team_id': team_id_for_verification
        })
        
        db.commit()
        
        return {
            "success": True,
            "message": "Default scoring selected successfully (all bonus options removed)"
        }
        
    except Exception as e:
        logger.error(f"Error selecting default option: {e}")
        return {"success": False, "message": f"Error selecting default option: {str(e)}"}

@app.get("/api/admin/games/{game_id}/rounds", response_model=dict)
async def get_admin_game_rounds(game_id: int, db: Session = Depends(get_db)):
    """Round names and question counts from the game table round_name column."""
    try:
        game = db.query(GamesList).filter(GamesList.id == game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        summary = _fetch_game_rounds_summary(
            db, _resolve_game_table_for_list_entry(db, game)
        )
        return {"success": True, **summary}
    except Exception as e:
        logger.error(f"Error getting admin game rounds: {e}")
        return {"success": False, "message": f"Error getting game rounds: {str(e)}"}


@app.get("/api/admin/games/{game_id}/structure", response_model=dict)
async def get_game_structure(game_id: int, db: Session = Depends(get_db)):
    """
    Get the structure of a game (tiers/rounds and questions) for bonus option creation.
    Uses round_name and primary-key id from the game table.
    """
    try:
        game = db.query(GamesList).filter(GamesList.id == game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}

        game_table_name = _resolve_game_table_for_list_entry(db, game)
        tiers: List[dict] = []
        questions: List[dict] = []
        err_msg = ""
        try:
            tiers, questions = _load_game_structure_for_bonus(db, game_table_name)
        except Exception as e:
            err_msg = str(e)
            logger.warning(
                "Could not load Quze game structure for %s (table=%s): %s",
                game.game_name,
                game_table_name,
                e,
            )

        return {
            "success": True,
            "game_info": {
                "id": game.id,
                "name": game.game_name,
                "table_name": game_table_name,
            },
            "tiers": tiers,
            "questions": questions,
            "total_tiers": len(tiers),
            "total_questions": len(questions),
            "message": err_msg if not questions else "",
        }

    except Exception as e:
        logger.error(f"Error getting game structure: {e}")
        return {"success": False, "message": f"Error getting game structure: {str(e)}"}

async def _delete_temp_tables_for_active_game(db: Session, active_game: ActiveGame):
    """
    Delete the 3 temporary tables and action_game_control table for the active game
    """
    try:
        
        # Get game name from GamesList table
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            logger.warning(f"Game not found for active_game_id: {active_game.id}")
            return
        
        game_name = game.game_name.replace(' ', '_').replace('-', '_').lower()
        
        # Drop the 3 temporary tables
        tables_to_drop = [
            f"active_new_scores_{game_name}",
            f"active_teams_answers_{game_name}",
            f"active_teams_results_{game_name}",
            f"active_teams_start_{game_name}",
            f"active_round_tracking_{game_name}",
        ]
        
        for table_name in tables_to_drop:
            drop_sql = f"DROP TABLE IF EXISTS `{table_name}`"
            db.execute(text(drop_sql))
        
        # Drop the action_game_control table
        action_control_table = f"action_game_control_{game_name}"
        drop_control_sql = f"DROP TABLE IF EXISTS `{action_control_table}`"
        db.execute(text(drop_control_sql))
        
        # Drop the backup_data table
        backup_table = f"backup_data_{game_name}"
        drop_backup_sql = f"DROP TABLE IF EXISTS `{backup_table}`"
        db.execute(text(drop_backup_sql))
        
        db.commit()
        logger.info(f"Deleted temporary tables, action_game_control table, and backup_data table for active game: {game_name}")
        
    except Exception as e:
        logger.error(f"Error deleting temporary tables: {e}")
        db.rollback()
        raise e

def _delete_action_game_control_table(db: Session, active_game: ActiveGame) -> None:
    """
    Delete the action_game_control_<game_name> table for the active game
    """
    try:
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            logger.warning(f"Game not found for active_game_id: {active_game.id} - cannot delete action_game_control table")
            return
        
        # Normalize game name for table identifier (same as in create function)
        game_name_safe = str(game.game_name).strip().lower().replace(' ', '_').replace('-', '_')
        table_name = f"action_game_control_{game_name_safe}"
        
        # Drop the table if it exists
        drop_sql = text(f"DROP TABLE IF EXISTS `{table_name}`")
        db.execute(drop_sql)
        db.commit()
        
        logger.info(f"Deleted action_game_control table: {table_name}")
        
    except Exception as e:
        logger.error(f"Error deleting action_game_control table: {e}")
        db.rollback()
        raise e

class AdminUserUpdate(BaseModel):
    name: Optional[str] = None
    email: Optional[EmailStr] = None
    password: Optional[str] = None
    role: Optional[str] = None
    is_active: Optional[bool] = None
    writer: Optional[bool] = None
    playing_in_team_id: Optional[str] = None

# WebSocket Connection Manager
class ConnectionManager:
    def __init__(self):
        self.active_connections: Dict[str, WebSocket] = {}
        self.user_connections: Dict[int, str] = {}  # user_id -> connection_id
        # Same user opened a new WS before old one finished teardown — skip one disconnection analytics event
        self.skip_disconnect_tracking_once: Set[int] = set()

    async def connect(self, websocket: WebSocket, connection_id: str, user_id: int) -> bool:
        """Returns True if an existing connection was replaced (reconnect / refresh), else False."""
        replaced_existing = False
        # Check if user already has an active connection
        if user_id in self.user_connections:
            replaced_existing = True
            self.skip_disconnect_tracking_once.add(user_id)
            old_connection_id = self.user_connections[user_id]
            logger.info(f"User {user_id} already has connection {old_connection_id}, closing it")
            
            if old_connection_id in self.active_connections:
                # Close the existing connection
                try:
                    await self.active_connections[old_connection_id].close(code=1000, reason="New connection from same user")
                    logger.info(f"Closed existing connection {old_connection_id} for user {user_id}")
                except (ConnectionResetError, BrokenPipeError, OSError) as e:
                    # Client already disconnected - this is normal
                    logger.debug(f"Existing connection {old_connection_id} already closed: {type(e).__name__}")
                except Exception as e:
                    logger.warning(f"Error closing existing connection for user {user_id}: {e}")
                # Remove from active connections
                try:
                    del self.active_connections[old_connection_id]
                except KeyError:
                    pass  # Already removed
            
            # Remove from user connections mapping
            del self.user_connections[user_id]
            logger.info(f"Removed old connection mapping for user {user_id}")
        
        # Accept the new WebSocket connection
        await websocket.accept()
        
        # Add the new connection
        self.active_connections[connection_id] = websocket
        self.user_connections[user_id] = connection_id
        
        logger.info(f"User {user_id} connected with new connection {connection_id}")
        logger.info(f"Active connections: {len(self.active_connections)}, User connections: {len(self.user_connections)}")
        return replaced_existing

    def disconnect(self, connection_id: str, user_id: int):
        logger.info(f"Disconnecting user {user_id} from connection {connection_id}")
        
        # Remove from active connections
        if connection_id in self.active_connections:
            del self.active_connections[connection_id]
            logger.info(f"Removed connection {connection_id} from active connections")
        
        # Remove from user connections mapping
        if user_id in self.user_connections:
            del self.user_connections[user_id]
            logger.info(f"Removed user {user_id} from user connections mapping")
        
        logger.info(f"User {user_id} disconnected from connection {connection_id}")
        logger.info(f"Active connections: {len(self.active_connections)}, User connections: {len(self.user_connections)}")

    async def send_personal_message(self, message: str, connection_id: str):
        if connection_id in self.active_connections:
            try:
                await self.active_connections[connection_id].send_text(message)
            except (ConnectionResetError, BrokenPipeError, OSError) as e:
                # Client disconnected abruptly - this is normal and not an error
                logger.debug(f"Client {connection_id} disconnected during send: {type(e).__name__}")
                # Remove the connection
                try:
                    del self.active_connections[connection_id]
                    # Also remove from user_connections if it exists
                    user_id_to_remove = None
                    for uid, cid in self.user_connections.items():
                        if cid == connection_id:
                            user_id_to_remove = uid
                            break
                    if user_id_to_remove:
                        del self.user_connections[user_id_to_remove]
                except Exception:
                    pass  # Already removed or doesn't exist
            except Exception as e:
                logger.error(f"Error sending message to {connection_id}: {e}")

    def is_user_connected(self, user_id: int) -> bool:
        """Check if user is already connected"""
        return user_id in self.user_connections and self.user_connections[user_id] in self.active_connections

    def get_user_connection_id(self, user_id: int) -> Optional[str]:
        """Get connection ID for a user"""
        return self.user_connections.get(user_id)

    async def force_disconnect_user(self, user_id: int, db: Session = None):
        """Force disconnect a user (close their WebSocket connection)"""
        logger.info(f"Force disconnecting user {user_id}")
        
        if user_id in self.user_connections:
            connection_id = self.user_connections[user_id]
            if connection_id in self.active_connections:
                try:
                    await self.active_connections[connection_id].close(code=1000, reason="Forced disconnect")
                    logger.info(f"Forced disconnect for user {user_id} on connection {connection_id}")
                except Exception as e:
                    logger.warning(f"Error force disconnecting user {user_id}: {e}")
                # Clean up
                del self.active_connections[connection_id]
            del self.user_connections[user_id]
            logger.info(f"User {user_id} force disconnected successfully")
        else:
            logger.info(f"User {user_id} was not connected")
        
        # Set visible_connected to 0 in database if db session provided
        if db is not None:
            try:
                user = db.query(User).filter(User.id == user_id).first()
                if user:
                    user.visible_connected = 0
                    db.commit()
                    logger.info(f"User {user_id} marked as not visible/connected in database")
            except Exception as e:
                logger.error(f"Error updating visible_connected for user {user_id}: {e}")
                db.rollback()

    async def send_to_user(self, user_id: int, message: str):
        """Send message to a specific user"""
        if user_id in self.user_connections:
            connection_id = self.user_connections[user_id]
            await self.send_personal_message(message, connection_id)
        else:
            logger.warning(f"User {user_id} not connected, cannot send message")

    async def broadcast_to_all_players(self, message: str):
        """Broadcast message to all connected players one by one"""
        logger.info(f"Broadcasting message to all players. Active connections: {len(self.active_connections)}")
        logger.info(f"Active connection IDs: {list(self.active_connections.keys())}")
        logger.info(f"User connections mapping: {self.user_connections}")
        
        if len(self.active_connections) == 0:
            logger.warning("No active WebSocket connections to broadcast to!")
            return
        
        sent_count = 0
        for connection_id, websocket in self.active_connections.items():
            try:
                logger.info(f"Sending message to connection {connection_id}")
                logger.info(f"Message content: {message}")
                await websocket.send_text(message)
                sent_count += 1
                logger.info(f"Message successfully sent to {connection_id}")
            except (ConnectionResetError, BrokenPipeError, OSError) as e:
                # Client disconnected abruptly - this is normal and not an error
                logger.debug(f"Client {connection_id} disconnected during broadcast: {type(e).__name__}")
                # Remove failed connection
                try:
                    del self.active_connections[connection_id]
                    # Also remove from user_connections if it exists
                    user_id_to_remove = None
                    for uid, cid in self.user_connections.items():
                        if cid == connection_id:
                            user_id_to_remove = uid
                            break
                    if user_id_to_remove:
                        del self.user_connections[user_id_to_remove]
                    logger.debug(f"Removed disconnected connection {connection_id}")
                except Exception as cleanup_error:
                    logger.debug(f"Error cleaning up disconnected connection {connection_id}: {cleanup_error}")
            except Exception as e:
                logger.error(f"Error broadcasting to {connection_id}: {e}")
                # Remove failed connection
                try:
                    del self.active_connections[connection_id]
                    # Also remove from user_connections if it exists
                    user_id_to_remove = None
                    for uid, cid in self.user_connections.items():
                        if cid == connection_id:
                            user_id_to_remove = uid
                            break
                    if user_id_to_remove:
                        del self.user_connections[user_id_to_remove]
                    logger.info(f"Removed failed connection {connection_id}")
                except Exception as cleanup_error:
                    logger.error(f"Error cleaning up failed connection {connection_id}: {cleanup_error}")
        
        logger.info(f"Broadcast completed: {sent_count} messages sent out of {len(self.active_connections)} connections")

    def get_connection_stats(self) -> dict:
        """Get connection statistics"""
        return {
            "total_connections": len(self.active_connections),
            "connected_users": len(self.user_connections),
            "user_connections": dict(self.user_connections)
        }
    
    def cleanup_orphaned_connections(self):
        """Clean up any orphaned connections where user_connections and active_connections are out of sync"""
        logger.info("Cleaning up orphaned connections...")
        
        # Find connections that are in active_connections but not in user_connections
        orphaned_connections = []
        for connection_id in list(self.active_connections.keys()):
            if not any(conn_id == connection_id for conn_id in self.user_connections.values()):
                orphaned_connections.append(connection_id)
        
        # Remove orphaned connections
        for connection_id in orphaned_connections:
            logger.warning(f"Removing orphaned connection: {connection_id}")
            del self.active_connections[connection_id]
        
        # Find users that are in user_connections but not in active_connections
        orphaned_users = []
        for user_id, connection_id in list(self.user_connections.items()):
            if connection_id not in self.active_connections:
                orphaned_users.append((user_id, connection_id))
        
        # Remove orphaned user mappings
        for user_id, connection_id in orphaned_users:
            logger.warning(f"Removing orphaned user mapping: user {user_id} -> connection {connection_id}")
            del self.user_connections[user_id]
        
        logger.info(f"Cleanup complete. Active connections: {len(self.active_connections)}, User connections: {len(self.user_connections)}")

# Timer Trigger Models
class TimerTriggerRequest(BaseModel):
    trigger_data: str  # The text data like "START_TIMER, STOP_TIMER and etc"

class TimerTriggerResponse(BaseModel):
    success: bool
    message: str
    round_name: Optional[str] = None
    timer_start: Optional[str] = None
    timer_action: Optional[str] = None

# Initialize connection manager
manager = ConnectionManager()

@app.put("/api/admin/users/{user_id}", response_model=dict)
async def update_user_admin(user_id: int, user_data: AdminUserUpdate, db: Session = Depends(get_db)):
    """
    Update user information by admin
    """
    try:
        logger.info(f"Admin updating user {user_id}")
        
        # Get the user
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return {"success": False, "message": "User not found"}
        
        # Update fields if provided
        if user_data.name is not None:
            user.name = user_data.name
        
        if user_data.email is not None:
            # Check if email is already taken by another user
            existing_user = db.query(User).filter(User.email == user_data.email, User.id != user_id).first()
            if existing_user:
                return {"success": False, "message": "Email already taken by another user"}
            user.email = user_data.email
        
        if user_data.password is not None:
            user.password_hash = get_password_hash(user_data.password)
        
        if user_data.role is not None:
            if user_data.role not in ['player', 'admin']:
                return {"success": False, "message": "Invalid role. Must be 'player' or 'admin'"}
            user.role = user_data.role
        
        if user_data.is_active is not None:
            user.is_active = user_data.is_active
        
        if user_data.playing_in_team_id is not None:
            # Handle team removal (set to empty/null)
            if user_data.playing_in_team_id == "":
                logger.info(f"Removing user {user_id} from team. Current team: {user.playing_in_team_id}")
                
                # Remove user from their current team if they have one
                if user.playing_in_team_id and user.playing_in_team_id.strip():
                    # Try to find team by team_code first
                    current_team = db.query(Teams).filter(Teams.team_code == user.playing_in_team_id).first()
                    
                    # If not found by team_code, try by team_id (in case playing_in_team_id contains team ID)
                    if not current_team:
                        try:
                            team_id_int = int(user.playing_in_team_id)
                            current_team = db.query(Teams).filter(Teams.id == team_id_int).first()
                        except (ValueError, TypeError):
                            pass
                    
                    if current_team:
                        logger.info(f"Found current team: {current_team.team_name} (ID: {current_team.id})")
                        
                        # Remove user from team_members_ids
                        if current_team.team_members_ids:
                            member_ids = [int(mid.strip()) for mid in current_team.team_members_ids.split(',') if mid.strip().isdigit()]
                            logger.info(f"Current team members: {member_ids}")
                            member_ids = [mid for mid in member_ids if mid != user_id]
                            current_team.team_members_ids = ','.join(map(str, member_ids)) if member_ids else None
                            logger.info(f"Updated team members: {current_team.team_members_ids}")
                        
                        # Remove user from team_captain if they were the captain
                        if current_team.team_captain == user_id:
                            logger.info(f"Removing user {user_id} from team captain role")
                            current_team.team_captain = None
                    else:
                        logger.warning(f"Current team not found for code: {user.playing_in_team_id}")
                else:
                    logger.info(f"User {user_id} has no current team to remove from")
                
                user.playing_in_team_id = None
                logger.info(f"Set user {user_id} playing_in_team_id to None")
            else:
                # Handle team assignment
                # First, remove user from their current team if they have one
                if user.playing_in_team_id:
                    # Try to find team by team_code first
                    current_team = db.query(Teams).filter(Teams.team_code == user.playing_in_team_id).first()
                    
                    # If not found by team_code, try by team_id (in case playing_in_team_id contains team ID)
                    if not current_team:
                        try:
                            team_id_int = int(user.playing_in_team_id)
                            current_team = db.query(Teams).filter(Teams.id == team_id_int).first()
                        except (ValueError, TypeError):
                            pass
                    
                    if current_team:
                        # Remove user from team_members_ids
                        if current_team.team_members_ids:
                            member_ids = [int(mid.strip()) for mid in current_team.team_members_ids.split(',') if mid.strip().isdigit()]
                            member_ids = [mid for mid in member_ids if mid != user_id]
                            current_team.team_members_ids = ','.join(map(str, member_ids)) if member_ids else None
                        
                        # Remove user from team_captain if they were the captain
                        if current_team.team_captain == user_id:
                            current_team.team_captain = None
                
                # Validate new team exists
                team = db.query(Teams).filter(Teams.team_code == user_data.playing_in_team_id).first()
                if not team:
                    return {"success": False, "message": f"Team with code '{user_data.playing_in_team_id}' not found"}
                
                # Add user to new team - store team ID, not team code
                user.playing_in_team_id = str(team.id)
                if team.team_members_ids:
                    member_ids = [int(mid.strip()) for mid in team.team_members_ids.split(',') if mid.strip().isdigit()]
                    if user_id not in member_ids:
                        member_ids.append(user_id)
                        team.team_members_ids = ','.join(map(str, member_ids))
                else:
                    team.team_members_ids = str(user_id)
        
        db.commit()
        
        # Return updated user data
        updated_user = {
            "id": user.id,
            "name": user.name,
            "email": user.email,
            "role": user.role,
            "is_active": user.is_active,
            "created_at": user.created_at.isoformat() if user.created_at else None,
            "playing_in_team_id": user.playing_in_team_id,
            "logged_in_at": user.logged_in_at.isoformat() if user.logged_in_at else None,
        }
        
        return {"success": True, "message": "User updated successfully", "user": updated_user}
        
    except Exception as e:
        logger.error(f"Error updating user: {e}")
        db.rollback()
        return {"success": False, "message": f"Error updating user: {str(e)}"}


def _apply_ws_disconnect_and_track(user_id: int, db: Session) -> None:
    """Mark user offline; record disconnection in round tracking when in a valid timer window."""
    u = db.query(User).filter(User.id == user_id).first()
    if not u:
        return
    try:
        skip_disconn_event = False
        if user_id in manager.skip_disconnect_tracking_once:
            manager.skip_disconnect_tracking_once.discard(user_id)
            skip_disconn_event = True
        if not skip_disconn_event:
            _try_record_player_tracking_event(db, u, "disconnection")
        u.visible_connected = 0
        db.commit()
    except Exception as e:
        logger.warning("ws disconnect handler: %s", e)
        db.rollback()


# WebSocket endpoint for real-time timer updates
@app.websocket("/ws/timer/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: int):
    connection_id = f"user_{user_id}_{datetime.utcnow().timestamp()}"
    logger.info(f"WebSocket connection attempt for user {user_id}, connection_id: {connection_id}")
    
    # Validate user session before allowing WebSocket connection
    db = SessionLocal()
    try:
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            logger.warning(f"WebSocket connection rejected for user {user_id}: User not found")
            await websocket.close(code=1008, reason="User not found")
            db.close()
            return
            
        if not user.session_token:
            logger.warning(f"WebSocket connection rejected for user {user_id}: No valid session token")
            # Ensure user is marked as not connected/visible
            user.visible_connected = 0
            db.commit()
            await websocket.close(code=1008, reason="No valid session")
            db.close()
            return
        
        # Clean up any orphaned connections before processing new connection
        manager.cleanup_orphaned_connections()
        
        # Check if user is already connected and log it
        if manager.is_user_connected(user_id):
            logger.info(f"User {user_id} already connected, closing previous connection")
        
        replaced_ws = await manager.connect(websocket, connection_id, user_id)
        logger.info(f"WebSocket connected for user {user_id} with valid session")
        
        # Set user as visible and connected
        user.visible_connected = 1
        _echo_app_visible[user_id] = True
        _prev_echo_app_visible[user_id] = True
        db.commit()
        logger.info(f"User {user_id} marked as visible and connected")
        if not replaced_ws:
            _try_record_player_tracking_event(db, user, "connection")
        
        while True:
            # Keep connection alive and listen for any incoming messages
            data = await websocket.receive_text()
            logger.info(f"Received message from user {user_id}: {data}")
            
            # Periodically validate session (every 30 seconds)
            # This is a simple implementation - in production, you might want more sophisticated session validation
            
    except WebSocketDisconnect:
        manager.disconnect(connection_id, user_id)
        logger.info(f"WebSocket disconnected for user {user_id}")
        _apply_ws_disconnect_and_track(user_id, db)
        logger.info(f"User {user_id} marked as not visible and disconnected")
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        # Client disconnected abruptly - this is normal and not an error
        logger.debug(f"WebSocket connection reset for user {user_id}: {type(e).__name__}")
        manager.disconnect(connection_id, user_id)
        _apply_ws_disconnect_and_track(user_id, db)
        logger.debug(f"User {user_id} marked as not visible and disconnected due to connection reset")
    except Exception as e:
        logger.error(f"WebSocket error for user {user_id}: {e}")
        manager.disconnect(connection_id, user_id)
        _apply_ws_disconnect_and_track(user_id, db)
        logger.info(f"User {user_id} marked as not visible and disconnected due to error")
    finally:
        db.close()

# Timer trigger API endpoint
@app.post("/api/timer/trigger", response_model=TimerTriggerResponse)
async def trigger_timer(request: TimerTriggerRequest, db: Session = Depends(get_db)):
    """
    Trigger timer for all connected players based on received text data
    Expected format:
    "Slide#" & slideIndex & "#START_TIMER#" & round_number & "#at#" & Time&Date & "#time#" & _sec or min_ or Minute Countdown
    "Slide#" & slideIndex & "#STOP_TIMER#" & round_number & "#at#" & Time&Date
    Examples:
         "Slide#164#START_TIMER#round_7#at#2025-10-29 10:16:49 PM#time#1 min_black"
         "Slide#159#STOP_TIMER##at#2025-10-29 10:14:19 PM"
    """
    global last_timer_setting, _pending_server_stop_task
    global _question_track_window_id, _question_track_round_name
    global _round_track_active, _round_track_active_game_id, _round_track_round_name, _round_track_window_id, _round_track_ends_at
    logger.info(f">>>>>>> DATA in BEGGINIG >>>>>>> - rounds_info value: {rounds_info}")
    try:
        ts_utc = _utc_now()
        timer_start = ts_utc.replace(tzinfo=None)  # naive UTC for MySQL datetime columns
        trigger_data = request.trigger_data.strip()
        logger.info(f"Received timer trigger: {trigger_data}")


        # Get the current active game that is running
        active_game = db.query(ActiveGame).filter(ActiveGame.is_started == 'running').first()
        if not active_game:
            return TimerTriggerResponse(
                success=False,
                message="No active game is currently running"
            )

        # Get game info
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return TimerTriggerResponse(
                success=False,
                message=f"Game {active_game.game_id} not found"
            )

        game_name_safe = str(game.game_name).strip().lower().replace(' ', '_').replace('-', '_')
        control_table_name = f"action_game_control_{game_name_safe}"
        game_table_name = game.game_name

        # rounds_info[f"round_{i}"] = {"Name": None, "Slide": None, "time_now": None}
        # Every odd item is a key, every even item is a value:
        # "Slide#164#START_TIMER#round_7#at#2025-10-29 10:16:49 PM#time#1 min_black"
        timer_data = trigger_data.split("#")

        # If the list has an odd number of elements, the last key has no value → assign None
        if len(timer_data) % 2 != 0:
            timer_data.append(None)
        parts = dict(zip(timer_data[0::2], timer_data[1::2]))
        try:
            if (parts.get("START_TIMER") is not None and
                    rounds_info.get(parts["START_TIMER"]) is not None and
                    rounds_info[parts["START_TIMER"]]["Name"] is not None):
                round_name = rounds_info[parts["START_TIMER"]]["Name"]
                timer_action = "START_TIME"
            elif (parts.get("STOP_TIMER") is not None and
                    rounds_info.get(parts["STOP_TIMER"]) is not None and
                    rounds_info[parts["STOP_TIMER"]]["Name"] is not None):
                round_name = rounds_info[parts["STOP_TIMER"]]["Name"]
                timer_action = "STOP_TIMER"
            elif (parts.get("PAUSE_TIMER") is not None and
                    rounds_info.get(parts["PAUSE_TIMER"]) is not None and
                    rounds_info[parts["PAUSE_TIMER"]]["Name"] is not None):
                round_name = rounds_info[parts["PAUSE_TIMER"]]["Name"]
                timer_action = "PAUSE_TIMER"
            elif (parts.get("LAST_TIMER") is not None and
                    rounds_info.get(parts["LAST_TIMER"]) is not None and
                    rounds_info[parts["LAST_TIMER"]]["Name"] is not None):
                round_name = rounds_info[parts["LAST_TIMER"]]["Name"]
                timer_action = "LAST_TIMER"
            else:
                return TimerTriggerResponse(
                    success=False,
                    message=f"Invalid timer trigger in the request:{trigger_data}"
                            " Expected: START_TIMER, STOP_TIMER, PAUSE_TIMER or LAST_TIMER with valid round name."
                )
            slide_number = int(parts["Slide"])
            # timer_start = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            # timer_start = datetime.utcnow()
        except (IndexError, ValueError):
            logger.warning(f"Could not parse slide number from: {trigger_data}")
            return TimerTriggerResponse(
                success=False,
                message=f"Could not parse slide number from: {trigger_data}"
            )

        # Handle different timer actions
        _id = 0  # question_id
        _timer = 0  # final_timer
        question_timer = 0  # time_to_get_answer

        if timer_action == "START_TIME":
            """
            Check if slide_number exists in action_game_control_<game_name> table and If exists, update timer_start
            """
            check_sql = text(f"SELECT question_id, round_name FROM `{control_table_name}` WHERE slide_number = :slide_num")
            result = db.execute(check_sql, {"slide_num": slide_number})
            existing_row = result.fetchone()

            if existing_row:
                # Update existing row in DB
                question_id = existing_row[0]
                _id = question_id
                update_sql = text(f"""
                    UPDATE `{control_table_name}`
                    SET timer_start = :timer_start
                    WHERE slide_number = :slide_num
                """)
                db.execute(update_sql, {"timer_start": timer_start, "slide_num": slide_number})
                db.commit()

                # Get final_timer and time_to_get_answer from game table
                try:
                    question_data_result = db.execute(text(f"SELECT type_game, time_to_get_answer FROM `{game_table_name}` WHERE id = :qid"), {"qid": question_id})
                    question_data_row = question_data_result.fetchone()
                    _timer = int(question_data_row[0]) if question_data_row and question_data_row[0] is not None else 0
                    question_timer = int(question_data_row[1]) if question_data_row and question_data_row[1] is not None else 0
                except Exception as e:
                    logger.warning(f"Could not get type_game/time_to_get_answer for question_id {question_id}: {e}")
                    _timer = 0
                    question_timer = 0

                # Update rounds_info with Slide and time_now (just in case the PPT is changed)
                round_key = None
                for key, value in rounds_info.items():
                    if value.get("Name") == round_name:
                        round_key = key
                        break

                if round_key:
                    rounds_info[round_key]["Slide"] = slide_number
                    rounds_info[round_key]["time_now"] = timer_start
            else:
                """ Insert new row with data about the slide published as is the next question_id """
                insert_sql = text(f"""
                    INSERT INTO `{control_table_name}` (slide_number, round_name, timer_start)
                    VALUES (:slide_num, :round_name, :timer_start)
                """)
                db.execute(insert_sql, {"slide_num": slide_number, "round_name": round_name, "timer_start": timer_start})
                db.commit()

                # Get the inserted question_id
                get_id_sql = text(f"SELECT question_id FROM `{control_table_name}` WHERE slide_number = :slide_num")
                id_result = db.execute(get_id_sql, {"slide_num": slide_number})
                inserted_row = id_result.fetchone()
                if inserted_row:
                    _id = inserted_row[0]

                    # Check if question_id exists in the game table,
                    # and the round_name from slide matches to the round_name for the question_id
                    try:
                        check_round_sql = text(f"SELECT round_name FROM `{game_table_name}` WHERE id = :qid")
                        round_result = db.execute(check_round_sql, {"qid": _id})
                        game_round_row = round_result.fetchone()

                        if game_round_row and game_round_row[0] == round_name:
                            # Valid - get final_timer (type_game) and time_to_get_answer
                            try:
                                question_data_result = db.execute(text(f"SELECT type_game, time_to_get_answer FROM `{game_table_name}` WHERE id = :qid"), {"qid": _id})
                                question_data_row = question_data_result.fetchone()
                                _timer = int(question_data_row[0]) if question_data_row and question_data_row[0] is not None else 0
                                question_timer = int(question_data_row[1]) if question_data_row and question_data_row[1] is not None else 0
                            except Exception as e:
                                logger.warning(f"Could not get type_game/time_to_get_answer for question_id {_id}: {e}")
                                _timer = 0
                                question_timer = 0

                            # Update rounds_info with Slide and time_now
                            round_key = None
                            for key, value in rounds_info.items():
                                if value.get("Name") == round_name:
                                    round_key = key
                                    break

                            if round_key:
                                rounds_info[round_key]["Slide"] = slide_number
                                rounds_info[round_key]["time_now"] = timer_start
                        else:
                            # round_name doesn't match - remove the inserted row
                            delete_sql = text(f"DELETE FROM `{control_table_name}` WHERE slide_number = :slide_num")
                            db.execute(delete_sql, {"slide_num": slide_number})
                            db.commit()
                            logger.warning(f"Round name mismatch for question_id {_id}. Removed inserted row.")
                            # Don't send broadcast message

                    except Exception as e:
                        logger.error(f"Error checking round_name for question_id {_id}: {e}")
                        # Remove the inserted row on error
                        delete_sql = text(f"DELETE FROM `{control_table_name}` WHERE slide_number = :slide_num")
                        db.execute(delete_sql, {"slide_num": slide_number})
                        db.commit()

            # If DB left question_timer at 0, use optional VBA "#time#" segment from trigger string
            if question_timer == 0:
                tt_seg = _parse_trigger_time_segment(parts.get("time"))
                if tt_seg > 0:
                    question_timer = tt_seg
                    logger.info("START_TIME: question_timer=%s from trigger #time# segment", question_timer)

        elif timer_action == "LAST_TIMER":
            """
            Uses type_game from game table to define the final timer:
            - if '0' then each question gets timer in round and no final timer
            - if '<0' then despite each question can gets timer in round
                and additional by the end of the round gets the final timer
            """
            # Find the last question for this round_name
            try:
                last_question_sql = text(f"""
                    SELECT id, type_game FROM `{game_table_name}`
                    WHERE round_name = :round_name
                    ORDER BY id DESC
                    LIMIT 1
                """)
                last_result = db.execute(last_question_sql, {"round_name": round_name})
                last_row = last_result.fetchone()

                if last_row:
                    _timer = int(last_row[1]) if last_row[1] is not None else 0
                else:
                    _timer = 0
            except Exception as e:
                logger.error(f"Error getting type_game for LAST_TIMER: {e}")
                _timer = 0

            _id = 0
            question_timer = 0
            if _timer != 0:
                # Update rounds_info with LAST_TIMER
                round_key = None
                for key, value in rounds_info.items():
                    if value.get("Name") == round_name:
                        round_key = key
                        break

                if round_key:
                    rounds_info[round_key]["Slide"] = "LAST_TIMER"
                    rounds_info[round_key]["time_now"] = timer_start
        else:
            # For PAUSE_TIMER or other actions, use default behavior
            _id = 0
            _timer = 0
            question_timer = 0
            pass

        # Server timer: cancel previous auto-STOP, update per-question answer window (START only)
        _cancel_pending_server_stop()
        if timer_action == "START_TIME" and question_timer > 0 and _id > 0:
            _set_server_answer_window(ts_utc + timedelta(seconds=question_timer), _id)
            _question_track_window_id = f"{active_game.id}:{round_name}:q{_id}:{int(ts_utc.timestamp())}"
            _question_track_round_name = round_name
        elif timer_action in ("STOP_TIMER", "PAUSE_TIMER"):
            _clear_server_answer_window()
            _clear_round_track_window()
        elif timer_action == "LAST_TIMER":
            _clear_server_answer_window()

        event_id = str(uuid.uuid4())
        duration_seconds = 0
        timer_end_utc = None
        if timer_action == "START_TIME" and question_timer > 0:
            duration_seconds = int(question_timer)
            timer_end_utc = ts_utc + timedelta(seconds=duration_seconds)
        elif timer_action == "LAST_TIMER" and _timer != 0:
            duration_seconds = abs(int(_timer))
            timer_end_utc = ts_utc + timedelta(seconds=duration_seconds)

        # Round-scoped player tracking (type_game != 0): window_id fixed for the round until STOP / LAST end
        if timer_action == "START_TIME" and _id > 0 and _timer != 0:
            if (
                (not _round_track_active)
                or (_round_track_active_game_id != active_game.id)
                or (_round_track_round_name != round_name)
            ):
                _round_track_active = True
                _round_track_active_game_id = active_game.id
                _round_track_round_name = round_name
                _round_track_window_id = f"{active_game.id}:{round_name}:r:{int(ts_utc.timestamp())}"
                _round_track_ends_at = None
        if timer_action == "LAST_TIMER":
            if _timer != 0 and timer_end_utc is not None:
                _round_track_ends_at = timer_end_utc
            else:
                _clear_round_track_window()

        timer_start_str = _format_utc_iso_z(ts_utc)
        timer_end_str = _format_utc_iso_z(timer_end_utc) if timer_end_utc else None

        broadcast_obj: Dict[str, Any] = {
            "type": "timer_trigger",
            "timer_action": timer_action,
            "slide_number": slide_number,
            "round_name": round_name,
            "timer_start": timer_start_str,
            "question_id": _id,
            "final_timer": _timer,
            "question_timer": question_timer,
            "event_id": event_id,
            "duration_seconds": duration_seconds,
        }
        if timer_end_str is not None:
            broadcast_obj["timer_end"] = timer_end_str
        broadcast_message = json.dumps(broadcast_obj)

        if broadcast_message:
            await manager.broadcast_to_all_players(broadcast_message)
            logger.info(f"Timer '{timer_action}' triggered for slide {slide_number} and round: {round_name},"
                        f" broadcasted to {len(manager.active_connections)} connections")
        else:
            logger.warning(f"Timer '{timer_action}' triggered but no broadcast message was sent")

        if duration_seconds > 0 and timer_end_utc is not None:
            delay = max(0.0, (timer_end_utc - _utc_now()).total_seconds())
            if delay > 0:
                _pending_server_stop_task = asyncio.create_task(
                    _emit_server_stop_timer(
                        float(delay), event_id, round_name, slide_number
                    )
                )
            grade_delay = delay + AUTO_GRADE_DELAY_SEC
            if timer_action == "START_TIME" and _id > 0 and _timer == 0:
                asyncio.create_task(
                    _run_scheduled_auto_grade_question(
                        float(grade_delay),
                        active_game.id,
                        game_table_name,
                        game_name_safe,
                        _id,
                    )
                )
            elif timer_action == "LAST_TIMER" and _timer != 0:
                asyncio.create_task(
                    _run_scheduled_auto_grade_round(
                        float(grade_delay),
                        active_game.id,
                        game_table_name,
                        game_name_safe,
                        round_name,
                    )
                )

        last_timer_setting = {
            "timer_action": timer_action,
            "slide_number": slide_number,
            "round_name": round_name,
            "timer_start": timer_start_str,
            "question_id": _id,
            "final_timer": _timer,
            "question_timer": question_timer,
            "event_id": event_id,
            "duration_seconds": duration_seconds,
            "timer_end": timer_end_str,
        }
        logger.info(f">>>>>>> SET >>>>>>> - last_timer_setting value: {last_timer_setting}") #
        logger.info(f">>>>>>> DATA in END >>>>>>> - rounds_info value: {rounds_info}")
        
        # Save both to database
        _save_last_timer_setting_to_db(active_game.id, db)
        _save_rounds_info_to_db(active_game.id, db)
        
        return TimerTriggerResponse(
            success=True,
            message=f"Timer {timer_action} triggered successfully",
            timer_start = timer_start_str,
            timer_action = timer_action
        )
    except Exception as e:
        logger.error(f"Error processing timer trigger: {e}")
        return TimerTriggerResponse(
            success=False,
            message=f"Error processing timer trigger: {str(e)}"
        )

# WebSocket connection management endpoints
@app.get("/api/connections/stats")
async def get_connection_stats():
    """Get WebSocket connection statistics"""
    return manager.get_connection_stats()

@app.post("/api/connections/disconnect/{user_id}")
async def force_disconnect_user(user_id: int, db: Session = Depends(get_db)):
    """Force disconnect a specific user"""
    try:
        await manager.force_disconnect_user(user_id, db)
        return {"success": True, "message": f"User {user_id} disconnected"}
    except Exception as e:
        logger.error(f"Error force disconnecting user {user_id}: {e}")
        return {"success": False, "message": f"Error disconnecting user: {str(e)}"}

@app.post("/api/connections/cleanup")
async def cleanup_connections():
    """Clean up orphaned connections"""
    try:
        manager.cleanup_orphaned_connections()
        stats = manager.get_connection_stats()
        return {"success": True, "message": "Connections cleaned up", "stats": stats}
    except Exception as e:
        logger.error(f"Error cleaning up connections: {e}")
        return {"success": False, "message": f"Error cleaning up connections: {str(e)}"}

@app.get("/api/auth/validate-session")
async def validate_session(current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Validate current session and return user data"""
    try:
        # Check if user is a captain of any team
        is_captain = db.query(Teams).filter(Teams.team_captain == current_user.id).first() is not None
        
        # Check if user is a writer for their team
        is_writer = False
        if current_user.playing_in_team_id:
            # Convert team ID to integer if it's a string
            try:
                team_id = int(current_user.playing_in_team_id) if isinstance(current_user.playing_in_team_id, str) else current_user.playing_in_team_id
                team = db.query(Teams).filter(Teams.id == team_id).first()
                if team and team.writer_user_id == current_user.id:
                    is_writer = True
            except (ValueError, TypeError):
                # If playing_in_team_id is not a valid integer, user is not a writer
                pass
        
        return {
            "success": True,
            "user": {
                "id": current_user.id,
                "email": current_user.email,
                "name": current_user.name,
                "role": current_user.role,
                "is_active": current_user.is_active,
                "writer": is_writer,  # Now based on team table
                "playing_in_team_id": current_user.playing_in_team_id,
                "is_captain": is_captain,
                "logged_in_at": current_user.logged_in_at,
                "visible_connected": current_user.visible_connected
            }
        }
    except Exception as e:
        logger.error(f"Error validating session: {e}")
        return {"success": False, "message": "Session validation failed"}

@app.get("/api/rounds-info")
async def get_rounds_info():
    """
    Get the current rounds information dictionary
    """
    return {
        "success": True,
        "rounds_info": rounds_info
    }

async def _update_teams_answers_table(active_game: ActiveGame, db: Session):
    """
    Update active_teams_answers_<game_name> table with all questions from the game for each team.
    - Gets team IDs from active_games.teams_ids
    - Gets all question IDs from the game table (id column)
    - Gets correct/wrong scores from reg_score (splitting "1;0" format)
    - Overrides scores from active_new_scores_<game_name> if they exist
    - Sets default empty player_answer slots, null is_correct_* / player_id / final_score, lucky_bonus=0 for new rows.
    - Only inserts if record doesn't exist (doesn't update existing records)
    """
    try:
        # Get game info
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            logger.warning(f"Game {active_game.game_id} not found")
            return
        
        # Normalize game name for table names
        game_name_safe = game.game_name.replace(' ', '_').replace('-', '_').lower()
        answers_table_name = f"active_teams_answers_{game_name_safe}"
        scores_table_name = f"active_new_scores_{game_name_safe}"
        game_table_name = game.game_name  # Use actual game table name
        
        # Get team IDs from active_games.teams_ids
        if not active_game.teams_ids:
            logger.warning(f"No teams_ids found for active game {active_game.id}")
            return
        
        team_ids = [tid.strip() for tid in active_game.teams_ids.split(',') if tid.strip()]
        if not team_ids:
            logger.warning(f"No valid team IDs found for active game {active_game.id}")
            return
        
        logger.info(f"Updating teams answers table for game {game.game_name}, teams: {team_ids}")
        
        # Get all questions from the game table with id and reg_score
        # question_id in answers table uses id from game table (as before)
        # but correct_score and wrong_score come from each question's reg_score
        questions_data = {}  # {question_id: reg_score}
        try:
            result = db.execute(text(f"SELECT id, reg_score FROM `{game_table_name}` ORDER BY id"))
            question_rows = result.fetchall()
            for row in question_rows:
                question_id = row[0]  # id from game table (used as question_id in answers table)
                reg_score = row[1]  # reg_score from game table
                
                questions_data[question_id] = reg_score
            
            logger.info(f"Found {len(questions_data)} questions in game table")
        except Exception as e:
            logger.error(f"Error getting questions from game table {game_table_name}: {e}")
            return
        
        if not questions_data:
            logger.warning(f"No questions found in game table {game_table_name}")
            return
        
        # Get scores from active_new_scores table (if they exist)
        scores_override = {}  # {(team_id, question_id): (correct_score, wrong_score)}
        try:
            result = db.execute(text(f"""
                SELECT team_id, question_id, correct_score, wrong_score 
                FROM `{scores_table_name}` 
                WHERE team_id IS NOT NULL AND question_id IS NOT NULL AND question_id > 0
            """))
            for row in result.fetchall():
                team_id = row[0]
                question_id = row[1]
                correct_score = row[2]
                wrong_score = row[3]
                if team_id and question_id:
                    scores_override[(int(team_id), int(question_id))] = (correct_score, wrong_score)
            logger.info(f"Found {len(scores_override)} score overrides from active_new_scores table")
        except Exception as e:
            logger.warning(f"Error reading scores from {scores_table_name}: {e}")
        
        # Insert records for each team and question (only if they don't exist)
        inserted_count = 0
        skipped_count = 0
        
        for team_id_str in team_ids:
            try:
                team_id = int(team_id_str)
            except ValueError:
                logger.warning(f"Invalid team ID: {team_id_str}")
                continue
            
            for question_id, reg_score in questions_data.items():
                # Check if record already exists
                try:
                    check_result = db.execute(text(f"""
                        SELECT id FROM `{answers_table_name}` 
                        WHERE team_id = :team_id AND question_id = :question_id
                    """), {
                        'team_id': team_id,
                        'question_id': question_id
                    })
                    if check_result.fetchone():
                        skipped_count += 1
                        continue  # Skip if already exists
                except Exception as e:
                    logger.warning(f"Error checking existing record: {e}")
                    # Continue anyway, try to insert
                
                # Get scores for this question
                # First check for override, then parse reg_score, then use defaults
                if (team_id, question_id) in scores_override:
                    correct_score, wrong_score = scores_override[(team_id, question_id)]
                    logger.debug(f"Using override scores for team {team_id}, question {question_id}: {correct_score}/{wrong_score}")
                else:
                    # Parse reg_score from game table (format: "correct;wrong", e.g., "1;0")
                    if reg_score:
                        try:
                            reg_score_str = str(reg_score)
                            reg_score_parts = reg_score_str.split(';')
                            correct_score = float(reg_score_parts[0]) if len(reg_score_parts) > 0 and reg_score_parts[0] else 1
                            wrong_score = float(reg_score_parts[1]) if len(reg_score_parts) > 1 and reg_score_parts[1] else 0
                            logger.debug(f"Using reg_score for question {question_id}: {correct_score}/{wrong_score} (from '{reg_score_str}')")
                        except Exception as e:
                            logger.warning(f"Error parsing reg_score '{reg_score}' for question {question_id}, using defaults 1;0: {e}")
                            correct_score = 1
                            wrong_score = 0
                    else:
                        # No reg_score, use defaults
                        correct_score = 1
                        wrong_score = 0
                        logger.debug(f"No reg_score for question {question_id}, using defaults: {correct_score}/{wrong_score}")
                
                # Insert new record with default values
                try:
                    db.execute(text(f"""
                        INSERT INTO `{answers_table_name}` 
                        (team_id, question_id, correct_score, wrong_score,
                         player_answer1, player_answer2, player_answer3, player_answer4,
                         is_correct_1, is_correct_2, is_correct_3, is_correct_4,
                         answered_at, player_id, lucky_bonus, final_score)
                        VALUES (:team_id, :question_id, :correct_score, :wrong_score,
                         NULL, NULL, NULL, NULL,
                         NULL, NULL, NULL, NULL,
                         NULL, NULL, 0, NULL)
                    """), {
                        'team_id': team_id,
                        'question_id': question_id,
                        'correct_score': correct_score,
                        'wrong_score': wrong_score
                    })
                    inserted_count += 1
                except Exception as e:
                    logger.warning(f"Error inserting record for team {team_id}, question {question_id}: {e}")
        
        db.commit()
        logger.info(f"Updated teams answers table: {inserted_count} records inserted, {skipped_count} skipped (already exist)")
        
    except Exception as e:
        logger.error(f"Error in _update_teams_answers_table: {e}")
        db.rollback()
        raise

@app.post("/api/be_ready_to_start")
async def be_ready_to_start(
    data: dict,
    db: Session = Depends(get_db)
):
    """
    Parse and validate START_GAME data,Expected format:
      "Slide#40#START_GAME#round_1#at#2025-10-27 12:05:21 AM"
    Update the rounds_info dictionary accordingly
      with slide number and time for the specified round.
    """
    try:
        text_data = data.get('trigger_data', '')
        
        # Check if data contains "START_GAME"
        if "START_GAME" not in text_data or "round_" not in text_data:
            logger.warning(f"Invalid request - does not contain START_GAME or round: {text_data}")
            return {
                "success": False,
                "reason": "Wrong request"
            }
        
        # Parse the data
        # Format: "Slide#40#START_GAME#round_1#at#2025-10-27 12:05:21 AM"
        # Extract: Slide number, Round number and Time
        try:
            # Split by '#'
            parts = text_data.split('#')
            
            if len(parts) < 6:
                logger.error(f"Invalid data format, not enough parts: {text_data}")
                return {
                    "success": False,
                    "reason": "Invalid data format"
                }
            
            # parts[0] = "Slide", parts[1] = slide_number,
            # parts[2] = "START_GAME", parts[3] = round_number,
            # parts[4] = "at", parts[5:] = datetime
            slide_number = parts[1]
            round_number = parts[3]
            time_str = '#'.join(parts[5:])  # Rejoin in case datetime has spaces
            logger.info(f"Parsed data - Slide: {slide_number}, Round: {round_number}, Time: {time_str}")

            # Get the running game ID (assume that on the same PC running one game only)
            active_game = db.query(ActiveGame).filter(
                ActiveGame.is_started.in_(['running'])
            ).first()
            
            if not active_game:
                logger.error("No running game found")
                return {
                    "success": False,
                    "reason": "No active game found"
                }
            
            # Ensure control table exists for this game
            create_action_game_control_table(active_game.id, db)

            # Populate rounds_info to get it with all existing in game rounds
            populate_rounds_info(active_game.id, db)
            
            # Check if round exists in rounds_info
            if round_number not in rounds_info:
                logger.error(f"Round key not found: {round_number}")
                return {
                    "success": False,
                    "reason": "The Round # is not found"
                }
            
            # Check if round Name is None
            round_data = rounds_info[round_number]
            if round_data["Name"] is None:
                logger.error(f"Round name is None for {round_number}")
                return {
                    "success": False,
                    "reason": "The Round # is not existing in the game"
                }
            
            # Update the round data with slide and time
            round_data["Slide"] = slide_number
            round_data["time_now"] = time_str
            logger.info(f"Updated {round_number} with Slide: {slide_number}, Time: {time_str}")
            
            # Keep only this round in the dictionary
            rounds_info.clear()
            rounds_info[round_number] = round_data
            logger.info(f"Cleared rounds_info, keeping only {round_number}")
            logger.info(f"{rounds_info}")
            
            # Save rounds_info to database
            _save_rounds_info_to_db(active_game.id, db)
            
            # Update active_teams_answers table with all questions for each team
            try:
                await _update_teams_answers_table(active_game, db)
            except Exception as e:
                logger.error(f"Error updating teams answers table: {e}")
                # Don't fail the whole request if this fails, just log it
            
            return {
                "success": True,
                "round_data": round_data
            }
        except Exception as e:
            logger.error(f"Error parsing data: {e}")
            return {
                "success": False,
                "reason": f"Error parsing data: {str(e)}"
            }
        
    except Exception as e:
        logger.error(f"Error in be_ready_to_start: {e}")
        return {
            "success": False,
            "reason": f"Error processing request: {str(e)}"
        }

@app.post("/api/team/toggle-writer")
async def toggle_writer_status(
    request: dict,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Toggle writer status for the current user's team
    Any team member can turn writer status ON or OFF
    """
    try:
        if not current_user.playing_in_team_id:
            return {"success": False, "message": "User is not assigned to any team"}
        
        # Get user's team
        try:
            team_id = int(current_user.playing_in_team_id) if isinstance(current_user.playing_in_team_id, str) else current_user.playing_in_team_id
            team = db.query(Teams).filter(Teams.id == team_id).first()
        except (ValueError, TypeError):
            return {"success": False, "message": "Invalid team ID"}
        
        if not team:
            return {"success": False, "message": "Team not found"}
        
        # Check if user is a member of this team
        if not team.team_members_ids or str(current_user.id) not in team.team_members_ids.split(','):
            return {"success": False, "message": "User is not a member of this team"}
        
        action = request.get('action')  # 'on' or 'off'
        if action not in ['on', 'off']:
            return {"success": False, "message": "Action must be 'on' or 'off'"}
        
        previous_writer_id = team.writer_user_id
        previous_writer_name = None
        
        if action == 'on':
            # Set current user as writer
            team.writer_user_id = current_user.id
            message = f"Writer status turned ON for {current_user.name}"
        else:
            # Turn off writer status
            team.writer_user_id = None
            message = f"Writer status turned OFF for {current_user.name}"
        
        # Get previous writer's name for notification
        if previous_writer_id and previous_writer_id != current_user.id:
            previous_writer = db.query(User).filter(User.id == previous_writer_id).first()
            if previous_writer:
                previous_writer_name = previous_writer.name
        
        db.commit()
        
        return {
            "success": True,
            "message": message,
            "writer_status": {
                "is_writer": action == 'on',
                "current_writer_id": team.writer_user_id,
                "current_writer_name": current_user.name if action == 'on' else None,
                "previous_writer_name": previous_writer_name
            }
        }
        
    except Exception as e:
        logger.error(f"Error toggling writer status: {e}")
        db.rollback()
        return {"success": False, "message": f"Error toggling writer status: {str(e)}"}

@app.get("/api/round/{round_id}")
async def test_rounds_query(round_id: int):
    """
    Get data about the specific round
    """
    if rounds_info.get(f"round_{round_id}") is not None:
        return {
            "success": True,
            "round_name": rounds_info[f"round_{id}"]["Name"],
            "round_slide": rounds_info[f"round_{id}"]["Slide"],
            "round_time": rounds_info[f"round_{id}"]["time_now"]
        }
    else:
        return {"success": False, "message": "Round not found"}

def _game_question_dict_one_row_round(
    row: tuple,
    *,
    has_answer4_column: bool,
    has_link_columns: bool,
) -> Dict[str, Any]:
    """Build API dict for one game-row. No DB column `question`; optional answer4 / links_* with fallback queries."""
    if has_answer4_column and has_link_columns:
        # id..question_num | a1,a2,a3,a4 | comments | lq la | tg tta
        return {
            "id": row[0],
            "round_name": row[1],
            "reg_score": row[2],
            "bonus_score": row[3],
            "answers_for_selection": row[4],
            "question_num": row[5],
            "answer1": row[6],
            "answer2": row[7],
            "answer3": row[8],
            "answer4": row[9],
            "comments": row[10],
            "links_for_question": row[11],
            "links_for_answer": row[12],
            "type_game": row[13],
            "time_to_get_answer": row[14],
        }
    if has_answer4_column and not has_link_columns:
        return {
            "id": row[0],
            "round_name": row[1],
            "reg_score": row[2],
            "bonus_score": row[3],
            "answers_for_selection": row[4],
            "question_num": row[5],
            "answer1": row[6],
            "answer2": row[7],
            "answer3": row[8],
            "answer4": row[9],
            "comments": row[10],
            "links_for_question": None,
            "links_for_answer": None,
            "type_game": row[11],
            "time_to_get_answer": row[12],
        }
    if (not has_answer4_column) and has_link_columns:
        return {
            "id": row[0],
            "round_name": row[1],
            "reg_score": row[2],
            "bonus_score": row[3],
            "answers_for_selection": row[4],
            "question_num": row[5],
            "answer1": row[6],
            "answer2": row[7],
            "answer3": row[8],
            "answer4": None,
            "comments": row[9],
            "links_for_question": row[10],
            "links_for_answer": row[11],
            "type_game": row[12],
            "time_to_get_answer": row[13],
        }
    # no answer4, no links
    return {
        "id": row[0],
        "round_name": row[1],
        "reg_score": row[2],
        "bonus_score": row[3],
        "answers_for_selection": row[4],
        "question_num": row[5],
        "answer1": row[6],
        "answer2": row[7],
        "answer3": row[8],
        "answer4": None,
        "comments": row[9],
        "links_for_question": None,
        "links_for_answer": None,
        "type_game": row[10],
        "time_to_get_answer": row[11],
    }


_GAME_Q_SELECT_TAIL_A4_LINKS = (
    "answer1, answer2, answer3, answer4, comments, links_for_question, links_for_answer, "
    "type_game, time_to_get_answer"
)
_GAME_Q_SELECT_TAIL_A4 = (
    "answer1, answer2, answer3, answer4, comments, type_game, time_to_get_answer"
)
_GAME_Q_SELECT_TAIL_LINKS = (
    "answer1, answer2, answer3, comments, links_for_question, links_for_answer, "
    "type_game, time_to_get_answer"
)
_GAME_Q_SELECT_TAIL_MIN = (
    "answer1, answer2, answer3, comments, type_game, time_to_get_answer"
)


def _fetch_game_question_rows_with_fallback(
    db: Session, game_table_name: str, where_sql: str, params: Dict[str, Any]
) -> tuple:
    """Run game SELECT with graceful degradation for older tables (missing answer4 / link columns).

    Returns (rows or single-row list-for-caller, has_answer4: bool, has_link_columns: bool).
    Caller uses fetchall() consumer; question-by-id uses fetchone wrapped as singleton.
    """
    head = (
        "SELECT id, round_name, reg_score, bonus_score, answers_for_selection, question_num, "
    )
    attempts = [
        (_GAME_Q_SELECT_TAIL_A4_LINKS, True, True),
        (_GAME_Q_SELECT_TAIL_A4, True, False),
        (_GAME_Q_SELECT_TAIL_LINKS, False, True),
        (_GAME_Q_SELECT_TAIL_MIN, False, False),
    ]
    sql_base = (
        "{head}{tail}\n"
        f"FROM `{game_table_name}` WHERE {where_sql}"
    )
    last_exc: Optional[BaseException] = None
    for tail, has_a4, has_l in attempts:
        q = sql_base.format(head=head, tail=tail)
        try:
            rows = db.execute(text(q), params).fetchall()
            return rows, has_a4, has_l
        except Exception as e:
            last_exc = e
            if "unknown column" not in str(e).lower() and "doesn't exist" not in str(e).lower():
                raise
            continue
    if last_exc is not None:
        raise last_exc
    return [], False, False


def _question_preview_from_row_dict(qd: Dict[str, Any]) -> str:
    for key in ("links_for_question", "comments", "answer1", "answer2"):
        v = qd.get(key)
        if v is not None and str(v).strip():
            return str(v).strip()
    qn = qd.get("question_num")
    qid = qd.get("id")
    if qn is not None and str(qn).strip():
        return f"Question {qn}"
    return f"Question {qid}"


def _load_game_structure_for_bonus_minimal(
    db: Session, game_table_name: str
) -> List[dict]:
    """Fallback when full column set is unavailable."""
    col_sets = [
        "id, round_name, question_num, comments, links_for_question",
        "id, round_name, question_num, comments",
        "id, round_name, question_num",
        "id, round_name",
    ]
    for cols in col_sets:
        try:
            q = text(f"SELECT {cols} FROM `{game_table_name}` ORDER BY id")
            rows = db.execute(q).fetchall()
            if not rows:
                continue
            names = [c.strip() for c in cols.split(",")]
            out: List[dict] = []
            for row in rows:
                rd = dict(zip(names, row))
                qd = {
                    "id": rd.get("id"),
                    "round_name": rd.get("round_name") or "",
                    "question_num": rd.get("question_num"),
                    "comments": rd.get("comments"),
                    "links_for_question": rd.get("links_for_question"),
                }
                out.append(
                    {
                        "id": qd["id"],
                        "round_name": qd.get("round_name") or "",
                        "question_num": qd.get("question_num"),
                        "preview": _question_preview_from_row_dict(qd),
                        "data": qd,
                    }
                )
            return out
        except Exception as e:
            logger.debug("Minimal bonus question select (%s) failed: %s", cols, e)
            continue
    return []


def _load_game_structure_for_bonus(
    db: Session, game_table_name: str
) -> tuple[List[dict], List[dict]]:
    """Tiers (rounds) and questions from Quze game table round_name / id columns."""
    tiers: List[dict] = []
    questions: List[dict] = []

    summary = _fetch_game_rounds_summary(db, game_table_name)
    for rn in summary.get("round_names") or []:
        tiers.append(
            {
                "name": rn,
                "column": "round_name",
                "question_count": 0,
            }
        )
    if tiers:
        count_q = text(
            f"""
            SELECT round_name, COUNT(*) AS cnt
            FROM `{game_table_name}`
            WHERE round_name IS NOT NULL AND round_name != ''
            GROUP BY round_name
            """
        )
        try:
            counts = {str(r[0]): int(r[1]) for r in db.execute(count_q).fetchall()}
            for t in tiers:
                t["question_count"] = counts.get(t["name"], 0)
        except Exception:
            pass

    try:
        rows, has_a4, has_l = _fetch_game_question_rows_with_fallback(
            db, game_table_name, "1=1 ORDER BY id", {}
        )
        for r in rows:
            qd = _game_question_dict_one_row_round(tuple(r), has_a4, has_l)
            questions.append(
                {
                    "id": qd["id"],
                    "round_name": qd.get("round_name") or "",
                    "question_num": qd.get("question_num"),
                    "preview": _question_preview_from_row_dict(qd),
                    "data": qd,
                }
            )
    except Exception as e:
        logger.warning(
            "Full bonus question fetch failed for %s: %s",
            game_table_name,
            e,
        )

    if not questions:
        questions = _load_game_structure_for_bonus_minimal(db, game_table_name)

    if not tiers and questions:
        by_round: Dict[str, int] = {}
        for q in questions:
            rn = (q.get("round_name") or "").strip() or "Unknown round"
            by_round[rn] = by_round.get(rn, 0) + 1
        tiers = [
            {
                "name": name,
                "column": "round_name",
                "question_count": cnt,
            }
            for name, cnt in by_round.items()
        ]

    return tiers, questions


@app.get("/api/games/{game_name}/round/{round_name}")
async def get_game_questions_by_round(
    game_name: str,
    round_name: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get all questions for a specific round in a game
    Returns list of questions with all their data
    """
    try:
        # Get game from GamesList
        game = db.query(GamesList).filter(GamesList.game_name == game_name).first()
        if not game:
            raise HTTPException(status_code=404, detail=f"Game '{game_name}' not found")
        
        game_table_name = game.game_name
        rows, has_a4, has_l = _fetch_game_question_rows_with_fallback(
            db,
            game_table_name,
            "round_name = :round_name ORDER BY id",
            {"round_name": round_name},
        )
        questions = [
            _game_question_dict_one_row_round(
                tuple(r), has_answer4_column=has_a4, has_link_columns=has_l
            )
            for r in rows
        ]
        return questions
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting game questions by round: {e}")
        raise HTTPException(status_code=500, detail=f"Error retrieving questions: {str(e)}")


@app.get("/api/games/{game_name}/question-by-id/{question_id}")
async def get_game_question_by_id(
    game_name: str,
    question_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Single question row by primary key id (bypasses round_name filter).
    Used when round-scoped list is empty due to name mismatch but timer already has question_id.
    """
    try:
        game = db.query(GamesList).filter(GamesList.game_name == game_name).first()
        if not game:
            raise HTTPException(status_code=404, detail=f"Game '{game_name}' not found")

        game_table_name = game.game_name
        rows, has_a4, has_l = _fetch_game_question_rows_with_fallback(
            db,
            game_table_name,
            "id = :qid LIMIT 1",
            {"qid": question_id},
        )
        if not rows:
            raise HTTPException(status_code=404, detail="Question not found")

        return _game_question_dict_one_row_round(
            tuple(rows[0]), has_answer4_column=has_a4, has_link_columns=has_l
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting game question by id: {e}")
        raise HTTPException(status_code=500, detail=f"Error retrieving question: {str(e)}")


@app.get("/api/games/{game_name}/rounds")
async def get_game_rounds(
    game_name: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get all distinct round names for a game
    Returns list of unique round names
    """
    try:
        # Get game from GamesList
        game = db.query(GamesList).filter(GamesList.game_name == game_name).first()
        if not game:
            raise HTTPException(status_code=404, detail=f"Game '{game_name}' not found")
        
        # Query the game table for distinct round names
        game_table_name = game.game_name
        query_sql = text(f"""
            SELECT DISTINCT round_name 
            FROM `{game_table_name}`
            WHERE round_name IS NOT NULL AND round_name != ''
            ORDER BY id
        """)
        
        result = db.execute(query_sql)
        rows = result.fetchall()
        
        # Convert to list of round names
        rounds = [row[0] for row in rows]
        
        return rounds
        
    except Exception as e:
        logger.error(f"Error getting game rounds: {e}")
        raise HTTPException(status_code=500, detail=f"Error retrieving rounds: {str(e)}")

@app.get("/api/active-games/team-answers/{game_name_safe}/{team_id}")
async def get_team_answers_for_game(
    game_name_safe: str,
    team_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get all recorded answers for a specific team in an active game
    """
    try:
        # Construct answers table name
        answers_table_name = f"active_teams_answers_{game_name_safe}"
        
        # Verify user has access (admin or belongs to the team)
        if current_user.role != 'admin':
            # Check if user belongs to the requested team
            try:
                user_team_id = int(current_user.playing_in_team_id) if current_user.playing_in_team_id else None
                if user_team_id != team_id:
                    raise HTTPException(status_code=403, detail="Access denied")
            except (ValueError, TypeError):
                raise HTTPException(status_code=403, detail="Access denied")
        
        # Query multislot answers (new schema includes final_score; correct_score/wrong_score = weights)
        query_sql = text(f"""
            SELECT id, team_id, question_id, correct_score, wrong_score,
                   player_answer1, player_answer2, player_answer3, player_answer4,
                   is_correct_1, is_correct_2, is_correct_3, is_correct_4,
                   lucky_bonus, final_score, answered_at, player_id
            FROM `{answers_table_name}`
            WHERE team_id = :team_id
            ORDER BY question_id
        """)
        result = db.execute(query_sql, {"team_id": team_id})
        rows = result.fetchall()

        answers: List[Dict[str, Any]] = []
        for row in rows:
            pa1 = row[5]
            pa2 = row[6]
            pa3 = row[7]
            pa4 = row[8]
            ic1, ic2, ic3, ic4 = row[9], row[10], row[11], row[12]
            lucky = row[13]
            final_s = row[14]
            p1 = str(pa1 or "")
            p2 = str(pa2 or "")
            p3 = str(pa3 or "")
            p4 = str(pa4 or "")
            rollup = _rollup_is_correct_four(ic1, ic2, ic3, ic4)
            answers.append({
                "id": row[0],
                "team_id": row[1],
                "question_id": row[2],
                "correct_score": row[3],
                "wrong_score": row[4],
                "answer": _synthetic_answer_from_four(p1, p2, p3, p4),
                "player_answer1": pa1,
                "player_answer2": pa2,
                "player_answer3": pa3,
                "player_answer4": pa4,
                "is_correct": rollup,
                "is_correct_1": ic1,
                "is_correct_2": ic2,
                "is_correct_3": ic3,
                "is_correct_4": ic4,
                "lucky_bonus": lucky,
                "final_score": final_s,
                "answered_at": row[15].isoformat() if row[15] else None,
                "player_id": row[16],
            })

        return answers
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting team answers: {e}")
        raise HTTPException(status_code=500, detail=f"Error retrieving team answers: {str(e)}")


@app.put("/api/active-games/team-answers/{game_name_safe}/{team_id}")
async def put_team_answers_batch(
    game_name_safe: str,
    team_id: int,
    body: TeamAnswersBatchRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Batch update player_answer slots in active_teams_answers_{game_name_safe}. Does not clear is_correct_*.
    Optional round_name: validate list/radio for that round.
    type_game == 0 (classic): each list question validated against its own options only.
    type_game != 0 (round mode): shared canonical list pool and cross-question exclusivity.
    Optional round_timer: retained for client compatibility.
    """
    try:
        answers_table_name = f"active_teams_answers_{game_name_safe}"
        if not body.answers:
            return {"success": True, "updated": 0, "conflicts": []}

        if current_user.role != "admin":
            user_team_id = _resolve_user_team_id_int(current_user, db)
            if user_team_id is None or user_team_id != team_id:
                raise HTTPException(status_code=403, detail="Access denied")

        team = db.query(Teams).filter(Teams.id == team_id).first()
        if not team:
            raise HTTPException(status_code=404, detail="Team not found")

        if current_user.role != "admin":
            if team.writer_user_id is None or team.writer_user_id != current_user.id:
                raise HTTPException(status_code=403, detail="Only the team writer can update answers")

        game = _find_games_list_by_safe(db, game_name_safe)
        if not game:
            raise HTTPException(status_code=404, detail=f"Game not found for '{game_name_safe}'")

        answer_only_legacy_table = False
        q_slots = text(
            f"""
            SELECT question_id,
                   COALESCE(player_answer1, '') AS p1,
                   COALESCE(player_answer2, '') AS p2,
                   COALESCE(player_answer3, '') AS p3,
                   COALESCE(player_answer4, '') AS p4
            FROM `{answers_table_name}`
            WHERE team_id = :team_id
        """
        )
        slot_rows = []
        try:
            slot_rows = db.execute(q_slots, {"team_id": team_id}).fetchall()
        except Exception as e:
            msg = str(e).lower()
            if "unknown column" not in msg and "1054" not in msg and "doesn't exist" not in msg:
                raise
            logger.warning(
                "answers table %s has no player_answer* columns — using legacy answer column: %s",
                answers_table_name,
                e,
            )
            answer_only_legacy_table = True
            ql = text(
                f"""
                SELECT question_id, COALESCE(answer, '') AS a
                FROM `{answers_table_name}`
                WHERE team_id = :team_id
            """
            )
            slot_rows = db.execute(ql, {"team_id": team_id}).fetchall()

        if answer_only_legacy_table:
            slot_map = {int(r[0]): (str(r[1] or ""), "", "", "") for r in slot_rows}
        else:
            slot_map = {
                int(r[0]): (str(r[1] or ""), str(r[2] or ""), str(r[3] or ""), str(r[4] or ""))
                for r in slot_rows
            }

        updated = 0
        upd_final_only = text(
            f"""
            UPDATE `{answers_table_name}`
            SET final_score=:fs
            WHERE team_id=:team_id AND question_id=:question_id
            """
        )
        final_patch_qids: Set[int] = set()

        for item in body.answers:
            dumped = item.model_dump(exclude_unset=True)
            keys_other = set(dumped.keys()) - {"question_id"}
            if (
                keys_other == {"final_score"}
                and "final_score" in dumped
            ):
                if current_user.role != "admin":
                    raise HTTPException(
                        status_code=403, detail="Only admin can adjust final_score"
                    )
                rc_exec = db.execute(
                    upd_final_only,
                    {
                        "fs": dumped["final_score"],
                        "team_id": team_id,
                        "question_id": item.question_id,
                    },
                )
                rc = getattr(rc_exec, "rowcount", None)
                if rc is None or rc == 0:
                    db.rollback()
                    raise HTTPException(
                        status_code=409,
                        detail=(
                            "No row to update for question_id="
                            f"{item.question_id} (run game bootstrap to create team answer rows)"
                        ),
                    )
                updated += int(rc)
                final_patch_qids.add(item.question_id)
                continue
            slot_map[item.question_id] = _team_answer_item_normalized_slots(item)

        merged = {
            qid: _comma_join_four_slots_for_list(t[0], t[1], t[2], t[3]) for qid, t in slot_map.items()
        }

        if body.round_name:
            game_table = game.game_name
            rq = text(
                f"""
                SELECT id, question_num, answers_for_selection
                FROM `{game_table}`
                WHERE round_name = :rn
                ORDER BY question_num ASC, id ASC
            """
            )
            round_rows = db.execute(rq, {"rn": body.round_name}).fetchall()
            list_qids: List[int] = []
            for row in round_rows:
                qid = int(row[0])
                afs = row[2]
                kind, _opts = _parse_answers_for_selection(afs)
                if kind == "list":
                    list_qids.append(qid)
                elif kind == "radio":
                    t = slot_map.get(qid)
                    if not t:
                        continue
                    nonempty = [x.strip() for x in list(t) if x and x.strip()]
                    if len(nonempty) != len(set(nonempty)):
                        raise HTTPException(
                            status_code=400,
                            detail={
                                "success": False,
                                "message": "Radio question has duplicate selections across answer slots",
                                "question_id": qid,
                            },
                        )

            round_type_game = _resolve_type_game_for_round(db, game_table, body.round_name)
            if round_type_game != 0:
                canonical_list = _canonical_list_options_first_in_round(round_rows)
                if canonical_list and list_qids:
                    canon_set = set(canonical_list)
                    for qid in list_qids:
                        raw = (merged.get(qid) or "").strip()
                        if not raw:
                            continue
                        for opt in [x.strip() for x in raw.split(",") if x.strip()]:
                            if opt not in canon_set:
                                raise HTTPException(
                                    status_code=400,
                                    detail={
                                        "success": False,
                                        "message": "List selection not in round canonical option pool",
                                        "question_id": qid,
                                        "option": opt,
                                        "canonical": canonical_list,
                                    },
                                )
                if len(list_qids) > 1:
                    confl = _list_exclusivity_conflicts(list_qids, merged)
                    if confl:
                        raise HTTPException(
                            status_code=409,
                            detail={
                                "success": False,
                                "message": "List option used in more than one question",
                                "conflicts": confl,
                            },
                        )
            else:
                _validate_list_selections_per_question(round_rows, merged)

        player_id = current_user.id

        upd_legacy_plain = text(
            f"""
            UPDATE `{answers_table_name}`
            SET answer = :ans_plain, player_id = :player_id
            WHERE team_id = :team_id AND question_id = :question_id
        """
        )
        upd_legacy_scores = text(
            f"""
            UPDATE `{answers_table_name}`
            SET answer = :ans_plain, player_id = :player_id,
                correct_score = :correct_score, wrong_score = :wrong_score
            WHERE team_id = :team_id AND question_id = :question_id
        """
        )
        upd_full_lb = text(
            f"""
            UPDATE `{answers_table_name}`
            SET player_answer1 = :p1, player_answer2 = :p2, player_answer3 = :p3,
                player_answer4 = :p4, player_id = :player_id,
                correct_score = :correct_score, wrong_score = :wrong_score,
                lucky_bonus = :lucky_bonus
            WHERE team_id = :team_id AND question_id = :question_id
        """
        )
        upd_full = text(
            f"""
            UPDATE `{answers_table_name}`
            SET player_answer1 = :p1, player_answer2 = :p2, player_answer3 = :p3,
                player_answer4 = :p4, player_id = :player_id,
                correct_score = :correct_score, wrong_score = :wrong_score
            WHERE team_id = :team_id AND question_id = :question_id
        """
        )
        upd_lb = text(
            f"""
            UPDATE `{answers_table_name}`
            SET player_answer1 = :p1, player_answer2 = :p2, player_answer3 = :p3,
                player_answer4 = :p4, player_id = :player_id,
                lucky_bonus = :lucky_bonus
            WHERE team_id = :team_id AND question_id = :question_id
        """
        )
        upd_slots = text(
            f"""
            UPDATE `{answers_table_name}`
            SET player_answer1 = :p1, player_answer2 = :p2, player_answer3 = :p3,
                player_answer4 = :p4, player_id = :player_id
            WHERE team_id = :team_id AND question_id = :question_id
        """
        )
        for item in body.answers:
            if item.question_id in final_patch_qids:
                continue
            p1, p2, p3, p4 = slot_map[item.question_id]
            ans_plain = _synthetic_answer_from_four(str(p1 or ""), str(p2 or ""), str(p3 or ""), str(p4 or ""))
            has_scores = item.correct_score is not None and item.wrong_score is not None
            has_lb = item.lucky_bonus is not None
            result: Any
            if answer_only_legacy_table:
                if has_lb:
                    logger.warning("lucky_bonus omitted for question_id=%s (legacy answers table)", item.question_id)
                if has_scores:
                    result = db.execute(
                        upd_legacy_scores,
                        {
                            "ans_plain": ans_plain,
                            "player_id": player_id,
                            "correct_score": item.correct_score,
                            "wrong_score": item.wrong_score,
                            "team_id": team_id,
                            "question_id": item.question_id,
                        },
                    )
                else:
                    result = db.execute(
                        upd_legacy_plain,
                        {
                            "ans_plain": ans_plain,
                            "player_id": player_id,
                            "team_id": team_id,
                            "question_id": item.question_id,
                        },
                    )
            elif has_scores and has_lb:
                result = db.execute(
                    upd_full_lb,
                    {
                        "p1": p1,
                        "p2": p2,
                        "p3": p3,
                        "p4": p4,
                        "player_id": player_id,
                        "correct_score": item.correct_score,
                        "wrong_score": item.wrong_score,
                        "lucky_bonus": item.lucky_bonus,
                        "team_id": team_id,
                        "question_id": item.question_id,
                    },
                )
            elif has_scores:
                result = db.execute(
                    upd_full,
                    {
                        "p1": p1,
                        "p2": p2,
                        "p3": p3,
                        "p4": p4,
                        "player_id": player_id,
                        "correct_score": item.correct_score,
                        "wrong_score": item.wrong_score,
                        "team_id": team_id,
                        "question_id": item.question_id,
                    },
                )
            elif has_lb:
                result = db.execute(
                    upd_lb,
                    {
                        "p1": p1,
                        "p2": p2,
                        "p3": p3,
                        "p4": p4,
                        "player_id": player_id,
                        "lucky_bonus": item.lucky_bonus,
                        "team_id": team_id,
                        "question_id": item.question_id,
                    },
                )
            else:
                result = db.execute(
                    upd_slots,
                    {
                        "p1": p1,
                        "p2": p2,
                        "p3": p3,
                        "p4": p4,
                        "player_id": player_id,
                        "team_id": team_id,
                        "question_id": item.question_id,
                    },
                )
            rc = result.rowcount  # type: ignore
            if rc is None or rc == 0:
                db.rollback()
                raise HTTPException(
                    status_code=409,
                    detail=(
                        "No row to update for question_id="
                        f"{item.question_id} (run game bootstrap to create team answer rows)"
                    ),
                )
            updated += int(rc)
        db.commit()
        return {"success": True, "updated": updated, "conflicts": []}

    except HTTPException as exc:
        try:
            db.rollback()
        except Exception:  # noqa: S110
            pass
        raise exc
    except Exception as e:
        logger.error(f"Error updating team answers: {e}")
        try:
            db.rollback()
        except Exception:  # noqa: S110
            pass
        raise HTTPException(status_code=500, detail=f"Error updating team answers: {str(e)}")


@app.get("/api/health")
async def health_check():
    return {"status": "healthy", "timestamp": datetime.utcnow()}

@app.get("/api/timer/last-setting")
async def get_last_timer_setting(current_user: User = Depends(get_current_user)):
    """
    Get the last timer setting/command that was sent from the server.
    This is used to restore timer state when a player logs in or refreshes the page.
    """
    try:
        logger.info(f"GET - rounds_info value: {rounds_info}")
        logger.info(f"GET /api/timer/last-setting - last_timer_setting value: {last_timer_setting}")
        if last_timer_setting is None:
            logger.info("No timer setting available (last_timer_setting is None)")
            return {"success": False, "message": "No timer setting available", "data": None}

        logger.info(f"Returning last timer setting: {last_timer_setting}")
        return {
            "success": True,
            "data": last_timer_setting
        }
    except Exception as e:
        logger.error(f"Error getting last timer setting: {e}")
        return {"success": False, "message": f"Error getting last timer setting: {str(e)}", "data": None}

@app.get("/api/action-game-control/{game_name_safe}/round/{round_name}")
async def get_action_game_control_by_round(
    game_name_safe: str,
    round_name: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get action_game_control data for a specific round_name.
    Returns the last question_id entry for the given round_name.
    """
    try:
        # Find the active game
        active_game = db.query(ActiveGame).filter(ActiveGame.is_started == 'running').first()
        if not active_game:
            return {"success": False, "message": "No active game found", "data": None}
        
        # Get game info
        game = db.query(GamesList).filter(GamesList.id == active_game.game_id).first()
        if not game:
            return {"success": False, "message": "Game not found", "data": None}
        
        # Normalize game name for table identifier
        game_name_normalized = str(game.game_name).strip().lower().replace(' ', '_').replace('-', '_')
        table_name = f"action_game_control_{game_name_normalized}"
        
        # Check if table exists
        check_table_sql = text(f"SHOW TABLES LIKE '{table_name}'")
        result = db.execute(check_table_sql)
        if not result.fetchone():
            return {"success": False, "message": f"Control table {table_name} does not exist", "data": None}
        
        # Get the last entry for this round_name (by question_id DESC)
        select_sql = text(f"""
            SELECT question_id, slide_number, round_name, timer_start 
            FROM `{table_name}` 
            WHERE round_name = :round_name 
            ORDER BY question_id DESC 
            LIMIT 1
        """)
        result = db.execute(select_sql, {"round_name": round_name})
        row = result.fetchone()
        
        if row:
            return {
                "success": True,
                "data": {
                    "question_id": row[0],
                    "slide_number": row[1],
                    "round_name": row[2],
                    "timer_start": row[3].isoformat() if row[3] else None
                }
            }
        else:
            return {"success": False, "message": f"No data found for round_name: {round_name}", "data": None}
            
    except Exception as e:
        logger.error(f"Error getting action_game_control data: {e}")
        return {"success": False, "message": f"Error: {str(e)}", "data": None}

@app.get("/api/app/version")
async def get_app_version():
    """
    Get the latest app version information.
    Update this version number when you release a new build.
    Format: version (e.g., "1.0.0") and build (e.g., "2")
    """
    return {
        "version": "1.0.0",  # Update this when releasing a new version
        "build": "2"  # Update this build number for each new build
    }

@app.get("/api/auth/check-login")
async def check_login_status(current_user: User = Depends(get_current_user)):
    """Simple endpoint to check if user is still logged in"""
    return {
        "success": True,
        "logged_in": True,
        "user_id": current_user.id,
        "email": current_user.email
    }

@app.post("/api/auth/echo")
async def echo_session(
        echo_data: dict,
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    """Echo call for session validation with app visibility status"""
    logger.info("#########################################################################")
    logger.info(f">>>>>>> CHECK_IN_ECHO >>>>>>> - last_timer_setting value: {last_timer_setting}")
    logger.info("#########################################################################")
    logger.info(f">>>>>>> CHECK_IN_ECHO >>>>>>> - rounds_info value: {rounds_info}")
    try:
        # Extract data from request
        session_token = echo_data.get('session_token')
        app_visible = echo_data.get('app_visible', False)
        
        # Validate session token matches current session
        if current_user.session_token != session_token:
            logger.warning(f"Echo call failed for user {current_user.email}: session token mismatch")
            return {
                "success": False,
                "message": "Session token mismatch",
                "should_logout": True
            }
        
        # Update last seen timestamp and visible_connected status
        current_user.last_seen = datetime.utcnow()
        current_user.visible_connected = 1 if app_visible else 0

        async with _echo_tracking_lock_for(current_user.id):
            source = str(echo_data.get("source") or "periodic").strip().lower()
            visibility_reason_raw = echo_data.get("visibility_reason")
            visibility_reason: Optional[str] = None
            if visibility_reason_raw is not None:
                visibility_reason = str(visibility_reason_raw).strip()[:64]

            if (
                source == "immediate"
                and visibility_reason
                and visibility_reason in TRACKING_REASONS_ALL
                and visibility_reason not in ("connection", "disconnection")
            ):
                _try_record_player_tracking_event(db, current_user, visibility_reason)

            _prev_echo_app_visible[current_user.id] = app_visible
            _echo_app_visible[current_user.id] = app_visible

        db.commit()
        
        # Log visibility status for monitoring
        if app_visible:
            logger.info(f"Echo call successful for user {current_user.email} - APP IS VISIBLE")
        else:
            logger.warning(f"Echo call successful for user {current_user.email} - APP IS NOT VISIBLE (user may have switched tabs/apps)")
        
        # Check current writer status for the user's team
        current_writer_id = None
        current_writer_name = None
        is_current_user_writer = False
        
        if current_user.playing_in_team_id:
            try:
                team_id = int(current_user.playing_in_team_id) if isinstance(current_user.playing_in_team_id, str) else current_user.playing_in_team_id
                team = db.query(Teams).filter(Teams.id == team_id).first()
                if team and team.writer_user_id:
                    current_writer_id = team.writer_user_id
                    is_current_user_writer = (team.writer_user_id == current_user.id)
                    
                    # Get writer's name
                    writer_user = db.query(User).filter(User.id == team.writer_user_id).first()
                    if writer_user:
                        current_writer_name = writer_user.name
            except (ValueError, TypeError):
                pass
        
        return {
            "success": True,
            "message": "Session valid",
            "should_logout": False,
            "user_id": current_user.id,
            "email": current_user.email,
            "visible_connected": current_user.visible_connected,
            "writer_status": {
                "is_writer": is_current_user_writer,
                "current_writer_id": current_writer_id,
                "current_writer_name": current_writer_name
            }
        }
        
    except Exception as e:
        logger.error(f"Error in echo call: {e}")
        return {
            "success": False,
            "message": "Echo call failed",
            "should_logout": True
        }

if __name__ == "__main__":
    # Run with HTTP for local development
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )
