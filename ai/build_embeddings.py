# ai/build_embeddings.py
from app import create_app
from models import db, PokemonProducto
from ai.search_service import upsert_product_embedding

app = create_app()
with app.app_context():
    n = 0
    for p in PokemonProducto.query.all():
        upsert_product_embedding(p); n += 1
    print(f"Embeddings actualizados para {n} productos.")