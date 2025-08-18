# fix_mojibake_all.py
# Arregla mojibake en archivos (templates/static) y en la DB.
# - Detecta encoding con charset-normalizer
# - Corrige mojibake con ftfy
# - Guarda en UTF-8 (sin BOM)
# Uso:
#   python fix_mojibake_all.py --files templates static --db
#   python fix_mojibake_all.py --files templates static --db --dry-run

import argparse
import os
import shutil
from datetime import datetime
from pathlib import Path

from charset_normalizer import from_bytes
from ftfy import fix_text

# Ajusta estas extensiones si quieres incluir/excluir otras
DEFAULT_EXTS = {".html", ".htm", ".css", ".js", ".md"}

def sniff_and_decode(b: bytes) -> tuple[str, str]:
    """
    Intenta decodificar bytes a str:
      - utf-8 / utf-8-sig
      - charset-normalizer (mejor candidato)
      - latin-1 como último recurso
    Retorna (texto, encoding_usado).
    """
    try:
        return b.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        pass
    try:
        return b.decode("utf-8-sig"), "utf-8-sig"
    except UnicodeDecodeError:
        pass
    try:
        best = from_bytes(b).best()
        if best and best.encoding:
            return str(best), best.encoding
    except Exception:
        pass
    return b.decode("latin-1", errors="replace"), "latin-1"

def looks_mojibake(s: str) -> bool:
    # Heurística rápida: caracteres típicos de mojibake CP1252<->UTF8
    # "Ã", "Â", "â€", "�" (replacement char)
    return any(x in s for x in ("Ã", "Â", "â€", "�"))

def ensure_backup_dir(root: Path) -> Path:
    bdir = root / f"backup_mojibake_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    bdir.mkdir(parents=True, exist_ok=True)
    return bdir

def process_file(path: Path, dry_run: bool = False) -> tuple[bool, str, str]:
    """
    Procesa un archivo: lee bytes, decodifica, repara con ftfy, guarda UTF-8 si cambió.
    Retorna (cambiado, encoding_in, note)
    """
    b = path.read_bytes()
    text_in, enc = sniff_and_decode(b)

    fixed = fix_text(text_in)  # repara mojibake y normaliza
    changed = (fixed != text_in) or looks_mojibake(text_in)

    if changed and not dry_run:
        # Guarda UTF-8 sin BOM
        path.write_text(fixed, encoding="utf-8", newline="\n")
    note = "fixed" if changed else "ok"
    return changed, enc, note

def process_files(dirs: list[str], exts: set[str], dry_run: bool, backup: bool):
    root = Path(".").resolve()
    if backup:
        bdir = ensure_backup_dir(root)
        # Copia solo los directorios solicitados
        for d in dirs:
            src = root / d
            if src.exists():
                shutil.copytree(src, bdir / d, dirs_exist_ok=True)

    total = 0
    changed = 0
    for d in dirs:
        base = Path(d)
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if p.is_file() and p.suffix.lower() in exts:
                total += 1
                try:
                    chg, enc, note = process_file(p, dry_run=dry_run)
                    if chg:
                        changed += 1
                    print(f"[{note}] {p}  (enc={enc})")
                except Exception as e:
                    print(f"[ERR ] {p}: {e}")
    print(f"\nArchivos procesados: {total} | Reparados: {changed} | Dry-run: {dry_run}")

def fix_db(dry_run: bool):
    # Evita importar Flask si no se pide DB
    from app import create_app
    from models import db, PokemonProducto, Order

    app = create_app()
    changed = 0
    with app.app_context():
        # Productos: nombre + descripcion
        for p in PokemonProducto.query.all():
            orig_nombre = p.nombre or ""
            orig_desc = p.descripcion or ""
            new_nombre = fix_text(orig_nombre) if looks_mojibake(orig_nombre) or orig_nombre else orig_nombre
            new_desc   = fix_text(orig_desc)   if looks_mojibake(orig_desc)   or orig_desc   else orig_desc
            if new_nombre != orig_nombre or new_desc != orig_desc:
                if not dry_run:
                    p.nombre = new_nombre
                    p.descripcion = new_desc
                changed += 1

        # Direcciones de pedidos (por si hay tildes/ñ)
        for o in Order.query.all():
            orig_name = o.ship_name or ""
            orig_addr = o.ship_address or ""
            new_name = fix_text(orig_name) if looks_mojibake(orig_name) or orig_name else orig_name
            new_addr = fix_text(orig_addr) if looks_mojibake(orig_addr) or orig_addr else orig_addr
            if new_name != orig_name or new_addr != orig_addr:
                if not dry_run:
                    o.ship_name = new_name
                    o.ship_address = new_addr
                changed += 1

        if not dry_run and changed:
            db.session.commit()
    print(f"Registros de DB reparados: {changed} | Dry-run: {dry_run}")

def main():
    ap = argparse.ArgumentParser(description="Fix universal de mojibake (archivos + DB).")
    ap.add_argument("--files", nargs="*", default=[], help="Directorios a procesar (ej: templates static)")
    ap.add_argument("--ext", nargs="*", default=list(DEFAULT_EXTS), help="Extensiones a incluir (por defecto html, css, js, md)")
    ap.add_argument("--db", action="store_true", help="Arreglar cadenas mojibake en la base de datos")
    ap.add_argument("--dry-run", action="store_true", help="No guarda cambios, solo informa")
    ap.add_argument("--no-backup", action="store_true", help="No crear backup antes de tocar archivos")
    args = ap.parse_args()

    exts = {e if e.startswith(".") else f".{e}" for e in args.ext}

    if args.files:
        process_files(args.files, exts, dry_run=args.dry_run, backup=(not args.no_backup))
    if args.db:
        fix_db(dry_run=args.dry_run)
    if not args.files and not args.db:
        print("Nada que hacer. Usa --files templates static y/o --db")

if __name__ == "__main__":
    main()