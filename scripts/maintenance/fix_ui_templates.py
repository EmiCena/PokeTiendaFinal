# fix_ui_templates.py
# 1) Repara mojibake en templates con ftfy
# 2) Reemplaza la UI fija (títulos/labels) por entidades HTML (ASCII) para blindar

from pathlib import Path
from ftfy import fix_text

# Mapa de UI -> entidades (solo textos fijos de interfaz)
REPLACE_UI = {
    "Catálogo": "Cat&aacute;logo",
    "Categoría": "Categor&iacute;a",
    "Búsqueda": "B&uacute;squeda",
    "Búsqueda…": "B&uacute;squeda&hellip;",
    "Historial": "Historial",  # ya ASCII
    "Favoritos": "Favoritos",  # ya ASCII
    "Carrito": "Carrito",      # ya ASCII
    "Mis pedidos": "Mis pedidos",
    "Perfil": "Perfil",
    "Novedades": "Novedades",
    "Aplicar": "Aplicar",
    "Expansión": "Expansi&oacute;n",
    "Rareza": "Rareza",        # ya ASCII
    "Idioma": "Idioma",        # ya ASCII
    "Condición": "Condici&oacute;n",
    "Número": "N&uacute;mero",
    "Nº": "N&ordm;",
    # separador “ · ” → &middot;
    " · ": " &middot; ",
}

def harden_ui(s: str) -> str:
    # aplica reemplazos UI solo en plantillas (no DB)
    out = s
    for k, v in REPLACE_UI.items():
        out = out.replace(k, v)
    return out

def process_template(p: Path) -> bool:
    raw = p.read_text(encoding="utf-8", errors="replace")
    fixed = fix_text(raw)          # repara “CatÃ¡logo” → “Catálogo”
    hardened = harden_ui(fixed)    # convierte UI a entidades ASCII
    if hardened != raw:
        p.write_text(hardened, encoding="utf-8", newline="\n")
        return True
    return False

if __name__ == "__main__":
    changed = 0
    tdir = Path("templates")
    for f in tdir.rglob("*.html"):
        if process_template(f):
            print("Fixed:", f)
            changed += 1
    print("Templates modificados:", changed)