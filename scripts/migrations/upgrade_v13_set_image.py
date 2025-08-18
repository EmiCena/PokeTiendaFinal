# scripts/migrations/upgrade_v13_set_image.py
import os
from sqlalchemy import text
from models import db

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
    from flask import Flask
    proj_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    db_file = os.path.join(proj_root, "store.db")
    flask_app = Flask(__name__)
    flask_app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_file}"
    flask_app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    db.init_app(flask_app)

with flask_app.app_context():
    cols = [r[1] for r in db.session.execute(text("PRAGMA table_info(pack_rules)")).fetchall()]
    if "set_image_url" not in cols:
        db.session.execute(text("ALTER TABLE pack_rules ADD COLUMN set_image_url TEXT"))
        db.session.commit()
        print("v13: pack_rules.set_image_url added")
    else:
        print("v13: pack_rules.set_image_url already present")
