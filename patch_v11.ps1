# patch_v11.ps1
$ErrorActionPreference = "Stop"
function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
Ensure-Dir "ai"; Ensure-Dir "services"

# 1) ai/similar_service.py
$similar = @'
# ai/similar_service.py
import json
from typing import List, Tuple
from sqlalchemy import text
from models import db, PokemonProducto
from ai.vector_utils import cosine
from ai.embedding_service import get_embedding

def _doc_for_product(p: PokemonProducto) -> str:
    parts = [
        p.nombre or "",
        p.descripcion or "",
        f"Tipo: {p.tipo or ''}",
        f"Categoria: {p.categoria or ''}",
    ]
    for k in ("expansion","rarity","language","condition","card_number"):
        v = getattr(p,k,None)
        if v: parts.append(f"{k}: {v}")
    return "\n".join(parts)

def similar_by_id(pid: int, k: int = 8) -> List[PokemonProducto]:
    p = PokemonProducto.query.get(pid)
    if not p: return []
    # vector de consulta: preferir vector almacenado, si no, generar on-the-fly
    row = db.session.execute(text("SELECT vector FROM product_embeddings WHERE product_id=:pid"), {"pid": pid}).fetchone()
    if row:
        try:
            qv = json.loads(row[0])
        except Exception:
            qv,_ = get_embedding(_doc_for_product(p))
    else:
        qv,_ = get_embedding(_doc_for_product(p))

    rows = db.session.execute(text("SELECT product_id, vector FROM product_embeddings WHERE product_id!=:pid"), {"pid": pid}).fetchall()
    scored: List[Tuple[int,float]] = []
    for pid2, vec_json in rows:
        try:
            vj = json.loads(vec_json)
        except Exception:
            continue
        scored.append((pid2, cosine(qv, vj)))
    scored.sort(key=lambda x: x[1], reverse=True)
    ids = [pid2 for pid2,_ in scored[:max(k*3, k)]]

    if not ids:
        return []

    # recuperar objetos y filtrar si es necesario (mismo tipo/cat primero)
    objs = PokemonProducto.query.filter(PokemonProducto.id.in_(ids)).all()
    # heurística simple: priorizar misma categoría/tipo
    objs.sort(key=lambda x: (
        1 if (p.categoria and x.categoria and p.categoria.lower()==(x.categoria or "").lower()) else 0,
        1 if (p.tipo and x.tipo and p.tipo.lower()==(x.tipo or "").lower()) else 0,
    ), reverse=True)
    return objs[:k]
'@
Set-Content -Path "ai\similar_service.py" -Value $similar -Encoding UTF8
Write-Host "ai/similar_service.py creado."

# 2) services/mail_service.py
$mail = @'
# services/mail_service.py
import os, smtplib
from email.mime.text import MIMEText
from email.utils import formataddr

class Mailer:
    def __init__(self):
        self.host = os.getenv("SMTP_HOST")
        self.port = int(os.getenv("SMTP_PORT", "587"))
        self.user = os.getenv("SMTP_USER")
        self.pw   = os.getenv("SMTP_PASS")
        self.sender_name = os.getenv("SMTP_FROM_NAME", "PokeShop")
        self.sender_addr = os.getenv("SMTP_FROM_ADDR", self.user or "no-reply@pokeshop.local")

    def send_order_confirmation(self, to_email: str, order, items):
        if not (self.host and self.user and self.pw and to_email):
            # sin SMTP: no rompe, imprime en consola
            print("[MAIL:disabled] To:", to_email, "Order:", order.id)
            return

        total = f"$ {order.total:.2f}"
        lines = []
        for it in items:
            lines.append(f"- {it['product'].nombre} x{it['qty']} — $ {it['unit_price']*it['qty']:.2f}")
        body = f"""Hola,
Gracias por tu compra.

Pedido #{order.id}
Total: {total}

Items:
{chr(10).join(lines)}

En breve recibirás novedades del envío.
— PokeShop
"""
        msg = MIMEText(body, "plain", "utf-8")
        msg["Subject"] = f"PokeShop — Confirmación de pedido #{order.id}"
        msg["From"] = formataddr((self.sender_name, self.sender_addr))
        msg["To"] = to_email

        with smtplib.SMTP(self.host, self.port, timeout=20) as s:
            s.starttls()
            s.login(self.user, self.pw)
            s.sendmail(self.sender_addr, [to_email], msg.as_string())
'@
Set-Content -Path "services\mail_service.py" -Value $mail -Encoding UTF8
Write-Host "services/mail_service.py creado."

# 3) requirements.txt — Stripe
if(Test-Path "requirements.txt"){
  $req = Get-Content "requirements.txt" -Raw
  if($req -notmatch "(?m)^stripe=="){
    Add-Content "requirements.txt" "`nstripe==6.9.0"
    Write-Host "stripe añadido a requirements.txt"
  } else { Write-Host "stripe ya estaba en requirements.txt" }
}else{
  Set-Content "requirements.txt" "stripe==6.9.0" -Encoding UTF8
  Write-Host "requirements.txt creado con stripe."
}
Write-Host "Instalando stripe..." -ForegroundColor Cyan
& $py -m pip install stripe==6.9.0 | Out-Null
Write-Host "Listo."