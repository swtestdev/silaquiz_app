@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo.
echo  Quze - player link generator
echo  =============================
echo.

python --version >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python is not installed or not on PATH.
  echo Install Python 3 from https://www.python.org/downloads/
  exit /b 1
)

python -c "import qrcode, docx" >nul 2>&1
if errorlevel 1 (
  echo Installing dependencies ^(qrcode, python-docx, pillow, reportlab^)...
  python -m pip install qrcode[pil] python-docx pillow reportlab --quiet
  if errorlevel 1 (
    echo ERROR: Failed to install Python packages.
    exit /b 1
  )
)

set "LAN_IP="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command ^
  "$n = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Virtual|Docker|WSL' } | Sort-Object InterfaceMetric | Select-Object -First 1; if ($n) { $n.IPAddress }"`) do set "LAN_IP=%%i"

if not defined LAN_IP (
  for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do (
    set "LAN_IP=%%a"
    goto :trim_ip
  )
)

:trim_ip
if defined LAN_IP (
  for /f "tokens=* delims= " %%a in ("%LAN_IP%") do set "LAN_IP=%%a"
)

if defined LAN_IP (
  echo Detected LAN IP: %LAN_IP%
  python scripts\generate_quiz_links.py %LAN_IP% --pdf
) else (
  echo Could not detect LAN IP automatically.
  python scripts\generate_quiz_links.py --pdf
)

if errorlevel 1 exit /b 1

echo.
echo Files saved in the share\ folder.
echo.
pause
