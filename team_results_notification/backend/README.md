# Quiz PWA Backend API

This is the backend API server for the Quiz PWA application that handles MySQL database operations for user authentication.

## Prerequisites

- Node.js (v14 or higher)
- MySQL Server
- MySQL database named `game_sila_misly`

## Setup Instructions

1. **Install Node.js dependencies:**
   ```bash
   cd backend
   npm install
   ```

2. **Configure MySQL Database:**
   - Make sure MySQL server is running
   - Create a database named `game_sila_misly`
   - Update the database configuration in `server.js` if needed:
     ```javascript
     const dbConfig = {
       host: 'localhost',
       port: 3306,
       user: 'root',
       password: '19761982', // Your MySQL password
       database: 'game_sila_misly',
       // ... other config
     };
     ```

3. **Start the server:**
   ```bash
   npm start
   ```
   
   Or for development with auto-restart:
   ```bash
   npm run dev
   ```

4. **Test the API:**
   - Health check: `GET http://localhost:3000/api/health`
   - Login: `POST http://localhost:3000/api/auth/login`
   - Register: `POST http://localhost:3000/api/auth/register`

## API Endpoints

### Authentication

- **POST /api/auth/login**
  - Body: `{ "email": "user@example.com", "password": "password123" }`
  - Returns: User data if successful

- **POST /api/auth/register**
  - Body: `{ "email": "user@example.com", "password": "password123", "name": "User Name" }`
  - Returns: Success message

### Admin

- **POST /api/admin/init-db**
  - Initializes the database and creates sample users
  - Returns: Success message

## Database Schema

The server automatically creates a `users` table with the following structure:

```sql
CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) UNIQUE NOT NULL,
  password VARCHAR(255) NOT NULL,
  name VARCHAR(255) NOT NULL,
  role VARCHAR(50) DEFAULT 'user',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## Sample Users

The server creates these sample users on initialization:

- **Admin User**
  - Email: admin@example.com
  - Password: admin123
  - Role: admin

- **Regular User**
  - Email: user@example.com
  - Password: user123
  - Role: user

- **Game Tester**
  - Email: test@game.com
  - Password: test123
  - Role: user

## Security Features

- Passwords are hashed using bcrypt
- CORS enabled for web app integration
- Input validation and error handling
- SQL injection protection with parameterized queries

## Flutter App Integration

Update the `_baseUrl` in your Flutter app's `DatabaseService` class:

```dart
static const String _baseUrl = 'http://localhost:3000/api';
```

Then change the login method to use the real API:

```dart
final result = await DatabaseService.checkCredentials(
  _emailController.text.trim(),
  _passwordController.text,
);
```
