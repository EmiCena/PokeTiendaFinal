# scripts/maintenance/list_tcg_sets.py
"""
Lista sets TCG disponibles en pokemon-tcg-data (GitHub) y los "restantes" que no tienes en tu DB.
Uso (desde la raíz del proyecto):
  python -m scripts.maintenance.list_tcg_sets --show-all
  python -m scripts.maintenance.list_tcg_sets --only-new
  python -m scripts.maintenance.list_tcg_sets --only-new --limit 20
  python -m scripts.maintenance.list_tcg_sets --import-cmd
  # Filtro por prefijo (opcional): sv, swsh, base, xy, etc.
  python -m scripts.maintenance.list_tcg_sets --only-new --prefix sv
"""

import argparse
import requests

from app import create_app
from models import db, PokemonProducto

RAW_BASE = "https://raw.githubusercontent.com/PokemonTCG/pokemon-tcg-data/master"
GH_CARDS_EN = "https://api.github.com/repos/PokemonTCG/pokemon-tcg-data/contents/cards/en"

def fetch_cards_dir_ids():
    """Devuelve ids de sets según los filenames cards/en/*.json (sin extensión)."""
    r = requests.get(GH_CARDS_EN, headers={"User-Agent":"PokeShop/sets-lister"}, timeout=30)
    r.raise_for_status()
    data = r.json()
    ids = []
    for entry in data:
        name = entry.get("name","")
        if name.endswith(".json"):
            ids.append(name[:-5])  # sin .json
    return sorted(ids)

def fetch_sets_index():
    """Devuelve dict { set_id_lower: set_name } usando sets/en.json."""
    url = f"{RAW_BASE}/sets/en.json"
    r = requests.get(url, headers={"User-Agent":"PokeShop/sets-lister"}, timeout=30)
    r.raise_for_status()
    data = r.json()
    idx = {}
    for s in data:
        sid = (s.get("id") or "").lower()
        name = s.get("name") or sid.upper()
        if sid:
            idx[sid] = name
    return idx

def existing_set_prefixes_in_db() -> set[str]:
    """Extrae prefijos de set desde tcg_card_id (antes del '-') de productos existentes."""
    prefixes = set()
    rows = (
        db.session.query(PokemonProducto.tcg_card_id)
        .filter(
            PokemonProducto.categoria=="tcg",
            PokemonProducto.tcg_card_id.isnot(None),
            PokemonProducto.tcg_card_id != ""
        )
        .all()
    )
    for (cid,) in rows:
        pref = (cid.split("-")[0]).lower() if "-" in cid else cid.lower()
        if pref:
            prefixes.add(pref)
    return prefixes

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show-all", action="store_true", help="Muestra todos los sets disponibles (id y nombre).")
    ap.add_argument("--only-new", action="store_true", help="Muestra solo los sets que no aparecen en tu DB.")
    ap.add_argument("--limit", type=int, default=0, help="Limita la cantidad impresa (solo para --only-new).")
    ap.add_argument("--import-cmd", action="store_true", help="Imprime el/los comandos de importación para los 'restantes'.")
    ap.add_argument("--prefix", type=str, default="", help="Filtra por prefijo (sv, swsh, base, xy, etc.).")
    args = ap.parse_args()

    app = create_app()
    with app.app_context():
        cards_ids = fetch_cards_dir_ids()            # p.ej. ['sv1','sv2','sv3','swsh7','zsv10pt5',...]
        if args.prefix:
            cards_ids = [sid for sid in cards_ids if sid.lower().startswith(args.prefix.lower())]

        idx_names = fetch_sets_index()               # mapea a nombres bonitos si existen
        exist_prefixes = existing_set_prefixes_in_db()

        enriched = [(sid, idx_names.get(sid.lower(), sid.upper())) for sid in cards_ids]

        if args.show_all and not args.only_new:
            print("Sets disponibles (según GitHub cards/en/*.json):")
            for sid, name in enriched:
                print(f"{sid}\t{name}")
            print(f"\nTotal: {len(enriched)}")
            return

        remaining = [(sid, idx_names.get(sid.lower(), sid.upper()))
                     for sid in cards_ids if sid.lower() not in exist_prefixes]

        if args.only_new:
            print("Sets restantes (no detectados en tu DB):")
            data = remaining
            if args.limit > 0:
                data = data[:args.limit]
            for sid, name in data:
                print(f"{sid}\t{name}")
            print(f"\nTotal restantes: {len(remaining)} (mostrados: {len(data)})")

        if args.import_cmd:
            if not remaining:
                print("No hay sets restantes por importar (según tcg_card_id presentes en tu DB).")
            else:
                # En bloques de 20 por comodidad
                chunk = 20
                for i in range(0, len(remaining), chunk):
                    ids_chunk = " ".join(sid for sid, _ in remaining[i:i+chunk])
                    print(f"python -m scripts.maintenance.import_tcg_github --sets {ids_chunk}")

if __name__ == "__main__":
    main()