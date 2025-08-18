# ai/cache_service.py
import json, time, hashlib
from sqlalchemy import text
from models import db

def _now():
    return time.strftime("%Y-%m-%d %H:%M:%S")

def get_cache(cache_key: str) -> str | None:
    row = db.session.execute(text("SELECT value FROM ai_cache WHERE cache_key=:k"), {"k": cache_key}).fetchone()
    return row[0] if row else None

def set_cache(cache_key: str, value: str) -> None:
    db.session.execute(
        text("""
        INSERT INTO ai_cache(cache_key, value, updated_at)
        VALUES (:k, :v, :ts)
        ON CONFLICT(cache_key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
        """),
        {"k": cache_key, "v": value, "ts": _now()}
    )
    db.session.commit()

def make_key(namespace: str, model: str, text: str) -> str:
    h = hashlib.sha1(text.encode("utf-8")).hexdigest()
    return f"{namespace}:{model}:{h}"
