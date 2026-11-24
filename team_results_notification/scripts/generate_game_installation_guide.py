#!/usr/bin/env python3
"""Build Quze Game Installation guide (DOCX + PDF) for new game owners."""

from __future__ import annotations

import argparse
import socket
from datetime import datetime
from pathlib import Path


def detect_lan_ip() -> str:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    return "192.168.0.100"


def guide_sections(lan_ip: str) -> list[tuple[str, int, str]]:
    """(title, level, body) — level 0 = title, 1 = h1, 2 = h2, -1 = paragraph."""
    player_url = f"http://{lan_ip}:8080/"
    cors_example = f"http://{lan_ip}:8080"
    return [
        ("Quze — Game Installation Guide", 0, ""),
        ("", -1, f"Document version: CM_Quiz package. Generated {datetime.now():%Y-%m-%d %H:%M}."),
        ("", -1, "Audience: game owner / technical host on Windows. Players use phones on the same Wi‑Fi."),
        ("1. What you are installing", 1, ""),
        (
            "",
            -1,
            "Quze runs on one Windows PC (game server). It serves the web app on port 8080 "
            "and the API on port 8000. MySQL stores game data locally. No public internet "
            "is required during the game if you built the web folder for offline use (local CanvasKit).",
        ),
        ("2. Package folder layout", 1, ""),
        (
            "",
            -1,
            "Copy the full CM_Quiz / WebAppServer folder to the host PC (e.g. C:\\WebAppServer or D:\\CM_Quiz). "
            "Required items: server_runner.exe, serve_no_cache.exe, web\\ (Flutter build), and scripts from the installer.",
        ),
        ("3. Install MySQL (one time per PC)", 1, ""),
        (
            "",
            -1,
            "Download MySQL Installer: https://dev.mysql.com/downloads/installer/\n"
            "Install MySQL Server 8.x. Set root password to match your .env (default in package: 19761982).\n"
            "Optional: place the Server .msi in mysql\\installer\\ before running Install-CMQuiz.ps1.",
        ),
        (
            "",
            -1,
            "If root has no password yet (first login in MySQL Shell):\n"
            "ALTER USER 'root'@'localhost' IDENTIFIED BY '19761982';\n"
            "FLUSH PRIVILEGES;",
        ),
        ("4. Build the web app (on a PC with Flutter)", 1, ""),
        (
            "",
            -1,
            "From team_results_notification run:\n"
            "flutter build web --release --no-web-resources-cdn\n"
            "Copy the entire build\\web\\ folder into the game package web\\ folder. "
            "Verify web\\canvaskit\\canvaskit.js exists (offline LAN).",
        ),
        ("5. One-time setup on the game PC", 1, ""),
        (
            "",
            -1,
            "1. Open PowerShell as Administrator.\n"
            "2. cd to the package folder (e.g. C:\\WebAppServer).\n"
            "3. Set-ExecutionPolicy -Scope Process Bypass -Force\n"
            "4. .\\Install-CMQuiz.ps1\n"
            "\n"
            "The installer checks MySQL, creates database game_sila_misly, writes .env "
            "(SECRET_KEY, CORS_ORIGINS), and can add firewall rules.",
        ),
        ("6. Firewall and Wi‑Fi profile", 1, ""),
        (
            "",
            -1,
            "Windows firewall rules in the package apply to the Private network profile. "
            "If your Wi‑Fi is Public, either set the network to Private in Windows Settings "
            "or extend the CM_Quiz rules to include Public (TCP 8000 and 8080 inbound).\n"
            "Configure-Firewall.ps1 must be run as Administrator.",
        ),
        ("7. Start and stop (each game night)", 1, ""),
        (
            "",
            -1,
            "Start: double-click Start-QuzeGame.bat (two console windows — keep them open).\n"
            "Stop: Stop-QuzeGame.ps1 or close both windows.\n"
            f"Player and admin URL: {player_url}\n"
            "Open this URL on the host PC too — do not use localhost:8080 for admin if CORS is set to the LAN IP.",
        ),
        ("8. Verify before players arrive", 1, ""),
        (
            "",
            -1,
            f"• Browser on PC: {player_url} loads login.\n"
            f"• {player_url}canvaskit/canvaskit.js returns file content (not 404).\n"
            f"• http://{lan_ip}:8000/docs opens API documentation.\n"
            "• Phone on same Wi‑Fi opens the same :8080 URL.\n"
            f"• .env contains CORS_ORIGINS={cors_example}",
        ),
        ("9. Troubleshooting", 1, ""),
        (
            "",
            -1,
            "White screen / canvaskit errors — redeploy web\\ with --no-web-resources-cdn.\n"
            "Login 401 — check MySQL, user exists, restart server_runner after .env change.\n"
            "Phone cannot connect — firewall profile, correct LAN IP, same Wi‑Fi subnet.\n"
            "API calls to localhost:8000 — use LAN IP in the browser address bar.",
        ),
        ("10. Default database URL", 1, ""),
        (
            "",
            -1,
            "mysql+pymysql://root:19761982@localhost:3306/game_sila_misly\n"
            "(In .env; if unset, server_runner uses the same default from code.)",
        ),
    ]


