from fastapi import FastAPI, HTTPException, Depends, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr, constr
from sqlalchemy import create_engine, Column, Integer, Float, String, DateTime, Boolean, text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session, validates
from passlib.context import CryptContext
from datetime import datetime, timedelta
from sqlalchemy import Enum
import random
import string
import jwt
import uvicorn
import os
import logging
import json
import asyncio
from typing import Optional, List, Dict, Any, Union

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Global dictionary to track round information for active games
# Format: {"round_1": {"Name": None, "Slide": None, "time_now": None}, ...}
rounds_info = {}
last_timer_setting = None
for i in range(1, 21):  # rounds 1-20
    rounds_info[f"round_{i}"] = {"Name": None, "Slide": None, "time_now": None}

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
        
        # Convert rounds_info to JSON string
        rounds_info_json = json.dumps(rounds_info, default=str)
        
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
        
        # Convert last_timer_setting to JSON string
        timer_setting_json = json.dumps(last_timer_setting, default=str)
        
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

# Database configuration
DATABASE_URL = "mysql+pymysql://root:19761982@localhost:3306/game_sila_misly"
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

# JWT settings
SECRET_KEY = "your-secret-key-change-this-in-production"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

# FastAPI app
app = FastAPI(title="Team Results Notification API", version="1.0.0")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure this properly for production
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
    - question - question text
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
            slide_id INT DEFAULT NULL,
            answer TEXT,
            is_correct INT DEFAULT 0,
            answered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            player_id INT DEFAULT NULL
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
        
        # Add question columns dynamically based on the game data
        await _add_question_columns_to_results_table(db, results_table_name, game)
        
        # Insert initial data for each team
        for team_id in team_ids:
            # Insert into results table
            results_insert_sql = f"""
            INSERT INTO `{results_table_name}` (team_id, total_score, correct_answers, wrong_answers, total_questions, question_ids)
            VALUES ({team_id}, 0, 0, 0, 0, '')
            """
            db.execute(text(results_insert_sql))
            
            # Insert bonus options into scores table
            for option in bonus_options:
                selection_type = option.get('selection_type', 'tier')
                selected_tiers = option.get('selected_tiers', [])
                selected_questions = option.get('selected_questions', [])
                
                if selection_type == 'tier':
                    # Insert one row per selected tier
                    for tier_name in selected_tiers:
                        scores_insert_sql = f"""
                        INSERT INTO `{scores_table_name}` (team_id, question_id, correct_score, wrong_score, option_name)
                        VALUES ({team_id}, 0, {option.get('correct_score', 1)}, {option.get('wrong_score', 0)}, '{option.get('name', '')}')
                        """
                        db.execute(text(scores_insert_sql))
                elif selection_type == 'question':
                    # Insert one row per selected question
                    for question_id in selected_questions:
                        scores_insert_sql = f"""
                        INSERT INTO `{scores_table_name}` (team_id, question_id, correct_score, wrong_score, option_name)
                        VALUES ({team_id}, {question_id}, {option.get('correct_score', 1)}, {option.get('wrong_score', 0)}, '{option.get('name', '')}')
                        """
                        db.execute(text(scores_insert_sql))
        
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
        
        # Get bonus options from the scores table
        result = db.execute(text(f"SELECT DISTINCT option_name, correct_score, wrong_score, question_id FROM `{scores_table_name}` WHERE option_name IS NOT NULL AND option_name != ''"))
        rows = result.fetchall()
        
        # Group by option name to create bonus options
        bonus_options = {}
        for row in rows:
            option_name = row[0]
            correct_score = row[1]
            wrong_score = row[2]
            question_id = row[3]
            
            if option_name not in bonus_options:
                bonus_options[option_name] = {
                    'name': option_name,
                    'correct_score': correct_score,
                    'wrong_score': wrong_score,
                    'selection_type': 'question' if question_id > 0 else 'tier',
                    'selected_tiers': [],
                    'selected_questions': [],
                    'question_count': 0
                }
            
            # Add question if it exists
            if question_id and question_id > 0:
                if str(question_id) not in bonus_options[option_name]['selected_questions']:
                    bonus_options[option_name]['selected_questions'].append(str(question_id))
        
        # Convert to list and calculate question counts
        bonus_options_list = []
        for option in bonus_options.values():
            if option['selection_type'] == 'tier':
                option['question_count'] = len(option['selected_tiers'])
            else:
                option['question_count'] = len(option['selected_questions'])
            bonus_options_list.append(option)
        
        return {
            "success": True,
            "bonus_options": bonus_options_list
        }
        
    except Exception as e:
        logger.error(f"Error getting bonus options: {e}")
        return {"success": False, "message": f"Error getting bonus options: {str(e)}"}

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

