# upgrade_v7.py
from app import create_app
from models import db

app = create_app()
with app.app_context():
    # product_embeddings: vector guardado como JSON (lista de floats)
    db.session.execute(db.text("""
    CREATE TABLE IF NOT EXISTS product_embeddings (
      product_id INTEGER PRIMARY KEY,
      model TEXT,
      vector TEXT NOT NULL,
      fingerprint TEXT,
      updated_at TEXT,
      FOREIGN KEY(product_id) REFERENCES productos(id) ON DELETE CASCADE
    );"""))

    # ai_cache: clave -> valor (para cachear respuestas del asistente)
    db.session.execute(db.text("""
    CREATE TABLE IF NOT EXISTS ai_cache (
      cache_key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT
    );"""))

    db.session.commit()
    print("v7: tablas product_embeddings y ai_cache listas.")