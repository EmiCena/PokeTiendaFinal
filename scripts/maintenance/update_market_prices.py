# scripts/maintenance/update_market_prices.py
import os, time, argparse, json, random
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from app import create_app
from models import db, PokemonProducto

POKEMON_API = "https://api.pokemontcg.io/v2/cards"
API_KEY = os.getenv("POKEMONTCG_API_KEY")  # recomendado

def make_session():
    s = requests.Session()
    retry = Retry(total=6, connect=3, read=3, status=3,
                  backoff_factor=1.5,
                  allowed_methods=("GET",), status_forcelist=(429,500,502,503,504))
    s.mount("https://", HTTPAdapter(max_retries=retry))
    h = {"Accept":"application/json","User-Agent":"PokeShopPriceUpdater/1.0"}
    if API_KEY: h["X-Api-Key"]=API_KEY
    s.headers.update(h)
    return s

S = make_session()

def best_market_price(card_json) -> float | None:
    tp = ((card_json or {}).get("tcgplayer") or {})
    prices = tp.get("prices") or {}
    order = ["holofoil","reverseHolofoil","normal","1stEditionHolofoil","unlimitedHolofoil","rareHoloEX"]
    vals = []
    for k in order:
        v = (prices.get(k) or {}).get("market")
        if v: 
            try: vals.append(float(v))
            except: pass
    if not vals:
        # fallback: máximo disponible
        for k, obj in prices.items():
            v = obj.get("market")
            if v:
                try: vals.append(float(v))
                except: pass
    return round(max(vals),2) if vals else None

def update_product(p: PokemonProducto) -> bool:
    if not p.tcg_card_id: 
        return False
    try:
        r = S.get(f"{POKEMON_API}/{p.tcg_card_id}", timeout=(10, 60))
        if r.status_code == 429:
            time.sleep(8); return False
        r.raise_for_status()
        data = r.json().get("data") or {}
        price = best_market_price(data)
        if price:
            p.market_price = price
            p.market_currency = "USD"
            p.market_source = "pokemontcg.io/tcgplayer.market"
            p.market_updated_at = time.strftime("%Y-%m-%d %H:%M:%S")
            return True
    except Exception as e:
        print(f"[skip] {p.id} ({p.tcg_card_id}): {e}")
    return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=300, help="n° de cartas a refrescar")
    ap.add_argument("--only-older-than", type=int, default=24, help="horas desde última actualización")
    args = ap.parse_args()

    app = create_app()
    with app.app_context():
        # elegimos TCG con id, en stock, más antiguos primero
        q = db.session.query(PokemonProducto).filter(
            PokemonProducto.categoria=="tcg",
            PokemonProducto.tcg_card_id.isnot(None),
            PokemonProducto.stock > 0
        ).order_by(db.text("COALESCE(market_updated_at,'0000-00-00 00:00:00') ASC")).limit(args.limit).all()

        n_ok = 0
        for p in q:
            if update_product(p):
                n_ok += 1
            if (n_ok % 20)==0:
                db.session.commit()
                time.sleep(0.6)
        db.session.commit()
        print(f"Actualizadas {n_ok} / {len(q)}")

if __name__ == "__main__":
    main()