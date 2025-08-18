# upgrade_v2.ps1
# Aplica mejoras v2 a la tienda Pokémon
# - Backup de v1
# - Actualiza/crea archivos (app.py, models.py, templates, upgrade_v2.py)
# - Añade Flask-WTF a requirements
# - Mensajes de siguiente pasos

$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }

# 0) Chequeos
$rootFiles = @("app.py","models.py","requirements.txt")
foreach($f in $rootFiles){ if(-not (Test-Path $f)){ Write-Error "No encuentro $f. Ejecuta este script en la carpeta del proyecto."; exit 1 } }

Ensure-Dir "templates"; Ensure-Dir "static"; Ensure-Dir "services"

# 1) Backup
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = "backup_v1_$ts"
Ensure-Dir $backupDir
Copy-Item app.py "$backupDir\app.py"
Copy-Item models.py "$backupDir\models.py"
Copy-Item requirements.txt "$backupDir\requirements.txt"
if(Test-Path "templates"){ Copy-Item "templates" "$backupDir\templates" -Recurse }
if(Test-Path "static"){ Copy-Item "static" "$backupDir\static" -Recurse }
if(Test-Path "services"){ Copy-Item "services" "$backupDir\services" -Recurse }
Write-Host "Backup creado en $backupDir" -ForegroundColor Green

# 2) requirements.txt → Flask-WTF si no está
$req = Get-Content requirements.txt -Raw
if($req -notmatch "Flask-WTF"){
  Add-Content requirements.txt "`nFlask-WTF==1.2.1"
  Write-Host "Agregado Flask-WTF a requirements.txt" -ForegroundColor Yellow
}

# 3) Escribir archivos v2

# 3.1) app.py v2 (reemplazo completo)
$app_py = @'
import os
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify, abort
from flask_login import LoginManager, login_user, login_required, logout_user, current_user
from email_validator import validate_email
from flask_wtf.csrf import CSRFProtect, generate_csrf
from sqlalchemy import func

from models import db, User, PokemonProducto, Order, OrderItem, ProductView, PromoCode
from services.precio_dinamico_service import PrecioDinamicoService

csrf = CSRFProtect()

