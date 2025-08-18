# scripts/maintenance/fix_tcg_expansion_names.py
import requests
from app import create_app
from models import db, PokemonProducto

RAW_BASE = "https://raw.githubusercontent.com/PokemonTCG/pokemon-tcg-data/master"

def fetch_sets_index():
    url = f"{RAW_BASE}/sets/en.json"
    r = requests.get(url, timeout=30)
    r.raise_for_status()
    data = r.json()
    # devuelve dict { "sv1": "Scarlet & Violet", "sv2": "Paldea Evolved", ... }
    return { (s.get("id") or "").lower(): (s.get("name") or "") for s in data }

def main():
    app = create_app()
    with app.app_context():
        idx = fetch_sets_index()
        changed = 0
        for code, name in idx.items():
            if not name:
                continue
            code_upper = code.upper()
            # fila ORM
            rows = PokemonProducto.query.filter(
                PokemonProducto.categoria=="tcg",
                PokemonProducto.expansion.in_([code, code_upper])
            ).all()
            for p in rows:
                if p.expansion != name:
                    p.expansion = name
                    changed += 1
        if changed:
            db.session.commit()
            try:
                db.session.execute(db.text("INSERT INTO product_fts(product_fts) VALUES('rebuild')"))
                db.session.commit()
            except Exception:
                pass
        print(f"Expansiones actualizadas: {changed}")

if __name__ == "__main__":
    main()