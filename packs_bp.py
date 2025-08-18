# packs_bp.py
from flask import Blueprint, render_template, request, redirect, url_for, flash, current_app
from flask_login import login_required, current_user
from werkzeug.utils import secure_filename
from sqlalchemy import text
from uuid import uuid4
import os, time

from models import db, PokemonProducto
from models_packs import PackAllowance, PackRule
from services.packs_service import open_pack, today_str, STAR_POINTS, rarity_tier

packs_bp = Blueprint("packs_bp", __name__)

def _tbl() -> str:
    try:
        return PokemonProducto.__tablename__
    except Exception:
        return "productos"

@packs_bp.get("/packs")
@login_required
def packs_home():
    tbl = _tbl()
    rows = db.session.execute(text(
        f"""
        SELECT DISTINCT substr(tcg_card_id,1, instr(tcg_card_id,'-')-1) AS set_code
        FROM {tbl}
        WHERE categoria='tcg'
          AND tcg_card_id IS NOT NULL AND tcg_card_id<>''
          AND instr(tcg_card_id,'-')>0
        """
    )).fetchall()
    set_codes = [r[0] for r in rows if r and r[0]]

    allowances = {a.set_code: a for a in PackAllowance.query.filter_by(user_id=current_user.id).all()}
    today = today_str()
    is_admin = getattr(current_user, "is_admin", False)

    data = []
    for sc in sorted(set_codes):
        a = allowances.get(sc)
        daily_available = True if is_admin else ((not a) or (a.last_daily_open_date != today))
        bonus = a.bonus_tokens if a else 0

        n = db.session.execute(text(
            f"""
            SELECT expansion, COUNT(*) c
            FROM {tbl}
            WHERE categoria='tcg'
              AND lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1))=:sc
            GROUP BY expansion
            ORDER BY c DESC
            LIMIT 1
            """
        ), {"sc": sc.lower()}).fetchone()
        set_name = n[0] if n and n[0] else sc.upper()

        rule = PackRule.query.filter_by(set_code=sc.lower()).first()
        image = getattr(rule, "set_image_url", None) if rule else None
        if not image:
            img_row = db.session.execute(text(
                f"""
                SELECT image_url FROM {tbl}
                WHERE categoria='tcg'
                  AND lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1))=:sc
                  AND image_url IS NOT NULL AND image_url<>''
                LIMIT 1
                """
            ), {"sc": sc.lower()}).fetchone()
            image = img_row[0] if img_row and img_row[0] else None

        data.append({"set_code": sc, "set_name": set_name, "daily": daily_available, "bonus": bonus, "image": image})

    return render_template("packs.html", sets=data)

@packs_bp.post("/packs/open")
@login_required
def packs_open():
    set_code = (request.form.get("set") or "").strip().lower()
    if not set_code:
        flash("Falta set.", "warning")
        return redirect(url_for("packs_bp.packs_home"))

    res = open_pack(current_user.id, set_code, admin_unlimited=getattr(current_user, "is_admin", False))
    if not res.get("ok"):
        flash(res.get("error","No se pudo abrir el pack."), "danger")
        return redirect(url_for("packs_bp.packs_home"))

    cards = res["cards"]; dup_points = res.get("dup_points",0)
    if dup_points:
        flash(f"Has recibido {dup_points} puntos estrella por duplicados.", "info")
    return render_template("packs.html", sets=[], opened_set=set_code, cards=cards, dup_points=dup_points)

