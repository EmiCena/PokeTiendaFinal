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
