# patch_packs_admin.ps1
# Packs: admin ilimitado + imagen por set + colección por set + reveal UX
$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# 0) Carpetas base
Ensure-Dir "scripts"; Ensure-Dir "scripts\migrations"
Ensure-Dir "services"; Ensure-Dir "ai"; Ensure-Dir "templates"; Ensure-Dir "static"

# Paquetes vacíos por si faltan
if(-not (Test-Path "services\__init__.py")) { Set-Content "services\__init__.py" "" -Encoding UTF8 }
if(-not (Test-Path "ai\__init__.py")) { Set-Content "ai\__init__.py" "" -Encoding UTF8 }

# 1) services/packs_service.py (admin ilimitado)
$svc = @'
import json, random, datetime
from typing import List, Dict
from models import db, PokemonProducto, User
from models_packs import PackRule, PackAllowance, PackOpen, UserCard, StarLedger

def rarity_tier(r: str) -> str:
    if not r: return "common"
    rl = r.lower()
    if "illustration" in rl: return "illustration"
    if "double rare" in rl or "ultra" in rl or "gold" in rl or "secret" in rl: return "rare"
    if "rare" in rl: return "rare"
    if "uncommon" in rl: return "uncommon"
    return "common"

STAR_POINTS = {"common":1, "uncommon":2, "rare":5, "illustration":25}

def today_str() -> str:
    return datetime.date.today().strftime("%Y-%m-%d")

def get_set_code_from_tcg_id(tid: str) -> str:
    return (tid.split("-")[0].lower()) if tid and "-" in tid else ""

def get_or_create_rule(set_code: str) -> PackRule:
    r = PackRule.query.filter_by(set_code=set_code).first()
    if not r:
        r = PackRule(set_code=set_code, pack_size=10,
                     weights_json='{"Common":0.7,"Uncommon":0.25,"Rare":0.05}',
                     god_chance=0.001, enabled=True)
        db.session.add(r); db.session.commit()
    return r

def get_or_create_allowance(user_id: int, set_code: str) -> PackAllowance:
    a = PackAllowance.query.filter_by(user_id=user_id, set_code=set_code).first()
    if not a:
        a = PackAllowance(user_id=user_id, set_code=set_code, last_daily_open_date=None, bonus_tokens=0)
        db.session.add(a); db.session.commit()
    return a

def universe_for_set(set_code: str) -> List[PokemonProducto]:
    like_prefix = f"{set_code.lower()}-%"
    rows = db.session.query(PokemonProducto).filter(
        PokemonProducto.categoria=="tcg",
        PokemonProducto.tcg_card_id.isnot(None),
        PokemonProducto.tcg_card_id.like(like_prefix)
    ).all()
    return rows

def pick_pack_cards(rule: PackRule, set_code: str, rng: random.Random) -> List[PokemonProducto]:
    cards = universe_for_set(set_code)
    if not cards: return []
    # God pack
    try: g = float(rule.god_chance or 0.0)
    except: g = 0.0
    if rng.random() < g:
        illus = [c for c in cards if rarity_tier(c.rarity) == "illustration"]
        if illus:
            rng.shuffle(illus)
            need = rule.pack_size or 10
            return illus[:need] if len(illus)>=need else (illus + rng.sample(cards, need-len(illus)))

    try: weights = json.loads(rule.weights_json or "{}")
    except: weights = {"Common":0.7,"Uncommon":0.25,"Rare":0.05}
    commons = [c for c in cards if rarity_tier(c.rarity) == "common"]
    uncommons = [c for c in cards if rarity_tier(c.rarity) == "uncommon"]
    rares = [c for c in cards if rarity_tier(c.rarity) in ("rare","illustration")]

    k = rule.pack_size or 10
    out: List[PokemonProducto] = []
    for _ in range(k):
        r = rng.random()
        if r < weights.get("Common",0.7) and commons:
            out.append(rng.choice(commons))
        elif r < weights.get("Common",0.7)+weights.get("Uncommon",0.25) and uncommons:
            out.append(rng.choice(uncommons))
        else:
            if rares: out.append(rng.choice(rares))
            elif uncommons: out.append(rng.choice(uncommons))
            elif commons: out.append(rng.choice(commons))
    if not any(rarity_tier(c.rarity) in ("rare","illustration") for c in out) and rares:
        out[-1] = rng.choice(rares)
    return out

