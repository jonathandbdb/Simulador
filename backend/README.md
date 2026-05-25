# backend/

Backend FastAPI del simulador. Se implementa en **Sprint 3** (F0).

Layout previsto (ver `context/fase_0_backend.md`):

```
backend/
├── docker-compose.yml      # api + db (Postgres) + bucket (MinIO) + nginx
├── api/
│   ├── main.py
│   ├── config.py
│   ├── database.py
│   ├── models/             # device, lens, version, admin_user
│   ├── routers/            # manifest, license, lenses, devices, versions, admin
│   ├── templates/          # Jinja2 + HTMX
│   └── static/             # Tailwind CSS
├── nginx/
│   └── nginx.conf
└── .env.example
```

**Vacio en Sprint 0 — placeholder.**
