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
