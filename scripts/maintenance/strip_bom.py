from pathlib import Path
for root in (Path("templates"), Path("static")):
    if not root.exists(): continue
    for p in root.rglob("*"):
        if p.suffix.lower() not in {".html",".htm",".css",".js"}: continue
        b = p.read_bytes()
        if len(b)>=3 and b[:3]==b"\xef\xbb\xbf":
            p.write_bytes(b[3:])
            print("stripped BOM:", p)