@app.get("/api/admin/games/{game_id}/structure", response_model=dict)
async def get_game_structure(game_id: int, db: Session = Depends(get_db)):
    """
    Get the structure of a game (tiers and questions) for bonus option creation
    """
    try:
        # Get game from GamesList
        game = db.query(GamesList).filter(GamesList.id == game_id).first()
        if not game:
            return {"success": False, "message": "Game not found"}
        
        # Find the actual game table
        game_table_name = f"{game.game_name}".replace(' ', '_').replace('-', '_').lower()
        
        # Try to find the actual game table by checking if it exists
        result = db.execute(text(f"SHOW TABLES LIKE '{game_table_name}%'"))
        tables = result.fetchall()
        
        if not tables:
            return {"success": False, "message": f"No game tables found for game: {game.game_name}"}
        
        # Use the first table found (assuming it's the main game table)
        actual_game_table = tables[0][0]
        
        # Get the structure of the game table
        result = db.execute(text(f"DESCRIBE `{actual_game_table}`"))
        columns = result.fetchall()
        
        # Analyze the table structure to identify tiers and questions
        tiers = []
        questions = []
        
        # Look for tier-related columns (usually contain tier names)
        tier_columns = []
        question_columns = []
        
        for column in columns:
            column_name = column[0]
            column_type = column[1]
            
            # Skip the id column
            if column_name == 'id':
                continue
                
            # Check if this might be a tier column
            if any(keyword in column_name.lower() for keyword in ['tier', 'round', 'category', 'section']):
                tier_columns.append(column_name)
            # Check if this might be a question column
            elif any(keyword in column_name.lower() for keyword in ['question', 'q', 'answer']):
                question_columns.append(column_name)
        
        # If we found tier columns, get unique tier values
        if tier_columns:
            for tier_col in tier_columns:
                try:
                    result = db.execute(text(f"SELECT DISTINCT `{tier_col}` FROM `{actual_game_table}` WHERE `{tier_col}` IS NOT NULL AND `{tier_col}` != ''"))
                    tier_values = result.fetchall()
                    
                    for tier_value in tier_values:
                        tier_name = tier_value[0]
                        if tier_name:
                            # Count questions in this tier
                            count_result = db.execute(text(f"SELECT COUNT(*) FROM `{actual_game_table}` WHERE `{tier_col}` = %s"), (tier_name,))
                            question_count = count_result.fetchone()[0]
                            
                            tiers.append({
                                'name': tier_name,
                                'column': tier_col,
                                'question_count': question_count
                            })
                except Exception as e:
                    logger.warning(f"Could not process tier column {tier_col}: {e}")
        
        # If we found question columns, create question entries
        if question_columns:
            try:
                # Get all data to understand question structure
                result = db.execute(text(f"SELECT * FROM `{actual_game_table}`"))
                all_rows = result.fetchall()
                
                # Get column names
                column_names = [desc[0] for desc in result.description]
                
                for i, row in enumerate(all_rows):
                    question_data = {}
                    for j, value in enumerate(row):
                        if j < len(column_names):
                            question_data[column_names[j]] = value
                    
                    # Try to find question text
                    question_text = ""
                    for col in question_columns:
                        if col in question_data and question_data[col]:
                            question_text = str(question_data[col])
                            break
                    
                    questions.append({
                        'id': i + 1,
                        'question': question_text or f"Question {i + 1}",
                        'data': question_data
                    })
                    
            except Exception as e:
                logger.warning(f"Could not process questions: {e}")
        
        # If no specific tiers/questions found, create generic structure
        if not tiers and not questions:
            # Try to get row count to estimate questions
            try:
                result = db.execute(text(f"SELECT COUNT(*) FROM `{actual_game_table}`"))
                row_count = result.fetchone()[0]
                
                # Create generic tier
                tiers.append({
                    'name': 'All Questions',
                    'column': 'id',
                    'question_count': row_count
                })
                
                # Create generic questions for all rows
                for i in range(row_count):
                    questions.append({
                        'id': i + 1,
                        'question': f"Question {i + 1}",
                        'data': {}
                    })
                    
            except Exception as e:
                logger.warning(f"Could not get row count: {e}")
        
        return {
            "success": True,
            "game_info": {
                "id": game.id,
                "name": game.game_name,
                "table_name": actual_game_table
            },
            "tiers": tiers,
            "questions": questions,
            "total_tiers": len(tiers),
            "total_questions": len(questions)
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
            f"active_teams_results_{game_name}"
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

    async def connect(self, websocket: WebSocket, connection_id: str, user_id: int):
        # Check if user already has an active connection
        if user_id in self.user_connections:
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
        
        await manager.connect(websocket, connection_id, user_id)
        logger.info(f"WebSocket connected for user {user_id} with valid session")
        
        # Set user as visible and connected
        user.visible_connected = 1
        db.commit()
        logger.info(f"User {user_id} marked as visible and connected")
        
        while True:
            # Keep connection alive and listen for any incoming messages
            data = await websocket.receive_text()
            logger.info(f"Received message from user {user_id}: {data}")
            
            # Periodically validate session (every 30 seconds)
            # This is a simple implementation - in production, you might want more sophisticated session validation
            
    except WebSocketDisconnect:
        manager.disconnect(connection_id, user_id)
        logger.info(f"WebSocket disconnected for user {user_id}")
        
        # Set user as not visible and disconnected
        user = db.query(User).filter(User.id == user_id).first()
        if user:
            user.visible_connected = 0
            db.commit()
            logger.info(f"User {user_id} marked as not visible and disconnected")
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        # Client disconnected abruptly - this is normal and not an error
        logger.debug(f"WebSocket connection reset for user {user_id}: {type(e).__name__}")
        manager.disconnect(connection_id, user_id)
        
        # Set user as not visible and disconnected
        user = db.query(User).filter(User.id == user_id).first()
        if user:
            user.visible_connected = 0
            db.commit()
            logger.debug(f"User {user_id} marked as not visible and disconnected due to connection reset")
    except Exception as e:
        logger.error(f"WebSocket error for user {user_id}: {e}")
        manager.disconnect(connection_id, user_id)
        
        # Set user as not visible and disconnected on error
        user = db.query(User).filter(User.id == user_id).first()
        if user:
            user.visible_connected = 0
            db.commit()
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
    global last_timer_setting  # Declare global to modify the global variable
    logger.info(f">>>>>>> DATA in BEGGINIG >>>>>>> - rounds_info value: {rounds_info}")
    try:
        timer_start = datetime.utcnow()
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

        # Create broadcast message
        # Convert timer_start to ISO format string for JSON serialization
        timer_start_str = timer_start.isoformat() if isinstance(timer_start, datetime) else str(timer_start)
        broadcast_message = json.dumps({
            "type": "timer_trigger",
            "timer_action": timer_action,
            "slide_number": slide_number,
            "round_name": round_name,
            "timer_start": timer_start_str,
            "question_id": _id,
            "final_timer": _timer,
            "question_timer": question_timer
        })
        # Broadcast to all connected players only if message was created
        if broadcast_message:
            await manager.broadcast_to_all_players(broadcast_message)
            logger.info(f"Timer '{timer_action}' triggered for slide {slide_number} and round: {round_name},"
                        f" broadcasted to {len(manager.active_connections)} connections")
        else:
            logger.warning(f"Timer '{timer_action}' triggered but no broadcast message was sent")

        last_timer_setting = {
            "timer_action": timer_action,
            "slide_number": slide_number,
            "round_name": round_name,
            "timer_start": timer_start_str,
            "question_id": _id,
            "final_timer": _timer,
            "question_timer": question_timer
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
    - Sets default values for slide_id, answer, is_correct, answered_at, player_id
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
                WHERE team_id IS NOT NULL AND question_id IS NOT NULL
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
                        (team_id, question_id, correct_score, wrong_score, slide_id, answer, is_correct, answered_at, player_id)
                        VALUES (:team_id, :question_id, :correct_score, :wrong_score, NULL, NULL, 0, NULL, NULL)
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
        
        # Query the game table for questions matching round_name
        game_table_name = game.game_name
        query_sql = text(f"""
            SELECT id, round_name, reg_score, bonus_score, answers_for_selection, 
                   question_num, question, answer1, answer2, answer3, comments, 
                    type_game, time_to_get_answer 
            FROM `{game_table_name}`
            WHERE round_name = :round_name
            ORDER BY id
        """)
        
        result = db.execute(query_sql, {"round_name": round_name})
        rows = result.fetchall()
        
        # Convert to list of dictionaries
        questions = []
        for row in rows:
            questions.append({
                "id": row[0],
                "round_name": row[1],
                "reg_score": row[2],
                "bonus_score": row[3],
                "answers_for_selection": row[4],
                "question_num": row[5],
                "question": row[6],
                "answer1": row[7],
                "answer2": row[8],
                "answer3": row[9],
                "comments": row[10],
                "type_game": row[11],
                "time_to_get_answer": row[12],
            })
        
        return questions
        
    except Exception as e:
        logger.error(f"Error getting game questions by round: {e}")
        raise HTTPException(status_code=500, detail=f"Error retrieving questions: {str(e)}")

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
        
        # Query answers table
        query_sql = text(f"""
            SELECT id, team_id, question_id, correct_score, wrong_score, 
                   slide_id, answer, is_correct, answered_at, player_id
            FROM `{answers_table_name}`
            WHERE team_id = :team_id
            ORDER BY question_id
        """)
        
        result = db.execute(query_sql, {"team_id": team_id})
        rows = result.fetchall()
        
        # Convert to list of dictionaries
        answers = []
        for row in rows:
            answers.append({
                "id": row[0],
                "team_id": row[1],
                "question_id": row[2],
                "correct_score": row[3],
                "wrong_score": row[4],
                "slide_id": row[5],
                "answer": row[6],
                "is_correct": row[7],
                "answered_at": row[8].isoformat() if row[8] else None,
                "player_id": row[9],
            })
        
        return answers
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting team answers: {e}")
        raise HTTPException(status_code=500, detail=f"Error retrieving team answers: {str(e)}")

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

@app.get("/api/app/version")
async def get_app_version():
    """
    Get the latest app version information.
    Update this version number when you release a new build.
    Format: version (e.g., "1.0.0") and build (e.g., "2")
    """
    return {
        "version": "1.0.0",  # Update this when releasing a new version
        "build": "1"  # Update this build number for each new build
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
