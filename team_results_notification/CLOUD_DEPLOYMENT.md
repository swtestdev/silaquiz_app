# Quze - Cloud Deployment Guide

This guide covers deploying the Quze game PWA and FastAPI backend to cloud platforms.

## Architecture Overview

- **PWA (Flutter web)**: Static files served over HTTPS
- **FastAPI backend**: REST API + WebSocket for timer sync
- **MySQL**: Database for users, teams, games, in-game data

## Prerequisites

- MySQL database (managed or self-hosted)
- Domain name (recommended for production)
- SSL certificates (usually provided by platform or Let's Encrypt)

---

## Backend Deployment (FastAPI)

### Environment Variables

Create a `.env` file or set these in your platform's environment:

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `DATABASE_URL` | Yes | MySQL connection string | `mysql+pymysql://user:pass@host:3306/quze_db` |
| `SECRET_KEY` | Yes (prod) | JWT signing key; use a strong random value | `openssl rand -hex 32` |
| `CORS_ORIGINS` | Yes (prod) | Comma-separated PWA origins | `https://quze.example.com` |

### Railway

1. Create a new project on [Railway](https://railway.app)
2. Add a MySQL service or connect an external MySQL (PlanetScale, Aiven, etc.)
3. Add a new service from GitHub repo, select `team_results_notification/backend_fastapi`
4. Set root directory to `backend_fastapi` (or deploy from subfolder)
5. Configure env vars: `DATABASE_URL`, `SECRET_KEY`, `CORS_ORIGINS`
6. Railway auto-detects Python; add start command: `uvicorn main:app --host 0.0.0.0 --port $PORT`
7. Deploy; Railway provides a URL like `https://your-app.up.railway.app`

### Render

1. Create a new Web Service on [Render](https://render.com)
2. Connect your repo, set root directory to `team_results_notification/backend_fastapi`
3. Build command: `pip install -r requirements.txt`
4. Start command: `uvicorn main:app --host 0.0.0.0 --port $PORT`
5. Add environment variables (Secret Files or env vars)
6. For MySQL: use Render MySQL add-on or external provider (PlanetScale, Neon, etc.)

### Fly.io

1. Install flyctl: `flyctl auth login`
2. From `backend_fastapi` directory:
   ```bash
   fly launch --name quze-api
   ```
3. Add MySQL (Upstash, PlanetScale, or Fly Postgres with MySQL compatibility layer)
4. Set secrets:
   ```bash
   fly secrets set DATABASE_URL="mysql+pymysql://..."
   fly secrets set SECRET_KEY="your-secret-key"
   fly secrets set CORS_ORIGINS="https://your-pwa-domain.com"
   ```
5. Deploy: `fly deploy`

### Docker (Generic)

Example `Dockerfile` in `backend_fastapi`:

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Build and run:

```bash
docker build -t quze-api ./backend_fastapi
docker run -p 8000:8000 -e DATABASE_URL=... -e SECRET_KEY=... -e CORS_ORIGINS=... quze-api
```

---

## PWA Deployment (Flutter Web)

### Build

```bash
cd team_results_notification
flutter build web
```

Output is in `build/web/`.

### Firebase Hosting

1. Install Firebase CLI: `npm install -g firebase-tools`
2. `firebase login` and `firebase init hosting`
3. Set public directory to `build/web`
4. Deploy: `firebase deploy`

### Netlify

1. Connect repo to Netlify
2. Build command: `cd team_results_notification && flutter build web`
3. Publish directory: `team_results_notification/build/web`
4. Add redirect rule for SPA: `/* /index.html 200`

### Vercel

1. Import project; set root to `team_results_notification`
2. Build: `flutter build web`
3. Output directory: `build/web`

### Same Server as API

If serving PWA from the same domain as the API (e.g. `/` for PWA, `/api` for backend):

- Use Nginx or Caddy to serve static files from `build/web` at `/`
- Proxy `/api` and `/ws` to the FastAPI backend
- Set `CORS_ORIGINS` to your domain only

---

## Client Configuration (API URL)

The Quze app loads the API base URL from local storage. Users configure it via:

1. **First launch**: Default is `http://localhost:8000/api`
2. **Database Info** (login screen): Tap "Database Info" → enter or select server URL → Save

For cloud deployments, users must enter your API URL (e.g. `https://quze-api.example.com/api`) in the Server Settings dialog. Consider providing a QR code or short link to a pre-configured install page.

---

## MySQL Setup

### Managed MySQL (PlanetScale, AWS RDS, Azure MySQL)

1. Create a database (e.g. `quze_db`)
2. Run schema creation (tables are auto-created by SQLAlchemy on first request, or use `init-db` endpoint)
3. Use the connection string in `DATABASE_URL`

### Schema

The backend auto-creates tables: `users`, `teams_list`, `games_list`, `active_games`. Game content tables are created when loading games from Excel via the admin panel.

---

## Security Checklist

- [ ] `SECRET_KEY` is a strong random value (not default)
- [ ] `CORS_ORIGINS` is set to your PWA domain(s), not `*`
- [ ] `DATABASE_URL` uses SSL if supported (`?ssl=true` for PlanetScale, etc.)
- [ ] API and PWA served over HTTPS
- [ ] WebSocket uses WSS (not WS) in production

---

## Health Check

After deployment, verify:

```bash
curl https://your-api.example.com/api/health
```

Expected: `{"status":"ok"}` or similar.