def create_app():
    app = Flask(__name__)
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret")
    app.config["SQLALCHEMY_DATABASE_URI"] = "sqlite:///store.db"
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    db.init_app(app)

    csrf.init_app(app)

    @app.context_processor
    def inject_csrf():
        return dict(csrf_token=generate_csrf)

    login_manager = LoginManager(app)
    login_manager.login_view = "login"

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    precio_service = PrecioDinamicoService()

    # Helpers
    def get_cart():
        if "cart" not in session:
            session["cart"] = {}
        return session["cart"]

    def cart_items_with_products():
        cart = get_cart()
        items = []
        for pid, qty in cart.items():
            p = PokemonProducto.query.get(int(pid))
            if not p: 
                continue
            precio, _, _ = precio_service.calcular_precio(p, current_user if current_user.is_authenticated else None)
            items.append({"product": p, "qty": qty, "unit_price": precio})
        return items

    # Catálogo con búsqueda, filtros, orden y paginación
    @app.route("/")
    def index():
        q = request.args.get("q", "", type=str).strip()
        tipo = request.args.get("tipo", "", type=str).strip().lower()
        sort = request.args.get("sort", "new", type=str)
        page = request.args.get("page", 1, type=int)
        per_page = 8

        qry = PokemonProducto.query
        if q:
            like = f"%{q}%"
            qry = qry.filter(PokemonProducto.nombre.ilike(like))
        if tipo:
            qry = qry.filter(PokemonProducto.tipo.ilike(tipo))

        if sort == "price_asc":
            qry = qry.order_by(PokemonProducto.precio_base.asc())
        elif sort == "price_desc":
            qry = qry.order_by(PokemonProducto.precio_base.desc())
        else:
            qry = qry.order_by(PokemonProducto.created_at.desc())

        pag = qry.paginate(page=page, per_page=per_page, error_out=False)
        return render_template("index.html", products=pag.items, q=q, tipo=tipo, sort=sort, pag=pag)

    # Detalle con precio dinámico y recomendaciones
    @app.route("/product/<int:pid>")
    def product_detail(pid: int):
        p = PokemonProducto.query.get_or_404(pid)

        if current_user.is_authenticated:
            db.session.add(ProductView(user_id=current_user.id, product_id=p.id))
            db.session.commit()

        precio, razones, feats = PrecioDinamicoService().calcular_precio(
            p, current_user if current_user.is_authenticated else None
        )

        q = db.session.query(PokemonProducto, func.coalesce(func.sum(OrderItem.quantity), 0).label("sold"))\
            .outerjoin(OrderItem, OrderItem.product_id == PokemonProducto.id)\
            .filter(PokemonProducto.tipo == p.tipo, PokemonProducto.id != p.id)\
            .group_by(PokemonProducto.id).order_by(func.coalesce(func.sum(OrderItem.quantity), 0).desc())\
            .limit(4).all()
        recs = [r[0] for r in q] or PokemonProducto.query.filter(
            PokemonProducto.tipo == p.tipo, PokemonProducto.id != p.id
        ).order_by(PokemonProducto.created_at.desc()).limit(4).all()

        return render_template("product.html", p=p, precio=precio, razones=razones, feats=feats, recs=recs)

    # API precio dinámico
    @app.get("/api/precio")
    def api_precio():
        pid = request.args.get("product", type=int)
        if not pid: 
            return jsonify({"ok": False, "error": "product requerido"}), 400
        p = PokemonProducto.query.get(pid)
        if not p:
            return jsonify({"ok": False, "error": "producto no encontrado"}), 404
        user = current_user if current_user.is_authenticated else None
        precio, razones, feats = PrecioDinamicoService().calcular_precio(p, user)
        return jsonify({"ok": True, "precio": precio, "razones": razones, "features": feats})

    # Carrito
    @app.post("/cart/add/<int:pid>")
    def cart_add(pid):
        p = PokemonProducto.query.get_or_404(pid)
        qty = max(1, min(99, request.form.get("qty", type=int) or 1))
        cart = get_cart()
        cart[str(pid)] = cart.get(str(pid), 0) + qty
        session.modified = True
        flash(f"Añadido al carrito: {p.nombre} (x{qty})", "success")
        return redirect(url_for("cart_view"))

    @app.route("/cart")
    def cart_view():
        items = cart_items_with_products()
        total = round(sum(i["unit_price"] * i["qty"] for i in items), 2)
        return render_template("cart.html", items=items, total=total)

    @app.post("/cart/update")
    def cart_update():
        cart = get_cart()
        for key, val in request.form.items():
            if key.startswith("qty_"):
                pid = key.split("_",1)[1]
                qty = max(0, min(99, int(val or 0)))
                if qty == 0:
                    cart.pop(pid, None)
                else:
                    cart[pid] = qty
        session.modified = True
        return redirect(url_for("cart_view"))

    @app.post("/cart/clear")
    def cart_clear():
        session.pop("cart", None)
        flash("Carrito vacío.", "info")
        return redirect(url_for("cart_view"))

    # Checkout con cupón
    @app.route("/checkout", methods=["GET","POST"])
    @login_required
    def checkout():
        items = cart_items_with_products()
        if not items:
            flash("Tu carrito está vacío.", "warning")
            return redirect(url_for("index"))
        if request.method == "POST":
            name = request.form.get("name","").strip()
            address = request.form.get("address","").strip()
            coupon = (request.form.get("coupon") or "").strip()
            if not name or not address:
                flash("Completa nombre y dirección.", "warning")
                return redirect(url_for("checkout"))

            total = 0.0
            for it in items:
                p = it["product"]
                qty = it["qty"]
                if qty > p.stock:
                    flash(f"Stock insuficiente para {p.nombre}.", "danger")
                    return redirect(url_for("cart_view"))
                total += it["unit_price"] * qty

            discount = 0.0
            promo = None
            if coupon:
                promo = PromoCode.query.filter(func.lower(PromoCode.code) == coupon.lower()).first()
                if not promo or not promo.usable():
                    flash("Cupón inválido o no disponible.", "warning")
                    promo = None
                else:
                    discount = round(total * (promo.percent/100.0), 2)
                    total = round(total - discount, 2)

            order = Order(user_id=current_user.id, total=round(total,2), ship_name=name, ship_address=address)
            db.session.add(order); db.session.flush()

            for it in items:
                p = it["product"]; qty = it["qty"]
                p.stock -= qty
                db.session.add(OrderItem(
                    order_id=order.id, product_id=p.id,
                    product_name=p.nombre, unit_price=it["unit_price"], quantity=qty
                ))
            if promo:
                promo.used_count += 1
                db.session.add(promo)

            db.session.commit()
            session.pop("cart", None)
            return redirect(url_for("order_success", oid=order.id))

        total = round(sum(i["unit_price"] * i["qty"] for i in items), 2)
        return render_template("checkout.html", items=items, total=total)

    @app.get("/order/<int:oid>")
    @login_required
    def order_success(oid):
        order = Order.query.filter_by(id=oid, user_id=current_user.id).first_or_404()
        return render_template("order_success.html", order=order)

    @app.get("/orders")
    @login_required
    def orders_list():
        orders = Order.query.filter_by(user_id=current_user.id).order_by(Order.created_at.desc()).all()
        return render_template("orders.html", orders=orders)

    # Auth
    @app.route("/login", methods=["GET","POST"])
    def login():
        if request.method == "POST":
            email = (request.form.get("email") or "").strip().lower()
            pw = request.form.get("password") or ""
            user = User.query.filter_by(email=email).first()
            if not user or not user.check_password(pw):
                flash("Credenciales inválidas.", "danger")
                return redirect(url_for("login"))
            login_user(user)
            return redirect(url_for("index"))
        return render_template("login.html")

    @app.route("/register", methods=["GET","POST"])
    def register():
        if request.method == "POST":
            email = (request.form.get("email") or "").strip().lower()
            pw = request.form.get("password") or ""
            favs = [t.strip().lower() for t in (request.form.get("favoritos") or "").split(",") if t.strip()]

            try:
                validate_email(email)
            except Exception:
                flash("Email inválido.", "danger"); return redirect(url_for("register"))
            if len(pw) < 6:
                flash("La contraseña debe tener al menos 6 caracteres.", "warning"); return redirect(url_for("register"))
            if User.query.filter_by(email=email).first():
                flash("Email ya registrado.", "warning"); return redirect(url_for("register"))

            u = User(email=email)
            u.set_password(pw); u.set_favoritos(favs)
            db.session.add(u); db.session.commit()
            login_user(u)
            return redirect(url_for("index"))
        return render_template("register.html")

    @app.route("/logout")
    def logout():
        logout_user()
        return redirect(url_for("index"))

    # Admin
    def require_admin():
        if not current_user.is_authenticated:
            return redirect(url_for("login", next=request.path))
        if not current_user.is_admin:
            abort(403)

    @app.route("/admin/products", methods=["GET","POST"])
    def admin_products():
        if isinstance(require_admin(), str):
            return require_admin()
        res = require_admin()
        if res: return res
        if request.method == "POST":
            nombre = request.form.get("nombre","").strip()
            tipo = request.form.get("tipo","").strip().lower()
            precio = float(request.form.get("precio") or 0)
            stock = int(request.form.get("stock") or 0)
            img = request.form.get("image_url") or ""
            desc = request.form.get("descripcion") or ""
            if not nombre or not tipo or precio <= 0:
                flash("Completa nombre/tipo/precio.", "warning")
            else:
                p = PokemonProducto(nombre=nombre, tipo=tipo, precio_base=precio, stock=stock, image_url=img, descripcion=desc)
                db.session.add(p); db.session.commit()
                flash("Producto creado.", "success")
        products = PokemonProducto.query.order_by(PokemonProducto.created_at.desc()).all()
        return render_template("admin_products.html", products=products)

    return app

