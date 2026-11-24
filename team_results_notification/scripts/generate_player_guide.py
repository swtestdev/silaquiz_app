#!/usr/bin/env python3
"""Build Quze Player Guide (DOCX + PDF) for phones on the game Wi‑Fi."""

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


def ensure_player_assets(assets_dir: Path) -> None:
    """Create simple infographics if missing (Pillow)."""
    assets_dir.mkdir(parents=True, exist_ok=True)
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return

    def font(size: int):
        for name in ("arial.ttf", "Arial.ttf", "DejaVuSans.ttf"):
            try:
                return ImageFont.truetype(name, size)
            except OSError:
                continue
        return ImageFont.load_default()

    navy = "#0f3460"
    accent = "#e94560"
    pale = "#f4f6fa"

    path_wifi = assets_dir / "player-wifi.jpg"
    if not path_wifi.exists():
        w, h = 1280, 720
        img = Image.new("RGB", (w, h), pale)
        draw = ImageDraw.Draw(img)
        draw.rectangle([0, 0, w, 72], fill=navy)
        draw.text((40, 22), "Quze — same Wi‑Fi as the game", fill="white", font=font(36))
        cx = w // 2
        draw.ellipse([cx - 120, 140, cx + 120, 380], outline=navy, width=4)
        draw.text((cx - 55, 240), "Wi‑Fi", fill=navy, font=font(40))
        draw.rectangle([180, 420, 420, 520], fill="white", outline=navy, width=3)
        draw.text((200, 450), "Game PC", fill=navy, font=font(28))
        draw.text((200, 488), ":8080 app", fill="#444", font=font(22))
        draw.rectangle([860, 420, 1100, 520], fill="white", outline=accent, width=3)
        draw.text((900, 450), "Your phone", fill=accent, font=font(28))
        draw.text((900, 488), "browser / PWA", fill="#444", font=font(22))
        draw.line([420, 470, 860, 470], fill=navy, width=3)
        draw.text((500, 560), "Do not use localhost or mobile data", fill=accent, font=font(26))
        img.save(path_wifi, quality=88)

    path_flow = assets_dir / "player-flow.jpg"
    if not path_flow.exists():
        w, h = 1280, 720
        img = Image.new("RGB", (w, h), pale)
        draw = ImageDraw.Draw(img)
        draw.rectangle([0, 0, w, 72], fill=navy)
        draw.text((40, 22), "Quze — player flow", fill="white", font=font(36))
        steps = [
            ("1. Open game URL", ":8080"),
            ("2. Register / Log in", "credentials from host"),
            ("3. Team ID", "profile → Team ID"),
            ("4. Writer ON", "top bar switch"),
            ("5. Board Quize", "enter answers"),
            ("6. View Summary", "scores anytime"),
        ]
        x0, y0 = 60, 110
        box_w, box_h, gap = 360, 88, 16
        for i, (title, sub) in enumerate(steps):
            col, row = i % 3, i // 3
            x = x0 + col * (box_w + gap)
            y = y0 + row * (box_h + gap + 8)
            fill = "white" if i != 4 else "#fff0f3"
            draw.rounded_rectangle([x, y, x + box_w, y + box_h], radius=12, fill=fill, outline=navy, width=2)
            draw.text((x + 16, y + 14), title, fill=navy, font=font(24))
            draw.text((x + 16, y + 48), sub, fill="#555", font=font(20))
        draw.text(
            (60, 620),
            "Keep Quze in the foreground during play (visibility tracking)",
            fill=accent,
            font=font(24),
        )
        img.save(path_flow, quality=88)


def make_qr_png(data: str, path: Path) -> None:
    import qrcode

    qr = qrcode.QRCode(version=1, box_size=6, border=2)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    img.save(path)


