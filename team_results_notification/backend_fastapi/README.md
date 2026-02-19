# FastAPI Backend for Team Results Notification

This is a FastAPI backend server that provides authentication endpoints for the Team Results Notification Flutter app.

## Features

- User registration and login
- JWT token-based authentication
- MySQL database integration
- HTTPS support (configurable)
- CORS enabled for Flutter web
- Password hashing with bcrypt
- SQLAlchemy ORM

## Prerequisites

- Python 3.8+
- MySQL server running
- Database: `game_sila_misly`
- User: `root` with password: `19761982`

## Installation

1. Install Python dependencies:
```bash
pip install -r requirements.txt
```

2. Ensure MySQL is running and create the database:
```sql
CREATE DATABASE IF NOT EXISTS game_sila_misly;
```

## Configuration

Configuration is loaded from environment variables. Copy `.env.example` to `.env` and set:

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | MySQL connection string | `mysql+pymysql://root:19761982@localhost:3306/game_sila_misly` |
| `SECRET_KEY` | JWT signing key | (dev default - **must** set in production) |
| `CORS_ORIGINS` | Comma-separated allowed origins, or `*` for allow-all | `*` |

For production:
- Set `SECRET_KEY` to a strong random value
- Set `CORS_ORIGINS` to your PWA domain(s)
- Use SSL certificates for HTTPS

## Running the Server

### Development (HTTP)
```bash
python main.py
```

### Production (HTTPS)
```bash
# Generate SSL certificates first
uvicorn main:app --host 0.0.0.0 --port 8000 --ssl-keyfile=key.pem --ssl-certfile=cert.pem
```

## API Endpoints

### Authentication
- `POST /api/auth/register` - Register new user
- `POST /api/auth/login` - Login user
- `GET /api/users/me` - Get current user (requires authentication)

### Admin
- `POST /api/admin/init-db` - Initialize database with sample users

### Health
- `GET /api/health` - Health check
- `GET /` - API info

## Sample Users (after init-db)

- **Admin**: admin@example.com / admin123
- **User**: user@example.com / user123  
- **Test**: test@game.com / test123

## Database Schema

```sql
CREATE TABLE users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    role VARCHAR(50) DEFAULT 'user',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## Flutter Integration

The Flutter app is configured to use:
- Base URL: `https://localhost:8000/api`
- Endpoints match the FastAPI routes
- JWT tokens for authenticated requests

## Security Notes

- Change the SECRET_KEY in production
- Use proper SSL certificates for HTTPS
- Configure CORS origins properly
- Implement rate limiting
- Add input validation and sanitization
- Use environment variables for sensitive data

## Troubleshooting

1. **Database Connection Error**: Ensure MySQL is running and credentials are correct
2. **CORS Issues**: Check the `allow_origins` configuration
3. **SSL Certificate Issues**: For development, you can run without HTTPS
4. **Import Errors**: Ensure all dependencies are installed with `pip install -r requirements.txt`
