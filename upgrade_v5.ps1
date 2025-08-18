# upgrade_v5.ps1
# v5: agrega campo "categoria" a productos, filtro de Categoría (TCG) en catálogo
#     y "Cartas TCG destacadas" en el home. Crea upgrade_v5.py y seed_tcg_cards.py.
#     Compatible con v3/v4 (wishlist, historial, reseñas, carrito persistente).

$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }

# Chequeos mínimos
$rootFiles = @("app.py","models.py","requirements.txt")
foreach($f in $rootFiles){ if(-not (Test-Path $f)){ Write-Error "No encuentro $f. Corré el script en la raíz del proyecto."; exit 1 } }

Ensure-Dir "templates"; Ensure-Dir "static"; Ensure-Dir "services"; Ensure-Dir "uploads"

# Backup
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = "backup_v4_$ts"
Ensure-Dir $backupDir
Copy-Item app.py "$backupDir\app.py"
Copy-Item models.py "$backupDir\models.py"
Copy-Item requirements.txt "$backupDir\requirements.txt"
if(Test-Path "templates"){ Copy-Item "templates" "$backupDir\templates" -Recurse }
if(Test-Path "static"){ Copy-Item "static" "$backupDir\static" -Recurse }
if(Test-Path "services"){ Copy-Item "services" "$backupDir\services" -Recurse }
Write-Host "Backup creado en $backupDir" -ForegroundColor Green

# -------- models.py con campo 'categoria' en PokemonProducto --------
$models_py = @'
from datetime import datetime
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
import json

db = SQLAlchemy()

class User(UserMixin, db.Model):
    __tablename__ = "users"
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(200), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    is_admin = db.Column(db.Boolean, default=False)
    favoritos_tipos = db.Column(db.Text, default="[]")

    def set_password(self, pw):
        self.password_hash = generate_password_hash(pw)

    def check_password(self, pw):
        return check_password_hash(self.password_hash, pw)

    def get_favoritos(self):
        try:
            return json.loads(self.favoritos_tipos or "[]")
        except Exception:
            return []

    def set_favoritos(self, tipos_list):
        self.favoritos_tipos = json.dumps(tipos_list or [])

class PokemonProducto(db.Model):
    __tablename__ = "productos"
    id = db.Column(db.Integer, primary_key=True)
    nombre = db.Column(db.String(255), nullable=False)
    tipo = db.Column(db.String(50), nullable=False)
    categoria = db.Column(db.String(50), nullable=False, default="general")  # NUEVO
    descripcion = db.Column(db.Text, default="")
    precio_base = db.Column(db.Float, nullable=False)
    stock = db.Column(db.Integer, default=0)
    image_url = db.Column(db.Text, default="")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class ProductView(db.Model):
    __tablename__ = "product_views"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    product_id = db.Column(db.Integer, db.ForeignKey("productos.id"), nullable=False)
    ts = db.Column(db.DateTime, default=datetime.utcnow)

class Order(db.Model):
    __tablename__ = "orders"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    total = db.Column(db.Float, nullable=False)
    status = db.Column(db.String(50), default="pagado")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    ship_name = db.Column(db.String(200))
    ship_address = db.Column(db.String(300))
    items = db.relationship("OrderItem", backref="order", cascade="all,delete-orphan")

class OrderItem(db.Model):
    __tablename__ = "order_items"
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey("orders.id"), nullable=False)
    product_id = db.Column(db.Integer, db.ForeignKey("productos.id"), nullable=False)
    product_name = db.Column(db.String(255), nullable=False)
    unit_price = db.Column(db.Float, nullable=False)
    quantity = db.Column(db.Integer, nullable=False, default=1)

class PromoCode(db.Model):
    __tablename__ = "promo_codes"
    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(50), unique=True, nullable=False)
    percent = db.Column(db.Integer, nullable=False, default=0)
    active = db.Column(db.Boolean, default=True)
    max_uses = db.Column(db.Integer, nullable=True)
    used_count = db.Column(db.Integer, default=0)
    expires_at = db.Column(db.DateTime, nullable=True)

    def usable(self) -> bool:
        if not self.active:
            return False
        if self.expires_at and self.expires_at < datetime.utcnow():
            return False
        if self.max_uses is not None and self.used_count >= self.max_uses:
            return False
        return True

