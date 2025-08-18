from app import create_app
from models import db, PokemonProducto
from ftfy import fix_text

def needs_fix(s: str) -> bool:
    return s and ("Ã" in s or "Â" in s or "â€" in s or "�" in s)

app = create_app()
with app.app_context():
    changed = 0
    for p in PokemonProducto.query.all():
        if needs_fix(p.nombre):
            p.nombre = fix_text(p.nombre); changed += 1
        if needs_fix(p.descripcion):
            p.descripcion = fix_text(p.descripcion); changed += 1
    if changed:
        db.session.commit()
    print("Registros corregidos:", changed)