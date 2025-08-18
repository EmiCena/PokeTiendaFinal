# upgrade_v6.ps1
# v6: Perfil de usuario, FTS5, facetas TCG y import desde Pokémon TCG API
$ErrorActionPreference = "Stop"
function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }

# Chequeos mínimos
$rootFiles = @("app.py","models.py","requirements.txt")
foreach($f in $rootFiles){ if(-not (Test-Path $f)){ Write-Error "No encuentro $f. Corré el script en la raíz del proyecto."; exit 1 } }

Ensure-Dir "templates"; Ensure-Dir "static"; Ensure-Dir "services"; Ensure-Dir "uploads"

# Backup
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = "backup_v5_$ts"
Ensure-Dir $backupDir
Copy-Item app.py "$backupDir\app.py"
Copy-Item models.py "$backupDir\models.py"
Copy-Item requirements.txt "$backupDir\requirements.txt"
if(Test-Path "templates"){ Copy-Item "templates" "$backupDir\templates" -Recurse }
if(Test-Path "static"){ Copy-Item "static" "$backupDir\static" -Recurse }
if(Test-Path "services"){ Copy-Item "services" "$backupDir\services" -Recurse }
Write-Host "Backup creado en $backupDir" -ForegroundColor Green

# requirements.txt (agregar requests si falta)
$req = Get-Content requirements.txt -Raw
if($req -notmatch "(?m)^requests=="){
  Add-Content requirements.txt "`nrequests==2.32.3"
  Write-Host "Agregado requests==2.32.3 a requirements.txt" -ForegroundColor Yellow
}

# ================= models.py (v6) =================
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
    full_name = db.Column(db.String(200))        # NUEVO
    ship_address = db.Column(db.String(400))     # NUEVO

    def set_password(self, pw):
        self.password_hash = generate_password_hash(pw)
    def check_password(self, pw):
        return check_password_hash(self.password_hash, pw)
    def get_favoritos(self):
        try: return json.loads(self.favoritos_tipos or "[]")
        except Exception: return []
    def set_favoritos(self, tipos_list):
        self.favoritos_tipos = json.dumps(tipos_list or [])

class PokemonProducto(db.Model):
    __tablename__ = "productos"
    id = db.Column(db.Integer, primary_key=True)
    nombre = db.Column(db.String(255), nullable=False)
    tipo = db.Column(db.String(50), nullable=False)
    categoria = db.Column(db.String(50), nullable=False, default="general")
    descripcion = db.Column(db.Text, default="")
    precio_base = db.Column(db.Float, nullable=False)
    stock = db.Column(db.Integer, default=0)
    image_url = db.Column(db.Text, default="")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    # Metadatos TCG (NUEVO)
    expansion = db.Column(db.String(120))
    rarity = db.Column(db.String(120))
    language = db.Column(db.String(30))
    condition = db.Column(db.String(60))
    card_number = db.Column(db.String(40))

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
        if not self.active: return False
        if self.expires_at and self.expires_at < datetime.utcnow(): return False
        if self.max_uses is not None and self.used_count >= self.max_uses: return False
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

# ================= app.py (v6) =================
$app_py = @'
import os, time
from uuid import uuid4
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify, abort, send_from_directory
from flask_login import LoginManager, login_user, login_required, logout_user, current_user
from email_validator import validate_email
from flask_wtf.csrf import CSRFProtect, generate_csrf
from sqlalchemy import func, text
from werkzeug.utils import secure_filename

from models import db, User, PokemonProducto, Order, OrderItem, ProductView, PromoCode, Wishlist, Review, CartItem
from services.precio_dinamico_service import PrecioDinamicoService

ALLOWED_EXTS = {"png","jpg","jpeg","gif","webp"}
csrf = CSRFProtect()

def allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".",1)[1].lower() in ALLOWED_EXTS

