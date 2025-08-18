<<<<<<< HEAD
# PokeTiendaFinal
=======
# Tienda Pokémon (Flask)

## Requisitos
- Python 3.10+
- pip, venv

## Setup rápido
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -U pip
pip install -r requirements.txt

## Ejecutar
py app.py

## Migraciones incluidas
py -m scripts.migrations.upgrade_v12
py -m scripts.migrations.upgrade_v13_set_image

## Admin
py -m scripts.utils.make_admin --email "admin@local" --password "TuPass123"

## Notas
- La base de datos SQLite local se guarda como store.db (ignorara por git).
- Subidas de imágenes se guardan en uploads/ (ignorado).
>>>>>>> 2db88ba (Inicial: tienda + packs + admin + IA básica)