if __name__ == "__main__":
    app = create_app()
    with app.app_context():
        if not os.path.exists("store.db"):
            db.create_all()
    app.run(debug=True)
'@
Set-Content -Path "app.py" -Value $app_py -Encoding UTF8

# 3.2) models.py v2 (con PromoCode)
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
'@
Set-Content -Path "models.py" -Value $models_py -Encoding UTF8

# 3.3) templates

Ensure-Dir "templates"

$base_html = @'
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <title>{% block title %}Tienda Pokémon{% endblock %}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="{{ url_for('static', filename='styles.css') }}">
</head>
<body>
<header class="topbar">
  <div class="wrap">
    <a class="brand" href="{{ url_for('index') }}">🌀 PokeShop</a>
    <form class="search" action="{{ url_for('index') }}">
      <input name="q" placeholder="Buscar..." value="{{ request.args.get('q','') }}">
      <button>Buscar</button>
    </form>
    <nav>
      <a href="{{ url_for('cart_view') }}">🛒 Carrito</a>
      {% if current_user.is_authenticated %}
        <a href="{{ url_for('orders_list') }}">📦 Mis pedidos</a>
        <span class="muted">Hola, {{ current_user.email }}</span>
        {% if current_user.is_admin %}
          <a href="{{ url_for('admin_products') }}">⚙️ Admin</a>
        {% endif %}
        <a href="{{ url_for('logout') }}">Salir</a>
      {% else %}
        <a href="{{ url_for('login') }}">Entrar</a>
        <a href="{{ url_for('register') }}">Registrarse</a>
      {% endif %}
    </nav>
  </div>
