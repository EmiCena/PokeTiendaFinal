# upgrade_v5.py
from app import create_app
from models import db

app = create_app()
with app.app_context():
    # Detectar si la columna ya existe
    cols = [row[1] for row in db.session.execute(db.text("PRAGMA table_info(productos)")).fetchall()]
    if "categoria" not in cols:
        db.session.execute(db.text('ALTER TABLE productos ADD COLUMN categoria VARCHAR(50) DEFAULT "general"'))
        db.session.commit()
        print('Columna "categoria" aÃ±adida a productos.')
    # Normalizar nulos a "general"
    db.session.execute(db.text('UPDATE productos SET categoria="general" WHERE categoria IS NULL'))
    db.session.commit()
    print("Upgrade v5 listo.")