class Wishlist(db.Model):
    __tablename__ = "wishlist"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    product_id = db.Column(db.Integer, db.ForeignKey("productos.id"), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    __table_args__ = (db.UniqueConstraint("user_id", "product_id", name="uq_wishlist"), )

class Review(db.Model):
    __tablename__ = "reviews"
    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey("productos.id"), nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    rating = db.Column(db.Integer, nullable=False)
    comment = db.Column(db.Text, default="")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    __table_args__ = (db.UniqueConstraint("user_id", "product_id", name="uq_review"), )

class CartItem(db.Model):
    __tablename__ = "cart_items"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    product_id = db.Column(db.Integer, db.ForeignKey("productos.id"), nullable=False)
    quantity = db.Column(db.Integer, nullable=False, default=1)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow)
    __table_args__ = (db.UniqueConstraint("user_id", "product_id", name="uq_cart_item"), )
'@
Set-Content -Path "models.py" -Value $models_py -Encoding UTF8

# -------- app.py: añade filtro cat y destacados TCG, admin con categoría --------
# Nota: Mantiene v4 (UTF-8, wishlist, historial, reseñas, carrito persistente).
# Solo se modifican index() y admin_products() para manejar 'categoria' y 'featured_tcg'.

$app_py = Get-Content app.py -Raw

# Parches simples: si tu app.py viene de v4, aplicamos reemplazos específicos.
# 1) En index(): añadir lectura de 'cat' y featured_tcg, y pasar a template.
# Intento reemplazo seguro por patrones (si falla te aviso para pegar manualmente).
$app_py = $app_py -replace 'def indexKATEX_INLINE_OPENKATEX_INLINE_CLOSE:\s*\n\s*q = .*?\n\s*tipo = .*?\n\s*sort = .*?\n\s*page = .*?\n\s*per_page = .*?\n\s*\n\s*qry = PokemonProducto\.query\s*.*?return render_templateKATEX_INLINE_OPEN"index\.html",[^KATEX_INLINE_CLOSE]*KATEX_INLINE_CLOSE\s*', @'
def index():
        q = request.args.get("q", "", type=str).strip()
        tipo = request.args.get("tipo", "", type=str).strip().lower()
        cat = request.args.get("cat", "", type=str).strip().lower()   # NUEVO
        sort = request.args.get("sort", "new", type=str)
        page = request.args.get("page", 1, type=int)
        per_page = 8

        qry = PokemonProducto.query
        if q:
            like = f"%{q}%"
            qry = qry.filter(PokemonProducto.nombre.ilike(like))
        if tipo:
            qry = qry.filter(PokemonProducto.tipo.ilike(tipo))
        if cat:
            qry = qry.filter(PokemonProducto.categoria.ilike(cat))     # NUEVO

        if sort == "price_asc":
            qry = qry.order_by(PokemonProducto.precio_base.asc())
        elif sort == "price_desc":
            qry = qry.order_by(PokemonProducto.precio_base.desc())
        else:
            qry = qry.order_by(PokemonProducto.created_at.desc())

        pag = qry.paginate(page=page, per_page=per_page, error_out=False)

        # Destacados TCG (últimos 8)
        featured_tcg = PokemonProducto.query.filter_by(categoria="tcg")\
                            .order_by(PokemonProducto.created_at.desc()).limit(8).all()

        return render_template("index.html", products=pag.items, q=q, tipo=tipo, sort=sort, pag=pag, cat=cat, featured_tcg=featured_tcg)
'@