</header>

<main class="wrap">
  {% with messages = get_flashed_messages(with_categories=true) %}
    {% if messages %}
      <div class="flash">
        {% for cat, msg in messages %}
          <div class="flash-item {{ cat }}">{{ msg }}</div>
        {% endfor %}
      </div>
    {% endif %}
  {% endwith %}
  {% block content %}{% endblock %}
</main>

<footer class="footer">
  <div class="wrap">
    <span>© {{ 2025 }} PokeShop (demo educativa)</span>
  </div>
</footer>
</body>
</html>
'@
Set-Content "templates/base.html" $base_html -Encoding UTF8

$index_html = @'
{% extends "base.html" %}
{% block title %}Catálogo · PokeShop{% endblock %}
{% block content %}
<h1>Catálogo</h1>
<form class="filters" action="{{ url_for('index') }}">
  <input type="hidden" name="q" value="{{ q }}">
  <select name="tipo">
    <option value="">Tipo (todos)</option>
    {% for t in ['fuego','agua','eléctrico','planta','hielo','roca','dragón'] %}
      <option value="{{t}}" {% if tipo==t %}selected{% endif %}>{{t|capitalize}}</option>
    {% endfor %}
  </select>
  <select name="sort">
    <option value="new" {% if sort=='new' %}selected{% endif %}>Novedades</option>
    <option value="price_asc" {% if sort=='price_asc' %}selected{% endif %}>Precio ↑</option>
    <option value="price_desc" {% if sort=='price_desc' %}selected{% endif %}>Precio ↓</option>
  </select>
  <button>Aplicar</button>
</form>
<div class="grid">
  {% for p in products %}
  <a class="card" href="{{ url_for('product_detail', pid=p.id) }}">
    <img src="{{ p.image_url or url_for('static', filename='noimg.png') }}" alt="{{ p.nombre }}">
    <div class="title">{{ p.nombre }}</div>
    <div class="muted">Tipo: {{ p.tipo|capitalize }}</div>
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
      <a class="btn" href="{{ url_for('index', q=q, tipo=tipo, sort=sort, page=pag.prev_num) }}">← Anterior</a>
    {% endif %}
    {% if pag.has_next %}
      <a class="btn" href="{{ url_for('index', q=q, tipo=tipo, sort=sort, page=pag.next_num) }}">Siguiente →</a>
    {% endif %}
  </div>
</nav>
{% endif %}
{% endblock %}
'@
Set-Content "templates/index.html" $index_html -Encoding UTF8

$product_html = @'
{% extends "base.html" %}
{% block title %}{{ p.nombre }} · PokeShop{% endblock %}
{% block content %}
<div class="product">
  <img class="photo" src="{{ p.image_url }}" alt="{{ p.nombre }}">
  <div class="info">
    <h1>{{ p.nombre }}</h1>
    <div class="muted">Tipo: {{ p.tipo|capitalize }} · Stock: {{ p.stock }}</div>
    <p>{{ p.descripcion }}</p>
    <div class="price">Precio para ti: <b>$ {{ "%.2f"|format(precio) }}</b></div>
    <form action="{{ url_for('cart_add', pid=p.id) }}" method="post">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <input type="number" name="qty" min="1" max="99" value="1">
      <button class="btn">Añadir al carrito</button>
    </form>
    <details>
      <summary>¿Cómo se calculó?</summary>
      <ul>
        {% for r in razones %}<li>{{ r }}</li>{% endfor %}
      </ul>
      <code>{{ feats }}</code>
    </details>
  </div>
