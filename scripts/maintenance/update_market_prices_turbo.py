import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from sqlalchemy import text
from models import db
try:
    from app import create_app
except Exception:
    create_app = None
from services.market_price_service import MarketPriceService
from typing import List, Optional, Tuple

def list_set_codes() -> List[str]:
    rows = db.session.execute(text("""
        SELECT DISTINCT lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1)) AS set_code
        FROM productos
        WHERE categoria='tcg' AND tcg_card_id IS NOT NULL AND tcg_card_id<>'' AND instr(tcg_card_id,'-')>0
    """)).fetchall()
    return [r[0] for r in rows if r and r[0]]

def update_one_set(sc: str, sleep: float, max_age_days: int) -> Tuple[str,int]:
    svc = MarketPriceService()
    n = svc.update_prices_by_set(sc, sleep=sleep, max_age_days=(max_age_days or None))
    return sc, n

def run(set_codes: Optional[List[str]], workers: int = 4, sleep: float = 0.0, max_age_days: int = 7):
    app = None
    if create_app:
        try: app = create_app()
        except Exception: app = None
    if app is None:
        from flask import Flask
        proj = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        db_file = os.path.join(proj, "store.db")
        app = Flask(__name__)
        app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_file}"
        app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
        db.init_app(app)

    total = 0
    with app.app_context():
        if not set_codes:
            set_codes = list_set_codes()
        with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
            futs = [ex.submit(update_one_set, sc, sleep, max_age_days) for sc in set_codes]
            for f in as_completed(futs):
                try:
                    sc, n = f.result()
                    print(f"[{sc}] updated: {n}")
                    total += n
                except Exception as e:
                    print(f"[ERR] {e}")
        print(f"Total updated: {total}")
        return total

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", dest="set_code", default=None, help="sv1,sv2 (comma separated)")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--sleep", type=float, default=0.0)
    ap.add_argument("--max-age", dest="max_age", type=int, default=7)
    args = ap.parse_args()
    sets = [s.strip().lower() for s in (args.set_code or "").split(",") if s.strip()] if args.set_code else None
    run(sets, workers=args.workers, sleep=args.sleep, max_age_days=args.max_age)
