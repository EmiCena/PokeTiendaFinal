# packs_bp.py
from datetime import date

from flask import (
    Blueprint, render_template, request, session,
    make_response, redirect, url_for, abort
)
from flask_login import current_user, login_required
from sqlalchemy import func, or_

from models import db, PokemonProducto, UserCard

packs_bp = Blueprint("packs_bp", __name__, url_prefix="/packs")

def _no_store(resp):
    resp.headers["Cache-Control"] = "no-store, max-age=0"
    resp.headers["Pragma"] = "no-cache"
    resp.headers["Expires"] = "0"
    return resp

# --------- helpers (sesión como fallback para anónimos) ----------
def _get_collection_session():
    col = session.get("collection", {})
    return {str(k): int(v) for k, v in col.items()}

def _save_collection_session(col):
    session["collection"] = {str(k): int(v) for k, v in col.items()}

def _add_to_collection_session(pid, inc=1):
    col = _get_collection_session()
    key = str(pid)
    col[key] = int(col.get(key, 0)) + int(inc)
    _save_collection_session(col)

# --------- queries ----------
def _base_q():
    return (
        PokemonProducto.query
        .filter(
            PokemonProducto.categoria == "tcg",
            PokemonProducto.stock > 0,
            PokemonProducto.image_url.isnot(None),
            PokemonProducto.image_url != ""
        )
    )

def _pick_random(q, n):
    return q.order_by(func.random()).limit(n).all()

def _draw_random_pack(set_code=None):

    def _rare_plus_q(base):
        rl = func.lower(PokemonProducto.rarity)
        return (
            base.filter(
                PokemonProducto.rarity.isnot(None),
                PokemonProducto.rarity != "",
                or_(
                    rl.like("rare%"),                  # rare, rare holo, rare ex, etc.
                rl.like("%holo%"),                 # holo rare, rare holo vstar...
                rl.like("%ultra%"),                # ultra rare / rare ultra
                rl.like("%illustration%"),         # Illustration Rare / Special Illustration Rare
                rl.like("%double rare%"),          # Double Rare (RR)
                rl.like("%special illustration%"), # SIR explícito
                rl.like("%hyper%"),                # Hyper Rare
                rl.like("%secret%"),               # Secret Rare
                rl.like("%gold%"),                 # Gold (suele ser secret)
                rl.like("%legend%"),               # LEGEND
                rl.like("%lv.x%"), rl.like("%lv x%"),  # Lv.X variantes
                rl.like("%gx%"), rl.like("%ex%"),  # GX / EX
                rl.like("%vmax%"), rl.like("%v-star%"), rl.like("%vstar%"),  # VMAX / VSTAR
                rl.like("%prism%"),                # Prism Star
                rl.like("%radiant%"),              # Radiant
                rl.like("%full art%"),             # Full Art
                rl.like("%trainer gallery%"),      # Trainer Gallery
                rl.like("%amazing%"),              # Amazing Rare
                rl.like("%shiny%"),                # Shiny Rare
            )
        )
    )

    base = _base_q()
    if set_code:
        base = base.filter(PokemonProducto.expansion == set_code)

    commons = _pick_random(base.filter(PokemonProducto.rarity.ilike("common")), 6)
    if len(commons) < 6:
        extra = _pick_random(base, 6 - len(commons))
        commons.extend([x for x in extra if x not in commons])

    uncommons = _pick_random(base.filter(PokemonProducto.rarity.ilike("uncommon")), 3)
    if len(uncommons) < 3:
        extra = _pick_random(base, 3 - len(uncommons))
        uncommons.extend([x for x in extra if x not in uncommons and x not in commons])

    rares_q = _rare_plus_q(base)
    rares = _pick_random(rares_q, 1)
    if not rares:
        # Fallback: al menos intenta “rare%”
        rares = _pick_random(base.filter(func.lower(PokemonProducto.rarity).like("rare%")), 1)
        if not rares:
            # Último recurso: cualquiera
            rares = _pick_random(base, 1)
    return commons + uncommons + rares

# --------- vistas ----------
@packs_bp.get("/", endpoint="packs_home")
def packs_home():
    exps = (
        db.session.query(PokemonProducto.expansion)
        .filter(
            PokemonProducto.categoria == "tcg",
            PokemonProducto.expansion.isnot(None),
            PokemonProducto.expansion != ""
        )
        .distinct()
        .all()
    )
    sets = []
    today = date.today().isoformat()
    for (exp,) in exps:
        sample = (
            _base_q()
            .filter(PokemonProducto.expansion == exp)
            .with_entities(PokemonProducto.image_url, PokemonProducto.nombre)
            .first()
        )
        img = sample[0] if sample else None
        sess_key = f"opened:{exp}:{today}"
        opened_today = session.get(sess_key, False)
        sets.append({
            "set_name": exp,
            "set_code": exp,
            "image": img,
            "daily": (not opened_today),
            "bonus": 0,
        })
    resp = make_response(render_template("packs.html", sets=sets, opened_set=None))
    return _no_store(resp)