</div>

{% if recs %}
  <h3 style="margin-top:14px">También te puede gustar</h3>
  <div class="grid">
    {% for r in recs %}
    <a class="card" href="{{ url_for('product_detail', pid=r.id) }}">
      <img src="{{ r.image_url }}" alt="{{ r.nombre }}">
      <div class="title">{{ r.nombre }}</div>
      <div class="muted">Tipo: {{ r.tipo|capitalize }}</div>
      <div class="price">$ {{ "%.2f"|format(r.precio_base) }}</div>
    </a>
    {% endfor %}
  </div>
{% endif %}
{% endblock %}
'@
Set-Content "templates/product.html" $product_html -Encoding UTF8

$cart_html = @'
{% extends "base.html" %}
{% block title %}Carrito · PokeShop{% endblock %}
{% block content %}
<h1>Carrito</h1>

<form action="{{ url_for('cart_update') }}" method="post">
<input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
<table class="table">
  <tr><th>Producto</th><th>Precio</th><th>Cantidad</th><th>Subtotal</th></tr>
  {% for it in items %}
  <tr>
    <td>{{ it.product.nombre }}</td>
    <td>$ {{ "%.2f"|format(it.unit_price) }}</td>
    <td><input type="number" name="qty_{{ it.product.id }}" min="0" max="99" value="{{ it.qty }}"></td>
    <td>$ {{ "%.2f"|format(it.unit_price * it.qty) }}</td>
  </tr>
  {% endfor %}
</table>
<div class="row">
  <div class="total">Total: <b>$ {{ "%.2f"|format(total) }}</b></div>
  <div class="right">
    <button class="btn" type="submit">Actualizar</button>
  </div>
</div>
</form>

<form action="{{ url_for('cart_clear') }}" method="post" style="margin-top:8px">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <button class="btn danger">Vaciar</button>
  <a class="btn primary" href="{{ url_for('checkout') }}">Ir a pagar</a>
</form>
{% endblock %}
'@
Set-Content "templates/cart.html" $cart_html -Encoding UTF8

$checkout_html = @'
{% extends "base.html" %}
{% block title %}Checkout · PokeShop{% endblock %}
{% block content %}
<h1>Checkout</h1>
<form method="post" class="checkout">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <label>Nombre completo <input name="name" required></label>
  <label>Dirección <input name="address" required></label>
  <label>Cupón (opcional) <input name="coupon" placeholder="PIKA10"></label>
  <h3>Resumen</h3>
  <ul>
    {% for it in items %}
      <li>{{ it.product.nombre }} × {{ it.qty }} — $ {{ "%.2f"|format(it.unit_price * it.qty) }}</li>
    {% endfor %}
  </ul>
  <div class="total">Total: <b>$ {{ "%.2f"|format(total) }}</b></div>
  <button class="btn primary">Pagar (demo)</button>
</form>
{% endblock %}
'@
Set-Content "templates/checkout.html" $checkout_html -Encoding UTF8

$order_success_html = @'
{% extends "base.html" %}
{% block title %}Pedido #{{ order.id }} · PokeShop{% endblock %}
{% block content %}
<h1>¡Gracias por tu compra!</h1>
<p>Pedido #{{ order.id }} — Total pagado: $ {{ "%.2f"|format(order.total) }}</p>
<p>Enviado a: {{ order.ship_name }} — {{ order.ship_address }}</p>
<h3>Items</h3>
<ul>
  {% for it in order.items %}
    <li>{{ it.product_name }} × {{ it.quantity }} — $ {{ "%.2f"|format(it.unit_price * it.quantity) }}</li>
  {% endfor %}
</ul>
<a class="btn" href="{{ url_for('index') }}">Volver a la tienda</a>
{% endblock %}
'@
Set-Content "templates/order_success.html" $order_success_html -Encoding UTF8

$login_html = @'
{% extends "base.html" %}
{% block title %}Entrar · PokeShop{% endblock %}
{% block content %}
<h1>Entrar</h1>
<form method="post" class="auth">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <label>Email <input name="email" type="email" required></label>
  <label>Contraseña <input name="password" type="password" required></label>
  <button class="btn primary">Entrar</button>
