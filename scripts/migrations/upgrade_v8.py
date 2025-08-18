# scripts/migrations/upgrade_v8.py
from app import create_app
from models import db

app = create_app()
with app.app_context():
    def has_col(table, col):
        cols = [r[1] for r in db.session.execute(db.text(f"PRAGMA table_info({table})")).fetchall()]
        return col in cols

    # ID de carta en TCG (ej. sv1-1) y campos de mercado
    if not has_col("productos","tcg_card_id"):
        db.session.execute(db.text("ALTER TABLE productos ADD COLUMN tcg_card_id VARCHAR(80)"))
    if not has_col("productos","market_price"):
        db.session.execute(db.text("ALTER TABLE productos ADD COLUMN market_price REAL"))
    if not has_col("productos","market_currency"):
        db.session.execute(db.text("ALTER TABLE productos ADD COLUMN market_currency VARCHAR(8) DEFAULT 'USD'"))
    if not has_col("productos","market_source"):
        db.session.execute(db.text("ALTER TABLE productos ADD COLUMN market_source VARCHAR(80)"))
    if not has_col("productos","market_updated_at"):
        db.session.execute(db.text("ALTER TABLE productos ADD COLUMN market_updated_at VARCHAR(32)"))
    db.session.commit()
    print("upgrade_v8: columnas tcg_card_id / market_* añadidas")