def open_pack(user_id: int, set_code: str, admin_unlimited: bool = False) -> Dict:
    set_code = set_code.lower()
    rule = get_or_create_rule(set_code)
    if not rule.enabled and not admin_unlimited:
        return {"ok": False, "error": "Pack deshabilitado para este set."}

    allow = get_or_create_allowance(user_id, set_code)
    today = today_str()

    can_daily = (allow.last_daily_open_date != today)
    used_bonus = False

    if not admin_unlimited:
        if not can_daily:
            if allow.bonus_tokens > 0:
                allow.bonus_tokens -= 1
                used_bonus = True
            else:
                return {"ok": False, "error": "Sin pack diario ni bonus tokens."}
    # Admin ilimitado: no consume diario ni tokens

    seed = int(datetime.datetime.utcnow().strftime("%Y%m%d")) ^ (user_id * 131) ^ (hash(set_code) & 0xffffffff)
    rng = random.Random(seed)

    picks = pick_pack_cards(rule, set_code, rng)
    if not picks:
        return {"ok": False, "error": "No hay cartas para ese set."}

    owned_ids = {uc.tcg_card_id for uc in UserCard.query.filter_by(user_id=user_id, set_code=set_code).all()}
    dup_points = 0; results = []
    for c in picks:
        is_dup = (c.tcg_card_id in owned_ids)
        results.append({
            "id": c.id, "tcg_card_id": c.tcg_card_id, "name": c.nombre,
            "rarity": c.rarity, "image_url": c.image_url, "duplicate": is_dup
        })
        db.session.add(UserCard(user_id=user_id, tcg_card_id=c.tcg_card_id, set_code=set_code,
                                name=c.nombre, rarity=c.rarity, image_url=c.image_url))
        if is_dup:
            dup_points += STAR_POINTS.get(rarity_tier(c.rarity), 1)

    if can_daily and not admin_unlimited:
        allow.last_daily_open_date = today
    db.session.add(allow)

    # No otorgar puntos al admin cuando abre ilimitado
    award_points = not admin_unlimited
    if dup_points and award_points:
        u = User.query.get(user_id)
        if u:
            try:
                u.star_points = (getattr(u,"star_points",0) or 0) + dup_points
                db.session.add(u)
            except Exception:
                pass
        db.session.add(StarLedger(user_id=user_id, points=dup_points, reason=f"Duplicados {set_code}"))

    db.session.add(PackOpen(user_id=user_id, set_code=set_code, cards_json=json.dumps(results)))
    db.session.commit()
    return {"ok": True, "set_code": set_code, "cards": results, "dup_points": (dup_points if award_points else 0), "used_bonus": used_bonus}
'@
Set-Content "services\packs_service.py" $svc -Encoding UTF8
Write-Host "services/packs_service.py actualizado."

# 2) models_packs.py (añade set_image_url)
$modelsPacks = @'
from datetime import datetime
from models import db

class PackRule(db.Model):
    __tablename__ = "pack_rules"
    id = db.Column(db.Integer, primary_key=True)
    set_code = db.Column(db.String(32), nullable=False, unique=True)
    pack_size = db.Column(db.Integer, nullable=False, default=10)
    weights_json = db.Column(db.Text, nullable=False, default='{"Common":0.7,"Uncommon":0.25,"Rare":0.05}')
    god_chance = db.Column(db.Float, nullable=False, default=0.001)
    enabled = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    set_image_url = db.Column(db.Text)

