# Timer Trigger API Documentation

## Overview
The Timer Trigger API allows external systems to send timer commands that will be broadcast to all connected players in real-time via WebSocket connections.

## API Endpoint
```
POST /api/timer/trigger
```

## Request Format
```json
{
  "trigger_data": ">>>>>>>START_TIMER>>>>>>>Slide#58##"
}
```

## Supported Timer Commands

### 1. Start Timer
```
>>>>>>>START_TIMER>>>>>>>Slide#58##
```
- **Action**: Starts the game timer
- **Slide Number**: Extracted from the text (e.g., 58)
- **Effect**: All connected players will see the timer start running

### 2. Stop Timer
```
>>>>>>>STOP_TIMER>>>>>>>
```
- **Action**: Stops the game timer
- **Effect**: All connected players will see the timer stop

### 3. Pause Timer
```
>>>>>>>PAUSE_TIMER>>>>>>>
```
- **Action**: Pauses the game timer
- **Effect**: All connected players will see the timer pause

### 4. Resume Timer
```
>>>>>>>RESUME_TIMER>>>>>>>
```
- **Action**: Resumes the game timer
- **Effect**: All connected players will see the timer resume

## Response Format
```json
{
  "success": true,
  "message": "Timer start triggered successfully",
  "slide_number": 58,
  "timer_action": "start"
}
```

## WebSocket Connection
Players connect to the WebSocket endpoint:
```
ws://localhost:8000/ws/timer/{user_id}
```

### WebSocket Message Format
When a timer trigger is received, all connected players receive:
```json
{
  "type": "timer_trigger",
  "action": "start",
  "slide_number": 58,
  "timestamp": "2024-01-15T10:30:00.000Z",
  "trigger_data": ">>>>>>>START_TIMER>>>>>>>Slide#58##"
}
```

## Usage Examples

### Using curl
```bash
curl -X POST http://localhost:8000/api/timer/trigger \
  -H "Content-Type: application/json" \
  -d '{"trigger_data": ">>>>>>>START_TIMER>>>>>>>Slide#58##"}'
```

### Using Python
```python
import requests

response = requests.post(
    "http://localhost:8000/api/timer/trigger",
    json={"trigger_data": ">>>>>>>START_TIMER>>>>>>>Slide#58##"}
)
print(response.json())
```

### Using JavaScript
```javascript
fetch('http://localhost:8000/api/timer/trigger', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/json',
    },
    body: JSON.stringify({
        trigger_data: ">>>>>>>START_TIMER>>>>>>>Slide#58##"
    })
})
.then(response => response.json())
.then(data => console.log(data));
```

## Testing
Use the provided test script:
```bash
python test_timer_trigger.py
```

## Frontend Integration
The Flutter app automatically:
1. Connects to WebSocket when a player logs in
2. Receives timer updates in real-time
3. Updates the Game Time bar with:
   - Current timer status (running/paused)
   - Slide number (if provided)
   - Progress bar
   - Current time vs total time

## Error Handling
- Invalid trigger format returns error response
- WebSocket connection errors are logged
- Timer state is maintained across reconnections
- Graceful handling of network interruptions

## Security Notes
- WebSocket connections are user-specific
- Timer triggers are broadcast to all connected players
- No authentication required for timer triggers (consider adding if needed)
- Consider rate limiting for production use
