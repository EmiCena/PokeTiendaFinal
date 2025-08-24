import os
from sqlalchemy import text
from models import db
try:
    from app import create_app
except Exception:
    create_app = None
flask_app = None
if create_app:
    try: flask_app = create_app()
    except Exception: flask_app = None
if flask_app is None:
    from flask import Flask
    proj = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    db_file = os.path.join(proj, "store.db")
    flask_app = Flask(__name__)
    flask_app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_file}"
    flask_app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    db.init_app(flask_app)
with flask_app.app_context():
    cols = [r[1] for r in db.session.execute(text("PRAGMA table_info(productos)")).fetchall()]
    def addcol(name, decl):
        if name not in cols:
            db.session.execute(text(f"ALTER TABLE productos ADD COLUMN {name} {decl}"))
    addcol("market_price","REAL")
    addcol("market_currency","VARCHAR(8)")
    addcol("market_source","VARCHAR(32)")
    addcol("market_updated_at","TEXT")
    db.session.commit()
    print("v14: columnas de mercado listas en productos")
