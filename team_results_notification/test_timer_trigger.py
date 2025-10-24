#!/usr/bin/env python3
"""
Test script for the Timer Trigger API
This script demonstrates how to send timer trigger data to the backend API
"""

import requests
import json
import time

# API endpoint - Change this to your server's IP address when testing remotely
SERVER_IP = "localhost"  # Change to your server IP (e.g., "192.168.1.100", "DESKTOP-638BFEB")
API_BASE_URL = f"http://{SERVER_IP}:8000"
TIMER_TRIGGER_ENDPOINT = f"{API_BASE_URL}/api/timer/trigger"

def send_timer_trigger(trigger_data):
    """Send timer trigger data to the API"""
    try:
        payload = {
            "trigger_data": trigger_data
        }
        
        response = requests.post(
            TIMER_TRIGGER_ENDPOINT,
            json=payload,
            headers={"Content-Type": "application/json"}
        )
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ Success: {result['message']}")
            if result.get('slide_number'):
                print(f"   Slide Number: {result['slide_number']}")
            if result.get('timer_action'):
                print(f"   Timer Action: {result['timer_action']}")
        else:
            print(f"❌ Error: {response.status_code} - {response.text}")
            
    except Exception as e:
        print(f"❌ Exception: {e}")

def main():
    """Main function to test different timer triggers"""
    print("🎮 Timer Trigger API Test")
    print("=" * 50)
    
    # Test cases
    test_cases = [
        ">>>>>>>START_TIMER>>>>>>>Slide#58##",
        ">>>>>>>START_TIMER>>>>>>>Slide#1##",
        ">>>>>>>STOP_TIMER>>>>>>>",
        ">>>>>>>PAUSE_TIMER>>>>>>>",
        ">>>>>>>RESUME_TIMER>>>>>>>",
        ">>>>>>>START_TIMER>>>>>>>Slide#25##",
    ]
    
    for i, trigger_data in enumerate(test_cases, 1):
        print(f"\n📤 Test {i}: Sending trigger data")
        print(f"   Data: {trigger_data}")
        send_timer_trigger(trigger_data)
        
        if i < len(test_cases):
            print("   ⏳ Waiting 3 seconds before next test...")
            time.sleep(3)
    
    print(f"\n🎉 All tests completed!")
    print(f"💡 Make sure your Flutter app is running and connected to see the timer updates!")

if __name__ == "__main__":
    main()
