# scripts/utils/make_admin.py
import os
import argparse
from sqlalchemy import text
from models import db
try:
    from app import create_app
except Exception:
    create_app = None

def main(email: str, password: str, only_flag: bool):
    # Levanta la app (usa la misma DB que tu app)
    app = None
    if create_app:
        try:
            app = create_app()
        except Exception:
            app = None
    if app is None:
        from flask import Flask
        proj_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        db_file = os.path.join(proj_root, "store.db")
        app = Flask(__name__)
        app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_file}"
        app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
        db.init_app(app)

    with app.app_context():
        # Asegura tablas base
        db.create_all()

        # Asegura columna is_admin en users (si faltara)
        cols = [r[1] for r in db.session.execute(text("PRAGMA table_info(users)")).fetchall()]
        if "is_admin" not in cols:
            db.session.execute(text("ALTER TABLE users ADD COLUMN is_admin INTEGER DEFAULT 0"))
            db.session.commit()
            print("INFO: columna users.is_admin creada.")

        from models import User

        u = User.query.filter_by(email=email.lower()).first()
        if not u:
            u = User(email=email.lower())
            if hasattr(u, "set_password"):
                u.set_password(password)
            else:
                # si tu modelo usara otro método, ajusta aquí
                raise RuntimeError("User.set_password no existe en tu modelo.")
            u.is_admin = True
            db.session.add(u)
            db.session.commit()
            print(f"Admin creado: {email}")
        else:
            if not only_flag:
                if hasattr(u, "set_password"):
                    u.set_password(password)
                else:
                    raise RuntimeError("User.set_password no existe en tu modelo.")
            u.is_admin = True
            db.session.add(u)
            db.session.commit()
            print(f"Admin actualizado: {email} (is_admin=True{', password reset' if not only_flag else ''})")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Crear/actualizar usuario admin")
    parser.add_argument("--email", required=True, help="Email del admin")
    parser.add_argument("--password", required=False, help="Contraseña del admin")
    parser.add_argument("--only-flag", action="store_true", help="Solo marcar is_admin=True sin cambiar contraseña")
    args = parser.parse_args()

    if not args.only_flag and not args.password:
        parser.error("--password es requerido (o usa --only-flag para no cambiarla)")
    main(args.email, args.password or "", args.only_flag)