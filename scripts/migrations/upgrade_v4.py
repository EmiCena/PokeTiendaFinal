from app import create_app
from models import db, CartItem

app = create_app()
with app.app_context():
    db.create_all()
    print("Upgrade v4: tabla CartItem creada.")