@packs_bp.get("/collection")
@login_required
def collection():
    tbl = _tbl()
    rows = db.session.execute(text(
        f"""
        SELECT lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1)) AS set_code,
               COUNT(*) as total
        FROM {tbl}
        WHERE categoria='tcg' AND tcg_card_id IS NOT NULL AND tcg_card_id<>''
          AND instr(tcg_card_id,'-')>0
        GROUP BY set_code
        """
    )).fetchall()
    totals = {r[0]: r[1] for r in rows}

    my_rows = db.session.execute(text(
        "SELECT set_code, COUNT(DISTINCT tcg_card_id) as owned FROM user_cards WHERE user_id=:uid GROUP BY set_code"
    ), {"uid": current_user.id}).fetchall()
    owned = {r[0]: r[1] for r in my_rows}

    names = {}
    for sc in totals.keys():
        n = db.session.execute(text(
            f"""
            SELECT expansion, COUNT(*) c
            FROM {tbl}
            WHERE categoria='tcg'
              AND lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1))=:sc
            GROUP BY expansion ORDER BY c DESC LIMIT 1
            """
        ), {"sc": sc}).fetchone()
        names[sc] = n[0] if n and n[0] else sc.upper()

    row = db.session.execute(text("SELECT COALESCE(SUM(points),0) FROM star_ledgers WHERE user_id=:uid"),
                             {"uid": current_user.id}).fetchone()
    star_points = int(row[0] or 0)

    data = []
    for sc, tot in sorted(totals.items()):
        data.append({"set_code": sc, "set_name": names.get(sc, sc.upper()), "owned": owned.get(sc,0), "total": tot})
    return render_template("collection.html", sets=data, star_points=star_points)

@packs_bp.get("/collection/<string:set_code>")
@login_required
def collection_set(set_code: str):
    sc = (set_code or "").lower()
    tbl = _tbl()

    rows = db.session.execute(text(
        f"""
        SELECT id, tcg_card_id, nombre, rarity, image_url
        FROM {tbl}
        WHERE categoria='tcg'
          AND tcg_card_id IS NOT NULL AND tcg_card_id<>''
          AND lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1))=:sc
        ORDER BY nombre ASC
        """
    ), {"sc": sc}).fetchall()

    my_rows = db.session.execute(text(
        "SELECT tcg_card_id, COUNT(*) as copies FROM user_cards WHERE user_id=:uid AND set_code=:sc GROUP BY tcg_card_id"
    ), {"uid": current_user.id, "sc": sc}).fetchall()
    owned_counts = {r[0]: r[1] for r in my_rows}

    name_row = db.session.execute(text(
        f"""
        SELECT expansion, COUNT(*) c
        FROM {tbl}
        WHERE categoria='tcg'
          AND lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1))=:sc
        GROUP BY expansion ORDER BY c DESC LIMIT 1
        """
    ), {"sc": sc}).fetchone()
    set_name = name_row[0] if name_row and name_row[0] else sc.upper()

    rule = PackRule.query.filter_by(set_code=sc).first()
    set_image = getattr(rule, "set_image_url", None) if rule else None

    cards = []
    for r in rows:
        tcg_id = r[1]
        copies = int(owned_counts.get(tcg_id, 0))
        cards.append({
            "id": r[0],
            "tcg_card_id": tcg_id,
            "name": r[2],
            "rarity": r[3],
            "image_url": r[4],
            "copies": copies,
            "owned": copies > 0,
            "duplicates": max(0, copies - 1),
        })

    total = len(cards)
    owned = sum(1 for c in cards if c["owned"])
    pct = int((owned * 100 / total)) if total else 0

    return render_template("collection_set.html", set_code=sc, set_name=set_name, set_image=set_image,
                           cards=cards, total=total, owned=owned, pct=pct)

