from app import create_app
from models import db, Wishlist, Review

app = create_app()
with app.app_context():
    db.create_all()
    print("Upgrade v3: tablas Wishlist y Review listas.")
