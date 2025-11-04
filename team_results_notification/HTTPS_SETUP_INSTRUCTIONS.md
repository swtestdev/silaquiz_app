# HTTPS Setup Instructions for Flutter Web App

## Overview
This guide explains how to serve your Flutter web app over HTTPS for secure connections.

## Why HTTPS?
- **PWAs require HTTPS** (except for localhost)
- **Secure connections** between phone and backend
- **No mixed content warnings**
- **Better for production** environments

## Quick Start (Recommended)

### Option 1: Use Python with SSL Certificate

**Step 1: Install required Python packages**
```bash
pip install cryptography
```

**Step 2: Build the Flutter web app**
```bash
cd team_results_notification
flutter build web
```

**Step 3: Create self-signed certificate**
```bash
cd build/web
python -c "
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from datetime import datetime, timedelta
import ipaddress

# Generate key
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# Create certificate
subject = issuer = x509.Name([
    x509.NameAttribute(NameOID.COMMON_NAME, 'localhost'),
])

cert = x509.CertificateBuilder().subject_name(subject).issuer_name(issuer)\
    .public_key(private_key.public_key())\
    .serial_number(x509.random_serial_number())\
    .not_valid_before(datetime.utcnow())\
    .not_valid_after(datetime.utcnow() + timedelta(days=365))\
    .sign(private_key, hashes.SHA256())

# Save files
with open('cert.pem', 'wb') as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))

with open('key.pem', 'wb') as f:
    f.write(private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    ))

print('Certificate created successfully!')
"
```

**Step 4: Start HTTPS server**
```bash
python https_server.py
```

Or use the provided script:
```powershell
.\start_https_server.ps1
```

**Step 5: Access the app**
- Open in browser: `https://localhost:8080`
- Accept the security warning (self-signed certificate)
- Access from phone: `https://YOUR_PC_IP:8080`

## Option 2: Use Caddy (Easiest - For Production)

**Step 1: Download Caddy**
Download from: https://caddyserver.com/download

**Step 2: Create Caddyfile**
Create a file named `Caddyfile` in your project root:
```
:8080 {
    root * build/web
    file_server
    encode zstd gzip
}
```

**Step 3: Start Caddy**
```bash
caddy run
```

**Access:** `https://localhost:8080`

## Option 3: Use Nginx (For Production)

**Step 1: Install Nginx**

**Step 2: Create nginx config** (`/etc/nginx/sites-available/flutter-app`):
```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    root /path/to/build/web;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

**Step 3: Enable site**
```bash
sudo ln -s /etc/nginx/sites-available/flutter-app /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

## Backend HTTPS Setup

Your FastAPI backend also needs HTTPS. Update your backend server to use SSL:

**Option A: Use Uvicorn with SSL**
```bash
cd backend_fastapi
uvicorn main:app --host 0.0.0.0 --port 8000 --ssl-keyfile key.pem --ssl-certfile cert.pem
```

**Option B: Use Gunicorn with SSL** (Production)
```bash
gunicorn -w 4 -k uvicorn.workers.UvicornWorker main:app --bind 0.0.0.0:8000 --keyfile key.pem --certfile cert.pem
```

## Firewall Configuration

Make sure ports are open in Windows Firewall:

```powershell
# Allow HTTPS port 8080
netsh advfirewall firewall add rule name="Flutter HTTPS Server" dir=in action=allow protocol=TCP localport=8080

# Allow backend HTTPS port 8000
netsh advfirewall firewall add rule name="FastAPI HTTPS Backend" dir=in action=allow protocol=TCP localport=8000
```

## Troubleshooting

### Certificate warnings
- **Expected behavior** for self-signed certificates
- Click "Advanced" → "Proceed to localhost" in browser
- On phone: Add exception for the site

### Connection refused
- Check firewall rules
- Verify server is running
- Check IP address is correct

### Mixed content warnings
- Ensure both frontend and backend use HTTPS
- Update `_baseUrl` in `login_page.dart` to use `https://`

## Testing HTTPS

Test from phone browser:
```
https://192.168.0.100:8080
```

Should see:
1. Security warning (click "Advanced" → "Proceed")
2. App loads normally
3. No mixed content errors

## Production Notes

For production, use a proper certificate from Let's Encrypt:
- Domain name required
- Automatic certificate renewal
- No browser warnings

Example with Caddy:
```
your-domain.com {
    root * build/web
    file_server
    reverse_proxy localhost:8000
}
```

## Security Considerations

1. **Self-signed certificates** are fine for local/development
2. **Production** should use proper CA-signed certificates
3. **HTTPS everywhere** for production deployments
4. **Regular certificate updates** required

## Next Steps

1. Set up HTTPS server using one of the options above
2. Update backend to use HTTPS
3. Test from phone
4. Configure firewall rules
5. Update app URLs to use HTTPS