class PackAllowance(db.Model):
    __tablename__ = "pack_allowances"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, nullable=False, index=True)
    set_code = db.Column(db.String(32), nullable=False, index=True)
    last_daily_open_date = db.Column(db.String(10))
    bonus_tokens = db.Column(db.Integer, nullable=False, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class PackOpen(db.Model):
    __tablename__ = "pack_opens"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, nullable=False, index=True)
    set_code = db.Column(db.String(32), nullable=False)
    opened_at = db.Column(db.DateTime, default=datetime.utcnow)
    cards_json = db.Column(db.Text, nullable=False)

class UserCard(db.Model):
    __tablename__ = "user_cards"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, nullable=False, index=True)
    tcg_card_id = db.Column(db.String(80), nullable=False, index=True)
    set_code = db.Column(db.String(32), nullable=False)
    name = db.Column(db.String(255), nullable=False)
    rarity = db.Column(db.String(120))
    image_url = db.Column(db.Text)
    acquired_at = db.Column(db.DateTime, default=datetime.utcnow)
    locked = db.Column(db.Boolean, default=False)

class StarLedger(db.Model):
    __tablename__ = "star_ledgers"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, nullable=False, index=True)
    points = db.Column(db.Integer, nullable=False)
    reason = db.Column(db.String(255))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
'@
Set-Content "models_packs.py" $modelsPacks -Encoding UTF8
Write-Host "models_packs.py actualizado."

# 3) packs_bp.py (completo con /packs, /packs/open, /collection, /collection/<set>, /admin/packs)
$bp = @'
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
'@
Set-Content "packs_bp.py" $bp -Encoding UTF8
Write-Host "packs_bp.py actualizado."

# 4) templates/packs.html (usa transition-delay inline por carta)
$packsTpl = @'
{% extends "base.html" %}
{% block title %}Packs diarios · PokeShop{% endblock %}
{% block content %}
<link rel="stylesheet" href="{{ url_for('static', filename='packs.css') }}">
<script defer src="{{ url_for('static', filename='packs.js') }}"></script>

<h1>Packs</h1>
{% if opened_set %}
  <div class="pack-stage reveal">
    <div class="cards">
      {% for c in cards %}
      <div class="card3d" style="transition-delay: {{ (loop.index0 * 0.08)|round(3) }}s;">
        <div class="face front"></div>
        <div class="face back">
          <img src="{{ c.image_url or url_for('static', filename='no-card.png') }}" alt="{{ c.name }}">
          <div class="meta">{{ c.name }}</div>
          <div class="muted">{{ c.tcg_card_id }} · {{ c.rarity or '-' }}</div>
          {% if c.duplicate %}<div class="dup">Duplicado ★</div>{% endif %}
        </div>
      </div>
      {% endfor %}
    </div>
  </div>
  {% if dup_points and dup_points>0 %}
    <p class="muted">Puntos estrella obtenidos: <b>{{ dup_points }}</b></p>
  {% endif %}
  <p><a class="btn" href="{{ url_for('packs_bp.packs_home') }}">Volver</a></p>
{% else %}
  <p class="muted">Abre 1 pack diario por set. También puedes usar tus bonus tokens acumulados por compras.</p>
  <div class="grid">
    {% for s in sets %}
    <div class="card">
      <div class="thumb">
        {% if s.image %}
          <img src="{{ s.image }}" alt="{{ s.set_name }}">
        {% else %}
          <div class="ph">SIN IMAGEN</div>
        {% endif %}
      </div>
      <div class="title">{{ s.set_name }}</div>
      <div class="muted">{{ s.set_code|upper }}</div>
      <div class="badges">
        {% if s.daily %}<span class="badge glow">Diario disponible</span>{% else %}<span class="badge">Usado hoy</span>{% endif %}
        <span class="badge">Bonus: {{ s.bonus }}</span>
      </div>
      <form method="post" action="{{ url_for('packs_bp.packs_open') }}" class="open-pack-form">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <input type="hidden" name="set" value="{{ s.set_code }}">
        <button class="btn" {% if not s.daily and s.bonus==0 %}disabled{% endif %}>Abrir pack</button>
      </form>
    </div>
    {% endfor %}
  </div>

  <div class="pack-stage preopen" id="preopen">
     <div class="packbox pulse">
       <div class="shine"></div>
       <div class="label">Abriendo sobre...</div>
     </div>
  </div>
{% endif %}
{% endblock %}
'@
Set-Content "templates\packs.html" $packsTpl -Encoding UTF8
Write-Host "templates/packs.html actualizado."

