# scripts/migrations/upgrade_v12.py
import os
from sqlalchemy import text
from models import db

# Intenta usar create_app; si falla, crea un app mínimo solo para migrar
try:
    from app import create_app
except Exception:
    create_app = None

flask_app = None
if create_app:
    try:
        flask_app = create_app()
    except Exception:
        flask_app = None

if flask_app is None:
    # Fallback: app mínimo con ruta ABSOLUTA a store.db (dos carpetas arriba)
    from flask import Flask
    proj_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    db_file = os.path.join(proj_root, "store.db")
    db_uri = os.getenv("SQLALCHEMY_DATABASE_URI", f"sqlite:///{db_file}")

    flask_app = Flask(__name__)
    flask_app.config["SQLALCHEMY_DATABASE_URI"] = db_uri
    flask_app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    db.init_app(flask_app)

with flask_app.app_context():
    # Log rápido de qué DB está usando esta migración
    try:
        print(f"[upgrade_v12] DB en uso: {db.engine.url}")
    except Exception:
        pass

    def has_table(name: str) -> bool:
        row = db.session.execute(text(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=:n"
        ), {"n": name}).fetchone()
        return bool(row)

    def has_col(table: str, col: str) -> bool:
        rows = db.session.execute(text(f"PRAGMA table_info({table})")).fetchall()
        return any(r[1] == col for r in rows)

    # Columna opcional en users
    if has_table("users") and not has_col("users", "star_points"):
        db.session.execute(text("ALTER TABLE users ADD COLUMN star_points INTEGER DEFAULT 0"))

    # Tablas de packs (sin DEFAULT JSON para evitar placeholders; luego se inicializa con '{}')
    db.session.execute(text("""
    CREATE TABLE IF NOT EXISTS pack_rules(
      id INTEGER PRIMARY KEY,
      set_code VARCHAR(32) UNIQUE NOT NULL,
      pack_size INTEGER NOT NULL DEFAULT 10,
      weights_json TEXT NOT NULL,
      god_chance REAL NOT NULL DEFAULT 0.001,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at TEXT
    );
    """))
    db.session.execute(text("UPDATE pack_rules SET weights_json='{}' WHERE weights_json IS NULL OR weights_json=''"))

    db.session.execute(text("""
    CREATE TABLE IF NOT EXISTS pack_allowances(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      set_code VARCHAR(32) NOT NULL,
      last_daily_open_date VARCHAR(10),
      bonus_tokens INTEGER NOT NULL DEFAULT 0,
      created_at TEXT,
      UNIQUE(user_id, set_code)
    );
    """))

    db.session.execute(text("""
    CREATE TABLE IF NOT EXISTS pack_opens(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      set_code VARCHAR(32) NOT NULL,
      opened_at TEXT,
      cards_json TEXT NOT NULL
    );
    """))

    db.session.execute(text("""
    CREATE TABLE IF NOT EXISTS user_cards(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      tcg_card_id VARCHAR(80) NOT NULL,
      set_code VARCHAR(32) NOT NULL,
      name VARCHAR(255) NOT NULL,
      rarity VARCHAR(120),
      image_url TEXT,
      acquired_at TEXT,
      locked INTEGER DEFAULT 0
    );
    """))

    db.session.execute(text("""
    CREATE TABLE IF NOT EXISTS star_ledgers(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      points INTEGER NOT NULL,
      reason VARCHAR(255),
      created_at TEXT
    );
    """))

    db.session.commit()
    print("v12: tablas listas (packs, star_points)")