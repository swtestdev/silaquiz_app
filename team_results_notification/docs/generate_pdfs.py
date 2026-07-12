"""Convert Quze HTML guides to PDF using Chrome headless."""
import subprocess
from pathlib import Path

DOCS = Path(__file__).resolve().parent
CHROME = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")

GUIDES = [
    ("quze-player-setup-guide.html", "quze-player-setup-guide.pdf"),
    ("quze-debug-mode-guide.html", "quze-debug-mode-guide.pdf"),
]


def html_to_pdf(html_path: Path, pdf_path: Path) -> None:
    if not CHROME.is_file():
        raise FileNotFoundError(f"Chrome not found at {CHROME}")
    file_url = html_path.resolve().as_uri()
    cmd = [
        str(CHROME),
        "--headless=new",
        "--disable-gpu",
        "--no-pdf-header-footer",
        f"--print-to-pdf={pdf_path.resolve()}",
        file_url,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(
            f"Chrome PDF failed for {html_path.name} (exit {result.returncode}): {result.stderr}"
        )
    if not pdf_path.is_file() or pdf_path.stat().st_size == 0:
        raise RuntimeError(f"PDF was not created: {pdf_path}")


def main() -> None:
    for html_name, pdf_name in GUIDES:
        html_path = DOCS / html_name
        pdf_path = DOCS / pdf_name
        if not html_path.is_file():
            raise FileNotFoundError(f"Missing HTML: {html_path}")
        print(f"Generating {pdf_path.name} ...")
        html_to_pdf(html_path, pdf_path)
        print(f"  OK ({pdf_path.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
