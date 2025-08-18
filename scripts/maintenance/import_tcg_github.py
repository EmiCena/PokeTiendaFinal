# -*- coding: utf-8 -*-
"""
Importa cartas TCG desde el repo publico:
  https://github.com/PokemonTCG/pokemon-tcg-data

Descarga cards/en/{set}.json y toma el nombre del set desde sets/en.json (indice global).

Uso (desde la raiz del proyecto):
  python -m scripts.maintenance.import_tcg_github --sets sv1 sv2 swsh7
"""
import argparse
import time
import random
import requests

from app import create_app
from models import db, PokemonProducto

RAW_BASE = "https://raw.githubusercontent.com/PokemonTCG/pokemon-tcg-data/master"

TYPE_MAP = {
    "Fire":"fuego","Water":"agua","Lightning":"eléctrico","Grass":"planta",
    "Dragon":"dragón","Psychic":"psíquico","Darkness":"siniestro","Fighting":"lucha",
    "Metal":"acero","Colorless":"incoloro","Fairy":"hada","Ice":"hielo","Rock":"roca",
}

SETS_INDEX_CACHE = None

def fetch_json(url: str):
    try:
        r = requests.get(url, timeout=30)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        print("[fetch] {} -> {}".format(url, e))
        return None

def get_sets_index() -> dict:
    """Devuelve dict { set_id_lower: set_name } usando sets/en.json."""
    global SETS_INDEX_CACHE
    if SETS_INDEX_CACHE is not None:
        return SETS_INDEX_CACHE
    url = "{}/sets/en.json".format(RAW_BASE)
    data = fetch_json(url) or []
    idx = {}
    for s in data:
        sid = (s.get("id") or "").lower()
        name = s.get("name") or sid.upper()
        if sid:
            idx[sid] = name
    SETS_INDEX_CACHE = idx
    return idx

def load_set_cards(set_code: str):
    """Carga las cartas del set y obtiene el nombre desde el indice global."""
    idx = get_sets_index()
    set_name = idx.get(set_code.lower(), set_code.upper())
    cards_url = "{}/cards/en/{}.json".format(RAW_BASE, set_code)
    cards = fetch_json(cards_url) or []
    if not isinstance(cards, list):
        cards = []
    print("Set {}: {} cartas, nombre: {}".format(set_code, len(cards), set_name))
    return cards, set_name

def extract_price(c: dict) -> float:
    price = 9.99
    tp = c.get("tcgplayer") or {}
    prices = tp.get("prices") or {}
    for k in ["holofoil","reverseHolofoil","normal","1stEditionHolofoil","unlimitedHolofoil","rareHoloEX"]:
        p = prices.get(k) or {}
        if "market" in p and p["market"]:
            try:
                price = max(2.99, float(p["market"]))
                break
            except Exception:
                pass
    return round(price, 2)

def upsert_card(c: dict, set_name: str) -> bool:
    tid = c.get("id")  # ej: "sv2-12"
    if not tid:
        return False

    # evita duplicados por id real de carta
    if PokemonProducto.query.filter_by(tcg_card_id=tid).first():
        return False

    name = c.get("name","").strip()
    number = c.get("number","")
    total = c.get("setTotal") or "?"
    card_number = "{}/{}".format(number, total)

    tipos = c.get("types") or ["Colorless"]
    tipo_api = tipos[0] if tipos else "Colorless"
    tipo = TYPE_MAP.get(tipo_api, "incoloro")

    imgs = c.get("images") or {}
    img = imgs.get("large") or imgs.get("small")

    rarity = c.get("rarity") or ""
    expansion = set_name
    language = "EN"
    condition = "NM"

    price = extract_price(c)
    stock = random.randint(1, 20)

    payload = dict(
        nombre="{} - {} {}".format(name, set_name, card_number),
        tipo=tipo, categoria="tcg",
        precio_base=price, stock=stock,
        image_url=img,
        # descripcion sin caracteres especiales para evitar mojibake en el .py
        descripcion="Carta TCG - Expansion: {} - Rareza: {} - Idioma: {} - Nro: {}".format(
            expansion, rarity, language, card_number
        ),
        expansion=expansion, rarity=rarity, language=language,
        condition=condition, card_number=card_number,
        tcg_card_id=tid,
    )

    p = PokemonProducto(**payload)  # IMPORTANT: kwargs
    db.session.add(p)
    return True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="*", required=True, help="Codigos de set: sv1 sv2 sv3 sv4 swsh7 ...")
    args = ap.parse_args()

    app = create_app()
    added = 0
    with app.app_context():
        for code in args.sets:
            cards, set_name = load_set_cards(code)
            for c in cards:
                if upsert_card(c, set_name):
                    added += 1
            db.session.commit()
            time.sleep(0.5)
    print("Import completado. Cartas agregadas: {}".format(added))

if __name__ == "__main__":
    main()