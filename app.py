# -*- coding: utf-8 -*-
import os
import time
from uuid import uuid4
from datetime import datetime

from flask import (
    Flask, render_template, request, redirect, url_for,
    session, flash, jsonify, abort, send_from_directory
)
from flask import current_app as flask_current_app
from flask_login import (
    LoginManager, login_user, login_required,
    logout_user, current_user
)

# email_validator opcional
try:
    from email_validator import validate_email
except Exception:
    def validate_email(email):
        if "@" not in email:
            raise ValueError("Invalid email")

from flask_wtf.csrf import CSRFProtect, generate_csrf
from sqlalchemy import func, text, or_
from werkzeug.utils import secure_filename

from models import (
    db, User, PokemonProducto, Order, OrderItem, ProductView,
    PromoCode, Wishlist, Review, CartItem
)

# Precio dinámico opcional (fallback al precio_base)
try:
    from services.precio_dinamico_service import PrecioDinamicoService
except Exception:
    class PrecioDinamicoService:
        def calcular_precio(self, p, user):
            base = float(getattr(p, "precio_base", 0.0) or 0.0)
            return base, [], {}

# AI opcional (búsqueda semántica / RAG)
try:
    from ai.search_service import semantic_search
except Exception:
    def semantic_search(q, k=16, filters=None):
        return []

try:
    from ai.rag_assistant import answer_question
except Exception:
    def answer_question(q, k=5):
        return None, []

# Groq opcional
_groq_import_error = None
try:
    from services.groq_service import groq_chat, GROQ_MODEL
except Exception as ex:
    GROQ_MODEL = None
    _groq_import_error = f"{type(ex).__name__}: {ex}"
    def groq_chat(_messages, **kwargs):
        raise RuntimeError(f"Groq no disponible: {_groq_import_error}")

ALLOWED_EXTS = {"png", "jpg", "jpeg", "gif", "webp"}
csrf = CSRFProtect()


def allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTS


