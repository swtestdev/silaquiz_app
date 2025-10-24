#!/usr/bin/env python3
"""
Startup script for the FastAPI backend server
"""

import uvicorn
import os
import sys

def main():
    """Start the FastAPI server"""
    
    # Check if we're in the right directory
    if not os.path.exists("main.py"):
        print("Error: main.py not found. Please run this script from the backend_fastapi directory.")
        sys.exit(1)
    
    print("Starting FastAPI server...")
    print("Server will be available at: http://localhost:8000")
    print("API documentation at: http://localhost:8000/docs")
    print("Press Ctrl+C to stop the server")
    
    try:
        uvicorn.run(
            "main:app",
            host="0.0.0.0",
            port=8000,
            reload=True,
            log_level="info"
        )
    except KeyboardInterrupt:
        print("\nServer stopped by user")
    except Exception as e:
        print(f"Error starting server: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
