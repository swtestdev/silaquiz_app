#!/usr/bin/env python3
"""
Installation script for FastAPI backend dependencies
"""

import subprocess
import sys
import os

def install_package(package):
    """Install a package using pip"""
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", package])
        print(f"✅ Successfully installed {package}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to install {package}: {e}")
        return False

def main():
    """Install all required dependencies"""
    print("Installing FastAPI Backend Dependencies...")
    print("=" * 50)
    
    # Core dependencies
    packages = [
        "fastapi==0.104.1",
        "uvicorn[standard]==0.24.0",
        "sqlalchemy==2.0.23",
        "pymysql==1.1.0",
        "cryptography==41.0.7",
        "passlib[bcrypt]==1.7.4",
        "bcrypt==4.0.1",
        "python-jose[cryptography]==3.3.0",
        "python-multipart==0.0.6",
        "email-validator==2.1.0",
        "pydantic[email]==2.5.0"
    ]
    
    success_count = 0
    for package in packages:
        if install_package(package):
            success_count += 1
    
    print("=" * 50)
    print(f"Installation complete: {success_count}/{len(packages)} packages installed successfully")
    
    if success_count == len(packages):
        print("🎉 All dependencies installed successfully!")
        print("You can now run: python main.py")
    else:
        print("⚠️  Some packages failed to install. Please check the errors above.")
        print("You may need to install them manually or check your Python environment.")

if __name__ == "__main__":
    main()
