import os, argparse
from models import db
try:
    from app import create_app
except Exception:
    create_app = None
from services.market_price_service import MarketPriceService
def main(set_code: str, limit: int, sleep: float):
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
    with app.app_context():
        if not os.getenv("POKEMONTCG_API_KEY"):
            print("WARN: POKEMONTCG_API_KEY no seteada.")
        svc = MarketPriceService()
        n = svc.update_prices(set_code=set_code or None, limit=(limit or None), sleep=sleep)
        print(f"Actualizadas {n} cartas{(' del set '+set_code) if set_code else ''}.")
if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", dest="set_code", default=None)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--sleep", type=float, default=0.25)
    args = ap.parse_args()
    main(args.set_code, args.limit if args.limit>0 else 0, args.sleep)
