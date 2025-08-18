# scripts/maintenance/dedupe_tcg_by_id.py
import re, argparse
from app import create_app
from models import db, PokemonProducto, OrderItem
from sqlalchemy import text

RE_IMG = re.compile(r"images\.pokemontcg\.io/([a-z0-9]+)/(\d+)(?:_|\.|/)", re.I)

def guess_card_id_from_image(url: str):
    if not url: return None
    m = RE_IMG.search(url)
    if not m: return None
    return f"{m.group(1).lower()}-{m.group(2)}"

def backfill_missing_ids():
    rows = db.session.query(PokemonProducto).filter(
        PokemonProducto.categoria=="tcg",
        (PokemonProducto.tcg_card_id.is_(None)) | (PokemonProducto.tcg_card_id=="")
    ).all()
    changed = 0
    for p in rows:
        cid = guess_card_id_from_image(p.image_url or "")
        if cid:
            p.tcg_card_id = cid
            changed += 1
    if changed: db.session.commit()
    return changed

def pick_keeper(items):
    items = sorted(items, key=lambda x: (0 if (x.market_price is None) else 1, x.id, x.stock or 0), reverse=True)
    return items[0]

def dedupe(dry_run=False):
    rows = db.session.query(PokemonProducto).filter(
        PokemonProducto.categoria=="tcg",
        PokemonProducto.tcg_card_id.isnot(None),
        PokemonProducto.tcg_card_id != ""
    ).all()
    groups = {}
    for p in rows: groups.setdefault(p.tcg_card_id, []).append(p)
    to_delete = []; n_groups = 0
    for cid, items in groups.items():
        if len(items) <= 1: continue
        n_groups += 1
        keep = pick_keeper(items)
        losers = [x for x in items if x.id != keep.id]
        keep.stock = (keep.stock or 0) + sum((x.stock or 0) for x in losers)
        loser_ids = [x.id for x in losers]
        if loser_ids:
            (db.session.query(OrderItem)
               .filter(OrderItem.product_id.in_(loser_ids))
               .update({OrderItem.product_id: keep.id}, synchronize_session=False))
        to_delete.extend(loser_ids)
    if not dry_run and to_delete:
        (db.session.query(PokemonProducto)
           .filter(PokemonProducto.id.in_(to_delete))
           .delete(synchronize_session=False))
        db.session.commit()
    return n_groups, len(to_delete)

def ensure_unique_index():
    try:
        db.session.execute(text(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_product_tcg_id_unique "
            "ON productos(tcg_card_id) WHERE tcg_card_id IS NOT NULL AND tcg_card_id <> ''"
        ))
        db.session.commit()
    except Exception as e:
        print("Indice unico:", e)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    app = create_app()
    with app.app_context():
        print("Backfill ids...")
        ch = backfill_missing_ids()
        print("  ids completados:", ch)
        print("Dedupe...")
        g, d = dedupe(dry_run=args.dry_run)
        print("  grupos:", g, "eliminados:", d if not args.dry_run else f"(sim) {d}")
        print("Indice unico...")
        ensure_unique_index()
        print("OK")
if __name__ == "__main__": main()
