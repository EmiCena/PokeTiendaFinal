# patch_v12_packs.ps1
# v12 Packs diarios + Coleccion + Star Points + God Pack + Bonus por compras
# Animaciones estilo TCG Pocket (flip glow + reveal)
$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# 0) carpetas
Ensure-Dir "scripts"; Ensure-Dir "scripts\migrations"
Ensure-Dir "services"; Ensure-Dir "ai"; Ensure-Dir "templates"; Ensure-Dir "static"

# Paquetes vacíos para evitar errores de import
if(-not (Test-Path "services\__init__.py")) { Set-Content "services\__init__.py" "" -Encoding UTF8 }
if(-not (Test-Path "ai\__init__.py")) { Set-Content "ai\__init__.py" "" -Encoding UTF8 }

# 1) models_packs.py (modelos nuevos)
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
Write-Host "models_packs.py creado."

# 2) services/packs_service.py (lógica de packs)
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

def open_pack(user_id: int, set_code: str) -> Dict:
    set_code = set_code.lower()
    rule = get_or_create_rule(set_code)
    if not rule.enabled: return {"ok": False, "error": "Pack deshabilitado para este set."}

    allow = get_or_create_allowance(user_id, set_code)
    today = today_str()
    can_daily = (allow.last_daily_open_date != today)
    used_bonus = False
    if not can_daily:
        if allow.bonus_tokens > 0:
            allow.bonus_tokens -= 1
            used_bonus = True
        else:
            return {"ok": False, "error": "Sin pack diario ni bonus tokens."}

    seed = int(datetime.datetime.utcnow().strftime("%Y%m%d")) ^ (user_id * 131) ^ (hash(set_code) & 0xffffffff)
    rng = random.Random(seed)

    picks = pick_pack_cards(rule, set_code, rng)
    if not picks: return {"ok": False, "error": "No hay cartas para ese set."}

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

    if can_daily:
        allow.last_daily_open_date = today
    db.session.add(allow)

    if dup_points:
        u = User.query.get(user_id)
        if u:
            try:
                # si existe la columna, la actualiza; si no, solo registra en ledger
                u.star_points = (getattr(u,"star_points",0) or 0) + dup_points
                db.session.add(u)
            except Exception:
                pass
        db.session.add(StarLedger(user_id=user_id, points=dup_points, reason=f"Duplicados {set_code}"))

    db.session.add(PackOpen(user_id=user_id, set_code=set_code, cards_json=json.dumps(results)))
    db.session.commit()
    return {"ok": True, "set_code": set_code, "cards": results, "dup_points": dup_points, "used_bonus": used_bonus}
'@
Set-Content "services\packs_service.py" $svc -Encoding UTF8
Write-Host "services/packs_service.py creado."

# 3) packs_bp.py (Blueprint con endpoints)
$bp = @'
from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from sqlalchemy import text
from models import db
from models_packs import PackAllowance, PackRule
from services.packs_service import open_pack, today_str

packs_bp = Blueprint("packs_bp", __name__)

@packs_bp.get("/packs")
@login_required
def packs_home():
    rows = db.session.execute(text("SELECT DISTINCT substr(tcg_card_id,1, instr(tcg_card_id,'-')-1) AS set_code FROM productos WHERE categoria='tcg' AND tcg_card_id IS NOT NULL AND tcg_card_id<>''")).fetchall()
    set_codes = [r[0] for r in rows if r[0]]
    allowances = {a.set_code: a for a in PackAllowance.query.filter_by(user_id=current_user.id).all()}
    today = today_str()
    data = []
    for sc in sorted(set_codes):
        a = allowances.get(sc)
        daily_available = (not a) or (a.last_daily_open_date != today)
        bonus = a.bonus_tokens if a else 0
        n = db.session.execute(text(
            "SELECT expansion, COUNT(*) c FROM productos WHERE categoria='tcg' AND lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1))=:sc GROUP BY expansion ORDER BY c DESC LIMIT 1"
        ), {"sc": sc.lower()}).fetchone()
        set_name = n[0] if n and n[0] else sc.upper()
        data.append({"set_code": sc, "set_name": set_name, "daily": daily_available, "bonus": bonus})
    return render_template("packs.html", sets=data)

