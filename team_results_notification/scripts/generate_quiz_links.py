#!/usr/bin/env python3
"""Generate Quze player access document with links and QR codes."""

from __future__ import annotations

import argparse
import socket
import sys
from datetime import datetime
from pathlib import Path


def detect_lan_ip() -> str | None:
    """Best-effort LAN IP for the machine running the quiz host."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass

    try:
        hostname = socket.gethostname()
        ip = socket.gethostbyname(hostname)
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass

    return None


def make_qr_png(data: str, path: Path) -> None:
    import qrcode

    qr = qrcode.QRCode(version=1, box_size=8, border=2)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    img.save(path)


def build_docx(ip: str, port: int, player_url: str, debug_url: str, out_dir: Path) -> Path:
    from docx import Document
    from docx.shared import Inches

    qr_player = out_dir / "qr_player.png"
    qr_debug = out_dir / "qr_debug.png"
    make_qr_png(player_url, qr_player)
    make_qr_png(debug_url, qr_debug)

    doc = Document()
    doc.add_heading("Quze — Player Access Links", 0)
    doc.add_paragraph(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    doc.add_paragraph(f"Host IP: {ip}")
    doc.add_paragraph(f"PWA port: {port}")

    doc.add_heading("Players (regular)", level=1)
    doc.add_paragraph(player_url)
    doc.add_picture(str(qr_player), width=Inches(2.5))

    doc.add_heading("Tech validation (debug console)", level=1)
    doc.add_paragraph(debug_url)
    doc.add_picture(str(qr_debug), width=Inches(2.5))

    doc.add_paragraph("")
    doc.add_paragraph(
        "Share the regular link with teams. Use the debug link on tablets/phones "
        "during setup to inspect timer and WebSocket logs."
    )

    out_file = out_dir / f"quze_links_{ip.replace('.', '_')}.docx"
    doc.save(out_file)
    return out_file


def build_pdf(ip: str, port: int, player_url: str, debug_url: str, out_dir: Path) -> Path:
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.lib.units import inch
    from reportlab.platypus import Image, Paragraph, SimpleDocTemplate, Spacer

    qr_player = out_dir / "qr_player.png"
    qr_debug = out_dir / "qr_debug.png"
    if not qr_player.exists():
        make_qr_png(player_url, qr_player)
    if not qr_debug.exists():
        make_qr_png(debug_url, qr_debug)

    out_file = out_dir / f"quze_links_{ip.replace('.', '_')}.pdf"
    doc = SimpleDocTemplate(str(out_file), pagesize=letter)
    styles = getSampleStyleSheet()
    story = [
        Paragraph("Quze — Player Access Links", styles["Title"]),
        Spacer(1, 0.2 * inch),
        Paragraph(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}", styles["Normal"]),
        Paragraph(f"Host IP: {ip} &nbsp;|&nbsp; PWA port: {port}", styles["Normal"]),
        Spacer(1, 0.3 * inch),
        Paragraph("Players (regular)", styles["Heading2"]),
        Paragraph(f'<link href="{player_url}">{player_url}</link>', styles["Normal"]),
        Spacer(1, 0.1 * inch),
        Image(str(qr_player), width=2.5 * inch, height=2.5 * inch),
        Spacer(1, 0.3 * inch),
        Paragraph("Tech validation (debug console)", styles["Heading2"]),
        Paragraph(f'<link href="{debug_url}">{debug_url}</link>', styles["Normal"]),
        Spacer(1, 0.1 * inch),
        Image(str(qr_debug), width=2.5 * inch, height=2.5 * inch),
    ]
    doc.build(story)
    return out_file


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Quze player link sheet with QR codes.")
    parser.add_argument("ip", nargs="?", help="LAN IP address (auto-detected if omitted)")
    parser.add_argument("--port", type=int, default=8080, help="PWA port (default: 8080)")
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Output directory (default: team_results_notification/share)",
    )
    parser.add_argument("--pdf", action="store_true", help="Also create a PDF copy")
    args = parser.parse_args()

    ip = (args.ip or detect_lan_ip() or "").strip()
    if not ip:
        print("Could not detect LAN IP. Pass it as an argument, e.g.:")
        print("  python scripts/generate_quiz_links.py 192.168.2.1")
        return 1

    root = Path(__file__).resolve().parent.parent
    out_dir = Path(args.out_dir) if args.out_dir else root / "share"
    out_dir.mkdir(parents=True, exist_ok=True)

    player_url = f"http://{ip}:{args.port}/#/login"
    debug_url = f"http://{ip}:{args.port}/?debug=true#/login"

    try:
        docx_path = build_docx(ip, args.port, player_url, debug_url, out_dir)
        print(f"Created DOCX: {docx_path}")
        if args.pdf:
            pdf_path = build_pdf(ip, args.port, player_url, debug_url, out_dir)
            print(f"Created PDF:  {pdf_path}")
        print()
        print(f"  Player:  {player_url}")
        print(f"  Debug:   {debug_url}")
        print(f"  QR PNGs: {out_dir / 'qr_player.png'}, {out_dir / 'qr_debug.png'}")
        return 0
    except ImportError:
        print("Missing dependencies. Run:")
        print("  python -m pip install qrcode[pil] python-docx pillow reportlab")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