def create_app():
    app = Flask(__name__)
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret")
    app.config["SQLALCHEMY_DATABASE_URI"] = "sqlite:///store.db"
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    app.config["UPLOAD_FOLDER"] = os.path.join(app.root_path, "uploads")
    app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024
    app.config["JSON_AS_ASCII"] = False
    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    db.init_app(app)
    csrf.init_app(app)

    @app.context_processor
    def inject_csrf():
        return dict(csrf_token=generate_csrf)

    @app.after_request
    def ensure_utf8(resp):
        if resp.mimetype == "text/html" and "charset" not in (resp.content_type or "").lower():
            resp.headers["Content-Type"] = "text/html; charset=utf-8"
        return resp

    login_manager = LoginManager(app)
    login_manager.login_view = "login"

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    precio_service = PrecioDinamicoService()

    # ---------- Helpers carrito (DB / sesión)
    def get_cart_session():
        if "cart" not in session: session["cart"] = {}
        return session["cart"]

    def add_to_cart_db(user_id: int, product_id: int, qty: int):
        ci = CartItem.query.filter_by(user_id=user_id, product_id=product_id).first()
        if ci: ci.quantity = min(99, ci.quantity + qty)
        else: db.session.add(CartItem(user_id=user_id, product_id=product_id, quantity=min(99, qty)))
        db.session.commit()

    def get_cart_items_db(user_id: int):
        rows = db.session.query(CartItem, PokemonProducto)\
            .join(PokemonProducto, PokemonProducto.id == CartItem.product_id)\
            .filter(CartItem.user_id == user_id).all()
        return [{"product": p, "qty": ci.quantity} for (ci, p) in rows]

    def clear_cart_db(user_id: int):
        CartItem.query.filter_by(user_id=user_id).delete(); db.session.commit()

    def merge_session_cart_to_db(user_id: int):
        cart = session.get("cart", {})
        for pid, qty in cart.items(): add_to_cart_db(user_id, int(pid), int(qty))
        session.pop("cart", None)

    def cart_items_with_products():
        out = []
        if current_user.is_authenticated:
            for it in get_cart_items_db(current_user.id):
                p = it["product"]; qty = it["qty"]
                precio, _, _ = precio_service.calcular_precio(p, current_user)
                out.append({"product": p, "qty": qty, "unit_price": precio})
            return out
        cart = session.get("cart", {})
        for pid, qty in cart.items():
            p = PokemonProducto.query.get(int(pid))
            if not p: continue
            precio, _, _ = precio_service.calcular_precio(p, None)
            out.append({"product": p, "qty": qty, "unit_price": precio})
        return out

    # ---------- FTS5 utilidades
    def fts_available():
        row = db.session.execute(text("SELECT name FROM sqlite_master WHERE type='table' AND name='product_fts'")).fetchone()
        return bool(row)

    def fts_match_ids(q: str, limit: int = 200):
        terms = [t for t in q.split() if t]
        if not terms: return []
        pattern = " ".join([f"{t}*" for t in terms])
        try:
            rows = db.session.execute(text("SELECT rowid FROM product_fts WHERE product_fts MATCH :pat LIMIT :lim"),
                                      {"pat": pattern, "lim": limit}).fetchall()
            return [int(r[0]) for r in rows]
        except Exception:
            return []

    def tcg_facets():
        base = PokemonProducto.query.filter(PokemonProducto.categoria=="tcg")
        def distinct(col):
            rows = base.with_entities(col).filter(col.isnot(None), col!="").distinct().order_by(col.asc()).all()
            return [r[0] for r in rows]
        return {
            "exp": distinct(PokemonProducto.expansion),
            "rare": distinct(PokemonProducto.rarity),
            "lang": distinct(PokemonProducto.language),
            "cond": distinct(PokemonProducto.condition),
        }

    # ---------- Static uploads
    @app.route("/uploads/<path:filename>")
    def uploaded_file(filename):
        return send_from_directory(app.config["UPLOAD_FOLDER"], filename)

    # ---------- Catálogo (búsqueda FTS + facetas TCG)
    @app.route("/")
    def index():
        q = request.args.get("q", "", type=str).strip()
        tipo = request.args.get("tipo", "", type=str).strip().lower()
        cat = request.args.get("cat", "", type=str).strip().lower()
        sort = request.args.get("sort", "new", type=str)
        page = request.args.get("page", 1, type=int)
        per_page = 8

        # Facetas TCG
        exp = request.args.get("exp","",type=str).strip()
        rare = request.args.get("rare","",type=str).strip()
        lang = request.args.get("lang","",type=str).strip()
        cond = request.args.get("cond","",type=str).strip()

        qry = PokemonProducto.query

        # Búsqueda
        if q:
            if fts_available():
                ids = fts_match_ids(q)
                if ids: qry = qry.filter(PokemonProducto.id.in_(ids))
                else: qry = qry.filter(PokemonProducto.id == -1)
            else:
                like = f"%{q}%"
                qry = qry.filter((PokemonProducto.nombre.ilike(like)) | (PokemonProducto.descripcion.ilike(like)))

        if tipo: qry = qry.filter(PokemonProducto.tipo.ilike(tipo))
        if cat: qry = qry.filter(PokemonProducto.categoria.ilike(cat))

        if cat == "tcg":
            if exp: qry = qry.filter(PokemonProducto.expansion == exp)
            if rare: qry = qry.filter(PokemonProducto.rarity == rare)
            if lang: qry = qry.filter(PokemonProducto.language == lang)
            if cond: qry = qry.filter(PokemonProducto.condition == cond)

        if sort == "price_asc": qry = qry.order_by(PokemonProducto.precio_base.asc())
        elif sort == "price_desc": qry = qry.order_by(PokemonProducto.precio_base.desc())
        else: qry = qry.order_by(PokemonProducto.created_at.desc())

        pag = qry.paginate(page=page, per_page=per_page, error_out=False)
        featured_tcg = PokemonProducto.query.filter_by(categoria="tcg").order_by(PokemonProducto.created_at.desc()).limit(8).all()
        facets = tcg_facets() if cat=="tcg" else {"exp":[], "rare":[], "lang":[], "cond":[]}

        return render_template("index.html", products=pag.items, q=q, tipo=tipo, sort=sort, cat=cat, pag=pag,
                               featured_tcg=featured_tcg, facets=facets, exp=exp, rare=rare, lang=lang, cond=cond)

    # ---------- Detalle
    @app.route("/product/<int:pid>")
    def product_detail(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        if current_user.is_authenticated:
            db.session.add(ProductView(user_id=current_user.id, product_id=p.id)); db.session.commit()
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
        reviews = Review.query.filter_by(product_id=p.id).order_by(Review.created_at.desc()).all()
        avg_rating = round(sum(r.rating for r in reviews)/len(reviews), 2) if reviews else None
        my_review = Review.query.filter_by(product_id=p.id, user_id=current_user.id).first() if current_user.is_authenticated else None
        purchasers = {uid for (uid,) in db.session.query(Order.user_id).join(OrderItem, Order.id == OrderItem.order_id)
                      .filter(OrderItem.product_id == p.id).all()}
        in_wishlist = Wishlist.query.filter_by(user_id=current_user.id, product_id=p.id).first() is not None if current_user.is_authenticated else False
        return render_template("product.html", p=p, precio=precio, razones=razones, feats=feats, recs=recs,
                               reviews=reviews, avg_rating=avg_rating, my_review=my_review,
                               purchasers=purchasers, in_wishlist=in_wishlist)

    # ---------- Reseñas
    @app.post("/product/<int:pid>/review")
    @login_required
    def post_review(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        rating = max(1, min(5, int(request.form.get("rating") or 0)))
        comment = (request.form.get("comment") or "").strip()
        rv = Review.query.filter_by(product_id=p.id, user_id=current_user.id).first()
        if rv: rv.rating, rv.comment, rv.created_at = rating, comment, datetime.utcnow()
        else: db.session.add(Review(product_id=p.id, user_id=current_user.id, rating=rating, comment=comment))
        db.session.commit()
        flash("Tu reseña fue guardada.", "success")
        return redirect(url_for("product_detail", pid=p.id))

    # ---------- Wishlist
    @app.get("/wishlist")
    @login_required
    def wishlist_view():
        rows = db.session.query(Wishlist, PokemonProducto).join(PokemonProducto, PokemonProducto.id == Wishlist.product_id)\
               .filter(Wishlist.user_id == current_user.id).order_by(Wishlist.created_at.desc()).all()
        items = [{"product": p, "ts": w.created_at} for (w,p) in rows]
        return render_template("wishlist.html", items=items)

    @app.post("/wishlist/add/<int:pid>")
    @login_required
    def wishlist_add(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        if not Wishlist.query.filter_by(user_id=current_user.id, product_id=p.id).first():
            db.session.add(Wishlist(user_id=current_user.id, product_id=p.id)); db.session.commit()
            flash("Añadido a favoritos.", "success")
        return redirect(request.referrer or url_for("product_detail", pid=p.id))

    @app.post("/wishlist/remove/<int:pid>")
    @login_required
    def wishlist_remove(pid: int):
        w = Wishlist.query.filter_by(user_id=current_user.id, product_id=pid).first()
        if w: db.session.delete(w); db.session.commit(); flash("Quitado de favoritos.", "info")
        return redirect(request.referrer or url_for("wishlist_view"))

    # ---------- Historial
    @app.get("/history")
    @login_required
    def history_view():
        rows = db.session.query(PokemonProducto, func.max(ProductView.ts).label("last"))\
            .join(ProductView, ProductView.product_id == PokemonProducto.id)\
            .filter(ProductView.user_id == current_user.id)\
            .group_by(PokemonProducto.id).order_by(func.max(ProductView.ts).desc()).limit(30).all()
        items = [{"product": p, "last": last} for (p,last) in rows]
        return render_template("history.html", items=items)

    # ---------- API precio
    @app.get("/api/precio")
    def api_precio():
        pid = request.args.get("product", type=int)
        if not pid: return jsonify({"ok": False, "error": "product requerido"}), 400
        p = PokemonProducto.query.get(pid)
        if not p: return jsonify({"ok": False, "error": "producto no encontrado"}), 404
        user = current_user if current_user.is_authenticated else None
        precio, razones, feats = PrecioDinamicoService().calcular_precio(p, user)
        return jsonify({"ok": True, "precio": precio, "razones": razones, "features": feats})

    # ---------- Carrito
    @app.post("/cart/add/<int:pid>")
    def cart_add(pid):
        p = PokemonProducto.query.get_or_404(pid)
        qty = max(1, min(99, request.form.get("qty", type=int) or 1))
        if current_user.is_authenticated: add_to_cart_db(current_user.id, p.id, qty)
        else:
            cart = get_cart_session(); cart[str(pid)] = min(99, cart.get(str(pid), 0) + qty)
            session["cart"] = cart; session.modified = True
        flash(f"Añadido al carrito: {p.nombre} (x{qty})", "success")
        return redirect(url_for("cart_view"))

    @app.route("/cart")
    def cart_view():
        items = cart_items_with_products()
        total = round(sum(i["unit_price"] * i["qty"] for i in items), 2)
        return render_template("cart.html", items=items, total=total)

    @app.post("/cart/update")
    def cart_update():
        if current_user.is_authenticated:
            for key, val in request.form.items():
                if key.startswith("qty_"):
                    pid = int(key.split("_",1)[1]); qty = max(0, min(99, int(val or 0)))
                    ci = CartItem.query.filter_by(user_id=current_user.id, product_id=pid).first()
                    if ci:
                        if qty == 0: db.session.delete(ci)
                        else: ci.quantity = qty
            db.session.commit()
        else:
            cart = get_cart_session()
            for key, val in request.form.items():
                if key.startswith("qty_"):
                    pid = key.split("_",1)[1]; qty = max(0, min(99, int(val or 0)))
                    if qty == 0: cart.pop(pid, None)
                    else: cart[pid] = qty
            session["cart"] = cart; session.modified = True
        return redirect(url_for("cart_view"))

    @app.post("/cart/clear")
    def cart_clear():
        if current_user.is_authenticated: clear_cart_db(current_user.id)
        else: session.pop("cart", None)
        flash("Carrito vacío.", "info")
        return redirect(url_for("cart_view"))

    # ---------- Checkout (autocompletar con perfil)
    @app.route("/checkout", methods=["GET","POST"])
    @login_required
    def checkout():
        items = cart_items_with_products()
        if not items:
            flash("Tu carrito está vacío.", "warning"); return redirect(url_for("index"))
        if request.method == "POST":
            name = (request.form.get("name") or current_user.full_name or "").strip()
            address = (request.form.get("address") or current_user.ship_address or "").strip()
            coupon = (request.form.get("coupon") or "").strip()
            if not name or not address:
                flash("Completa nombre y dirección.", "warning"); return redirect(url_for("checkout"))
            total = 0.0
            for it in items:
                p = it["product"]; qty = it["qty"]
                if qty > p.stock: flash(f"Stock insuficiente para {p.nombre}.", "danger"); return redirect(url_for("cart_view"))
                total += it["unit_price"] * qty
            promo = None
            if coupon:
                promo = PromoCode.query.filter(func.lower(PromoCode.code) == coupon.lower()).first()
                if not promo or not promo.usable(): flash("Cupón inválido o no disponible.", "warning"); promo = None
                else: total = round(total - round(total * (promo.percent/100.0), 2), 2)
            order = Order(user_id=current_user.id, total=round(total,2), ship_name=name, ship_address=address)
            db.session.add(order); db.session.flush()
            for it in items:
                p = it["product"]; qty = it["qty"]
                p.stock -= qty
                db.session.add(OrderItem(order_id=order.id, product_id=p.id, product_name=p.nombre, unit_price=it["unit_price"], quantity=qty))
            if promo: promo.used_count += 1; db.session.add(promo)
            db.session.commit()
            clear_cart_db(current_user.id); session.pop("cart", None)
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

    # ---------- Perfil
    @app.route("/profile", methods=["GET","POST"])
    @login_required
    def profile():
        if request.method == "POST":
            full_name = (request.form.get("full_name") or "").strip()
            ship_address = (request.form.get("ship_address") or "").strip()
            favs = [t.strip().lower() for t in (request.form.get("favoritos") or "").split(",") if t.strip()]
            current_user.full_name = full_name or None
            current_user.ship_address = ship_address or None
            current_user.set_favoritos(favs)
            db.session.commit()
            flash("Perfil actualizado.", "success")
            return redirect(url_for("profile"))
        return render_template("profile.html")

    # ---------- Auth
    @app.route("/login", methods=["GET","POST"])
    def login():
        if request.method == "POST":
            email = (request.form.get("email") or "").strip().lower()
            pw = request.form.get("password") or ""
            user = User.query.filter_by(email=email).first()
            if not user or not user.check_password(pw):
                flash("Credenciales inválidas.", "danger"); return redirect(url_for("login"))
            login_user(user)
            if "cart" in session and session["cart"]: merge_session_cart_to_db(user.id)
            return redirect(url_for("index"))
        return render_template("login.html")

    @app.route("/register", methods=["GET","POST"])
    def register():
        if request.method == "POST":
            email = (request.form.get("email") or "").strip().lower()
            pw = request.form.get("password") or ""
            favs = [t.strip().lower() for t in (request.form.get("favoritos") or "").split(",") if t.strip()]
            try: validate_email(email)
            except Exception: flash("Email inválido.", "danger"); return redirect(url_for("register"))
            if len(pw) < 6: flash("La contraseña debe tener al menos 6 caracteres.", "warning"); return redirect(url_for("register"))
            if User.query.filter_by(email=email).first(): flash("Email ya registrado.", "warning"); return redirect(url_for("register"))
            u = User(email=email); u.set_password(pw); u.set_favoritos(favs)
            db.session.add(u); db.session.commit()
            login_user(u)
            if "cart" in session and session["cart"]: merge_session_cart_to_db(u.id)
            return redirect(url_for("index"))
        return render_template("register.html")

    @app.route("/logout")
    def logout():
        logout_user(); return redirect(url_for("index"))

    # ---------- Admin (incluye campos TCG + upload)
    def require_admin():
        if not current_user.is_authenticated: return redirect(url_for("login", next=request.path))
        if not current_user.is_admin: abort(403)

    @app.route("/admin/products", methods=["GET","POST"])
    def admin_products():
        res = require_admin()
        if res: return res
        if request.method == "POST":
            nombre = (request.form.get("nombre") or "").strip()
            tipo = (request.form.get("tipo") or "").strip().lower()
            categoria = (request.form.get("categoria") or "general").strip().lower()
            precio = float(request.form.get("precio") or 0)
            stock = int(request.form.get("stock") or 0)
            img = request.form.get("image_url") or ""
            desc = request.form.get("descripcion") or ""
            expa = request.form.get("expansion") or ""
            rarity = request.form.get("rarity") or ""
            language = request.form.get("language") or ""
            condition = request.form.get("condition") or ""
            card_number = request.form.get("card_number") or ""
            file = request.files.get("image_file")
            if file and allowed_file(file.filename):
                fn = secure_filename(file.filename)
                unique = f"{int(time.time())}_{uuid4().hex[:8]}_{fn}"
                path = os.path.join(app.config["UPLOAD_FOLDER"], unique)
                file.save(path); img = url_for("uploaded_file", filename=unique)
            if not nombre or not tipo or precio <= 0:
                flash("Completa nombre/tipo/precio.", "warning")
            else:
                p = PokemonProducto(nombre=nombre, tipo=tipo, categoria=categoria, precio_base=precio, stock=stock,
                                    image_url=img, descripcion=desc, expansion=expa, rarity=rarity, language=language,
                                    condition=condition, card_number=card_number)
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

# ================= templates =================
# base.html
$base_html = @'
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <title>{% block title %}PokeShop{% endblock %}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="{{ url_for('static', filename='styles.css') }}">
</head>
<body>
<header class="topbar">
  <div class="wrap">
    <a class="brand" href="{{ url_for('index') }}">PokeShop</a>
    <form class="search" action="{{ url_for('index') }}">
      <input name="q" placeholder="Buscar..." value="{{ request.args.get('q','') }}">
      <button>Buscar</button>
    </form>
    <nav>
      <a href="{{ url_for('cart_view') }}">Carrito</a>
      {% if current_user.is_authenticated %}
        <a href="{{ url_for('wishlist_view') }}">Favoritos</a>
        <a href="{{ url_for('history_view') }}">Historial</a>
        <a href="{{ url_for('orders_list') }}">Mis pedidos</a>
        <a href="{{ url_for('profile') }}">Perfil</a>
        {% if current_user.is_admin %}
          <a href="{{ url_for('admin_products') }}">Admin</a>
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
    <span>© {{ 2025 }} PokeShop (demo)</span>
  </div>
</footer>
</body>
</html>
'@
Set-Content "templates/base.html" $base_html -Encoding UTF8

# index.html (con facetas TCG)
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
  {% if cat == 'tcg' %}
    <select name="exp"><option value="">Expansión (todas)</option>
      {% for v in facets.exp %}<option value="{{v}}" {% if exp==v %}selected{% endif %}>{{v}}</option>{% endfor %}
    </select>
    <select name="rare"><option value="">Rareza (todas)</option>
      {% for v in facets.rare %}<option value="{{v}}" {% if rare==v %}selected{% endif %}>{{v}}</option>{% endfor %}
    </select>
    <select name="lang"><option value="">Idioma (todos)</option>
      {% for v in facets.lang %}<option value="{{v}}" {% if lang==v %}selected{% endif %}>{{v}}</option>{% endfor %}
    </select>
    <select name="cond"><option value="">Condición (todas)</option>
      {% for v in facets.cond %}<option value="{{v}}" {% if cond==v %}selected{% endif %}>{{v}}</option>{% endfor %}
    </select>
  {% endif %}
  <button>Aplicar</button>
</form>

{% if featured_tcg and (not q) and (not tipo) and (not cat or cat=='tcg') %}
  <h3 style="margin:8px 0">Cartas TCG destacadas</h3>
  <div class="grid">
    {% for p in featured_tcg %}
      <a class="card" href="{{ url_for('product_detail', pid=p.id) }}">
        <img src="{{ p.image_url or url_for('static', filename='noimg.png') }}" alt="{{ p.nombre }}">
        <div class="title">{{ p.nombre }}</div>
        <div class="muted">Tipo: {{ p.tipo|capitalize }} · TCG</div>
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
      <a class="btn" href="{{ url_for('index', q=q, tipo=tipo, cat=cat, sort=sort, exp=exp, rare=rare, lang=lang, cond=cond, page=pag.prev_num) }}">← Anterior</a>
    {% endif %}
    {% if pag.has_next %}
      <a class="btn" href="{{ url_for('index', q=q, tipo=tipo, cat=cat, sort=sort, exp=exp, rare=rare, lang=lang, cond=cond, page=pag.next_num) }}">Siguiente →</a>
    {% endif %}
  </div>
</nav>
{% endif %}
{% endblock %}
'@
Set-Content "templates/index.html" $index_html -Encoding UTF8

# product.html: insertar bloque Metadatos TCG justo tras el primer </p> (Regex.Replace con count=1)
if(Test-Path "templates\product.html"){
  $prod = Get-Content "templates\product.html" -Raw
  if($prod -notmatch "Metadatos TCG"){
    $meta = @'
    <div class="muted" style="margin:6px 0">
      {% if p.categoria == 'tcg' %}
        <div><b>Metadatos TCG</b>:
          {% if p.expansion %} Expansión: {{ p.expansion }} ·{% endif %}
          {% if p.rarity %} Rareza: {{ p.rarity }} ·{% endif %}
          {% if p.language %} Idioma: {{ p.language }} ·{% endif %}
          {% if p.condition %} Condición: {{ p.condition }} ·{% endif %}
          {% if p.card_number %} Nº: {{ p.card_number }}{% endif %}
        </div>
      {% endif %}
    </div>
'@
    $regex = [regex]'(</p>)'
    $replacement = '$1' + "`r`n" + $meta
    $prod = $regex.Replace($prod, $replacement, 1)
    Set-Content "templates\product.html" $prod -Encoding UTF8
    Write-Host "Metadatos TCG insertados en product.html"
  } else {
    Write-Host "product.html ya contiene Metadatos TCG (no se modifica)."
  }
} else {
  Write-Host "Aviso: templates\product.html no existe; no se pudo insertar metadatos." -ForegroundColor Yellow
}

# checkout.html (autocompletar con perfil)
$checkout_html = @'
{% extends "base.html" %}
{% block title %}Checkout · PokeShop{% endblock %}
{% block content %}
<h1>Checkout</h1>
<form method="post" class="checkout">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <label>Nombre completo <input name="name" value="{{ current_user.full_name or '' }}" required></label>
  <label>Dirección <input name="address" value="{{ current_user.ship_address or '' }}" required></label>
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

# admin_products.html (con campos TCG)
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

  <h3>Metadatos TCG (opcional)</h3>
  <input name="expansion" placeholder="Expansión">
  <input name="rarity" placeholder="Rareza">
  <input name="language" placeholder="Idioma (EN, ES...)">
  <input name="condition" placeholder="Condición (NM, LP...)">
  <input name="card_number" placeholder="Nº de carta">

  <button class="btn primary">Crear</button>
</form>

<h3>Listado</h3>
<div class="grid">
  {% for p in products %}
  <div class="card">
    <img src="{{ p.image_url }}" alt="{{ p.nombre }}">
    <div class="title">{{ p.nombre }}</div>
    <div class="muted">{{ p.tipo|capitalize }} · {{ p.categoria|capitalize }} · Stock {{ p.stock }}</div>
    <div class="muted">
      {% if p.categoria == 'tcg' %}
        {% if p.expansion %} {{ p.expansion }} ·{% endif %}
        {% if p.rarity %} {{ p.rarity }} ·{% endif %}
        {% if p.language %} {{ p.language }} ·{% endif %}
        {% if p.condition %} {{ p.condition }} ·{% endif %}
        {% if p.card_number %} Nº {{ p.card_number }}{% endif %}
      {% endif %}
    </div>
    <div class="price">$ {{ "%.2f"|format(p.precio_base) }}</div>
  </div>
  {% endfor %}
</div>
{% endblock %}
'@
Set-Content "templates/admin_products.html" $admin_html -Encoding UTF8

# profile.html
$profile_html = @'
{% extends "base.html" %}
{% block title %}Mi perfil · PokeShop{% endblock %}
{% block content %}
<h1>Mi perfil</h1>
<form method="post" class="auth">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <label>Nombre completo
    <input name="full_name" value="{{ current_user.full_name or '' }}">
  </label>
  <label>Dirección de envío
    <input name="ship_address" value="{{ current_user.ship_address or '' }}">
  </label>
  <label>Tipos favoritos (coma separada)
    <input name="favoritos" placeholder="fuego,agua" value="{{ (current_user.get_favoritos() | join(', ')) if current_user.get_favoritos() else '' }}">
  </label>
  <button class="btn primary">Guardar</button>
</form>
{% endblock %}
'@
Set-Content "templates/profile.html" $profile_html -Encoding UTF8

# ================= upgrade_v6.py (migración DB + FTS5) =================
$upgrade_py = @'
from app import create_app
from models import db

app = create_app()
with app.app_context():
    def has_col(table, col):
        rows = db.session.execute(db.text(f"PRAGMA table_info({table})")).fetchall()
        cols = [r[1] for r in rows]
        return col in cols

    if not has_col("users","full_name"):
        db.session.execute(db.text("ALTER TABLE users ADD COLUMN full_name VARCHAR(200)"))
    if not has_col("users","ship_address"):
        db.session.execute(db.text("ALTER TABLE users ADD COLUMN ship_address VARCHAR(400)"))

    if not has_col("productos","categoria"):
        db.session.execute(db.text("ALTER TABLE productos ADD COLUMN categoria VARCHAR(50) DEFAULT 'general'"))
    for col, sqltype in [
        ("expansion","VARCHAR(120)"), ("rarity","VARCHAR(120)"),
        ("language","VARCHAR(30)"), ("condition","VARCHAR(60)"),
        ("card_number","VARCHAR(40)")
    ]:
        if not has_col("productos", col):
            db.session.execute(db.text(f"ALTER TABLE productos ADD COLUMN {col} {sqltype}"))
    db.session.commit()

    exists = db.session.execute(db.text("SELECT name FROM sqlite_master WHERE type='table' AND name='product_fts'")).fetchone()
    if not exists:
        db.session.execute(db.text("""
            CREATE VIRTUAL TABLE product_fts USING fts5(
              nombre, descripcion, content='productos', content_rowid='id'
            );
        """))
        db.session.execute(db.text("""
            INSERT INTO product_fts(rowid, nombre, descripcion)
            SELECT id, COALESCE(nombre,''), COALESCE(descripcion,'') FROM productos;
        """))
        db.session.execute(db.text("""
        CREATE TRIGGER productos_ai AFTER INSERT ON productos BEGIN
          INSERT INTO product_fts(rowid, nombre, descripcion) VALUES (new.id, COALESCE(new.nombre,''), COALESCE(new.descripcion,''));
        END;"""))
        db.session.execute(db.text("""
        CREATE TRIGGER productos_ad AFTER DELETE ON productos BEGIN
          INSERT INTO product_fts(product_fts, rowid, nombre, descripcion) VALUES('delete', old.id, '', '');
        END;"""))
        db.session.execute(db.text("""
        CREATE TRIGGER productos_au AFTER UPDATE ON productos BEGIN
          INSERT INTO product_fts(product_fts, rowid, nombre, descripcion) VALUES('delete', old.id, '', '');
          INSERT INTO product_fts(rowid, nombre, descripcion) VALUES (new.id, COALESCE(new.nombre,''), COALESCE(new.descripcion,''));
        END;"""))
        db.session.commit()
        print("FTS5 creado y poblado.")
    else:
        print("FTS5 ya existe.")

    print("Upgrade v6 listo.")
'@
Set-Content "upgrade_v6.py" $upgrade_py -Encoding UTF8

# ================= import_tcg_api.py (importador) =================
$import_py = @'
import os, time, random
import requests
from app import create_app
from models import db, PokemonProducto

API = "https://api.pokemontcg.io/v2/cards"
API_KEY = os.getenv("POKEMONTCG_API_KEY")  # opcional

TYPE_MAP = {
    "Fire":"fuego","Water":"agua","Lightning":"eléctrico","Grass":"planta",
    "Dragon":"dragón","Psychic":"psíquico","Darkness":"siniestro","Fighting":"lucha",
    "Metal":"acero","Colorless":"incoloro","Fairy":"hada","Ice":"hielo","Rock":"roca",
}

def fetch_cards(query, pageSize=50):
    headers = {"Accept":"application/json"}
    if API_KEY: headers["X-Api-Key"] = API_KEY
    r = requests.get(API, params={"q":query, "pageSize":pageSize, "orderBy":"-set.releaseDate"}, headers=headers, timeout=25)
    r.raise_for_status()
    return r.json().get("data", [])

def upsert(card) -> bool:
    name = card.get("name","")
    set_name = (card.get("set") or {}).get("name","")
    number = card.get("number","")
    total = (card.get("set") or {}).get("total") or "?"
    nombre = f"{name} - {set_name} {number}/{total}"

    tipo_api = (card.get("types") or ["Colorless"])[0]
    tipo = TYPE_MAP.get(tipo_api, "incoloro")
    img = (card.get("images") or {}).get("large") or (card.get("images") or {}).get("small")
    rarity = card.get("rarity") or ""
    language = "EN"
    condition = "NM"
    expansion = set_name
    card_number = f"{number}/{total}"

    price = 9.99
    tp = card.get("tcgplayer") or {}
    prices = (tp.get("prices") or {})
    for k in ["holofoil","reverseHolofoil","normal","1stEditionHolofoil","unlimitedHolofoil","rareHoloEX"]:
        if k in prices and "market" in prices[k] and prices[k]["market"]:
            try: price = max(2.99, float(prices[k]["market"]))
            except Exception: pass
            break
    stock = random.randint(1, 20)

    if PokemonProducto.query.filter_by(nombre=nombre).first():
        return False
    db.session.add(PokemonProducto(
        nombre=nombre, tipo=tipo, categoria="tcg", precio_base=round(price,2), stock=stock,
        image_url=img, descripcion=f"Carta TCG • Expansión: {expansion} • Rareza: {rarity} • Idioma: {language} • Nº: {card_number}",
        expansion=expansion, rarity=rarity, language=language, condition=condition, card_number=card_number
    ))
    return True

if __name__ == "__main__":
    app = create_app()
    added = 0
    with app.app_context():
        queries = [
            'set.id:sv4', 'set.id:sv3', 'set.id:sv2', 'set.id:sv1',
            'set.id:swsh7', 'name:Charizard',
            'supertype:Pokémon rarity:"Rare Holo"'
        ]
        for q in queries:
            cards = fetch_cards(q, pageSize=50)
            for c in cards:
                if upsert(c): added += 1
            time.sleep(0.6)
        db.session.commit()
    print(f"TCG importadas: {added}")
'@
Set-Content "import_tcg_api.py" $import_py -Encoding UTF8

Write-Host "v6 escrita. Archivos en UTF-8." -ForegroundColor Green
Write-Host "Siguientes pasos:" -ForegroundColor Cyan
Write-Host "1) .\\.venv\\Scripts\\Activate.ps1"
Write-Host "2) pip install -r requirements.txt"
Write-Host "3) python upgrade_v6.py    (migración columnas + FTS5)"
Write-Host "4) (Opcional) $env:POKEMONTCG_API_KEY='tu_key' ; python import_tcg_api.py"
Write-Host "5) python app.py"