def create_app():
    app = Flask(__name__)
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret")

    # DB absoluta
    db_path = os.path.join(app.root_path, "store.db")
    app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_path}"
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    app.config["UPLOAD_FOLDER"] = os.path.join(app.root_path, "uploads")
    app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024
    app.config["JSON_AS_ASCII"] = False
    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    db.init_app(app)
    csrf.init_app(app)

    @app.after_request
    def ensure_utf8(resp):
        if resp.mimetype == "text/html" and "charset" not in (resp.content_type or "").lower():
            resp.headers["Content-Type"] = "text/html; charset=utf-8"
        return resp

    @app.context_processor
    def inject_globals():
        def has_endpoint(name: str) -> bool:
            try:
                return name in app.view_functions
            except Exception:
                return False

        def get_cart_qty():
            try:
                if current_user.is_authenticated:
                    return int(
                        db.session.query(func.coalesce(func.sum(CartItem.quantity), 0))
                        .filter(CartItem.user_id == current_user.id)
                        .scalar() or 0
                    )
                return sum(int(q) for q in session.get("cart", {}).values())
            except Exception:
                return 0

        return dict(
            csrf_token=generate_csrf,
            has_packs=("packs_bp" in app.blueprints),
            has_endpoint=has_endpoint,
            current_app=flask_current_app,
            cart_qty=get_cart_qty(),
        )

    login_manager = LoginManager(app)
    login_manager.login_view = "login"

    @login_manager.user_loader
    def load_user(user_id):
        try:
            return User.query.get(int(user_id))
        except Exception:
            return None

    precio_service = PrecioDinamicoService()

    # ---------- Helpers carrito (DB / sesión)
    def get_cart_session():
        if "cart" not in session:
            session["cart"] = {}
        return session["cart"]

    def add_to_cart_db(user_id: int, product_id: int, qty: int):
        ci = CartItem.query.filter_by(user_id=user_id, product_id=product_id).first()
        if ci:
            ci.quantity = min(99, ci.quantity + qty)
        else:
            db.session.add(CartItem(user_id=user_id, product_id=product_id, quantity=min(99, qty)))
        db.session.commit()

    def get_cart_items_db(user_id: int):
        rows = (
            db.session.query(CartItem, PokemonProducto)
            .join(PokemonProducto, PokemonProducto.id == CartItem.product_id)
            .filter(CartItem.user_id == user_id)
            .all()
        )
        return [{"product": p, "qty": ci.quantity} for (ci, p) in rows]

    def clear_cart_db(user_id: int):
        CartItem.query.filter_by(user_id=user_id).delete()
        db.session.commit()

    def update_cart_db_bulk(user_id: int, updates):
        for pid, qty in updates.items():
            ci = CartItem.query.filter_by(user_id=user_id, product_id=pid).first()
            if qty <= 0:
                if ci:
                    db.session.delete(ci)
            else:
                if ci:
                    ci.quantity = min(99, qty)
                else:
                    db.session.add(CartItem(user_id=user_id, product_id=pid, quantity=min(99, qty)))
        db.session.commit()

    def remove_from_cart_db(user_id: int, product_id: int):
        CartItem.query.filter_by(user_id=user_id, product_id=product_id).delete()
        db.session.commit()

    def merge_session_cart_to_db(user_id: int):
        cart = session.get("cart", {})
        for pid, qty in cart.items():
            add_to_cart_db(user_id, int(pid), int(qty))
        session.pop("cart", None)

    def cart_items_with_products():
        out = []
        if current_user.is_authenticated:
            rows = (
                db.session.query(CartItem, PokemonProducto)
                .join(PokemonProducto, PokemonProducto.id == CartItem.product_id)
                .filter(CartItem.user_id == current_user.id)
                .all()
            )
            for ci, p in rows:
                precio, _, _ = precio_service.calcular_precio(p, current_user)
                out.append({"product": p, "qty": ci.quantity, "unit_price": precio})
            return out
        else:
            cart = session.get("cart", {})
            if not cart:
                return []
            pids = [int(pid) for pid in cart.keys()]
            products = PokemonProducto.query.filter(PokemonProducto.id.in_(pids)).all()
            products_map = {p.id: p for p in products}
            for pid_str, qty_str in cart.items():
                pid = int(pid_str)
                qty = int(qty_str)
                p = products_map.get(pid)
                if not p:
                    continue
                precio, _, _ = precio_service.calcular_precio(p, None)
                out.append({"product": p, "qty": qty, "unit_price": precio})
            return out

    # ---------- FTS5 utilidades
    def fts_available():
        row = db.session.execute(text(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='product_fts'"
        )).fetchone()
        return bool(row)

    def fts_match_ids(q: str, limit: int = 200):
        terms = [t for t in q.split() if t]
        if not terms:
            return []
        pattern = " ".join([f"{t}*" for t in terms])
        try:
            rows = db.session.execute(
                text("SELECT rowid FROM product_fts WHERE product_fts MATCH :pat LIMIT :lim"),
                {"pat": pattern, "lim": limit}
            ).fetchall()
            return [int(r[0]) for r in rows]
        except Exception:
            return []

    _tcg_facets_cache = {"data": None, "timestamp": None}
    _TCG_FACETS_CACHE_TTL_SECONDS = 3600

    def tcg_facets():
        now = datetime.utcnow()
        if (
            _tcg_facets_cache["data"] is not None and
            _tcg_facets_cache["timestamp"] is not None and
            (now - _tcg_facets_cache["timestamp"]).total_seconds() < _TCG_FACETS_CACHE_TTL_SECONDS
        ):
            return _tcg_facets_cache["data"]

        base = PokemonProducto.query.filter(PokemonProducto.categoria == "tcg")

        def distinct(col):
            rows = (
                base.with_entities(col)
                .filter(col.isnot(None), col != "")
                .distinct()
                .order_by(col.asc())
                .all()
            )
            return [r[0] for r in rows]

        facets_data = {
            "exp": distinct(PokemonProducto.expansion),
            "rare": distinct(PokemonProducto.rarity),
            "lang": distinct(PokemonProducto.language),
            "cond": distinct(PokemonProducto.condition),
        }
        _tcg_facets_cache["data"] = facets_data
        _tcg_facets_cache["timestamp"] = now
        return facets_data

    # ---------- Static uploads
    @app.route("/uploads/<path:filename>")
    def uploaded_file(filename):
        return send_from_directory(app.config["UPLOAD_FOLDER"], filename)

    # ---------- Auth: logout/login/register
    @app.route("/login", methods=["GET", "POST"], endpoint="login")
    def login():
        if current_user.is_authenticated:
            return redirect(url_for("index"))

        if request.method == "POST":
            email = request.form.get("email")
            password = request.form.get("password")
            user = User.query.filter_by(email=email).first()

            if user and user.check_password(password):
                login_user(user)
                merge_session_cart_to_db(user.id)
                flash("Inicio de sesión exitoso.", "success")
                next_page = request.args.get("next")
                return redirect(next_page or url_for("index"))
            else:
                flash("Email o contraseña inválidos.", "danger")
        return render_template("login.html")

    @app.route("/register", methods=["GET", "POST"], endpoint="register")
    def register():
        if current_user.is_authenticated:
            return redirect(url_for("index"))

        if request.method == "POST":
            email = request.form.get("email")
            password = request.form.get("password")
            full_name = request.form.get("full_name")
            ship_address = request.form.get("ship_address")

            if not email or not password:
                flash("Email y contraseña son requeridos.", "danger")
                return render_template("register.html", email=email, full_name=full_name, ship_address=ship_address)

            try:
                validate_email(email)
            except ValueError as e:
                flash(f"Email inválido: {e}", "danger")
                return render_template("register.html", email=email, full_name=full_name, ship_address=ship_address)

            if User.query.filter_by(email=email).first():
                flash("Ya existe un usuario con ese email.", "danger")
                return render_template("register.html", email=email, full_name=full_name, ship_address=ship_address)

            new_user = User(email=email, full_name=full_name, ship_address=ship_address)
            new_user.set_password(password)
            db.session.add(new_user)
            db.session.commit()
            flash("Registro exitoso. Por favor, inicia sesión.", "success")
            return redirect(url_for("login"))

        return render_template("register.html")

    @app.get("/logout", endpoint="logout")
    def logout():
        if current_user.is_authenticated:
            try:
                logout_user()
            except Exception:
                pass
        session.pop("cart", None)
        flash("Sesión cerrada.", "success")
        return redirect(url_for("index"))

    # ---------- Carrito
    @app.get("/cart", endpoint="cart")
    @app.get("/cart/view", endpoint="cart_view")
    def cart_page():
        items = cart_items_with_products()
        total = round(sum(float(i["unit_price"]) * int(i["qty"]) for i in items), 2)
        return render_template("cart.html", items=items, total=total)

    @app.route("/cart/add/<int:pid>", methods=["POST"], endpoint="cart_add")
    def cart_add(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        try:
            qty = int(request.form.get("qty", 1))
        except Exception:
            qty = 1
        qty = max(1, min(99, qty))

        if current_user.is_authenticated:
            add_to_cart_db(current_user.id, pid, qty)
        else:
            cart = session.get("cart", {})
            cart[str(pid)] = min(99, int(cart.get(str(pid), 0)) + qty)
            session["cart"] = cart

        flash(f"{p.nombre} agregado al carrito.", "success")
        next_url = request.form.get("next") or request.args.get("next") or request.referrer or url_for("index")
        return redirect(next_url)

    @app.route("/cart/update", methods=["POST"], endpoint="cart_update")
    def cart_update():
        updates = {}
        for k, v in request.form.items():
            if k.startswith("qty_"):
                try:
                    pid = int(k.split("_", 1)[1]); qty = int(v)
                except Exception:
                    continue
                updates[pid] = max(0, min(99, qty))

        if not updates:
            pids = request.form.getlist("pid"); qtys = request.form.getlist("qty")
            for pid_str, qty_str in zip(pids, qtys):
                try:
                    pid = int(pid_str); qty = int(qty_str)
                except Exception:
                    continue
                updates[pid] = max(0, min(99, qty))

        if current_user.is_authenticated:
            update_cart_db_bulk(current_user.id, updates)
        else:
            cart = session.get("cart", {})
            for pid, qty in updates.items():
                key = str(pid)
                if qty <= 0:
                    cart.pop(key, None)
                else:
                    cart[key] = qty
            session["cart"] = cart

        flash("Carrito actualizado.", "success")
        return redirect(url_for("cart"))

    @app.route("/cart/remove/<int:pid>", methods=["POST"], endpoint="cart_remove")
    def cart_remove(pid: int):
        if current_user.is_authenticated:
            remove_from_cart_db(current_user.id, pid)
        else:
            cart = session.get("cart", {})
            cart.pop(str(pid), None)
            session["cart"] = cart
        flash("Producto eliminado del carrito.", "success")
        return redirect(url_for("cart"))

    @app.route("/cart/clear", methods=["POST"], endpoint="cart_clear")
    def cart_clear():
        if current_user.is_authenticated:
            clear_cart_db(current_user.id)
        else:
            session.pop("cart", None)
        flash("Carrito vaciado.", "success")
        return redirect(url_for("cart"))

    # ---------- Checkout
    @app.route("/checkout", methods=["GET", "POST"], endpoint="checkout")
    @login_required
    def checkout():
        items = cart_items_with_products()
        if not items:
            flash("Tu carrito está vacío.", "info")
            return redirect(url_for("cart"))

        total = round(sum(float(i["unit_price"]) * int(i["qty"]) for i in items), 2)

        try:
            # Verificar stock antes de crear la orden
            for item in items:
                product = item["product"]
                requested_qty = item["qty"]
                if product.stock < requested_qty:
                    flash(f"No hay suficiente stock para {product.nombre}. Disponible: {product.stock}, Solicitado: {requested_qty}", "error")
                    return redirect(url_for("cart"))

            order = Order(user_id=current_user.id)
            if hasattr(order, "total"):
                order.total = total
            elif hasattr(order, "total_amount"):
                order.total_amount = total
            elif hasattr(order, "amount"):
                order.amount = total
            if hasattr(order, "status"):
                try:
                    order.status = "created"
                except Exception:
                    pass

            db.session.add(order)
            db.session.flush()  # order.id para los OrderItems

            for it in items:
                prod = it["product"]
                pid = int(getattr(prod, "id"))
                qty = int(it["qty"])
                unit_price = float(it["unit_price"])

                # Decrementar stock
                prod.stock -= qty
                if prod.stock < 0:
                    prod.stock = 0

                product_name = (
                    getattr(prod, "nombre", None)
                    or getattr(prod, "name", None)
                    or f"Producto {pid}"
                )

                oi = OrderItem(order_id=order.id, product_id=pid, quantity=qty)

                if hasattr(oi, "product_name"):
                    oi.product_name = product_name
                if hasattr(oi, "unit_price"):
                    oi.unit_price = unit_price
                elif hasattr(oi, "price"):
                    oi.price = unit_price
                elif hasattr(oi, "unit_amount"):
                    oi.unit_amount = unit_price
                if hasattr(oi, "currency"):
                    oi.currency = getattr(prod, "market_currency", None) or "$"
                if hasattr(oi, "image_url") and getattr(prod, "image_url", None):
                    oi.image_url = prod.image_url
                if hasattr(oi, "product_sku") and getattr(prod, "card_number", None):
                    oi.product_sku = prod.card_number

                db.session.add(oi)

            db.session.commit()
        except Exception as e:
            db.session.rollback()
            flash(f"Error al crear el pedido: {e}. Por favor, inténtalo de nuevo.", "error")
            # Log the full exception for debugging
            flask_current_app.logger.error(f"Checkout error: {e}", exc_info=True)
            return redirect(url_for("cart"))

        # Vacía el carrito
        try:
            clear_cart_db(current_user.id)
        except Exception:
            session.pop("cart", None)

        flash(f"Pedido #{getattr(order, 'id', '?')} creado. ¡Gracias!", "success")
        try:
            if "orders_list" in app.view_functions:
                return redirect(url_for("orders_list"))
        except Exception:
            pass
        return redirect(url_for("index"))

    # ---------- Wishlist
    @app.get("/wishlist", endpoint="wishlist")
    @login_required
    def wishlist_view():
        rows = (
            db.session.query(Wishlist, PokemonProducto)
            .join(PokemonProducto, PokemonProducto.id == Wishlist.product_id)
            .filter(Wishlist.user_id == current_user.id)
            .order_by(Wishlist.id.desc() if hasattr(Wishlist, "id") else PokemonProducto.created_at.desc())
            .all()
        )
        items = [p for (_, p) in rows]
        return render_template("wishlist.html", items=items)

    @app.route("/wishlist/add/<int:pid>", methods=["POST"], endpoint="wishlist_add")
    @login_required
    def wishlist_add(pid: int):
        PokemonProducto.query.get_or_404(pid)
        exists = Wishlist.query.filter_by(user_id=current_user.id, product_id=pid).first()
        if not exists:
            db.session.add(Wishlist(user_id=current_user.id, product_id=pid))
            db.session.commit()
            flash("Añadido a favoritos.", "success")
        else:
            flash("Ya estaba en favoritos.", "info")
        return redirect(request.referrer or url_for("product_detail", pid=pid))

    @app.route("/wishlist/remove/<int:pid>", methods=["POST"], endpoint="wishlist_remove")
    @login_required
    def wishlist_remove(pid: int):
        row = Wishlist.query.filter_by(user_id=current_user.id, product_id=pid).first()
        if row:
            db.session.delete(row)
            db.session.commit()
            flash("Eliminado de favoritos.", "success")
        else:
            flash("No estaba en favoritos.", "info")
        return redirect(request.referrer or url_for("product_detail", pid=pid))

    # ---------- IA endpoints

    @app.get("/ai/search")
    def ai_search():
        q = (request.args.get("q") or "").strip()
        cat = (request.args.get("cat") or "").strip().lower()
        tipo = (request.args.get("tipo") or "").strip().lower()

        results = []
        products = []
        if q:
            filters = {"cat": cat, "tipo": tipo}
            try:
                results = semantic_search(q, k=16, filters=filters)
            except Exception as e:
                app.logger.warning(f"ai_search error: {e}")
                results = []

            ids = []
            for r in results:
                try:
                    if isinstance(r, PokemonProducto):
                        products.append(r); continue
                    if isinstance(r, int):
                        ids.append(r); continue
                    if isinstance(r, dict):
                        if "id" in r: ids.append(int(r["id"]))
                        elif "product_id" in r: ids.append(int(r["product_id"]))
                        continue
                    rid = getattr(r, "id", None)
                    if rid is not None:
                        ids.append(int(rid))
                except Exception:
                    pass
            if ids:
                ids = list({int(x) for x in ids})
                products.extend(PokemonProducto.query.filter(PokemonProducto.id.in_(ids)).all())

        return render_template("ai_search.html", q=q, products=products, raw_results=results, cat=cat, tipo=tipo)

    @app.route("/ai/ask", methods=["GET", "POST"])
    def ai_ask():
        answer = None
        hits = []
        q = (request.form.get("q") or request.args.get("q") or "").strip()
        provider = (request.values.get("provider") or ("groq" if os.getenv("GROQ_API_KEY") else "rag")).lower()

        if request.method == "POST" and q:
            try:
                if provider == "groq" and os.getenv("GROQ_API_KEY"):
                    msgs = [
                        {"role": "system", "content": "Eres un asistente de una tienda Pokémon. Responde breve, útil y en español."},
                        {"role": "user", "content": q}
                    ]
                    answer = groq_chat(msgs, temperature=0.3, max_tokens=400)
                    if not answer:
                        raise RuntimeError("Respuesta vacía de Groq")
                else:
                    try:
                        answer, hits = answer_question(q, k=5)
                        if not answer:
                            answer = "No pude procesar la pregunta ahora."
                    except Exception:
                        answer, hits = ("No pude procesar la pregunta ahora.", [])
            except Exception as e:
                flask_current_app.logger.warning(f"ai_ask error: {e}")
                answer, hits = (f"Error IA: {e}", [])

        return render_template("ai_assistant.html", q=q, answer=answer, hits=hits, provider=provider)

    @app.get("/ai/groq/health")
    def ai_groq_health():
        try:
            model = os.getenv("GROQ_MODEL", "llama-3.1-8b-instant")
            if not os.getenv("GROQ_API_KEY"):
                return jsonify({"ok": False, "model": model, "error": "GROQ_API_KEY no seteada"}), 400
            txt = groq_chat([{"role": "user", "content": "ping"}], max_tokens=4)
            if not txt:
                return jsonify({"ok": False, "model": model, "error": "Groq devolvió respuesta vacía"}), 502
            return jsonify({"ok": True, "model": model, "reply": txt}), 200
        except Exception as e:
            return jsonify({"ok": False, "model": os.getenv("GROQ_MODEL", "llama-3.1-8b-instant"), "error": str(e)}), 502

    # --------- Helpers Chat: solo sugerencia de productos ---------
    def _search_products_for_text(q: str, limit: int = 8):
        prods = []
        # 1) semantic_search si está disponible
        try:
            results = semantic_search(q, k=limit, filters={"cat": "tcg", "tipo": "tcg"})
        except Exception:
            results = []
        ids = []
        for r in results:
            try:
                if isinstance(r, PokemonProducto):
                    if r.categoria == "tcg": prods.append(r)
                    continue
                if isinstance(r, int):
                    ids.append(int(r)); continue
                if isinstance(r, dict):
                    rid = r.get("id") or r.get("product_id")
                    if rid: ids.append(int(rid)); continue
                rid = getattr(r, "id", None)
                if rid is not None: ids.append(int(rid))
            except Exception:
                pass
        if ids:
            ids = list({int(x) for x in ids})
            found = PokemonProducto.query.filter(PokemonProducto.id.in_(ids)).all()
            prods.extend([p for p in found if getattr(p, "categoria", None) == "tcg"])
        # 2) FTS fallback
        if len(prods) < limit and fts_available():
            try:
                fids = fts_match_ids(q, limit=limit*2)
                if fids:
                    more = PokemonProducto.query.filter(PokemonProducto.id.in_(fids)).all()
                    for p in more:
                        if p not in prods and p.categoria == "tcg":
                            prods.append(p)
            except Exception:
                pass
        # 3) LIKE fallback
        if len(prods) < limit:
            like = f"%{q}%"
            more = (
                PokemonProducto.query
                .filter(
                    PokemonProducto.categoria == "tcg",
                    (PokemonProducto.nombre.ilike(like)) | (PokemonProducto.descripcion.ilike(like))
                )
                .limit(limit * 2)
                .all()
            )
            for p in more:
                if p not in prods:
                    prods.append(p)
        # Orden simple por fecha e imagen primero
        prods = [p for p in prods if getattr(p, "image_url", None)]
        prods = sorted(prods, key=lambda p: getattr(p, "created_at", datetime.min), reverse=True)
        return prods[:limit]

    # --------- Chat vistas (sin mazos) ---------
    @app.get("/ai/chat")
    def ai_chat():
        msgs = session.get("ai_chat", [])
        rendered = []
        for m in msgs:
            m2 = dict(m)
            if m2.get("product_ids"):
                ids = [int(x) for x in m2["product_ids"]]
                prods = PokemonProducto.query.filter(PokemonProducto.id.in_(ids)).all()
                mp = {p.id: p for p in prods}
                m2["products"] = [mp[i] for i in ids if i in mp]
            rendered.append(m2)
        return render_template("ai_chat.html", messages=rendered)

    @app.post("/ai/chat/send")
    def ai_chat_send():
        text = (request.form.get("q") or "").strip()
        if not text:
            return redirect(url_for("ai_chat"))

        msgs = session.get("ai_chat", [])
        msgs.append({"role": "user", "text": text})

        assistant = {"role": "assistant", "text": None}

        # Si piden “mazo/meta”, responde que esa función no está disponible
        lower = text.lower()
        if any(k in lower for k in ["mazo", "deck", "meta"]):
            assistant["text"] = "Por ahora el generador de mazos está desactivado. Te dejo cartas relacionadas por si quieres explorar."
        else:
            # Respuesta general con IA (Groq si hay clave)
            if os.getenv("GROQ_API_KEY"):
                try:
                    msgs_in = [
                        {"role": "system", "content": "Eres un asistente de una tienda Pokémon. Sé claro y útil."},
                        {"role": "user", "content": text}
                    ]
                    assistant["text"] = groq_chat(msgs_in, temperature=0.3, max_tokens=450) or "..."
                except Exception as e:
                    assistant["text"] = f"No pude responder con IA: {e}"
            else:
                assistant["text"] = "IA (Groq) no disponible."

        # Sugerencias de productos siempre que sea posible
        try:
            prods = _search_products_for_text(text, limit=8)
            assistant["product_ids"] = [int(p.id) for p in prods]
        except Exception as e:
            flask_current_app.logger.warning(f"product_suggest error: {e}")

        msgs.append(assistant)
        session["ai_chat"] = msgs[-20:]
        return redirect(url_for("ai_chat"))

    @app.post("/ai/chat/reset")
    def ai_chat_reset():
        session.pop("ai_chat", None)
        flash("Chat reiniciado.", "info")
        return redirect(url_for("ai_chat"))

    # ---------- Catálogo
    @app.route("/")
    def index():
        q = request.args.get("q", "", type=str).strip()
        tipo = request.args.get("tipo", "", type=str).strip().lower()
        cat = request.args.get("cat", "", type=str).strip().lower()
        sort = request.args.get("sort", "new", type=str)
        page = request.args.get("page", 1, type=int)
        per_page = 8

        exp = request.args.get("exp", "", type=str).strip()
        rare = request.args.get("rare", "", type=str).strip()
        lang = request.args.get("lang", "", type=str).strip()
        cond = request.args.get("cond", "", type=str).strip()

        qry = PokemonProducto.query

        if q:
            if fts_available():
                ids = fts_match_ids(q)
                if ids:
                    qry = qry.filter(PokemonProducto.id.in_(ids))
                else:
                    qry = qry.filter(PokemonProducto.id == -1)
            else:
                like = f"%{q}%"
                qry = qry.filter(
                    (PokemonProducto.nombre.ilike(like)) |
                    (PokemonProducto.descripcion.ilike(like))
                )

        if tipo:
            qry = qry.filter(PokemonProducto.tipo.ilike(tipo))
        if cat:
            qry = qry.filter(PokemonProducto.categoria.ilike(cat))

        if cat == "tcg":
            if exp:
                qry = qry.filter(PokemonProducto.expansion == exp)
            if rare:
                qry = qry.filter(PokemonProducto.rarity == rare)
            if lang:
                qry = qry.filter(PokemonProducto.language == lang)
            if cond:
                qry = qry.filter(PokemonProducto.condition == cond)

        if sort == "price_asc":
            qry = qry.order_by(PokemonProducto.precio_base.asc())
        elif sort == "price_desc":
            qry = qry.order_by(PokemonProducto.precio_base.desc())
        else:
            qry = qry.order_by(PokemonProducto.created_at.desc())

        pag = qry.paginate(page=page, per_page=per_page, error_out=False)
        featured_tcg = (
            PokemonProducto.query.filter_by(categoria="tcg")
            .order_by(PokemonProducto.created_at.desc())
            .limit(8)
            .all()
        )
        facets = tcg_facets() if cat == "tcg" else {"exp": [], "rare": [], "lang": [], "cond": []}

        computed_prices = {}
        user = current_user if current_user.is_authenticated else None
        for p in pag.items:
            try:
                dyn_price, _, _ = precio_service.calcular_precio(p, user)
            except Exception as e:
                flask_current_app.logger.error(f"Error calculating dynamic price for product {p.id}: {e}", exc_info=True)
                dyn_price = float(getattr(p, "precio_base", 0.0) or 0.0)

            if getattr(p, "market_price", None):
                price_val = round(float(p.market_price), 2)
                curr = (p.market_currency or "").upper()
                using_market = True
                source = getattr(p, "market_source", None)
            else:
                price_val = round(float(dyn_price), 2)
                curr = "$"; using_market = False; source = None

            computed_prices[p.id] = {
                "price": price_val,
                "currency": curr,
                "using_market": using_market,
                "source": source,
            }

        return render_template(
            "index.html",
            products=pag.items, q=q, tipo=tipo, sort=sort, cat=cat, pag=pag,
            featured_tcg=featured_tcg, facets=facets,
            exp=exp, rare=rare, lang=lang, cond=cond,
            computed_prices=computed_prices
        )

    # ---------- Detalle
    @app.route("/product/<int:pid>")
    def product_detail(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        if current_user.is_authenticated:
            db.session.add(ProductView(user_id=current_user.id, product_id=p.id))
            db.session.commit()

        precio, razones, feats = precio_service.calcular_precio(
            p, current_user if current_user.is_authenticated else None
        )

        q = (
            db.session.query(
                PokemonProducto,
                func.coalesce(func.sum(OrderItem.quantity), 0).label("sold"),
            )
            .outerjoin(OrderItem, OrderItem.product_id == PokemonProducto.id)
            .filter(PokemonProducto.tipo == p.tipo, PokemonProducto.id != p.id)
            .group_by(PokemonProducto.id)
            .order_by(func.coalesce(func.sum(OrderItem.quantity), 0).desc())
            .limit(4)
            .all()
        )
        recs = [r[0] for r in q] or (
            PokemonProducto.query.filter(
                PokemonProducto.tipo == p.tipo, PokemonProducto.id != p.id
            )
            .order_by(PokemonProducto.created_at.desc())
            .limit(4)
            .all()
        )

        reviews = (
            Review.query.filter_by(product_id=p.id)
            .order_by(Review.created_at.desc())
            .all()
        )
        avg_rating = round(sum(r.rating for r in reviews) / len(reviews), 2) if reviews else None
        my_review = (
            Review.query.filter_by(product_id=p.id, user_id=current_user.id).first()
            if current_user.is_authenticated else None
        )
        purchasers = {
            uid for (uid,) in (
                db.session.query(Order.user_id)
                .join(OrderItem, Order.id == OrderItem.order_id)
                .filter(OrderItem.product_id == p.id)
                .all()
            )
        }
        in_wishlist = (
            Wishlist.query.filter_by(user_id=current_user.id, product_id=p.id).first() is not None
            if current_user.is_authenticated else False
        )

        return render_template(
            "product.html", p=p, precio=precio, razones=razones, feats=feats, recs=recs,
            reviews=reviews, avg_rating=avg_rating, my_review=my_review,
            purchasers=purchasers, in_wishlist=in_wishlist
        )

    # ---------- Reseñas (reviews)
    @app.route("/product/<int:pid>/review", methods=["POST"], endpoint="post_review")
    @login_required
    def post_review(pid: int):
        PokemonProducto.query.get_or_404(pid)

        raw_rating = request.form.get("rating") or request.form.get("stars") or request.form.get("score")
        try:
            rating = int(raw_rating)
        except Exception:
            rating = 0
        rating = max(1, min(5, rating)) if rating else 0

        comment = (request.form.get("comment")
                   or request.form.get("content")
                   or request.form.get("text")
                   or request.form.get("body")
                   or "").strip()

        if rating <= 0:
            flash("Selecciona una puntuación (1-5).", "warning")
            return redirect(url_for("product_detail", pid=pid))

        rv = Review.query.filter_by(product_id=pid, user_id=current_user.id).first()
        if rv:
            rv.rating = rating
            for attr in ("comment", "content", "text", "body"):
                if hasattr(rv, attr):
                    setattr(rv, attr, comment)
            if hasattr(rv, "updated_at"):
                rv.updated_at = datetime.utcnow()
            db.session.commit()
            flash("Reseña actualizada.", "success")
        else:
            rv = Review(product_id=pid, user_id=current_user.id, rating=rating)
            for attr in ("comment", "content", "text", "body"):
                if hasattr(rv, attr):
                    setattr(rv, attr, comment)
            if hasattr(rv, "created_at"):
                rv.created_at = datetime.utcnow()
            db.session.add(rv)
            db.session.commit()
            flash("Gracias por tu reseña.", "success")

        return redirect(url_for("product_detail", pid=pid) + "#reviews")

    @app.route("/product/<int:pid>/review/delete", methods=["POST"], endpoint="delete_review")
    @login_required
    def delete_review(pid: int):
        rv = Review.query.filter_by(product_id=pid, user_id=current_user.id).first()
        if rv:
            db.session.delete(rv)
            db.session.commit()
            flash("Reseña eliminada.", "success")
        else:
            flash("No tenías reseña para este producto.", "info")
        return redirect(url_for("product_detail", pid=pid) + "#reviews")

    # ---------- IA por producto (endpoint para el form en product.html)
    @app.route("/ai/ask_product/<int:pid>", methods=["POST"])
    def ai_ask_product(pid: int):
        p = PokemonProducto.query.get_or_404(pid)
        q = (request.form.get("q") or "").strip()

        ai_answer = None
        if q:
            try:
                context = (
                    f"Producto: {getattr(p, 'nombre', '')}\n"
                    f"Tipo: {getattr(p, 'tipo', '')} | Categoría: {getattr(p, 'categoria', '')}\n"
                    f"Precio base: {float(getattr(p, 'precio_base', 0) or 0):.2f}\n"
                    f"Descripción: {getattr(p, 'descripcion', '') or ''}"
                )
                msgs = [
                    {"role": "system", "content": "Eres un asesor de una tienda Pokémon. Responde claro, breve y útil."},
                    {"role": "user", "content": f"Pregunta: {q}\n\nContexto del producto:\n{context}\n\nResponde:"}
                ]
                if os.getenv("GROQ_API_KEY"):
                    ai_answer = groq_chat(msgs, temperature=0.3, max_tokens=400) or "No obtuve respuesta de la IA."
                else:
                    ai_answer = "IA (Groq) no disponible. Revisa la descripción y especificaciones del producto."
            except Exception as e:
                ai_answer = f"Error IA: {e}"

        precio, razones, feats = precio_service.calcular_precio(
            p, current_user if current_user.is_authenticated else None
        )
        reviews = Review.query.filter_by(product_id=p.id).order_by(Review.created_at.desc()).all()
        avg_rating = round(sum(r.rating for r in reviews) / len(reviews), 2) if reviews else None
        my_review = (
            Review.query.filter_by(product_id=p.id, user_id=current_user.id).first()
            if current_user.is_authenticated else None
        )
        purchasers = {
            uid for (uid,) in (
                db.session.query(Order.user_id)
                .join(OrderItem, Order.id == OrderItem.order_id)
                .filter(OrderItem.product_id == p.id)
                .all()
            )
        }
        in_wishlist = (
            Wishlist.query.filter_by(user_id=current_user.id, product_id=p.id).first() is not None
            if current_user.is_authenticated else False
        )

        return render_template(
            "product.html", p=p, precio=precio, razones=razones, feats=feats,
            reviews=reviews, avg_rating=avg_rating, my_review=my_review,
            purchasers=purchasers, in_wishlist=in_wishlist,
            ai_q=q, ai_answer=ai_answer
        )

    # ---------- Admin (incluye campos TCG + upload)
    def require_admin():
        if not current_user.is_authenticated:
            return redirect(url_for("login", next=request.path))
        if not getattr(current_user, "is_admin", False):
            flash("No tienes permisos de administrador para acceder a esta página.", "danger")
            abort(403)

    @app.route("/admin/products", methods=["GET", "POST"])
    def admin_products():
        res = require_admin()
        if res:
            return res
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
            tcg_card_id = (request.form.get("tcg_card_id") or "").strip()
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
                p = PokemonProducto(
                    nombre=nombre, tipo=tipo, categoria=categoria,
                    precio_base=precio, stock=stock, image_url=img, descripcion=desc,
                    expansion=expa, rarity=rarity, language=language,
                    condition=condition, card_number=card_number, tcg_card_id=tcg_card_id
                )
                db.session.add(p)
                db.session.commit()
                flash("Producto creado.", "success")
        products = PokemonProducto.query.order_by(PokemonProducto.created_at.desc()).all()
        return render_template("admin_products.html", products=products)

    # ---------- Registrar blueprint packs una sola vez
    try:
        from packs_bp import packs_bp
    except Exception as e:
        app.logger.warning(f"packs_bp import failed: {e}")
    else:
        if "packs_bp" not in app.blueprints:
            app.register_blueprint(packs_bp)

    # Crea tablas base si faltan (primera vez)
    with app.app_context():
        try:
            row = db.session.execute(
                text("SELECT name FROM sqlite_master WHERE type='table' AND name='productos'")
            ).fetchone()
            if not row:
                db.create_all()
                app.logger.info("Tablas base creadas (productos, users, etc.)")
        except Exception as e:
            app.logger.warning(f"auto create tables failed: {e}")

    return app


if __name__ == "__main__":
    application = create_app()
    if application is None:
        raise RuntimeError("create_app() returned None. Revisa que la función termine con 'return app'.")
    with application.app_context():
        db.create_all()
    application.run(
        debug=True,
        port=int(os.environ.get("PORT", 5000)),
        host="127.0.0.1"
    )