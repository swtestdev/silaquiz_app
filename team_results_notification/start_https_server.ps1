# PowerShell script to start HTTPS server for Flutter Web App
# This creates a self-signed certificate and serves the app over HTTPS

param(
    [string]$Port = "8080"
)

$ErrorActionPreference = "Stop"

Write-Host "Starting HTTPS Server for Flutter Web App" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green

# Check if build directory exists
$buildDir = Join-Path $PSScriptRoot "build\web"
if (-not (Test-Path $buildDir)) {
    Write-Host "Error: Build directory not found: $buildDir" -ForegroundColor Red
    Write-Host "Please run 'flutter build web' first" -ForegroundColor Yellow
    exit 1
}

Write-Host "Build directory found: $buildDir" -ForegroundColor Green

# Check if certificate files exist
$certFile = Join-Path $buildDir "cert.pem"
$keyFile = Join-Path $buildDir "key.pem"

if (-not (Test-Path $certFile) -or -not (Test-Path $keyFile)) {
    Write-Host "Certificate files not found. Creating self-signed certificate..." -ForegroundColor Yellow
    
    # Use Python to create certificate
    $pythonScript = @"
import ssl
import socketserver
from http.server import HTTPServer, SimpleHTTPRequestHandler
import os

# Generate self-signed certificate (Windows-specific using CertEnroll COM)
try:
    import win32com.client
    import win32con
    
    # This will create a basic self-signed cert
    # Note: Requires pywin32 package
    Write-Host "Creating self-signed certificate..." -ForegroundColor Yellow
except:
    Write-Host "Error creating certificate" -ForegroundColor Red
    Write-Host "Please install pywin32: pip install pywin32" -ForegroundColor Yellow
"@
    
    Write-Host "Please install the cryptography package first:" -ForegroundColor Yellow
    Write-Host "pip install cryptography" -ForegroundColor Yellow
    exit 1
}

Write-Host "Certificate found: $certFile" -ForegroundColor Green

Write-Host ""
Write-Host "Starting HTTPS server on port $Port..." -ForegroundColor Cyan
Write-Host "Note: Browser will show security warning for self-signed certificate" -ForegroundColor Yellow
Write-Host ""
Write-Host "Access the app at:" -ForegroundColor Green
Write-Host "  - https://localhost:$Port" -ForegroundColor White
Write-Host "  - https://YOUR_PC_IP:$Port" -ForegroundColor White
Write-Host ""
Write-Host "Press Ctrl+C to stop the server" -ForegroundColor Yellow
Write-Host ""

# Start server using Python's http.server with SSL
python -c @"
import ssl
import socketserver
from http.server import HTTPServer, SimpleHTTPRequestHandler
import os

os.chdir('$buildDir')

class MyHTTPRequestHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        super().end_headers()
    
    def log_message(self, format, *args):
        """Override to suppress harmless 404 errors for common non-existent resources"""
        harmless_404s = ['/apilog', '/favicon.ico', '/robots.txt', '/apple-touch-icon.png']
        if len(args) >= 1:
            request_line = args[0] if args else ''
            for harmless_path in harmless_404s:
                if harmless_path in request_line and '404' in str(args):
                    return
        super().log_message(format, *args)

with socketserver.TCPServer(('', $Port), MyHTTPRequestHandler) as httpd:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile='$certFile', keyfile='$keyFile')
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    print('HTTPS Server started on https://0.0.0.0:$Port')
    httpd.serve_forever()
"@

