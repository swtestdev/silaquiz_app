# CM_Quiz (Quze) — offline LAN game server package

Copy this folder to the game PC (e.g. `C:\WebAppServer` or `D:\CM_Quiz`) and run setup once, then start services before each game.

## Required files in this folder

| File / folder | Role |
|---------------|------|
| `server_runner.exe` | API on port **8000** |
| `serve_no_cache.exe` | PWA static files on port **8080** |
| `web\` | Flutter release build (`flutter build web --release --no-web-resources-cdn`) |
| `.env` | Created/updated by `Install-CMQuiz.ps1` |

## One-time install

1. Open **PowerShell as Administrator**.
2. `cd` to this folder (e.g. `C:\WebAppServer`).
3. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-CMQuiz.ps1
```

Install into another path:

```powershell
.\Install-CMQuiz.ps1 -TargetDir "D:\CM_Quiz"
```

## Start / stop (each game)

- **Start:** double-click `Start-QuzeGame.bat` or run `.\Start-QuzeGame.ps1`
- **Stop:** `.\Stop-QuzeGame.ps1` or close both server windows

Players open: **`http://<LAN-IP>:8080/`** (printed at start).

Use the **LAN IP** on the admin PC too (not `http://localhost:8080/`).

## Database

- Default connection (`.env` or code fallback):  
  `mysql+pymysql://root:19761982@localhost:3306/game_sila_misly`
- Schema/bootstrap: when `server_runner.exe` starts.

Optional: place MySQL Installer `*.msi` in `mysql\installer\` before running install.

### Set root password (first time)

```sql
ALTER USER 'root'@'localhost' IDENTIFIED BY '19761982';
FLUSH PRIVILEGES;
```

Then: `.\scripts\Setup-Database.ps1`

## Offline Flutter build

```powershell
flutter build web --release --no-web-resources-cdn
```

Deploy entire `build\web\` into `web\` (must include `canvaskit\`).

## Firewall

```powershell
.\Configure-Firewall.ps1
```

Allows inbound TCP **8000** and **8080** on Private networks.

## Printable guides for game owners

| Guide | File in `guides/` |
|-------|-------------------|
| Installation | `Quze_Game_Installation_Guide.pdf` |
| Admin (super_admin / floor admin) | `Quze_Admin_Guide.pdf` |
| Player (phones on venue Wi‑Fi) | `Quze_Player_Guide.pdf` |

Regenerate from the Quze repo: `python scripts/generate_game_installation_guide.py`, `python scripts/generate_admin_guide.py`, `python scripts/generate_player_guide.py`.