@packs_bp.post("/packs/open")
@login_required
def packs_open():
    set_code = (request.form.get("set") or "").strip().lower()
    if not set_code:
        flash("Falta set.", "warning"); return redirect(url_for("packs_bp.packs_home"))
    res = open_pack(current_user.id, set_code)
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
    rows = db.session.execute(text(
        "SELECT lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1)) AS set_code, COUNT(*) as total FROM productos WHERE categoria='tcg' AND tcg_card_id IS NOT NULL GROUP BY set_code"
    )).fetchall()
    totals = {r[0]: r[1] for r in rows}
    my_rows = db.session.execute(text(
        "SELECT set_code, COUNT(DISTINCT tcg_card_id) as owned FROM user_cards WHERE user_id=:uid GROUP BY set_code"
    ), {"uid": current_user.id}).fetchall()
    owned = {r[0]: r[1] for r in my_rows}
    names = {}
    for sc in totals.keys():
        n = db.session.execute(text(
            "SELECT expansion, COUNT(*) c FROM productos WHERE categoria='tcg' AND lower(substr(tcg_card_id,1,instr(tcg_card_id,'-')-1))=:sc GROUP BY expansion ORDER BY c DESC LIMIT 1"
        ), {"sc": sc}).fetchone()
        names[sc] = n[0] if n and n[0] else sc.upper()

    # Calcula star_points desde el ledger para no depender de columna en User
    row = db.session.execute(text("SELECT COALESCE(SUM(points),0) FROM star_ledgers WHERE user_id=:uid"), {"uid": current_user.id}).fetchone()
    star_points = int(row[0] if row and row[0] is not None else 0)

    data = []
    for sc, tot in sorted(totals.items()):
        data.append({"set_code": sc, "set_name": names.get(sc, sc.upper()), "owned": owned.get(sc,0), "total": tot})
    return render_template("collection.html", sets=data, star_points=star_points)

@packs_bp.route("/admin/packs", methods=["GET","POST"])
def admin_packs():
    # check admin
    from flask import abort
    if not current_user.is_authenticated: 
        return redirect(url_for("login", next=request.path))
    if not getattr(current_user,"is_admin", False):
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
Write-Host "packs_bp.py creado."

# 4) migración upgrade_v12.py
$upg = @'
from app import create_app
from models import db
app = create_app()

with app.app_context():
    def has_col(table, col):
        cols = [r[1] for r in db.session.execute(db.text(f"PRAGMA table_info({table})")).fetchall()]
        return col in cols

    # star_points en tabla users (opcional si no existe)
    if not has_col("users","star_points"):
        db.session.execute(db.text("ALTER TABLE users ADD COLUMN star_points INTEGER DEFAULT 0"))

    db.session.execute(db.text("""
    CREATE TABLE IF NOT EXISTS pack_rules(
      id INTEGER PRIMARY KEY,
      set_code VARCHAR(32) UNIQUE NOT NULL,
      pack_size INTEGER NOT NULL DEFAULT 10,
      weights_json TEXT NOT NULL DEFAULT '{"Common":0.7,"Uncommon":0.25,"Rare":0.05}',
      god_chance REAL NOT NULL DEFAULT 0.001,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at TEXT
    );"""))
    db.session.execute(db.text("""
    CREATE TABLE IF NOT EXISTS pack_allowances(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      set_code VARCHAR(32) NOT NULL,
      last_daily_open_date VARCHAR(10),
      bonus_tokens INTEGER NOT NULL DEFAULT 0,
      created_at TEXT,
      UNIQUE(user_id, set_code)
    );"""))
    db.session.execute(db.text("""
    CREATE TABLE IF NOT EXISTS pack_opens(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      set_code VARCHAR(32) NOT NULL,
      opened_at TEXT,
      cards_json TEXT NOT NULL
    );"""))
    db.session.execute(db.text("""
    CREATE TABLE IF NOT EXISTS user_cards(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      tcg_card_id VARCHAR(80) NOT NULL,
      set_code VARCHAR(32) NOT NULL,
      name VARCHAR(255) NOT NULL,
      rarity VARCHAR(120),
      image_url TEXT,
      acquired_at TEXT,
      locked INTEGER DEFAULT 0
    );"""))
    db.session.execute(db.text("""
    CREATE TABLE IF NOT EXISTS star_ledgers(
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      points INTEGER NOT NULL,
      reason VARCHAR(255),
      created_at TEXT
    );"""))
    db.session.commit()
    print("v12: tablas listas (packs, star_points)")
'@
Ensure-Dir "scripts\migrations"
Set-Content "scripts\migrations\upgrade_v12.py" $upg -Encoding UTF8
Write-Host "scripts/migrations/upgrade_v12.py creado."