</form>
<p class="muted">¿No tienes cuenta? <a href="{{ url_for('register') }}">Regístrate</a></p>
{% endblock %}
'@
Set-Content "templates/login.html" $login_html -Encoding UTF8

$register_html = @'
{% extends "base.html" %}
{% block title %}Registro · PokeShop{% endblock %}
{% block content %}
<h1>Registro</h1>
<form method="post" class="auth">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <label>Email <input name="email" type="email" required></label>
  <label>Contraseña (6+ caracteres) <input name="password" type="password" required></label>
  <label>Tipos favoritos (coma separada) <input name="favoritos" placeholder="fuego,agua"></label>
  <button class="btn primary">Crear cuenta</button>
</form>
{% endblock %}
'@
Set-Content "templates/register.html" $register_html -Encoding UTF8

$admin_html = @'
{% extends "base.html" %}
{% block title %}Admin · Productos{% endblock %}
{% block content %}
<h1>Admin · Productos</h1>
<form method="post" class="admin-form">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <input name="nombre" placeholder="Nombre" required>
  <input name="tipo" placeholder="Tipo (fuego/agua/...)" required>
  <input name="precio" type="number" step="0.01" placeholder="Precio base" required>
  <input name="stock" type="number" placeholder="Stock" required>
  <input name="image_url" placeholder="URL de imagen">
  <textarea name="descripcion" placeholder="Descripción"></textarea>
  <button class="btn primary">Crear</button>
</form>

<h3>Listado</h3>
<div class="grid">
  {% for p in products %}
  <div class="card">
    <img src="{{ p.image_url }}" alt="{{ p.nombre }}">
    <div class="title">{{ p.nombre }}</div>
    <div class="muted">{{ p.tipo|capitalize }} · Stock {{ p.stock }}</div>
    <div class="price">$ {{ "%.2f"|format(p.precio_base) }}</div>
  </div>
  {% endfor %}
</div>
{% endblock %}
'@
Set-Content "templates/admin_products.html" $admin_html -Encoding UTF8

$orders_html = @'
{% extends "base.html" %}
{% block title %}Mis pedidos · PokeShop{% endblock %}
{% block content %}
<h1>Mis pedidos</h1>
{% if orders %}
  <ul>
  {% for o in orders %}
    <li>
      <b>#{{ o.id }}</b> — {{ o.created_at.strftime("%Y-%m-%d %H:%M") }} —
      Total: $ {{ "%.2f"|format(o.total) }} — Estado: {{ o.status }}
      <ul>
        {% for it in o.items %}
          <li>{{ it.product_name }} × {{ it.quantity }} — $ {{ "%.2f"|format(it.unit_price * it.quantity) }}</li>
        {% endfor %}
      </ul>
    </li>
  {% endfor %}
  </ul>
{% else %}
  <p class="muted">Aún no tienes pedidos.</p>
{% endif %}
{% endblock %}
'@
Set-Content "templates/orders.html" $orders_html -Encoding UTF8

# 3.4) upgrade_v2.py (crea tabla de cupones y seed)
$upgrade_py = @'
from app import create_app
from models import db, PromoCode

app = create_app()
with app.app_context():
    db.create_all()
    if not PromoCode.query.filter_by(code="PIKA10").first():
        db.session.add(PromoCode(code="PIKA10", percent=10))
    if not PromoCode.query.filter_by(code="WATER15").first():
        db.session.add(PromoCode(code="WATER15", percent=15, max_uses=100))
    db.session.commit()
    print("Upgrade v2 aplicado. Cupones: PIKA10 (10%), WATER15 (15%)")
'@
Set-Content "upgrade_v2.py" $upgrade_py -Encoding UTF8

Write-Host "Archivos v2 escritos." -ForegroundColor Green
Write-Host ""
Write-Host "Siguientes pasos:" -ForegroundColor Cyan
Write-Host "1) (Opcional) Activá tu venv y actualizá dependencias: pip install -r requirements.txt"
Write-Host "2) Ejecutá el upgrade de la base: python upgrade_v2.py"
Write-Host "3) Levantá la app: python app.py"
Write-Host "4) Probá: / (catálogo), /product/1, /cart, /checkout, /orders, /admin/products"