def guide_sections(lan_ip: str) -> list[tuple[str, int, str]]:
    player_url = f"http://{lan_ip}:8080/"
    api_url = f"http://{lan_ip}:8000/api"
    return [
        ("Quze — Player Guide", 0, ""),
        (
            "",
            -1,
            f"Generated {datetime.now():%Y-%m-%d %H:%M}. "
            "Audience: players on phones or tablets at the venue.",
        ),
        ("1. Connect to the game Wi‑Fi", 1, ""),
        (
            "",
            -1,
            "Join the same wireless network as the game computer (not mobile data). "
            "Ask the host for the Wi‑Fi name and password if needed. "
            "If the phone cannot reach the host PC, the app shows Offline in the top bar.",
        ),
        ("2. Open Quze in the browser", 1, ""),
        (
            "",
            -1,
            f"Open this address in Chrome or Safari:\n{player_url}\n"
            "Do not use localhost or 127.0.0.1 — that only works on the host PC.\n"
            "Optional: Add to Home screen / Install app so Quze opens like an app icon.",
        ),
        ("3. Server connection (API)", 1, ""),
        (
            "",
            -1,
            f"When you open the PWA with the LAN IP above, Quze usually sets the API automatically to:\n"
            f"{api_url}\n\n"
            "If login fails with connection errors, open Database Info on the login screen and save that API URL. "
            "The host must have server_runner running on port 8000 and firewall open on the venue network.",
        ),
        ("4. Register or log in", 1, ""),
        (
            "",
            -1,
            "Create an account (Register) or use credentials your game admin gave you (Log in). "
            "Password must be at least 6 characters. "
            "After login you land on Welcome with your name and connection status.",
        ),
        ("5. Join your team", 1, ""),
        (
            "",
            -1,
            "Your captain shares a Team ID (numeric). "
            "Tap the settings icon next to your name → profile → Team ID → Update.\n"
            "Until you are on a team, Board Quize stays disabled and the Writer switch is greyed out.",
        ),
        ("6. Bonus options (if prompted)", 1, ""),
        (
            "",
            -1,
            "When the host starts a game with bonus rules, a popup may ask your team to pick an option. "
            "Choose once when prompted; you can continue on Welcome afterward.",
        ),
        ("7. Writer role — who enters answers", 1, ""),
        (
            "",
            -1,
            "Only one player per team should be the writer during a round. "
            "On Welcome, use the Writer switch in the top bar (orange when ON). "
            "Turn writer ON on the device that will type answers on Board Quize. "
            "Other teammates can follow along with View Summary.",
        ),
        ("8. Board Quize and View Summary", 1, ""),
        (
            "",
            -1,
            "View Summary — team scoreboard and results (team must be in the active game).\n"
            "Board Quize — question board and answer entry (writer only, same eligibility). "
            "If a button is dimmed, your team may not be in the running game or you are not the writer.",
        ),
        ("9. During the game — visibility", 1, ""),
        (
            "",
            -1,
            "Keep the Quze tab or app in the foreground. Switching apps, blurring the browser, "
            "or locking the phone may mark you invisible for admin tracking until you return. "
            "Stay on Welcome or Board Quize with the screen on when the host asks players to be ready.",
        ),
        ("10. Troubleshooting", 1, ""),
        (
            "",
            -1,
            "White screen — host may need to redeploy offline web build; try reload.\n"
            "Offline in top bar — wrong Wi‑Fi, wrong URL, or servers not started on host PC.\n"
            "Cannot log in — check API URL in Database Info; confirm account is active with admin.\n"
            "Board Quize locked — enable Writer, confirm Team ID, confirm host added your team to the active game.",
        ),
    ]


def add_player_table_docx(doc) -> None:
    doc.add_heading("Quick reference", level=2)
    table = doc.add_table(rows=1, cols=2)
    table.style = "Table Grid"
    hdr = table.rows[0].cells
    hdr[0].text = "Item"
    hdr[1].text = "What to do"
    rows = [
        ("Game link", "http://<host-LAN-IP>:8080/"),
        ("API (if needed)", "http://<host-LAN-IP>:8000/api"),
        ("Team", "Profile → Team ID from captain"),
        ("Enter answers", "Writer ON → Board Quize"),
        ("Scores", "View Summary"),
    ]
    for a, b in rows:
        cells = table.add_row().cells
        cells[0].text = a
        cells[1].text = b
    doc.add_paragraph("")


