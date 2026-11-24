#!/usr/bin/env python3
"""Build Quze Admin Guide (DOCX + PDF) — super_admin and game admin roles."""

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
    admin_url = f"http://{lan_ip}:8080/"
    return [
        ("Quze — Admin Guide", 0, ""),
        (
            "",
            -1,
            f"Generated {datetime.now():%Y-%m-%d %H:%M}. "
            "Audience: game owner (super_admin) and floor game admins (role: admin).",
        ),
        ("1. Sign in", 1, ""),
        (
            "",
            -1,
            f"Open the Quze PWA at {admin_url} on the host PC (use the LAN IP, not localhost, "
            "so API and CORS match player devices).\n"
            "Log in with your admin account. Main page shows Admin Panel when role is admin or super_admin.",
        ),
        ("2. Admin roles", 1, ""),
        (
            "",
            -1,
            "super_admin — single game owner account (bootstrapped on server start). "
            "Default email is admin@silaquiz.com unless SUPER_ADMIN_EMAIL is set in server .env. "
            "Only super_admin can edit other users, change roles, activate/deactivate, or remove users "
            "(except another super_admin row).\n\n"
            "admin — floor / assigned game admin. Same Admin Panel for teams, games, and analytics. "
            "Can open User Management to view the list; can only remove their own account from the menu. "
            "Cannot promote users to admin while they are assigned to a team.\n\n"
            "player — not covered in this guide.",
        ),
        ("3. Admin Panel (main page)", 1, ""),
        (
            "",
            -1,
            "Team Management — create teams, captains, members, writers.\n"
            "User Management — list users; full actions for super_admin only.\n"
            "Game Management — load games from Excel, open Active Games.\n"
            "Analytics — live grading and Tracking APP (enabled only when an active game is running, not idle).",
        ),
        ("4. Team Management", 1, ""),
        (
            "",
            -1,
            "Create teams before players arrive. Assign team codes/IDs players use at registration.\n"
            "Set team captain and writer (writer submits answers on Question page).\n"
            "Teams list view shows all teams; edit membership before the game starts.",
        ),
        ("5. User Management (super_admin)", 1, ""),
        (
            "",
            -1,
            "Filters: All / Players / Admins. Tap a user (super_admin only) for:\n"
            "• Edit User — name, email, password, team, role player vs admin\n"
            "• Change Role — player ↔ admin (admin requires user has no team assignment)\n"
            "• Activate / Deactivate\n"
            "• Remove user — permanent; precheck blocks if user is captain, writer, or on a team\n\n"
            "Assigned admin: read-only list; optional Remove my account on their own row only.",
        ),
        ("6. Game Management", 1, ""),
        (
            "",
            -1,
            "Load New Game — upload Excel (.xlsx); each sheet becomes a game in the database.\n"
            "Active Games — create a session from a loaded game, pick teams, bonus options, "
            "set status (idle → running). Only one live running game drives Analytics.\n"
            "Round timing is driven by your presentation deck; Quze receives timer triggers when slides advance.",
        ),
        ("7. Analytics — Grading hub", 1, ""),
        (
            "",
            -1,
            "Opens when an active game is not idle. Shows current game and rounds.\n"
            "Round not started — locked until the round is recorded in action_game_control (first slide).\n"
            "Per started round:\n"
            "• Round table — grading matrix (teams × questions), open cells for review.\n"
            "• Tracking APP — per-player visibility / disconnect timeline for the round.\n"
            "Export Data — Excel workbook (SUMMARY + one tab per round); Local download and/or "
            "Server path if QUZE_EXPORT_SERVER_DIR is set on the API host.",
        ),
        ("8. Question / list review (from grading)", 1, ""),
        (
            "",
            -1,
            "From the round matrix, open a question or list item to review team answers, "
            "override scores, and mark review state.",
        ),
        ("9. Recommended game-night sequence", 1, ""),
        (
            "",
            -1,
            "1. Start server_runner and serve_no_cache (Start-QuzeGame.bat).\n"
            "2. super_admin: verify users and teams.\n"
            "3. Create or select Active Game → set Running.\n"
            "4. Share player URL / QR (same LAN IP :8080).\n"
            "5. During play: Analytics → Tracking APP + Round table as needed.\n"
            "6. After rounds: Export Data for records.",
        ),
        ("10. Admin tips", 1, ""),
        (
            "",
            -1,
            "Keep the Quze browser tab in the foreground during play (visibility / tracking).\n"
            "Use the same LAN IP URL on the admin device as players.\n"
            "If Analytics is greyed out, no active game is running — start one in Active Games.\n"
            "Do not assign admin role to a user who is still on a team — remove team first.",
        ),
    ]


