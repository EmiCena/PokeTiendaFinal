from app import create_app
from models import db

app = create_app()
with app.app_context():
    def has_col(table, col):
        rows = db.session.execute(db.text(f"PRAGMA table_info({table})")).fetchall()
        cols = [r[1] for r in rows]
        return col in cols

    if not has_col("users","full_name"):
        db.session.execute(db.text("ALTER TABLE users ADD COLUMN full_name VARCHAR(200)"))
    if not has_col("users","ship_address"):
        db.session.execute(db.text("ALTER TABLE users ADD COLUMN ship_address VARCHAR(400)"))

    if not has_col("productos","categoria"):
        db.session.execute(db.text("ALTER TABLE productos ADD COLUMN categoria VARCHAR(50) DEFAULT 'general'"))
    for col, sqltype in [
        ("expansion","VARCHAR(120)"), ("rarity","VARCHAR(120)"),
        ("language","VARCHAR(30)"), ("condition","VARCHAR(60)"),
        ("card_number","VARCHAR(40)")
    ]:
        if not has_col("productos", col):
            db.session.execute(db.text(f"ALTER TABLE productos ADD COLUMN {col} {sqltype}"))
    db.session.commit()

    exists = db.session.execute(db.text("SELECT name FROM sqlite_master WHERE type='table' AND name='product_fts'")).fetchone()
    if not exists:
        db.session.execute(db.text("""
            CREATE VIRTUAL TABLE product_fts USING fts5(
              nombre, descripcion, content='productos', content_rowid='id'
            );
        """))
        db.session.execute(db.text("""
            INSERT INTO product_fts(rowid, nombre, descripcion)
            SELECT id, COALESCE(nombre,''), COALESCE(descripcion,'') FROM productos;
        """))
        db.session.execute(db.text("""
        CREATE TRIGGER productos_ai AFTER INSERT ON productos BEGIN
          INSERT INTO product_fts(rowid, nombre, descripcion) VALUES (new.id, COALESCE(new.nombre,''), COALESCE(new.descripcion,''));
        END;"""))
        db.session.execute(db.text("""
        CREATE TRIGGER productos_ad AFTER DELETE ON productos BEGIN
          INSERT INTO product_fts(product_fts, rowid, nombre, descripcion) VALUES('delete', old.id, '', '');
        END;"""))
        db.session.execute(db.text("""
        CREATE TRIGGER productos_au AFTER UPDATE ON productos BEGIN
          INSERT INTO product_fts(product_fts, rowid, nombre, descripcion) VALUES('delete', old.id, '', '');
          INSERT INTO product_fts(rowid, nombre, descripcion) VALUES (new.id, COALESCE(new.nombre,''), COALESCE(new.descripcion,''));
        END;"""))
        db.session.commit()
        print("FTS5 creado y poblado.")
    else:
        print("FTS5 ya existe.")

    print("Upgrade v6 listo.")