@packs_bp.route("/open", methods=["POST", "GET"], endpoint="packs_open")
def packs_open():
    set_code = request.values.get("set") or ""

    # marca “abierto hoy” (si usas regla de 1 diario)
    today = date.today().isoformat()
    sess_key = f"opened:{set_code}:{today}"
    session[sess_key] = True

    # sorteo
    pack = _draw_random_pack(set_code=set_code)

    # dup + persistencia
    dup_points = 0
    cards = []
    seen_in_this_pack = set()
    ids = [int(p.id) for p in pack]

    if current_user.is_authenticated:
        # Trae lo que ya tiene el usuario para estos ids
        rows = (
            UserCard.query
            .filter(UserCard.user_id == current_user.id, UserCard.product_id.in_(ids))
            .all()
        )
        existing = {r.product_id: r for r in rows}

        for p in pack:
            pid = int(p.id)
            already = (pid in existing) or (pid in seen_in_this_pack)
            if already:
                dup_points += 1

            # upsert
            row = existing.get(pid)
            if row:
                row.qty = int(row.qty) + 1
            else:
                row = UserCard(user_id=current_user.id, product_id=pid, qty=1)
                db.session.add(row)
                existing[pid] = row

            seen_in_this_pack.add(pid)

            cards.append({
                "id": pid,
                "name": getattr(p, "nombre", None) or getattr(p, "name", f"Card {p.id}"),
                "image_url": getattr(p, "image_url", None),
                "rarity": getattr(p, "rarity", None),
                "tcg_card_id": getattr(p, "tcg_card_id", None),
                "duplicate": already,
            })
        db.session.commit()
    else:
        # anónimo: usa sesión
        col_before = _get_collection_session()
        for p in pack:
            pid = int(p.id)
            already = (str(pid) in col_before) or (pid in seen_in_this_pack)
            if already:
                dup_points += 1
            seen_in_this_pack.add(pid)
            _add_to_collection_session(pid, 1)
            cards.append({
                "id": pid,
                "name": getattr(p, "nombre", None) or getattr(p, "name", f"Card {p.id}"),
                "image_url": getattr(p, "image_url", None),
                "rarity": getattr(p, "rarity", None),
                "tcg_card_id": getattr(p, "tcg_card_id", None),
                "duplicate": already,
            })

    resp = make_response(render_template(
        "packs.html",
        opened_set=set_code or None,
        cards=cards,
        dup_points=dup_points,
        sets=[]
    ))
    return _no_store(resp)

@packs_bp.get("/collection", endpoint="collection")
@login_required
def collection():
    # filtros
    exp = (request.args.get("exp") or "").strip()
    rare = (request.args.get("rare") or "").strip()
    qstr = (request.args.get("q") or "").strip()
    sort = (request.args.get("sort") or "name").strip()

    base = (
        db.session.query(UserCard, PokemonProducto)
        .join(PokemonProducto, PokemonProducto.id == UserCard.product_id)
        .filter(UserCard.user_id == current_user.id)
    )

    # facets (sin filtros aplicados, solo por usuario)
    exps = (
        db.session.query(PokemonProducto.expansion)
        .join(UserCard, UserCard.product_id == PokemonProducto.id)
        .filter(UserCard.user_id == current_user.id,
                PokemonProducto.expansion.isnot(None),
                PokemonProducto.expansion != "")
        .distinct().order_by(PokemonProducto.expansion.asc()).all()
    )
    rares = (
        db.session.query(PokemonProducto.rarity)
        .join(UserCard, UserCard.product_id == PokemonProducto.id)
        .filter(UserCard.user_id == current_user.id,
                PokemonProducto.rarity.isnot(None),
                PokemonProducto.rarity != "")
        .distinct().order_by(PokemonProducto.rarity.asc()).all()
    )
    exp_facets = [r[0] for r in exps]
    rare_facets = [r[0] for r in rares]

    # aplica filtros
    if exp:
        base = base.filter(PokemonProducto.expansion == exp)
    if rare:
        base = base.filter(func.lower(PokemonProducto.rarity) == rare.lower())
    if qstr:
        like = f"%{qstr}%"
        base = base.filter(
            (PokemonProducto.nombre.ilike(like)) |
            (PokemonProducto.descripcion.ilike(like)) |
            (func.cast(PokemonProducto.id, db.String).ilike(like))
        )

    # orden
    if sort == "qty_desc":
        base = base.order_by(UserCard.qty.desc(), PokemonProducto.nombre.asc())
    elif sort == "qty_asc":
        base = base.order_by(UserCard.qty.asc(), PokemonProducto.nombre.asc())
    elif sort == "rarity":
        base = base.order_by(PokemonProducto.rarity.asc(), PokemonProducto.nombre.asc())
    else:
        base = base.order_by(PokemonProducto.nombre.asc())

    rows = base.all()
    items = [{"product": p, "qty": uc.qty} for (uc, p) in rows]
    total = sum(i["qty"] for i in items)
    unique = len(items)

    resp = make_response(render_template(
        "packs_collection.html",
        items=items, total=total, unique=unique,
        exp=exp, rare=rare, q=qstr, sort=sort,
        exp_facets=exp_facets, rare_facets=rare_facets
    ))
    return _no_store(resp)

@packs_bp.post("/collection/clear", endpoint="collection_clear")
@login_required
def collection_clear():
    UserCard.query.filter_by(user_id=current_user.id).delete()
    db.session.commit()
    return redirect(url_for("packs_bp.collection"))

@packs_bp.get("/admin", endpoint="admin_packs")
def admin_packs():
    if not current_user.is_authenticated:
        return redirect(url_for("login", next=request.path))
    if not getattr(current_user, "is_admin", False):
        abort(403)
    return redirect(url_for("packs_bp.packs_home"))