def add_role_table_docx(doc) -> None:
    doc.add_heading("Role permissions (summary)", level=2)
    table = doc.add_table(rows=1, cols=4)
    table.style = "Table Grid"
    hdr = table.rows[0].cells
    for i, text in enumerate(["Feature", "super_admin", "admin", "player"]):
        hdr[i].text = text
    rows = [
        ("Admin Panel", "Yes", "Yes", "No"),
        ("Team Management", "Yes", "Yes", "No"),
        ("User Management (edit others)", "Yes", "No", "No"),
        ("Game / Active Games", "Yes", "Yes", "No"),
        ("Analytics / Tracking", "Yes", "Yes", "No"),
        ("Play / Writer", "If on team", "If on team", "Yes"),
    ]
    for row in rows:
        cells = table.add_row().cells
        for i, text in enumerate(row):
            cells[i].text = text
    doc.add_paragraph("")


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

    add_role_table_docx(doc)

    for heading, name in (
        ("Diagram: admin roles", "admin-roles.jpg"),
        ("Diagram: game-night workflow", "admin-workflow.jpg"),
    ):
        doc.add_heading(heading, level=2)
        img = assets_dir / name
        if img.exists():
            doc.add_picture(str(img), width=Inches(6.0))
        else:
            doc.add_paragraph(f"[Missing: {name}]")

    doc.save(out_path)


def build_pdf(out_path: Path, assets_dir: Path, lan_ip: str) -> None:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import cm
    from reportlab.platypus import Image, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

    styles = getSampleStyleSheet()
    body = ParagraphStyle("Body", parent=styles["Normal"], fontSize=10, leading=14, spaceAfter=6)

    story: list = []
    doc = SimpleDocTemplate(str(out_path), pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm)

    for title, level, text in guide_sections(lan_ip):
        if level == 0 and title:
            story.append(Paragraph(title, styles["Title"]))
            story.append(Spacer(1, 0.3 * cm))
        elif level == 1 and title:
            story.append(Paragraph(title, styles["Heading2"]))
        if text:
            for para in text.split("\n"):
                line = para.strip().replace("&", "&amp;").replace("<", "&lt;")
                if line:
                    story.append(Paragraph(line, body))

    story.append(Paragraph("Role permissions (summary)", styles["Heading2"]))
    data = [
        ["Feature", "super_admin", "admin", "player"],
        ["Admin Panel", "Yes", "Yes", "No"],
        ["Team Management", "Yes", "Yes", "No"],
        ["User Management (edit others)", "Yes", "No", "No"],
        ["Game / Active Games", "Yes", "Yes", "No"],
        ["Analytics / Tracking", "Yes", "Yes", "No"],
    ]
    t = Table(data, colWidths=[6 * cm, 3 * cm, 3 * cm, 3 * cm])
    t.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#0f3460")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
                ("FONTSIZE", (0, 0), (-1, -1), 9),
            ]
        )
    )
    story.append(t)
    story.append(Spacer(1, 0.4 * cm))

    for heading, name in (
        ("Diagram: admin roles", "admin-roles.jpg"),
        ("Diagram: game-night workflow", "admin-workflow.jpg"),
    ):
        story.append(Paragraph(heading, styles["Heading2"]))
        img = assets_dir / name
        if img.exists():
            story.append(Image(str(img), width=16 * cm, height=9 * cm))
        story.append(Spacer(1, 0.3 * cm))

    doc.build(story)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", default=None)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--assets", default=None)
    parser.add_argument("--copy-to", default=None)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    out_dir = Path(args.out_dir) if args.out_dir else root / "docs" / "guides"
    assets_dir = Path(args.assets) if args.assets else out_dir / "assets"
    out_dir.mkdir(parents=True, exist_ok=True)

    lan_ip = (args.ip or detect_lan_ip()).strip()
    docx_path = out_dir / "Quze_Admin_Guide.docx"
    pdf_path = out_dir / "Quze_Admin_Guide.pdf"

    try:
        build_docx(docx_path, assets_dir, lan_ip)
        build_pdf(pdf_path, assets_dir, lan_ip)
    except ImportError:
        print("Install: python -m pip install python-docx pillow reportlab")
        return 1

    print(f"LAN IP in examples: {lan_ip}")
    print(f"DOCX: {docx_path}")
    print(f"PDF:  {pdf_path}")

    if args.copy_to:
        import shutil

        dest = Path(args.copy_to)
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(docx_path, dest / docx_path.name)
        shutil.copy2(pdf_path, dest / pdf_path.name)
        ad = dest / "assets"
        ad.mkdir(exist_ok=True)
        for name in ("admin-roles.jpg", "admin-workflow.jpg"):
            src = assets_dir / name
            if src.exists():
                shutil.copy2(src, ad / name)
        print(f"Copied to: {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())