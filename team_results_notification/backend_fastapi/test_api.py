#!/usr/bin/env python3
"""
Test script for the FastAPI backend
"""

import requests
import json

def test_api():
    """Test the FastAPI endpoints"""
    base_url = "http://localhost:8000"
    
    print("Testing FastAPI Backend...")
    print("=" * 50)
    
    # Test 1: Health check
    try:
        response = requests.get(f"{base_url}/api/health")
        print(f"Health Check: {response.status_code} - {response.json()}")
    except Exception as e:
        print(f"Health Check Failed: {e}")
        return
    
    # Test 2: Root endpoint
    try:
        response = requests.get(f"{base_url}/")
        print(f"Root Endpoint: {response.status_code} - {response.json()}")
    except Exception as e:
        print(f"Root Endpoint Failed: {e}")
    
    # Test 3: Initialize database
    try:
        response = requests.post(f"{base_url}/api/admin/init-db")
        print(f"Init DB: {response.status_code} - {response.json()}")
    except Exception as e:
        print(f"Init DB Failed: {e}")
    
    # Test 4: Register a new user
    try:
        user_data = {
            "email": "test@example.com",
            "password": "test123",
            "name": "Test User"
        }
        response = requests.post(
            f"{base_url}/api/auth/register",
            headers={"Content-Type": "application/json"},
            data=json.dumps(user_data)
        )
        print(f"Register User: {response.status_code} - {response.json()}")
    except Exception as e:
        print(f"Register User Failed: {e}")
    
    # Test 5: Login with existing user
    try:
        login_data = {
            "email": "admin@example.com",
            "password": "admin123"
        }
        response = requests.post(
            f"{base_url}/api/auth/login",
            headers={"Content-Type": "application/json"},
            data=json.dumps(login_data)
        )
        print(f"Login: {response.status_code} - {response.json()}")
    except Exception as e:
        print(f"Login Failed: {e}")
    
    print("=" * 50)
    print("Test completed!")

if __name__ == "__main__":
    test_api()
