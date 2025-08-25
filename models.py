from datetime import datetime
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
import json

db = SQLAlchemy()

class UserCard(db.Model):
    __tablename__ = "user_cards"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, nullable=False, index=True)
    product_id = db.Column(db.Integer, nullable=False, index=True)
    qty = db.Column(db.Integer, nullable=False, default=1)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    __table_args__ = (
        db.UniqueConstraint("user_id", "product_id", name="uq_user_product"),
    )

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

    # Metadatos TCG (si no los tenías ya)
    expansion = db.Column(db.String(120))
    rarity = db.Column(db.String(120))
    language = db.Column(db.String(30))
    condition = db.Column(db.String(60))
    card_number = db.Column(db.String(40))

    # NUEVO v8: id y precio de mercado
    tcg_card_id = db.Column(db.String(80))           # ej: "sv2-12"
    market_price = db.Column(db.Float)               # precio de mercado en USD
    market_currency = db.Column(db.String(8), default="USD")
    market_source = db.Column(db.String(80))         # p. ej. "pokemontcg.io/tcgplayer.market"
    market_updated_at = db.Column(db.String(32))     # timestamp texto

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


