# upgrade_v4.ps1
# v4: carrito persistente en BD + merge al iniciar sesión/registrarse
# Requiere que ya tengas la v3 (wishlist, historial, reseñas, uploads, UTF‑8)

$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }

# Chequeos
$rootFiles = @("app.py","models.py","requirements.txt")
foreach($f in $rootFiles){ if(-not (Test-Path $f)){ Write-Error "No encuentro $f. Corré el script en la raíz del proyecto."; exit 1 } }

Ensure-Dir "templates"; Ensure-Dir "static"; Ensure-Dir "services"; Ensure-Dir "uploads"

# Backup
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = "backup_v3_$ts"
Ensure-Dir $backupDir
Copy-Item app.py "$backupDir\app.py"
Copy-Item models.py "$backupDir\models.py"
Copy-Item requirements.txt "$backupDir\requirements.txt"
if(Test-Path "templates"){ Copy-Item "templates" "$backupDir\templates" -Recurse }
if(Test-Path "static"){ Copy-Item "static" "$backupDir\static" -Recurse }
if(Test-Path "services"){ Copy-Item "services" "$backupDir\services" -Recurse }
Write-Host "Backup creado en $backupDir" -ForegroundColor Green

# =================== app.py (v4 completa) ===================
$app_py = @'
import os, time
from uuid import uuid4
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify, abort, send_from_directory
from flask_login import LoginManager, login_user, login_required, logout_user, current_user
from email_validator import validate_email
from flask_wtf.csrf import CSRFProtect, generate_csrf
from sqlalchemy import func
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
    app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024  # 5 MB
    app.config["JSON_AS_ASCII"] = False  # UTF-8 en JSON
    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    db.init_app(app)
    csrf.init_app(app)

    @app.context_processor
    def inject_csrf():
        return dict(csrf_token=generate_csrf)

    @app.after_request
    def ensure_utf8(resp):
        # Blindar HTML con charset utf-8 (por si algún proxy lo pierde)
        if resp.mimetype == "text/html" and "charset" not in (resp.content_type or "").lower():
            resp.headers["Content-Type"] = "text/html; charset=utf-8"
        return resp

    login_manager = LoginManager(app)
    login_manager.login_view = "login"

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    precio_service = PrecioDinamicoService()

    # -------- Helpers (carrito)
    def get_cart_session():
        if "cart" not in session:
            session["cart"] = {}
        return session["cart"]

    def add_to_cart_db(user_id: int, product_id: int, qty: int):
        ci = CartItem.query.filter_by(user_id=user_id, product_id=product_id).first()
        if ci:
            ci.quantity = min(99, ci.quantity + qty)
        else:
            ci = CartItem(user_id=user_id, product_id=product_id, quantity=min(99, qty))
            db.session.add(ci)
        db.session.commit()

    def get_cart_items_db(user_id: int):
        rows = db.session.query(CartItem, PokemonProducto)\
            .join(PokemonProducto, PokemonProducto.id == CartItem.product_id)\
            .filter(CartItem.user_id == user_id).all()
        return [{"product": p, "qty": ci.quantity} for (ci, p) in rows]

    def clear_cart_db(user_id: int):
        CartItem.query.filter_by(user_id=user_id).delete()
        db.session.commit()

    def merge_session_cart_to_db(user_id: int):
        cart = session.get("cart", {})
        for pid, qty in cart.items():
            add_to_cart_db(user_id, int(pid), int(qty))
        session.pop("cart", None)

    def cart_items_with_products():
        # Usuario logueado → carrito en DB
        if current_user.is_authenticated:
            raw = get_cart_items_db(current_user.id)
            out = []
            for it in raw:
                p = it["product"]; qty = it["qty"]
                precio, _, _ = precio_service.calcular_precio(p, current_user)
                out.append({"product": p, "qty": qty, "unit_price": precio})
            return out
        # Invitado → carrito en sesión
        cart = session.get("cart", {})
        out = []
        for pid, qty in cart.items():
            p = PokemonProducto.query.get(int(pid))
            if not p: 
                continue
            precio, _, _ = precio_service.calcular_precio(p, None)
            out.append({"product": p, "qty": qty, "unit_price": precio})
        return out

    # -------- Static uploads
    @app.route("/uploads/<path:filename>")
    def uploaded_file(filename):
        return send_from_directory(app.config["UPLOAD_FOLDER"], filename)

    # -------- Catálogo con filtros, orden y paginación
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

    # -------- Detalle: precio dinámico, recomendaciones, reseñas, wishlist
    @app.route("/product/<int:pid>")
    def product_detail(pid: int):
        p = PokemonProducto.query.get_or_404(pid)

        # registrar vista si está logueado
        if current_user.is_authenticated:
            db.session.add(ProductView(user_id=current_user.id, product_id=p.id))
            db.session.commit()

        precio, razones, feats = precio_service.calcular_precio(
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
        my_review = None
        if current_user.is_authenticated:
            my_review = Review.query.filter_by(product_id=p.id, user_id=current_user.id).first()

        purchasers = {uid for (uid,) in db.session.query(Order.user_id)
                      .join(OrderItem, Order.id == OrderItem.order_id)
                      .filter(OrderItem.product_id == p.id).all()}

        in_wishlist = False
        if current_user.is_authenticated:
            in_wishlist = Wishlist.query.filter_by(user_id=current_user.id, product_id=p.id).first() is not None

        return render_template("product.html",
            p=p, precio=precio, razones=razones, feats=feats, recs=recs,
            reviews=reviews, avg_rating=avg_rating, my_review=my_review,
            purchasers=purchasers, in_wishlist=in_wishlist
        )

    # -------- Reseñas
    @app.post("/product/<int:pid>/review")
    @login_required
    def post_review(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        rating = max(1, min(5, int(request.form.get("rating") or 0)))
        comment = (request.form.get("comment") or "").strip()
        rv = Review.query.filter_by(product_id=p.id, user_id=current_user.id).first()
        if rv:
            rv.rating = rating
            rv.comment = comment
            rv.created_at = datetime.utcnow()
        else:
            rv = Review(product_id=p.id, user_id=current_user.id, rating=rating, comment=comment)
            db.session.add(rv)
        db.session.commit()
        flash("Tu reseña fue guardada.", "success")
        return redirect(url_for("product_detail", pid=p.id))

    # -------- Wishlist
    @app.get("/wishlist")
    @login_required
    def wishlist_view():
        rows = db.session.query(Wishlist, PokemonProducto)\
               .join(PokemonProducto, PokemonProducto.id == Wishlist.product_id)\
               .filter(Wishlist.user_id == current_user.id)\
               .order_by(Wishlist.created_at.desc()).all()
        items = [{"product": p, "ts": w.created_at} for (w,p) in rows]
        return render_template("wishlist.html", items=items)

    @app.post("/wishlist/add/<int:pid>")
    @login_required
    def wishlist_add(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        if not Wishlist.query.filter_by(user_id=current_user.id, product_id=p.id).first():
            db.session.add(Wishlist(user_id=current_user.id, product_id=p.id))
            db.session.commit()
            flash("Añadido a favoritos.", "success")
        return redirect(request.referrer or url_for("product_detail", pid=p.id))

    @app.post("/wishlist/remove/<int:pid>")
    @login_required
    def wishlist_remove(pid: int):
        w = Wishlist.query.filter_by(user_id=current_user.id, product_id=pid).first()
        if w:
            db.session.delete(w); db.session.commit()
            flash("Quitado de favoritos.", "info")
        return redirect(request.referrer or url_for("wishlist_view"))

    # -------- Historial
    @app.get("/history")
    @login_required
    def history_view():
        rows = db.session.query(PokemonProducto, func.max(ProductView.ts).label("last"))\
            .join(ProductView, ProductView.product_id == PokemonProducto.id)\
            .filter(ProductView.user_id == current_user.id)\
            .group_by(PokemonProducto.id)\
            .order_by(func.max(ProductView.ts).desc())\
            .limit(30).all()
        items = [{"product": p, "last": last} for (p,last) in rows]
        return render_template("history.html", items=items)

    # -------- API precio dinámico
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

    # -------- Carrito (DB si logueado, sesión si invitado)
    @app.post("/cart/add/<int:pid>")
    def cart_add(pid):
        p = PokemonProducto.query.get_or_404(pid)
        qty = max(1, min(99, request.form.get("qty", type=int) or 1))
        if current_user.is_authenticated:
            add_to_cart_db(current_user.id, p.id, qty)
        else:
            cart = get_cart_session()
            cart[str(pid)] = min(99, cart.get(str(pid), 0) + qty)
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
        if current_user.is_authenticated:
            clear_cart_db(current_user.id)
        else:
            session.pop("cart", None)
        flash("Carrito vacío.", "info")
        return redirect(url_for("cart_view"))

    # -------- Checkout (con cupón) + limpiar carrito (DB/sesión)
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
                p = it["product"]; qty = it["qty"]
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
            # Limpiar carrito según origen
            clear_cart_db(current_user.id)
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

    # -------- Auth (fusionar carrito de sesión → DB)
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
            if "cart" in session and session["cart"]:
                merge_session_cart_to_db(user.id)
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
            if "cart" in session and session["cart"]:
                merge_session_cart_to_db(u.id)
            return redirect(url_for("index"))
        return render_template("register.html")

    @app.route("/logout")
    def logout():
        logout_user()
        return redirect(url_for("index"))

    # -------- Admin (con upload de imagen)
    def require_admin():
        if not current_user.is_authenticated:
            return redirect(url_for("login", next=request.path))
        if not current_user.is_admin:
            abort(403)

    @app.route("/admin/products", methods=["GET","POST"])
    def admin_products():
        res = require_admin()
        if res: return res
        if request.method == "POST":
            nombre = request.form.get("nombre","").strip()
            tipo = request.form.get("tipo","").strip().lower()
            precio = float(request.form.get("precio") or 0)
            stock = int(request.form.get("stock") or 0)
            img = request.form.get("image_url") or ""
            desc = request.form.get("descripcion") or ""
            file = request.files.get("image_file")
            if file and allowed_file(file.filename):
                fn = secure_filename(file.filename)
                unique = f"{int(time.time())}_{uuid4().hex[:8]}_{fn}"
                path = os.path.join(app.config["UPLOAD_FOLDER"], unique)
                file.save(path)
                img = url_for("uploaded_file", filename=unique)
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
'
Set-Content -Path "app.py" -Value $app_py -Encoding UTF8

# =================== models.py (añade CartItem) ===================
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

# =================== upgrade_v4.py (migración) ===================
$upgrade_py = @'
from app import create_app
from models import db, CartItem

app = create_app()
with app.app_context():
    db.create_all()
    print("Upgrade v4: tabla CartItem creada.")
'@
Set-Content "upgrade_v4.py" $upgrade_py -Encoding UTF8

Write-Host "v4 aplicada. Archivos escritos en UTF-8." -ForegroundColor Green
Write-Host ""
Write-Host "Siguientes pasos:" -ForegroundColor Cyan
Write-Host "1) pip install -r requirements.txt"
Write-Host "2) python upgrade_v4.py   (crea la tabla del carrito)"
Write-Host "3) python app.py          (levanta la app)"
Write-Host ""
Write-Host "Prueba: agrega productos como invitado → logueate → el carrito se fusiona y persiste en la BD."