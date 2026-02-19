#!/usr/bin/env python
"""
Serve Flutter web build with NO-CACHE headers.
Use this during development to force browsers to always fetch the latest version.
Run from: team_results_notification/
Or: cd team_results_notification && python serve_no_cache.py
"""
import http.server
import os
import socketserver

PORT = 8080

class NoCacheHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()

def main():
    build_dir = os.path.join(os.path.dirname(__file__), "build", "web")
    if not os.path.exists(build_dir):
        print(f"Error: Build directory not found: {build_dir}")
        print("Run 'flutter build web --release' first")
        return
    os.chdir(build_dir)

    with socketserver.TCPServer(("", PORT), NoCacheHTTPRequestHandler) as httpd:
        print(f"Serving with NO-CACHE headers on http://0.0.0.0:{PORT}")
        print("Browsers will always fetch the latest build (but service worker may still cache)")
        print("Use 'Force reload app' in Database Info dialog to clear service worker cache")
        print("\nAccess at: http://YOUR_PC_IP:8080/   or   http://DESKTOP-638BFEB:8080/")
        print("Press Ctrl+C to stop")
        httpd.serve_forever()

if __name__ == "__main__":
    main()