# 5) templates: packs.html, collection.html, admin_packs.html con animaciones
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
      <div class="card3d" style="--i:{{ loop.index0 }};">
        <div class="face front"></div>
        <div class="face back">
          <img src="{{ c.image_url }}" alt="{{ c.name }}">
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
    <div class="progress">
      <div class="bar" style="width:{{ pct }}%"></div>
    </div>
    <div class="badge">{{ pct }}%</div>
  </div>
  {% endfor %}
</div>
{% endblock %}
'@
Set-Content "templates\collection.html" $collTpl -Encoding UTF8

$adminTpl = @'
{% extends "base.html" %}
{% block title %}Admin · Packs{% endblock %}
{% block content %}
<h1>Admin · Packs</h1>
<form method="post" class="admin-form">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <input type="hidden" name="action" value="save_rule">
  <label>Set code <input name="set_code" placeholder="sv1" required></label>
  <label>Tamaño de pack <input type="number" name="pack_size" value="10" min="1"></label>
  <label>Odds JSON <input name="weights_json" value='{"Common":0.7,"Uncommon":0.25,"Rare":0.05}'></label>
  <label>God chance <input name="god_chance" value="0.001"></label>
  <label>Habilitado <input type="checkbox" name="enabled" checked></label>
  <button class="btn primary">Guardar regla</button>
</form>

<table class="table" style="margin-top:10px">
  <tr><th>Set</th><th>Pack</th><th>Odds</th><th>God</th><th>Enabled</th></tr>
  {% for r in rules %}
    <tr>
      <td>{{ r.set_code|upper }}</td>
      <td>{{ r.pack_size }}</td>
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

# 6) static: packs.css + packs.js (animaciones estilo TCG Pocket)
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

