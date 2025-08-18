# seed_tcg_cards.py
from app import create_app
from models import db, PokemonProducto

CARDS = [
    dict(nombre="Charizard VMAX - Darkness Ablaze 020/189", tipo="fuego",
         categoria="tcg", precio_base=129.99, stock=3,
         image_url="https://images.pokemontcg.io/swsh3/20_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Darkness Ablaze â€¢ Rareza: Rare Holo VMAX â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: 020/189"),
    dict(nombre="Charizard ex - Obsidian Flames 125/197", tipo="fuego",
         categoria="tcg", precio_base=59.90, stock=4,
         image_url="https://images.pokemontcg.io/sv3/125_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Obsidian Flames â€¢ Rareza: Double Rare â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: 125/197"),
    dict(nombre="Blastoise VMAX - Shining Fates 109/190", tipo="agua",
         categoria="tcg", precio_base=34.90, stock=6,
         image_url="https://images.pokemontcg.io/swsh45/109_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Shining Fates â€¢ Rareza: Rare Holo VMAX â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: 109/190"),
    dict(nombre="Gyarados ex - Scarlet & Violet 045/198", tipo="agua",
         categoria="tcg", precio_base=14.90, stock=12,
         image_url="https://images.pokemontcg.io/sv1/45_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Scarlet & Violet â€¢ Rareza: Double Rare â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: 045/198"),
    dict(nombre="Pikachu - Base Set 58/102", tipo="elÃ©ctrico",
         categoria="tcg", precio_base=19.90, stock=10,
         image_url="https://images.pokemontcg.io/base1/58_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Base Set â€¢ Rareza: Common â€¢ Idioma: EN â€¢ CondiciÃ³n: LP-NM â€¢ NÂº: 58/102"),
    dict(nombre="Raichu - Base Set 14/102", tipo="elÃ©ctrico",
         categoria="tcg", precio_base=39.90, stock=5,
         image_url="https://images.pokemontcg.io/base1/14_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Base Set â€¢ Rareza: Holo Rare â€¢ Idioma: EN â€¢ CondiciÃ³n: LP-NM â€¢ NÂº: 14/102"),
    dict(nombre="Rayquaza VMAX - Evolving Skies 218/203", tipo="dragÃ³n",
         categoria="tcg", precio_base=199.90, stock=1,
         image_url="https://images.pokemontcg.io/swsh7/218_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Evolving Skies â€¢ Rareza: Rainbow Rare â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: 218/203"),
    dict(nombre="Mewtwo VSTAR - Crown Zenith GG44/GG70", tipo="psÃ­quico",
         categoria="tcg", precio_base=69.90, stock=3,
         image_url="https://images.pokemontcg.io/swsh12pt5gg/GG44_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Crown Zenith â€¢ Rareza: Galarian Gallery â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: GG44/GG70"),
    dict(nombre="Gardevoir ex - Scarlet & Violet 245/198", tipo="psÃ­quico",
         categoria="tcg", precio_base=24.90, stock=8,
         image_url="https://images.pokemontcg.io/sv1/245_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Scarlet & Violet â€¢ Rareza: Illustration Rare â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: 245/198"),
    dict(nombre="Umbreon VMAX - Evolving Skies 215/203", tipo="siniestro",
         categoria="tcg", precio_base=299.00, stock=1,
         image_url="https://images.pokemontcg.io/swsh7/215_hires.png",
         descripcion="Carta TCG â€¢ ExpansiÃ³n: Evolving Skies â€¢ Rareza: Alternate Art â€¢ Idioma: EN â€¢ CondiciÃ³n: NM â€¢ NÂº: 215/203"),
]

if __name__ == "__main__":
    app = create_app()
    with app.app_context():
        count_added = 0
        for c in CARDS:
            exists = PokemonProducto.query.filter_by(nombre=c["nombre"]).first()
            if exists:
                continue
            p = PokemonProducto(
                nombre=c["nombre"], tipo=c["tipo"], categoria=c["categoria"],
                precio_base=c["precio_base"], stock=c["stock"],
                image_url=c["image_url"], descripcion=c["descripcion"],
            )
            db.session.add(p)
            count_added += 1
        db.session.commit()
        print(f"Cartas TCG aÃ±adidas: {count_added} (de {len(CARDS)})")