def build_docx(
    out_path: Path,
    assets_dir: Path,
    lan_ip: str,
    qr_path: Path | None,
) -> None:
    from docx import Document
    from docx.shared import Inches

    player_url = f"http://{lan_ip}:8080/"

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

    add_player_table_docx(doc)

    if qr_path and qr_path.exists():
        doc.add_heading("QR code — open on your phone", level=2)
        doc.add_paragraph(player_url)
        doc.add_picture(str(qr_path), width=Inches(2.4))

    for heading, name in (
        ("Diagram: Wi‑Fi and host", "player-wifi.jpg"),
        ("Diagram: player steps", "player-flow.jpg"),
    ):
        doc.add_heading(heading, level=2)
        img = assets_dir / name
        if img.exists():
            doc.add_picture(str(img), width=Inches(6.0))
        else:
            doc.add_paragraph(f"[Missing: {name}]")

    doc.save(out_path)


def build_pdf(
    out_path: Path,
    assets_dir: Path,
    lan_ip: str,
    qr_path: Path | None,
) -> None:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import cm
    from reportlab.platypus import Image, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

    styles = getSampleStyleSheet()
    body = ParagraphStyle("Body", parent=styles["Normal"], fontSize=10, leading=14, spaceAfter=6)
    player_url = f"http://{lan_ip}:8080/"

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

    story.append(Paragraph("Quick reference", styles["Heading2"]))
    data = [
        ["Item", "What to do"],
        ["Game link", "http://&lt;host-LAN-IP&gt;:8080/"],
        ["API (if needed)", "http://&lt;host-LAN-IP&gt;:8000/api"],
        ["Team", "Profile → Team ID from captain"],
        ["Enter answers", "Writer ON → Board Quize"],
        ["Scores", "View Summary"],
    ]
    t = Table(data, colWidths=[4.5 * cm, 11.5 * cm])
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

    if qr_path and qr_path.exists():
        story.append(Paragraph("QR code — open on your phone", styles["Heading2"]))
        story.append(Paragraph(player_url.replace("&", "&amp;"), body))
        story.append(Image(str(qr_path), width=5 * cm, height=5 * cm))
        story.append(Spacer(1, 0.3 * cm))

    for heading, name in (
        ("Diagram: Wi‑Fi and host", "player-wifi.jpg"),
        ("Diagram: player steps", "player-flow.jpg"),
    ):
        story.append(Paragraph(heading, styles["Heading2"]))
        img = assets_dir / name
        if img.exists():
            story.append(Image(str(img), width=16 * cm, height=9 * cm))
        story.append(Spacer(1, 0.3 * cm))

    doc.build(story)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", default=None, help="LAN IP for URL examples and QR")
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--assets", default=None)
    parser.add_argument("--copy-to", default=None, help="Also copy outputs to this folder")
    parser.add_argument("--no-qr", action="store_true", help="Skip QR code in the guide")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    out_dir = Path(args.out_dir) if args.out_dir else root / "docs" / "guides"
    assets_dir = Path(args.assets) if args.assets else out_dir / "assets"
    out_dir.mkdir(parents=True, exist_ok=True)

    lan_ip = (args.ip or detect_lan_ip()).strip()
    ensure_player_assets(assets_dir)

    player_url = f"http://{lan_ip}:8080/"
    qr_path: Path | None = None
    if not args.no_qr:
        qr_path = out_dir / f"_qr_player_{lan_ip.replace('.', '_')}.png"
        try:
            make_qr_png(player_url, qr_path)
        except ImportError:
            print("QR skipped — install: python -m pip install qrcode[pil]")
            qr_path = None

    docx_path = out_dir / "Quze_Player_Guide.docx"
    pdf_path = out_dir / "Quze_Player_Guide.pdf"

    try:
        build_docx(docx_path, assets_dir, lan_ip, qr_path)
        build_pdf(pdf_path, assets_dir, lan_ip, qr_path)
    except ImportError:
        print("Install: python -m pip install python-docx pillow reportlab qrcode[pil]")
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
        for name in ("player-wifi.jpg", "player-flow.jpg"):
            src = assets_dir / name
            if src.exists():
                shutil.copy2(src, ad / name)
        print(f"Copied to: {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())