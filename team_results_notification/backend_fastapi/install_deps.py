#!/usr/bin/env python3
"""
Install FastAPI backend dependencies (aligned with requirements.txt and main.py).

On Windows/Python 3.9, greenlet must come from a pre-built wheel (no MSVC required).
"""

import os
import subprocess
import sys
from typing import Optional


def install_package(
    package: str,
    *,
    only_binary: Optional[str] = None,
) -> bool:
    """Install a package using pip."""
    cmd = [sys.executable, "-m", "pip", "install", "--upgrade"]
    if only_binary:
        cmd.extend(["--only-binary", only_binary])
    cmd.append(package)
    try:
        subprocess.check_call(cmd)
        print(f"Successfully installed {package}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"Failed to install {package}: {e}")
        return False


def load_packages() -> list[str]:
    """Load pins from requirements.txt; adjust for what main.py actually imports."""
    req_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements.txt")
    packages: list[str] = []

    if os.path.isfile(req_path):
        with open(req_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.lower().startswith("python-jose"):
                    packages.append("PyJWT>=2.8.0")
                    continue
                packages.append(line)
    else:
        packages = [
            "fastapi==0.104.1",
            "uvicorn[standard]==0.24.0",
            "python-dotenv==1.0.0",
            "greenlet==3.1.1",
            "sqlalchemy==2.0.36",
            "pymysql==1.1.2",
            "PyJWT>=2.8.0",
            "passlib[bcrypt]==1.7.4",
            "bcrypt>=4.0.1,<5",
            "cffi==1.17.1",
            "cryptography==41.0.7",
            "email-validator>=2.1.0",
            "python-multipart==0.0.12",
            "pandas==2.1.3",
            "openpyxl==3.1.2",
        ]

    # Install greenlet before SQLAlchemy (needs a wheel on Windows without C++ Build Tools).
    greenlet_first: list[str] = []
    rest: list[str] = []
    for pkg in packages:
        if pkg.lower().startswith("greenlet"):
            greenlet_first.append(pkg)
        else:
            rest.append(pkg)
    return greenlet_first + rest


def main() -> None:
    print("Installing FastAPI backend dependencies...")
    print("=" * 50)

    packages = load_packages()
    success_count = 0

    for package in packages:
        only_binary = "greenlet" if package.lower().startswith("greenlet") else None
        if install_package(package, only_binary=only_binary):
            success_count += 1

    print("=" * 50)
    print(
        f"Installation complete: {success_count}/{len(packages)} "
        "packages installed successfully"
    )

    if success_count == len(packages):
        print("All dependencies installed.")
        print("Run: python main.py")
        print("Or:  python start_server.py")
    else:
        print("Some packages failed to install. Check errors above.")
        print(
            "If greenlet still fails, install Microsoft C++ Build Tools or "
            "use Python 3.11+ where more wheels are available."
        )


if __name__ == "__main__":
    main()
