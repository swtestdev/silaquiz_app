#!/usr/bin/env python
"""
HTTPS Server for Flutter Web App
Run this script to serve the app over HTTPS
"""
import http.server
import ssl
import socketserver
import os

# Configuration
PORT = 8080
CERT_FILE = "cert.pem"
KEY_FILE = "key.pem"

class MyHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Add CORS headers
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        super().end_headers()

def main():
    # Change to the directory containing the built Flutter web app
    build_dir = os.path.join(os.path.dirname(__file__), "build", "web")
    
    if not os.path.exists(build_dir):
        print(f"Error: Build directory not found: {build_dir}")
        print("Please run 'flutter build web' first")
        return
    
    os.chdir(build_dir)
    
    # Check if certificate files exist
    if not os.path.exists(CERT_FILE) or not os.path.exists(KEY_FILE):
        print(f"Certificate files not found. Creating self-signed certificate...")
        create_self_signed_cert()
    
    # Create HTTP server
    with socketserver.TCPServer(("", PORT), MyHTTPRequestHandler) as httpd:
        # Wrap socket with SSL
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        
        print(f"HTTPS Server started on https://0.0.0.0:{PORT}")
        print(f"Server is accessible from any device on the network")
        print(f"Certificate warning is expected (self-signed certificate)")
        print(f"\nAccess the app at:")
        print(f"  - http://localhost:{PORT}")
        print(f"  - https://YOUR_PC_IP:{PORT}")
        print(f"\nPress Ctrl+C to stop the server")
        
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer stopped")

def create_self_signed_cert():
    """Create a self-signed SSL certificate"""
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from datetime import datetime, timedelta
    import ipaddress
    
    try:
        # Generate private key
        private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )
        
        # Create certificate
        subject = issuer = x509.Name([
            x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
            x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "CA"),
            x509.NameAttribute(NameOID.LOCALITY_NAME, "San Francisco"),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Quiz App"),
            x509.NameAttribute(NameOID.COMMON_NAME, "localhost"),
        ])
        
        cert = x509.CertificateBuilder().subject_name(subject).issuer_name(issuer).public_key(
            private_key.public_key()
        ).serial_number(x509.random_serial_number()).not_valid_before(
            datetime.utcnow()
        ).not_valid_after(
            datetime.utcnow() + timedelta(days=365)
        ).add_extension(
            x509.SubjectAlternativeName([
                x509.DNSName("localhost"),
                x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
            ]),
            critical=False,
        ).sign(private_key, hashes.SHA256())
        
        # Save certificate and key
        with open(CERT_FILE, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        
        with open(KEY_FILE, "wb") as f:
            f.write(private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption()
            ))
        
        print(f"Self-signed certificate created: {CERT_FILE}, {KEY_FILE}")
        
    except ImportError:
        print("Error: cryptography library not installed")
        print("Install it with: pip install cryptography")
        raise

if __name__ == "__main__":
    main()