# 5) templates/admin_packs.html
$adminTpl = @'
{% extends "base.html" %}
{% block title %}Admin · Packs{% endblock %}
{% block content %}
<h1>Admin · Packs</h1>

<form method="post" class="admin-form" enctype="multipart/form-data">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <input type="hidden" name="action" value="save_rule">

  <label>Set code <input name="set_code" placeholder="sv1" required></label>
  <label>Tamaño de pack <input type="number" name="pack_size" value="10" min="1"></label>
  <label>Odds JSON <input name="weights_json" value='{"Common":0.7,"Uncommon":0.25,"Rare":0.05}'></label>
  <label>God chance <input name="god_chance" value="0.001"></label>
  <label>Habilitado <input type="checkbox" name="enabled" checked></label>

  <label>Imagen del set (URL) <input name="set_image_url" placeholder="https://..."></label>
  <label>Imagen del set (archivo) <input type="file" name="set_image_file" accept=".png,.jpg,.jpeg,.gif,.webp"></label>

  <button class="btn primary">Guardar regla</button>
</form>

<table class="table" style="margin-top:10px">
  <tr><th>Set</th><th>Pack</th><th>Imagen</th><th>Odds</th><th>God</th><th>Enabled</th></tr>
  {% for r in rules %}
    <tr>
      <td>{{ r.set_code|upper }}</td>
      <td>{{ r.pack_size }}</td>
      <td>
        {% if r.set_image_url %}
          <img src="{{ r.set_image_url }}" alt="{{ r.set_code }}" style="width:80px;height:60px;object-fit:cover;border-radius:6px;border:1px solid #2a3670;">
        {% else %}<span class="muted">—</span>{% endif %}
      </td>
      <td><code>{{ r.weights_json }}</code></td>
      <td>{{ r.god_chance }}</td>
      <td>{{ "Sí" if r.enabled else "No" }}</td>
    </tr>
  {% endfor %}
</table>

<h3>Otorgar bonus tokens</h3>
<form method="post" class="admin-form">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <input type="hidden" name="action" value="grant_bonus">
  <label>User ID <input name="user_id" type="number" min="1" required></label>
  <label>Set code <input name="grant_set_code" placeholder="sv1" required></label>
  <label>Tokens <input name="tokens" type="number" min="1" required></label>
  <button class="btn">Otorgar</button>
</form>
{% endblock %}
'@
Set-Content "templates\admin_packs.html" $adminTpl -Encoding UTF8
Write-Host "templates/admin_packs.html actualizado."

