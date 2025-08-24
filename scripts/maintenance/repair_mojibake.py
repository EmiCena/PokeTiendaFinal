# scripts/maintenance/repair_mojibake_v2.py
from pathlib import Path

ROOTS = [Path("templates"), Path("static")]
EXTS = {".html", ".htm", ".css", ".js"}

NEEDLES = ("Ã", "Â", "â€™", "â€œ", "â€", "â€“", "â€”", "ï»¿")

def has_bom(b: bytes) -> bool:
    return len(b) >= 3 and b[:3] == b"\xef\xbb\xbf"

def strip_bom(b: bytes) -> bytes:
    return b[3:] if has_bom(b) else b

def looks_mojibake(txt: str) -> bool:
    return any(n in txt for n in NEEDLES)

def one_pass_fix(txt: str) -> str:
    # Revertir utf8->cp1252 mojibake: latin1 bytes -> utf8 str
    try:
        return txt.encode("latin1", errors="ignore").decode("utf-8", errors="ignore")
    except Exception:
        return txt

def multi_fix(txt: str, max_passes: int = 3) -> str:
    fixed = txt
    for _ in range(max_passes):
        if not looks_mojibake(fixed):
            break
        new = one_pass_fix(fixed)
        if new == fixed:
            break
        fixed = new
    return fixed

def process_file(p: Path) -> bool:
    if p.suffix.lower() not in EXTS:
        return False

    b = p.read_bytes()
    changed = False

    # 1) quitar BOM si hay
    if has_bom(b):
        b = strip_bom(b)
        changed = True

    # 2) intentar leer como utf-8
    try:
        txt = b.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        # si no es utf-8, decodifica como cp1252 y guarda en utf-8
        txt1252 = b.decode("cp1252", errors="ignore")
        p.write_text(txt1252, encoding="utf-8")
        print(f"reencoded cp1252->utf8: {p}")
        return True

    # 3) multipasada si huele a mojibake
    if looks_mojibake(txt):
        fixed = multi_fix(txt, max_passes=3)
        if fixed != txt:
            p.write_text(fixed, encoding="utf-8")
            print(f"fixed xN: {p}")
            return True

    # 4) si sólo quitamos BOM, reescribir bytes
    if changed:
        p.write_bytes(b)
        print(f"stripped BOM: {p}")
        return True

    return False

def main():
    total = 0
    for root in ROOTS:
        if not root.exists():
            continue
        for p in root.rglob("*"):
            try:
                if process_file(p):
                    total += 1
            except Exception as e:
                print(f"skip {p}: {e}")
    print(f"Done. changed={total}")

if __name__ == "__main__":
    main()