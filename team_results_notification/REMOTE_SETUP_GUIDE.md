# Remote Server Setup Guide

## Overview
This guide explains how to configure the timer trigger system to work with remote servers and mobile devices.

## Server Configuration

### 1. Backend Server Setup

#### For Local Development:
```python
# In backend_fastapi/main.py
uvicorn.run(
    "main:app",
    host="0.0.0.0",  # Important: Use 0.0.0.0, not 127.0.0.1
    port=8000,
    reload=True,
    log_level="info"
)
```

#### For Production:
```python
# In backend_fastapi/main.py
uvicorn.run(
    "main:app",
    host="0.0.0.0",  # Listen on all interfaces
    port=8000,
    reload=False,
    log_level="info"
)
```

### 2. Network Configuration

#### Find Your Server IP Address:

**Windows:**
```cmd
ipconfig
```
Look for "IPv4 Address" under your network adapter.

**Linux/Mac:**
```bash
ifconfig
# or
ip addr show
```

**Common IP Addresses:**
- `localhost` or `127.0.0.1` - Same machine only
- `192.168.x.x` - Local network (WiFi/Ethernet)
- `10.x.x.x` - Local network
- `172.16.x.x` - Local network

## Flutter App Configuration

### 1. Update Server URL in login_page.dart

```dart
// In lib/pages/login_page.dart
class DatabaseService {
  // Change this to your server's IP address
  static String _baseUrl = 'http://YOUR_SERVER_IP:8000/api';
  
  // Examples:
  // static String _baseUrl = 'http://192.168.1.100:8000/api';
  // static String _baseUrl = 'http://DESKTOP-638BFEB:8000/api';
  // static String _baseUrl = 'http://10.0.0.50:8000/api';
}
```

### 2. Dynamic Server Configuration

The app supports dynamic server configuration through the settings dialog:

1. Open the app
2. Go to Settings (if available)
3. Enter your server's IP address
4. The WebSocket connection will automatically use the new URL

## Testing Tools Configuration

### 1. HTML Test Page

Edit `timer_test.html`:
```javascript
// Change this to your server's IP address
const SERVER_IP = 'YOUR_SERVER_IP'; // e.g., '192.168.1.100'
const API_URL = `http://${SERVER_IP}:8000/api/timer/trigger`;
```

### 2. Python Test Script

Edit `test_timer_trigger.py`:
```python
# Change this to your server's IP address
SERVER_IP = "YOUR_SERVER_IP"  # e.g., "192.168.1.100"
API_BASE_URL = f"http://{SERVER_IP}:8000"
```

### 3. VBA Macros

Edit `VBA_Timer_Examples.vba`:
```vba
' Change this to your server's IP address
Const SERVER_IP As String = "YOUR_SERVER_IP"  ' e.g., "192.168.1.100"
```

## Network Troubleshooting

### 1. Check Server Accessibility

**From Command Line:**
```bash
# Test HTTP connection
curl http://YOUR_SERVER_IP:8000/api/health

# Test WebSocket connection (if you have wscat installed)
wscat -c ws://YOUR_SERVER_IP:8000/ws/timer/1
```

**From Browser:**
```
http://YOUR_SERVER_IP:8000/api/health
```

### 2. Firewall Configuration

**Windows Firewall:**
1. Open Windows Defender Firewall
2. Click "Allow an app or feature through Windows Defender Firewall"
3. Add Python or your terminal application
4. Ensure port 8000 is open

**Router Configuration:**
- If testing from different networks, configure port forwarding
- Forward external port to internal port 8000

### 3. Mobile Device Testing

**Android:**
- Ensure device is on same network as server
- Use server's local IP address (e.g., `192.168.1.100`)

**iOS:**
- Same as Android
- May need to allow HTTP connections in Info.plist

## Common Issues and Solutions

### Issue: "Connection refused"
**Solution:** 
- Check if server is running
- Verify IP address is correct
- Check firewall settings

### Issue: "WebSocket connection failed"
**Solution:**
- Ensure WebSocket URL is correct
- Check if server supports WebSockets
- Verify network connectivity

### Issue: "Timer not updating on mobile"
**Solution:**
- Check if mobile device can reach server
- Verify WebSocket connection is established
- Check server logs for errors

## Security Considerations

### For Development:
- Use local network IPs only
- No authentication required (for testing)

### For Production:
- Implement authentication
- Use HTTPS/WSS
- Configure proper firewall rules
- Consider rate limiting

## Example Configurations

### Local Development (Same Machine):
```dart
static String _baseUrl = 'http://localhost:8000/api';
```

### Local Network (WiFi):
```dart
static String _baseUrl = 'http://192.168.1.100:8000/api';
```

### Remote Server:
```dart
static String _baseUrl = 'http://your-server.com:8000/api';
```

### Docker/Container:
```dart
static String _baseUrl = 'http://container-ip:8000/api';
```

## Testing Checklist

- [ ] Server is running and accessible
- [ ] Flutter app connects to correct server
- [ ] WebSocket connection established
- [ ] Timer triggers work from browser
- [ ] Timer triggers work from VBA
- [ ] Mobile device can connect
- [ ] Timer updates appear in real-time

## Quick Test Commands

**Test HTTP API:**
```bash
curl -X POST http://YOUR_SERVER_IP:8000/api/timer/trigger \
  -H "Content-Type: application/json" \
  -d '{"trigger_data": ">>>>>>>START_TIMER>>>>>>>Slide#58##"}'
```

**Test WebSocket (if wscat available):**
```bash
wscat -c ws://YOUR_SERVER_IP:8000/ws/timer/1
```

**Test from Browser:**
Open `timer_test.html` and change `SERVER_IP` to your server's IP address.
