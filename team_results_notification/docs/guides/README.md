# Quze owner guides

| Guide | Files |
|-------|--------|
| **Game Installation** | `Quze_Game_Installation_Guide.docx`, `.pdf` |
| **Admin** | `Quze_Admin_Guide.docx`, `.pdf` |
| **Player** | `Quze_Player_Guide.docx`, `.pdf` |

Regenerate installation guide (updates LAN IP in examples):

```powershell
cd team_results_notification
python scripts/generate_game_installation_guide.py
python scripts/generate_game_installation_guide.py --ip 192.168.0.100 --copy-to C:\WebAppServer\guides
```

Regenerate admin guide:

```powershell
python scripts/generate_admin_guide.py
python scripts/generate_admin_guide.py --ip 192.168.0.100 --copy-to C:\WebAppServer\guides
```

Regenerate player guide (includes QR for `:8080`):

```powershell
python scripts/generate_player_guide.py
python scripts/generate_player_guide.py --ip 192.168.0.100 --copy-to C:\WebAppServer\guides
```

Requires: `python -m pip install python-docx pillow reportlab qrcode[pil]`

Diagrams: `assets/game-install-network.jpg`, `assets/game-install-folder.jpg`, `admin-roles.jpg`, `admin-workflow.jpg`, `player-wifi.jpg`, `player-flow.jpg`