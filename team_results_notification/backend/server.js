const express = require('express');
const mysql = require('mysql2/promise');
const cors = require('cors');
const bcrypt = require('bcrypt');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());

// MySQL Database Configuration
const dbConfig = {
  host: 'localhost',
  port: 3306,
  user: 'root',
  password: '19761982',
  database: 'game_sila_misly',
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0
};

// Create MySQL connection pool
const pool = mysql.createPool(dbConfig);

// Initialize database and create tables
async function initializeDatabase() {
  try {
    const connection = await pool.getConnection();
    
    // Create users table
    await connection.execute(`
      CREATE TABLE IF NOT EXISTS users (
        id INT AUTO_INCREMENT PRIMARY KEY,
        email VARCHAR(255) UNIQUE NOT NULL,
        password VARCHAR(255) NOT NULL,
        name VARCHAR(255) NOT NULL,
        role VARCHAR(50) DEFAULT 'user',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
    
    // Insert sample users (with hashed passwords)
    const hashedPassword = await bcrypt.hash('admin123', 10);
    await connection.execute(`
      INSERT IGNORE INTO users (email, password, name, role) 
      VALUES (?, ?, ?, ?)
    `, ['admin@example.com', hashedPassword, 'Admin User', 'admin']);
    
    const hashedPassword2 = await bcrypt.hash('user123', 10);
    await connection.execute(`
      INSERT IGNORE INTO users (email, password, name, role) 
      VALUES (?, ?, ?, ?)
    `, ['user@example.com', hashedPassword2, 'Regular User', 'user']);
    
    const hashedPassword3 = await bcrypt.hash('test123', 10);
    await connection.execute(`
      INSERT IGNORE INTO users (email, password, name, role) 
      VALUES (?, ?, ?, ?)
    `, ['test@game.com', hashedPassword3, 'Game Tester', 'user']);
    
    connection.release();
    console.log('Database initialized successfully');
  } catch (error) {
    console.error('Database initialization failed:', error);
  }
}

// Routes

// Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'OK', message: 'Server is running' });
});

// Login endpoint
app.post('/api/auth/login', async (req, res) => {
  try {
    const { email, password } = req.body;
    
    if (!email || !password) {
      return res.status(400).json({ 
        success: false, 
        message: 'Email and password are required' 
      });
    }
    
    const connection = await pool.getConnection();
    const [rows] = await connection.execute(
      'SELECT id, email, password, name, role FROM users WHERE email = ?',
      [email]
    );
    
    connection.release();
    
    if (rows.length === 0) {
      return res.status(401).json({ 
        success: false, 
        message: 'Invalid email or password' 
      });
    }
    
    const user = rows[0];
    const isValidPassword = await bcrypt.compare(password, user.password);
    
    if (!isValidPassword) {
      return res.status(401).json({ 
        success: false, 
        message: 'Invalid email or password' 
      });
    }
    
    // Remove password from response
    const { password: _, ...userWithoutPassword } = user;
    
    res.json({
      success: true,
      user: userWithoutPassword
    });
    
  } catch (error) {
    console.error('Login error:', error);
    res.status(500).json({ 
      success: false, 
      message: 'Internal server error' 
    });
  }
});

// Register endpoint
app.post('/api/auth/register', async (req, res) => {
  try {
    const { email, password, name } = req.body;
    
    if (!email || !password || !name) {
      return res.status(400).json({ 
        success: false, 
        message: 'Email, password, and name are required' 
      });
    }
    
    const hashedPassword = await bcrypt.hash(password, 10);
    const connection = await pool.getConnection();
    
    await connection.execute(
      'INSERT INTO users (email, password, name) VALUES (?, ?, ?)',
      [email, hashedPassword, name]
    );
    
    connection.release();
    
    res.json({
      success: true,
      message: 'User registered successfully'
    });
    
  } catch (error) {
    console.error('Registration error:', error);
    if (error.code === 'ER_DUP_ENTRY') {
      res.status(409).json({ 
        success: false, 
        message: 'Email already exists' 
      });
    } else {
      res.status(500).json({ 
        success: false, 
        message: 'Internal server error' 
      });
    }
  }
});

// Initialize database endpoint
app.post('/api/admin/init-db', async (req, res) => {
  try {
    await initializeDatabase();
    res.json({ 
      success: true, 
      message: 'Database initialized successfully' 
    });
  } catch (error) {
    console.error('Database initialization error:', error);
    res.status(500).json({ 
      success: false, 
      message: 'Database initialization failed' 
    });
  }
});

// Start server
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`API available at http://localhost:${PORT}/api`);
  
  // Initialize database on startup
  initializeDatabase();
});

module.exports = app;
