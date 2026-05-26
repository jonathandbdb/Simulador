"""FastAPI app entry point."""
import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlmodel import Session

from app.config import settings
from app.database import engine, init_db
from app.routers import limiter, router as public_router
from app.seed import seed

logging.basicConfig(level=settings.log_level.upper())
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Simulador VR — Backend",
    description="API publica + panel admin del simulador oftalmologico.",
    version="0.1.0",
)

# Rate limiting (afecta los endpoints decorados con @limiter.limit).
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# CORS: Sprint 3 abre todo para facilitar desarrollo.
# Sprint 8 lo restringira al dominio del panel admin.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(public_router)


@app.on_event("startup")
def on_startup() -> None:
    logger.info("Inicializando schema de BD (SQLModel.metadata.create_all)...")
    init_db()
    logger.info("Ejecutando seed inicial...")
    with Session(engine) as session:
        seed(session)
    logger.info("Backend listo en %s", settings.public_base_url)


@app.get("/healthz")
def healthz() -> dict:
    """Health check para Docker / load balancer / Caddy."""
    return {"status": "ok"}


@app.get("/")
def root() -> dict:
    return {
        "name": "Simulador VR Backend",
        "version": app.version,
        "docs": "/docs",
        "endpoints": {
            "manifest": "/api/manifest.json",
            "verify": "POST /api/verify",
            "lenses": "/api/lenses",
            "log": "POST /api/log",
            "healthz": "/healthz",
        },
    }