@packs_bp.post("/collection/burn")
@login_required
def burn_duplicates():
    tcg_card_id = (request.form.get("tcg_card_id") or "").strip()
    set_code = (request.form.get("set_code") or "").strip().lower()
    if not tcg_card_id or not set_code:
        flash("Faltan datos.", "warning")
        return redirect(url_for("packs_bp.collection_set", set_code=set_code or ""))

    # Trae copias
    cards = db.session.execute(text(
        "SELECT id FROM user_cards WHERE user_id=:uid AND set_code=:sc AND tcg_card_id=:tid"
    ), {"uid": current_user.id, "sc": set_code, "tid": tcg_card_id}).fetchall()
    count = len(cards)
    if count <= 1:
        flash("No tienes duplicados de esa carta.", "info")
        return redirect(url_for("packs_bp.collection_set", set_code=set_code))

    # Puntos por rareza
    tbl = _tbl()
    rrow = db.session.execute(text(f"SELECT rarity FROM {tbl} WHERE tcg_card_id=:tid LIMIT 1"),
                              {"tid": tcg_card_id}).fetchone()
    rarity = (rrow[0] if rrow and rrow[0] else "") if rrow else ""
    points_each = STAR_POINTS.get(rarity_tier(rarity), 1)
    to_burn = count - 1
    total_points = to_burn * points_each

    # Borra copias extra (deja una)
    ids = [r[0] for r in cards][1:]
    for cid in ids:
        db.session.execute(text("DELETE FROM user_cards WHERE id=:id"), {"id": cid})

    # Ledger y star_points si existe la columna
    from models_packs import StarLedger
    from models import User
    db.session.add(StarLedger(user_id=current_user.id, points=total_points,
                              reason=f"Burn duplicados {set_code}:{tcg_card_id} x{to_burn}"))
    u = User.query.get(current_user.id)
    try:
        u.star_points = (getattr(u, "star_points", 0) or 0) + total_points
        db.session.add(u)
    except Exception:
        pass

    db.session.commit()
    flash(f"Has convertido {to_burn} duplicados en {total_points} puntos estrella.", "success")
    return redirect(url_for("packs_bp.collection_set", set_code=set_code))

@packs_bp.route("/admin/packs", methods=["GET","POST"])
def admin_packs():
    from flask import abort

    if not current_user.is_authenticated:
        return redirect(url_for("login", next=request.path))
    if not getattr(current_user, "is_admin", False):
        abort(403)

    if request.method=="POST":
        action = request.form.get("action","")
        set_code = (request.form.get("set_code") or "").lower()
        if action=="save_rule" and set_code:
            rule = PackRule.query.filter_by(set_code=set_code).first() or PackRule(set_code=set_code)
            try: rule.pack_size = int(request.form.get("pack_size") or 10)
            except: rule.pack_size = 10
            rule.weights_json = request.form.get("weights_json") or '{"Common":0.7,"Uncommon":0.25,"Rare":0.05}'
            try: rule.god_chance = float(request.form.get("god_chance") or 0.001)
            except: rule.god_chance = 0.001
            rule.enabled = (request.form.get("enabled")=="on")

            img_url = (request.form.get("set_image_url") or "").strip()
            file = request.files.get("set_image_file")
            exts = {"png","jpg","jpeg","gif","webp"}
            if file and file.filename and "." in file.filename and file.filename.rsplit(".",1)[1].lower() in exts:
                fn = secure_filename(file.filename)
                unique = f"{int(time.time())}_{uuid4().hex[:8]}_{fn}"
                os.makedirs(current_app.config["UPLOAD_FOLDER"], exist_ok=True)
                path = os.path.join(current_app.config["UPLOAD_FOLDER"], unique)
                file.save(path)
                img_url = url_for("uploaded_file", filename=unique)
            if img_url:
                rule.set_image_url = img_url

            db.session.add(rule); db.session.commit()
            flash("Regla guardada.","success")
        elif action=="grant_bonus":
            try: uid = int(request.form.get("user_id") or "0")
            except: uid = 0
            try: tokens = int(request.form.get("tokens") or "0")
            except: tokens = 0
            sc = (request.form.get("grant_set_code") or "").lower()
            if uid>0 and tokens>0 and sc:
                a = PackAllowance.query.filter_by(user_id=uid, set_code=sc).first()
                if not a: a = PackAllowance(user_id=uid, set_code=sc, bonus_tokens=0)
                a.bonus_tokens += tokens
                db.session.add(a); db.session.commit()
                flash("Tokens otorgados.","success")
    rules = PackRule.query.order_by(PackRule.set_code.asc()).all()
    return render_template("admin_packs.html", rules=rules)
