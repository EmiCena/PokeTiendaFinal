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

    # CatÃ¡logo con bÃºsqueda, filtros, orden y paginaciÃ³n
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

    # Detalle con precio dinÃ¡mico y recomendaciones
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

    # API precio dinÃ¡mico
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
        flash(f"AÃ±adido al carrito: {p.nombre} (x{qty})", "success")
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
        flash("Carrito vacÃ­o.", "info")
        return redirect(url_for("cart_view"))

    # Checkout con cupÃ³n
    @app.route("/checkout", methods=["GET","POST"])
    @login_required
    def checkout():
        items = cart_items_with_products()
        if not items:
            flash("Tu carrito estÃ¡ vacÃ­o.", "warning")
            return redirect(url_for("index"))
        if request.method == "POST":
            name = request.form.get("name","").strip()
            address = request.form.get("address","").strip()
            coupon = (request.form.get("coupon") or "").strip()
            if not name or not address:
                flash("Completa nombre y direcciÃ³n.", "warning")
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
                    flash("CupÃ³n invÃ¡lido o no disponible.", "warning")
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
                flash("Credenciales invÃ¡lidas.", "danger")
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
                flash("Email invÃ¡lido.", "danger"); return redirect(url_for("register"))
            if len(pw) < 6:
                flash("La contraseÃ±a debe tener al menos 6 caracteres.", "warning"); return redirect(url_for("register"))
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