# 2) En admin_products(): leer categoria del form y guardarla en el producto
$app_py = $app_py -replace 'p = PokemonProductoKATEX_INLINE_OPENnombre=nombre, tipo=tipo, precio_base=precio, stock=stock, image_url=img, descripcion=descKATEX_INLINE_CLOSE', 'p = PokemonProducto(nombre=nombre, tipo=tipo, categoria=request.form.get("categoria","general").strip().lower(), precio_base=precio, stock=stock, image_url=img, descripcion=desc)'

Set-Content -Path "app.py" -Value $app_py -Encoding UTF8

# -------- templates/index.html (filtro Categoría + Destacados TCG) --------
$index_html = @'
{% extends "base.html" %}
{% block title %}Catálogo · PokeShop{% endblock %}
{% block content %}
<h1>Catálogo</h1>

<form class="filters" action="{{ url_for('index') }}">
  <input type="hidden" name="q" value="{{ q }}">
  <select name="tipo">
    <option value="">Tipo (todos)</option>
    {% for t in ['fuego','agua','eléctrico','planta','hielo','roca','dragón','psíquico','siniestro','lucha','acero','incoloro'] %}
      <option value="{{t}}" {% if tipo==t %}selected{% endif %}>{{t|capitalize}}</option>
    {% endfor %}
  </select>
  <select name="cat">
    <option value="">Categoría (todas)</option>
    <option value="tcg" {% if cat=='tcg' %}selected{% endif %}>TCG</option>
    <option value="general" {% if cat=='general' %}selected{% endif %}>General/Merch</option>
  </select>
  <select name="sort">
    <option value="new" {% if sort=='new' %}selected{% endif %}>Novedades</option>
    <option value="price_asc" {% if sort=='price_asc' %}selected{% endif %}>Precio ↑</option>
    <option value="price_desc" {% if sort=='price_desc' %}selected{% endif %}>Precio ↓</option>
  </select>
  <button>Aplicar</button>
</form>

{% if featured_tcg %}
  <h3 style="margin:8px 0">Cartas TCG destacadas</h3>
  <div class="grid">
    {% for p in featured_tcg %}
      <a class="card" href="{{ url_for('product_detail', pid=p.id) }}">
        <img src="{{ p.image_url or url_for('static', filename='noimg.png') }}" alt="{{ p.nombre }}">
        <div class="title">{{ p.nombre }}</div>
        <div class="muted">Tipo: {{ p.tipo|capitalize }} · <b>TCG</b></div>
        <div class="price">$ {{ "%.2f"|format(p.precio_base) }}</div>
      </a>
    {% endfor %}
  </div>
{% endif %}

<h3 style="margin:8px 0">Todos los productos</h3>
<div class="grid">
  {% for p in products %}
  <a class="card" href="{{ url_for('product_detail', pid=p.id) }}">
    <img src="{{ p.image_url or url_for('static', filename='noimg.png') }}" alt="{{ p.nombre }}">
    <div class="title">{{ p.nombre }}</div>
    <div class="muted">Tipo: {{ p.tipo|capitalize }} · {{ p.categoria|capitalize }}</div>
    <div class="price">$ {{ "%.2f"|format(p.precio_base) }}</div>
    <div class="muted">Stock: {{ p.stock }}</div>
  </a>
  {% else %}
  <p>No hay productos.</p>
  {% endfor %}
</div>

{% if pag and pag.pages>1 %}
<nav class="row" style="margin-top:10px">
  <div>Página {{ pag.page }} de {{ pag.pages }}</div>
  <div>
    {% if pag.has_prev %}
      <a class="btn" href="{{ url_for('index', q=q, tipo=tipo, cat=cat, sort=sort, page=pag.prev_num) }}">← Anterior</a>
    {% endif %}
    {% if pag.has_next %}
      <a class="btn" href="{{ url_for('index', q=q, tipo=tipo, cat=cat, sort=sort, page=pag.next_num) }}">Siguiente →</a>
    {% endif %}
  </div>
</nav>
{% endif %}
{% endblock %}
'@
Set-Content "templates/index.html" $index_html -Encoding UTF8