def build_docx(out_path: Path, assets_dir: Path, lan_ip: str) -> None:
    from docx import Document
    from docx.shared import Inches

    doc = Document()
    for title, level, body in guide_sections(lan_ip):
        if level == 0 and title:
            doc.add_heading(title, 0)
        elif level == 1 and title:
            doc.add_heading(title, level=1)
        if body:
            for para in body.split("\n"):
                if para.strip():
                    doc.add_paragraph(para.strip())
                else:
                    doc.add_paragraph("")

    doc.add_heading("Diagram: LAN layout", level=2)
    net = assets_dir / "game-install-network.jpg"
    if net.exists():
        doc.add_picture(str(net), width=Inches(6.0))
    else:
        doc.add_paragraph("[Diagram: game-install-network.jpg]")

    doc.add_heading("Diagram: folder layout", level=2)
    folder = assets_dir / "game-install-folder.jpg"
    if folder.exists():
        doc.add_picture(str(folder), width=Inches(6.0))
    else:
        doc.add_paragraph("[Diagram: game-install-folder.jpg]")

    doc.save(out_path)


def build_pdf(out_path: Path, assets_dir: Path, lan_ip: str) -> None:
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import cm
    from reportlab.platypus import Image, Paragraph, SimpleDocTemplate, Spacer

    styles = getSampleStyleSheet()
    body_style = ParagraphStyle(
        "Body",
        parent=styles["Normal"],
        fontSize=10,
        leading=14,
        spaceAfter=8,
    )
    doc = SimpleDocTemplate(str(out_path), pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm)

    story: list = []
    for title, level, body in guide_sections(lan_ip):
        if level == 0 and title:
            story.append(Paragraph(title, styles["Title"]))
            story.append(Spacer(1, 0.3 * cm))
        elif level == 1 and title:
            story.append(Spacer(1, 0.2 * cm))
            story.append(Paragraph(title, styles["Heading2"]))
        if body:
            for para in body.split("\n"):
                text = para.strip().replace("&", "&amp;").replace("<", "&lt;")
                if text:
                    story.append(Paragraph(text, body_style))

    story.append(Paragraph("Diagram: LAN layout", styles["Heading2"]))
    net = assets_dir / "game-install-network.jpg"
    if net.exists():
        story.append(Image(str(net), width=16 * cm, height=9 * cm))
    story.append(Spacer(1, 0.3 * cm))
    story.append(Paragraph("Diagram: folder layout", styles["Heading2"]))
    folder = assets_dir / "game-install-folder.jpg"
    if folder.exists():
        story.append(Image(str(folder), width=16 * cm, height=9 * cm))

    doc.build(story)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", default=None, help="LAN IP for examples in the guide")
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Output directory (default: docs/guides)",
    )
    parser.add_argument(
        "--assets",
        default=None,
        help="Folder with game-install-network.jpg and game-install-folder.jpg",
    )
    parser.add_argument("--copy-to", default=None, help="Also copy DOCX/PDF to this folder")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    out_dir = Path(args.out_dir) if args.out_dir else root / "docs" / "guides"
    assets_dir = Path(args.assets) if args.assets else out_dir / "assets"
    out_dir.mkdir(parents=True, exist_ok=True)

    lan_ip = (args.ip or detect_lan_ip()).strip()

    docx_path = out_dir / "Quze_Game_Installation_Guide.docx"
    pdf_path = out_dir / "Quze_Game_Installation_Guide.pdf"

    try:
        build_docx(docx_path, assets_dir, lan_ip)
        build_pdf(pdf_path, assets_dir, lan_ip)
    except ImportError:
        print("Install: python -m pip install python-docx pillow reportlab")
        return 1

    print(f"LAN IP used in examples: {lan_ip}")
    print(f"DOCX: {docx_path}")
    print(f"PDF:  {pdf_path}")

    if args.copy_to:
        dest = Path(args.copy_to)
        dest.mkdir(parents=True, exist_ok=True)
        import shutil

        shutil.copy2(docx_path, dest / docx_path.name)
        shutil.copy2(pdf_path, dest / pdf_path.name)
        assets_dest = dest / "assets"
        assets_dest.mkdir(exist_ok=True)
        for name in ("game-install-network.jpg", "game-install-folder.jpg"):
            src = assets_dir / name
            if src.exists():
                shutil.copy2(src, assets_dest / name)
        print(f"Copied to: {dest}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())