.card3d{ width:180px; height:240px; perspective:1000px; position:relative; }
.card3d .face{
  width:100%; height:100%; position:absolute; backface-visibility:hidden; border-radius:14px;
  border:1px solid #2a3670; overflow:hidden; display:grid; place-items:center;
  background:#0f1735;
}
.card3d .front{
  background:
    radial-gradient(circle at 70% 30%, rgba(99,102,241,.25), transparent 55%),
    radial-gradient(circle at 20% 80%, rgba(34,197,94,.2), transparent 50%),
    #0f1735;
  animation: glow 1.2s ease-in-out infinite;
}
.card3d .back img{ width:100%; height:100%; object-fit:contain; background:#0b152f; }
.card3d .back .meta{ position:absolute; left:8px; bottom:8px; right:8px; font-weight:800; font-size:13px; color:#e9f1ff; text-shadow:0 2px 6px rgba(0,0,0,.5) }
.card3d .back .muted{ position:absolute; left:8px; bottom:28px; right:8px; font-size:12px; color:#a9b6d8 }
.card3d .back .dup{ position:absolute; top:8px; right:8px; background:#17224a; border:1px solid #2a3670; color:#ffd34d; font-weight:700; padding:4px 8px; border-radius:999px; font-size:12px }

.reveal .card3d{
  transform-style: preserve-3d;
  animation: flipin .8s ease forwards;
  animation-delay: calc(var(--i) * .08s);
}
.face.back{ transform: rotateY(180deg); }
@keyframes flipin{
  0% { transform: rotateY(0deg) translateY(18px); opacity:.0 }
  50%{ opacity:1 }
  100%{ transform: rotateY(180deg) translateY(0); opacity:1 }
}
@keyframes glow{
  0%{ box-shadow: 0 0 0 rgba(96,165,250,0) }
  50%{ box-shadow: 0 0 30px rgba(96,165,250,.35) }
  100%{ box-shadow: 0 0 0 rgba(96,165,250,0) }
}

/* progress bar */
.progress{ width:100%; height:8px; background:#0f1735; border:1px solid #2a3670; border-radius:999px; overflow:hidden; }
.progress .bar{ height:100%; background:linear-gradient(90deg, #60a5fa, #7dd3fc); }
.badge.glow{ box-shadow: 0 0 14px rgba(96,165,250,.5) }
'@
Set-Content "static\packs.css" $packsCss -Encoding UTF8

$packsJs = @'
document.addEventListener("DOMContentLoaded", ()=>{
  const forms = document.querySelectorAll(".open-pack-form");
  const pre = document.getElementById("preopen");
  forms.forEach(f=>{
    f.addEventListener("submit", (e)=>{
      if(!pre) return;
      e.preventDefault();
      pre.classList.add("show");
      setTimeout(()=> f.submit(), 900); // animación "abrir" ~0.9s, luego envía
    });
  });
});
'@
Set-Content "static\packs.js" $packsJs -Encoding UTF8

# 7) Registrar blueprint en app.py y añadir bonus en checkout
$appPath = "app.py"
if(Test-Path $appPath){
  $app = Get-Content $appPath -Raw

  # Registrar blueprint antes de 'return app' solo si no existe ya
  if($app -notmatch "app\.register_blueprintKATEX_INLINE_OPEN\s*packs_bp\s*KATEX_INLINE_CLOSE"){
    $snippet = @"
    try:
        from packs_bp import packs_bp
        app.register_blueprint(packs_bp)
    except Exception as e:
        app.logger.warning(f"packs_bp not registered: {e}")
"@
    $regex = [regex]'(\n\s*return app\s*\n)'
    $app = $regex.Replace($app, ($snippet + "`n$1"), 1)
    Set-Content $appPath $app -Encoding UTF8
    Write-Host "app.py: blueprint packs_bp registrado."
  } else {
    Write-Host "app.py ya tiene packs_bp registrado (ok)."
  }

  # Bonus tokens en checkout (antes del primer db.session.commit() dentro de checkout)
  $app = Get-Content $appPath -Raw
  if($app -notmatch "spend_by_set"){
    $start = $app.IndexOf("def checkout")
    if($start -ge 0){
      $sub = $app.Substring($start)
      $posCommit = $sub.IndexOf("db.session.commit()")
      if($posCommit -ge 0){
        $globalPos = $start + $posCommit
        $before = $app.Substring(0, $globalPos)
        $after  = $app.Substring($globalPos)
$bonus = @"
# bonus tokens por compras TCG (+1 pack por cada \$25 por set)
try:
    from models_packs import PackAllowance
    spend_by_set = {}
    for it in items:
        p = it[""product""]; qty = it[""qty""]
        if (getattr(p,""categoria"","""") or """").lower()==""tcg"" and getattr(p,""tcg_card_id"",None):
            sc = (p.tcg_card_id.split(""-"")[0]).lower()
            spend_by_set[sc] = spend_by_set.get(sc,0.0) + (it[""unit_price""]*qty)
    for sc, amt in spend_by_set.items():
        bonus = int(amt // 25)
        if bonus>0:
            a = PackAllowance.query.filter_by(user_id=current_user.id, set_code=sc).first()
            if not a: a = PackAllowance(user_id=current_user.id, set_code=sc, bonus_tokens=0)
            a.bonus_tokens += bonus
            db.session.add(a)
except Exception as _e:
    app.logger.warning(f""packs bonus error: {_e}"")
"@
        $app = $before + $bonus + $after
        Set-Content $appPath $app -Encoding UTF8
        Write-Host "app.py: bonus tokens por compra añadidos al checkout."
      } else {
        Write-Warning "No se encontró db.session.commit() dentro de checkout; no se insertó bonus."
      }
    } else {
      Write-Warning "No se encontró def checkout en app.py; no se insertó bonus."
    }
  } else {
    Write-Host "app.py ya tiene bonus tokens (ok)."
  }

  # Añadir links Packs/Colección en base.html (si existe)
  $basePath = "templates\base.html"
  if(Test-Path $basePath){
    $base = Get-Content $basePath -Raw
    if($base -notmatch "packs_bp.packs_home"){
      $base = $base -replace '(</nav>)', ' <a href="{{ url_for(''packs_bp.packs_home'') }}">Packs</a> <a href="{{ url_for(''packs_bp.collection'') }}">Colecci&oacute;n</a>$1'
      Set-Content $basePath $base -Encoding UTF8
      Write-Host "base.html: links Packs/Colección añadidos."
    } else {
      Write-Host "base.html ya tiene links a Packs/Colección (ok)."
    }
  }
}else{
  Write-Host "app.py no encontrado; registra blueprint y bonus manualmente."
}

Write-Host "`nListo. Ejecuta ahora:" -ForegroundColor Green
Write-Host "  .\.venv\Scripts\Activate.ps1"
Write-Host "  python -m scripts.migrations.upgrade_v12"
Write-Host "  python app.py"
Write-Host ""
Write-Host "Prueba /packs (abre pack con animación), /collection (progreso y estrellas)." -ForegroundColor Cyan