# -------- templates/admin_products.html (selector de categoría) --------
$admin_html = @'
{% extends "base.html" %}
{% block title %}Admin · Productos{% endblock %}
{% block content %}
<h1>Admin · Productos</h1>
<form method="post" class="admin-form" enctype="multipart/form-data">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <input name="nombre" placeholder="Nombre" required>
  <input name="tipo" placeholder="Tipo (fuego/agua/...)" required>
  <label>Categoría
    <select name="categoria">
      <option value="general">General/Merch</option>
      <option value="tcg">TCG</option>
    </select>
  </label>
  <input name="precio" type="number" step="0.01" placeholder="Precio base" required>
  <input name="stock" type="number" placeholder="Stock" required>
  <input name="image_url" placeholder="URL de imagen">
  <label>Imagen (archivo) <input type="file" name="image_file" accept=".png,.jpg,.jpeg,.gif,.webp"></label>
  <textarea name="descripcion" placeholder="Descripción"></textarea>
  <button class="btn primary">Crear</button>
</form>

<h3>Listado</h3>
<div class="grid">
  {% for p in products %}
  <div class="card">
    <img src="{{ p.image_url }}" alt="{{ p.nombre }}">
    <div class="title">{{ p.nombre }}</div>
    <div class="muted">{{ p.tipo|capitalize }} · {{ p.categoria|capitalize }} · Stock {{ p.stock }}</div>
    <div class="price">$ {{ "%.2f"|format(p.precio_base) }}</div>
  </div>
  {% endfor %}
</div>
{% endblock %}
'@
Set-Content "templates/admin_products.html" $admin_html -Encoding UTF8

# -------- seed_tcg_cards.py (con categoria='tcg') --------
$seed_tcg = @'
# seed_tcg_cards.py
from app import create_app
from models import db, PokemonProducto

CARDS = [
    dict(nombre="Charizard VMAX - Darkness Ablaze 020/189", tipo="fuego",
         categoria="tcg", precio_base=129.99, stock=3,
         image_url="https://images.pokemontcg.io/swsh3/20_hires.png",
         descripcion="Carta TCG • Expansión: Darkness Ablaze • Rareza: Rare Holo VMAX • Idioma: EN • Condición: NM • Nº: 020/189"),
    dict(nombre="Charizard ex - Obsidian Flames 125/197", tipo="fuego",
         categoria="tcg", precio_base=59.90, stock=4,
         image_url="https://images.pokemontcg.io/sv3/125_hires.png",
         descripcion="Carta TCG • Expansión: Obsidian Flames • Rareza: Double Rare • Idioma: EN • Condición: NM • Nº: 125/197"),
    dict(nombre="Blastoise VMAX - Shining Fates 109/190", tipo="agua",
         categoria="tcg", precio_base=34.90, stock=6,
         image_url="https://images.pokemontcg.io/swsh45/109_hires.png",
         descripcion="Carta TCG • Expansión: Shining Fates • Rareza: Rare Holo VMAX • Idioma: EN • Condición: NM • Nº: 109/190"),
    dict(nombre="Gyarados ex - Scarlet & Violet 045/198", tipo="agua",
         categoria="tcg", precio_base=14.90, stock=12,
         image_url="https://images.pokemontcg.io/sv1/45_hires.png",
         descripcion="Carta TCG • Expansión: Scarlet & Violet • Rareza: Double Rare • Idioma: EN • Condición: NM • Nº: 045/198"),
    dict(nombre="Pikachu - Base Set 58/102", tipo="eléctrico",
         categoria="tcg", precio_base=19.90, stock=10,
         image_url="https://images.pokemontcg.io/base1/58_hires.png",
         descripcion="Carta TCG • Expansión: Base Set • Rareza: Common • Idioma: EN • Condición: LP-NM • Nº: 58/102"),
    dict(nombre="Raichu - Base Set 14/102", tipo="eléctrico",
         categoria="tcg", precio_base=39.90, stock=5,
         image_url="https://images.pokemontcg.io/base1/14_hires.png",
         descripcion="Carta TCG • Expansión: Base Set • Rareza: Holo Rare • Idioma: EN • Condición: LP-NM • Nº: 14/102"),
    dict(nombre="Rayquaza VMAX - Evolving Skies 218/203", tipo="dragón",
         categoria="tcg", precio_base=199.90, stock=1,
         image_url="https://images.pokemontcg.io/swsh7/218_hires.png",
         descripcion="Carta TCG • Expansión: Evolving Skies • Rareza: Rainbow Rare • Idioma: EN • Condición: NM • Nº: 218/203"),
    dict(nombre="Mewtwo VSTAR - Crown Zenith GG44/GG70", tipo="psíquico",
         categoria="tcg", precio_base=69.90, stock=3,
         image_url="https://images.pokemontcg.io/swsh12pt5gg/GG44_hires.png",
         descripcion="Carta TCG • Expansión: Crown Zenith • Rareza: Galarian Gallery • Idioma: EN • Condición: NM • Nº: GG44/GG70"),
    dict(nombre="Gardevoir ex - Scarlet & Violet 245/198", tipo="psíquico",
         categoria="tcg", precio_base=24.90, stock=8,
         image_url="https://images.pokemontcg.io/sv1/245_hires.png",
         descripcion="Carta TCG • Expansión: Scarlet & Violet • Rareza: Illustration Rare • Idioma: EN • Condición: NM • Nº: 245/198"),
    dict(nombre="Umbreon VMAX - Evolving Skies 215/203", tipo="siniestro",
         categoria="tcg", precio_base=299.00, stock=1,
         image_url="https://images.pokemontcg.io/swsh7/215_hires.png",
         descripcion="Carta TCG • Expansión: Evolving Skies • Rareza: Alternate Art • Idioma: EN • Condición: NM • Nº: 215/203"),
]

