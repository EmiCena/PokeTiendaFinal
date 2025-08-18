from app import create_app
from models import db, PokemonProducto
from ftfy import fix_text

CANON = {
    "fuego": "fuego",
    "agua": "agua",
    "electrico": "eléctrico",
    "eléctrico": "eléctrico",
    "electrico/eléctrico": "eléctrico",  # por si vienen mezclas raras
    "planta": "planta",
    "dragon": "dragón",
    "dragón": "dragón",
    "psiquico": "psíquico",
    "psíquico": "psíquico",
    "siniestro": "siniestro",
    "lucha": "lucha",
    "acero": "acero",
    "incoloro": "incoloro",
    "roca": "roca",
    "hielo": "hielo",
}

TEXT_COLS = ["nombre", "descripcion", "tipo", "expansion", "rarity", "language", "condition", "card_number"]

def looks_mojibake(s: str) -> bool:
    return s and any(mark in s for mark in ("Ã", "Â", "â€", "�"))

def fix_str(s: str) -> str:
    if not s:
        return s
    out = fix_text(s)  # repara cp1252/utf-8 confusiones comunes
    # recorta y normaliza whitespace
    out = " ".join(out.split())
    return out

def canon_tipo(s: str) -> str:
    if not s:
        return s
    t = fix_text(s).strip().lower()
    t = t.replace("é", "é").replace("í", "í").replace("ó","ó")  # normaliza combinaciones
    # quita tildes para el lookup clave "electrico","psiquico","dragon".
    base = (
        t.replace("é","e").replace("í","i").replace("ó","o")
         .replace("á","a").replace("ú","u")
    )
    return CANON.get(base, CANON.get(t, s))

app = create_app()
with app.app_context():
    changed_rows = 0
    changed_fields = 0
    rows = PokemonProducto.query.all()
    for p in rows:
        before = {}
        after  = {}
        for col in TEXT_COLS:
            val = getattr(p, col)
            if not val:
                continue
            new = fix_str(val) if looks_mojibake(val) or col in ("nombre","descripcion") else val
            if col == "tipo":
                new = canon_tipo(new)
            if new != val:
                before[col] = val
                after[col] = new
                setattr(p, col, new)
                changed_fields += 1
        if after:
            changed_rows += 1

    if changed_fields:
        db.session.commit()
        print(f"Productos modificados: {changed_rows} | Campos actualizados: {changed_fields}")
        # Rebuild FTS5 (si existe)
        try:
            db.session.execute(db.text("INSERT INTO product_fts(product_fts) VALUES('rebuild')"))
            db.session.commit()
            print("FTS5 reconstruido.")
        except Exception as e:
            print("Aviso: no se pudo reconstruir FTS5 (quizá no existe). Detalle:", e)
    else:
        print("No había nada para corregir (DB ya limpia).")