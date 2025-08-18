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

    # ---------- Helpers carrito (DB / sesiÃ³n)
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
        # tokeniza y agrega * a cada tÃ©rmino
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
        # valores distintos para filtros
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

    # ---------- CatÃ¡logo (bÃºsqueda FTS + facetas TCG)
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

        # BÃºsqueda
        if q:
            if fts_available():
                ids = fts_match_ids(q)
                if ids:
                    qry = qry.filter(PokemonProducto.id.in_(ids))
                else:
                    qry = qry.filter(PokemonProducto.id == -1)  # sin resultados
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

        if sort == "price_asc":
            qry = qry.order_by(PokemonProducto.precio_base.asc())
        elif sort == "price_desc":
            qry = qry.order_by(PokemonProducto.precio_base.desc())
        else:
            qry = qry.order_by(PokemonProducto.created_at.desc())

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

    # ---------- ReseÃ±as
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
        flash("Tu reseÃ±a fue guardada.", "success")
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
            flash("AÃ±adido a favoritos.", "success")
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
        flash(f"AÃ±adido al carrito: {p.nombre} (x{qty})", "success")
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
        flash("Carrito vacÃ­o.", "info")
        return redirect(url_for("cart_view"))

    # ---------- Checkout (autocompletar con perfil)
    @app.route("/checkout", methods=["GET","POST"])
    @login_required
    def checkout():
        items = cart_items_with_products()
        if not items:
            flash("Tu carrito estÃ¡ vacÃ­o.", "warning"); return redirect(url_for("index"))
        if request.method == "POST":
            name = (request.form.get("name") or current_user.full_name or "").strip()
            address = (request.form.get("address") or current_user.ship_address or "").strip()
            coupon = (request.form.get("coupon") or "").strip()
            if not name or not address:
                flash("Completa nombre y direcciÃ³n.", "warning"); return redirect(url_for("checkout"))
            total = 0.0
            for it in items:
                p = it["product"]; qty = it["qty"]
                if qty > p.stock: flash(f"Stock insuficiente para {p.nombre}.", "danger"); return redirect(url_for("cart_view"))
                total += it["unit_price"] * qty
            promo = None
            if coupon:
                promo = PromoCode.query.filter(func.lower(PromoCode.code) == coupon.lower()).first()
                if not promo or not promo.usable(): flash("CupÃ³n invÃ¡lido o no disponible.", "warning"); promo = None
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
                flash("Credenciales invÃ¡lidas.", "danger"); return redirect(url_for("login"))
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
            except Exception: flash("Email invÃ¡lido.", "danger"); return redirect(url_for("register"))
            if len(pw) < 6: flash("La contraseÃ±a debe tener al menos 6 caracteres.", "warning"); return redirect(url_for("register"))
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
        res = require_admin(); if res: return res
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
