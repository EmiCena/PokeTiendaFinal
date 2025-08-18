# seed.py
from app import create_app
from models import db, User, PokemonProducto

app = create_app()
with app.app_context():
    db.drop_all()
    db.create_all()

    admin = User(email="admin@poke.com", is_admin=True)
    admin.set_password("admin123")
    admin.set_favoritos(["fuego","dragón"])
    db.session.add(admin)

    demo = [
        dict(nombre="Peluche Pikachu", tipo="eléctrico", precio_base=19.99, stock=20,
             image_url="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/25.png",
             descripcion="Peluche suave de Pikachu."),
        dict(nombre="Carta Charizard VMAX", tipo="fuego", precio_base=129.99, stock=3,
             image_url="https://images.pokemontcg.io/swsh3/20_hires.png",
             descripcion="Carta rara VMAX."),
        dict(nombre="Peluche Squirtle", tipo="agua", precio_base=22.5, stock=60,
             image_url="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/7.png",
             descripcion="Peluche adorable de Squirtle."),
        dict(nombre="Figura Bulbasaur", tipo="planta", precio_base=29.9, stock=10,
             image_url="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/1.png",
             descripcion="Figura coleccionable Bulbasaur."),
    ]
    for d in demo:
        db.session.add(PokemonProducto(**d))
    db.session.commit()
    print("Base inicial creada. Admin: admin@poke.com / admin123")