if __name__ == "__main__":
    app = create_app()
    with app.app_context():
        count_added = 0
        for c in CARDS:
            exists = PokemonProducto.query.filter_by(nombre=c["nombre"]).first()
            if exists:
                continue
            p = PokemonProducto(
                nombre=c["nombre"], tipo=c["tipo"], categoria=c["categoria"],
                precio_base=c["precio_base"], stock=c["stock"],
                image_url=c["image_url"], descripcion=c["descripcion"],
            )
            db.session.add(p)
            count_added += 1
        db.session.commit()
        print(f"Cartas TCG añadidas: {count_added} (de {len(CARDS)})")
'@
Set-Content "seed_tcg_cards.py" $seed_tcg -Encoding UTF8

# -------- upgrade_v5.py: ALTER TABLE para agregar columna en SQLite --------
$upgrade_py = @'
# upgrade_v5.py
from app import create_app
from models import db

app = create_app()
with app.app_context():
    # Detectar si la columna ya existe
    cols = [row[1] for row in db.session.execute(db.text("PRAGMA table_info(productos)")).fetchall()]
    if "categoria" not in cols:
        db.session.execute(db.text('ALTER TABLE productos ADD COLUMN categoria VARCHAR(50) DEFAULT "general"'))
        db.session.commit()
        print('Columna "categoria" añadida a productos.')
    # Normalizar nulos a "general"
    db.session.execute(db.text('UPDATE productos SET categoria="general" WHERE categoria IS NULL'))
    db.session.commit()
    print("Upgrade v5 listo.")
'@
Set-Content "upgrade_v5.py" $upgrade_py -Encoding UTF8

Write-Host "v5 aplicada. Archivos escritos en UTF-8." -ForegroundColor Green
Write-Host ""
Write-Host "Siguientes pasos:" -ForegroundColor Cyan
Write-Host "1) (Opcional) activar venv: .\.venv\Scripts\Activate.ps1"
Write-Host "2) pip install -r requirements.txt"
Write-Host "3) python upgrade_v5.py   (agrega columna categoria y normaliza)"
Write-Host "4) python seed_tcg_cards.py   (añade cartas TCG demo)"
Write-Host "5) python app.py"
Write-Host ""
Write-Host "Home: verás 'Cartas TCG destacadas' y filtro de Categoría."