# 6) templates/collection.html (añade botón Ver cartas)
$collTpl = @'
{% extends "base.html" %}
{% block title %}Mi colección · PokeShop{% endblock %}
{% block content %}
<h1>Mi colección</h1>
<p class="muted">Puntos estrella: <b>{{ star_points }}</b></p>
<div class="grid">
  {% for s in sets %}
  <div class="card">
    <div class="title">{{ s.set_name }}</div>
    <div class="muted">{{ s.set_code|upper }}</div>
    <div class="muted">Progreso: <b>{{ s.owned }}/{{ s.total }}</b></div>
    {% set pct = (s.owned*100//s.total) if s.total>0 else 0 %}
    <div class="progress"><div class="bar" style="width:{{ pct }}%"></div></div>
    <div class="badge">{{ pct }}%</div>
    <p style="margin-top:8px"><a class="btn" href="{{ url_for('packs_bp.collection_set', set_code=s.set_code) }}">Ver cartas</a></p>
  </div>
  {% endfor %}
</div>
{% endblock %}
'@
Set-Content "templates\collection.html" $collTpl -Encoding UTF8
Write-Host "templates/collection.html actualizado."

# 7) templates/collection_set.html (detalle + burn duplicados)
$collSetTpl = @'
{% extends "base.html" %}
{% block title %}Colección · {{ set_name }}{% endblock %}
{% block content %}
<link rel="stylesheet" href="{{ url_for('static', filename='packs.css') }}">

<h1>Colección · {{ set_name }}</h1>
{% if set_image %}
  <div class="thumb" style="max-width:420px;margin:8px 0;">
    <img src="{{ set_image }}" alt="{{ set_name }}">
  </div>
{% endif %}
<p class="muted">Progreso: <b>{{ owned }}/{{ total }}</b> ({{ pct }}%)</p>
<div class="progress"><div class="bar" style="width: {{ pct }}%"></div></div>

<div class="grid" style="margin-top:12px">
  {% for c in cards %}
  <div class="card" style="position:relative">
    <div class="thumb">
      {% if c.image_url %}
        <img src="{{ c.image_url }}" alt="{{ c.name }}">
      {% else %}
        <div class="ph">SIN IMAGEN</div>
      {% endif %}
    </div>
    <div class="title" style="font-size:14px">{{ c.name }}</div>
    <div class="muted">{{ c.tcg_card_id }} · {{ c.rarity or "-" }}</div>
    {% if c.owned %}
      <div class="badge glow">En colección</div>
      {% if c.duplicates > 0 %}
      <div class="muted">Duplicados: {{ c.duplicates }}</div>
      <form method="post" action="{{ url_for('packs_bp.burn_duplicates') }}" style="margin-top:6px">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <input type="hidden" name="tcg_card_id" value="{{ c.tcg_card_id }}">
        <input type="hidden" name="set_code" value="{{ set_code }}">
        <button class="btn">Fundir duplicados</button>
      </form>
      {% endif %}
    {% else %}
      <div class="badge">Falta</div>
    {% endif %}
  </div>
  {% endfor %}
</div>

<p style="margin-top:12px">
  <a class="btn" href="{{ url_for('packs_bp.packs_home') }}">Volver a packs</a>
</p>
{% endblock %}
'@
Set-Content "templates\collection_set.html" $collSetTpl -Encoding UTF8
Write-Host "templates/collection_set.html creado."

# 8) static/packs.css (reveal + miniatura + fallback)
$packsCss = @'
/* packs.css — animaciones estilo TCG Pocket */
.pack-stage{ position:relative; margin:12px 0; min-height:220px; display:grid; place-items:center; }
.pack-stage.preopen{ height:220px; }
.packbox{
  width:180px; height:240px; border-radius:16px;
  background: linear-gradient(135deg, rgba(96,165,250,.25), rgba(34,197,94,.18));
  border:1px solid #2a3670; box-shadow: 0 10px 30px rgba(0,0,0,.35);
  position:relative; display:grid; place-items:center; overflow:hidden;
}
.packbox .shine{ position:absolute; width:160%; height:60%; background: radial-gradient(ellipse at center, rgba(255,255,255,.35), rgba(255,255,255,0) 70%); transform: rotate(-20deg) translateY(-20%); filter: blur(6px); }
.packbox .label{ color:#e9f1ff; font-weight:800; text-shadow: 0 2px 8px rgba(0,0,0,.5); }
.pulse{ animation: pulse 1.2s ease-in-out infinite; }
@keyframes pulse{ 0%{transform:scale(1)} 50%{transform:scale(1.03)} 100%{transform:scale(1)} }

.cards{ display:grid; grid-template-columns: repeat(5, minmax(140px,1fr)); gap:14px; }
@media (max-width: 900px){ .cards{ grid-template-columns: repeat(2, minmax(140px,1fr)); } }

.card3d{ width:180px; height:240px; position:relative; perspective:1000px; transform-style: preserve-3d; transition: transform .6s ease; outline:none; }
.card3d:hover { filter: brightness(1.05); }

.card3d .face{
  width:100%; height:100%; position:absolute; top:0; left:0;
  backface-visibility:hidden; border-radius:14px;
  border:1px solid #2a3670; overflow:hidden; display:grid; place-items:center;
  background:#0f1735;
}
.card3d .front{
  background:
    radial-gradient(circle at 70% 30%, rgba(99,102,241,.25), transparent 55%),
    radial-gradient(circle at 20% 80%, rgba(34,197,94,.2), transparent 50%),
    #0f1735;
  animation: glow 1.6s ease-in-out infinite;
}
.card3d .back{ background:#0b152f; }
.card3d .back img{ width:100%; height:100%; object-fit:contain; background:#0b152f; }
.card3d .back .meta{ position:absolute; left:8px; bottom:8px; right:8px; font-weight:800; font-size:13px; color:#e9f1ff; text-shadow:0 2px 6px rgba(0,0,0,.5) }
.card3d .back .muted{ position:absolute; left:8px; bottom:28px; right:8px; font-size:12px; color:#a9b6d8 }
.card3d .back .dup{ position:absolute; top:8px; right:8px; background:#17224a; border:1px solid #2a3670; color:#ffd34d; font-weight:700; padding:4px 8px; border-radius:999px; font-size:12px }

.face.back{ transform: rotateY(180deg); }

.pack-stage.reveal .card3d{ transform: rotateY(180deg); }

.card3d.flip { transform: rotateY(180deg) !important; }

@keyframes glow{
  0%{ box-shadow: 0 0 0 rgba(96,165,250,0) }
  50%{ box-shadow: 0 0 30px rgba(96,165,250,.28) }
  100%{ box-shadow: 0 0 0 rgba(96,165,250,0) }
}

/* Miniatura del set */
.card .thumb{
  width:100%; height:120px; background:#0b152f; border:1px solid #2a3670;
  border-radius:12px; overflow:hidden; margin-bottom:8px; display:grid; place-items:center;
}
.card .thumb img{ width:100%; height:100%; object-fit:cover; }
.card .thumb .ph{ color:#a9b6d8; font-size:12px; }

/* Progreso */
.progress{ width:100%; height:8px; background:#0f1735; border:1px solid #2a3670; border-radius:999px; overflow:hidden; }
.progress .bar{ height:100%; background:linear-gradient(90deg, #60a5fa, #7dd3fc); }
.badge.glow{ box-shadow: 0 0 14px rgba(96,165,250,.5) }

@media (prefers-reduced-motion: reduce) {
  .card3d { transition: none; }
  .pulse, .card3d .front { animation: none; }
}
'@
Set-Content "static\packs.css" $packsCss -Encoding UTF8
Write-Host "static/packs.css actualizado."

# 9) static/packs.js (reveal + fallback)
$packsJs = @'
document.addEventListener("DOMContentLoaded", ()=>{
  const forms = document.querySelectorAll(".open-pack-form");
  const pre = document.getElementById("preopen");
  forms.forEach(f=>{
    f.addEventListener("submit", (e)=>{
      if(!pre) return;
      e.preventDefault();
      pre.classList.add("show");
      setTimeout(()=> f.submit(), 900);
    });
  });

  const stage = document.querySelector(".pack-stage");
  const hasCards = stage && stage.querySelector(".cards");
  if(stage && hasCards){
    if(stage.classList.contains("reveal")){
      stage.classList.remove("reveal");
      // force reflow
      // eslint-disable-next-line no-unused-expressions
      stage.offsetHeight;
    }
    setTimeout(()=> stage.classList.add("reveal"), 50);
  }

  document.querySelectorAll(".card3d").forEach(card=>{
    card.setAttribute("tabindex","0");
    card.addEventListener("click", ()=> card.classList.toggle("flip"));
    card.addEventListener("keydown", e=>{
      if(e.key===" "||e.key==="Enter"){
        e.preventDefault();
        card.classList.toggle("flip");
      }
    });
  });
});
'@
Set-Content "static\packs.js" $packsJs -Encoding UTF8
Write-Host "static/packs.js actualizado."

# 10) Migración v13: columna set_image_url
$upg13 = @'
# scripts/migrations/upgrade_v13_set_image.py
import os
from sqlalchemy import text
from models import db

try:
    from app import create_app
except Exception:
    create_app = None

flask_app = None
if create_app:
    try:
        flask_app = create_app()
    except Exception:
        flask_app = None

if flask_app is None:
    from flask import Flask
    proj_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    db_file = os.path.join(proj_root, "store.db")
    flask_app = Flask(__name__)
    flask_app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_file}"
    flask_app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    db.init_app(flask_app)

with flask_app.app_context():
    cols = [r[1] for r in db.session.execute(text("PRAGMA table_info(pack_rules)")).fetchall()]
    if "set_image_url" not in cols:
        db.session.execute(text("ALTER TABLE pack_rules ADD COLUMN set_image_url TEXT"))
        db.session.commit()
        print("v13: pack_rules.set_image_url added")
    else:
        print("v13: pack_rules.set_image_url already present")
'@
Set-Content "scripts\migrations\upgrade_v13_set_image.py" $upg13 -Encoding UTF8
Write-Host "scripts/migrations/upgrade_v13_set_image.py creado."

# 11) Parches en app.py: DB absoluta (si usas sqlite) + blueprint único
$appPath = "app.py"
if(Test-Path $appPath){
  $app = Get-Content $appPath -Raw

  # Ruta absoluta para sqlite si detectamos la cadena por defecto
  if($app -match 'SQLALCHEMY_DATABASE_URI"```\s*=\s*"sqlite:///store\.db"'){
    $app = $app -replace 'app\.config```math
"SQLALCHEMY_DATABASE_URI"```\s*=\s*"sqlite:///store\.db"', 'db_path = os.path.join(app.root_path, "store.db")`n    app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_path}"'
    Write-Host "app.py: convertida URI sqlite a ruta absoluta."
  }

  # Eliminar líneas directas previas de register_blueprint(packs_bp) para evitar duplicados
  $app = ($app -split "`n") | Where-Object { $_ -notmatch 'register_blueprint\s*KATEX_INLINE_OPEN\s*packs_bp\s*KATEX_INLINE_CLOSE' } | Out-String

  # Insertar bloque robusto antes de 'return app'
  $snippet = @"
    try:
        from packs_bp import packs_bp
    except Exception as e:
        app.logger.warning(f"packs_bp import failed: {e}")
    else:
        if "packs_bp" not in app.blueprints:
            app.register_blueprint(packs_bp)
"@
  $regex = [regex]'(\n\s*return app\s*\n)'
  if($regex.IsMatch($app)){
    $app = $regex.Replace($app, ($snippet + "`n$1"), 1)
    Write-Host "app.py: bloque de blueprint insertado."
  } else {
    Write-Warning "No se encontró 'return app' para insertar el blueprint. Revísalo manualmente."
  }
  Set-Content $appPath $app -Encoding UTF8
} else {
  Write-Warning "No se encontró app.py; registra el blueprint manualmente."
}

# 12) Navbar: enlaces a Packs/Colección si faltan
$basePath = "templates\base.html"
if(Test-Path $basePath){
  $base = Get-Content $basePath -Raw
  if($base -notmatch "packs_bp.packs_home"){
    $base = $base -replace '(</nav>)', ' <a href="{{ url_for(''packs_bp.packs_home'') }}">Packs</a> <a href="{{ url_for(''packs_bp.collection'') }}">Colecci&oacute;n</a>$1'
    Set-Content $basePath $base -Encoding UTF8
    Write-Host "base.html: enlaces Packs/Colección añadidos."
  } else {
    Write-Host "base.html ya contiene enlaces a Packs/Colección (ok)."
  }
}

Write-Host "`nHecho. Próximos pasos:" -ForegroundColor Green
Write-Host "  1) .\.venv\Scripts\Activate.ps1"
Write-Host "  2) py -m scripts.migrations.upgrade_v13_set_image"
Write-Host "  3) py app.py"
Write-Host ""
Write-Host "Entra a /admin/packs para configurar imagen por set; /packs para abrir; /collection y /collection/<set> para ver progreso" -ForegroundColor Cyan