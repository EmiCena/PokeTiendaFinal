# services/precio_dinamico_service.py
from typing import Tuple, List, Dict
from models import db, Order, OrderItem, PokemonProducto, User
from sqlalchemy import func

class PrecioDinamicoService:
    """
    Servicio de precio dinámico (sin ML, solo reglas explicables).
    Ajustes:
     - +10% si el tipo del producto está en favoritos del usuario
     - -5% si NO está en favoritos
     - +12% si stock <= 5
     - -8% si stock >= 50
     - -3% si el usuario lo vio pero no lo compró
     - +2% por cada compra previa del mismo tipo (tope +10%)
    Guardrails: precio final dentro de [50%, 180%] del precio base.
    """
    def _purchases_same_type(self, user_id: int, tipo: str) -> int:
        q = db.session.query(func.coalesce(func.sum(OrderItem.quantity), 0))\
            .join(Order, OrderItem.order_id == Order.id)\
            .join(PokemonProducto, OrderItem.product_id == PokemonProducto.id)\
            .filter(Order.user_id == user_id, PokemonProducto.tipo == tipo)
        return int(q.scalar() or 0)

    def _seen_not_bought(self, user_id: int, product_id: int) -> bool:
        if not user_id:
            return False
        # Lo vio:
        seen = db.session.execute(
            db.text("SELECT COUNT(*) c FROM product_views WHERE user_id=:u AND product_id=:p"),
            {"u": user_id, "p": product_id}
        ).scalar()
        # Lo compró:
        bought = db.session.query(OrderItem).join(Order)\
            .filter(Order.user_id == user_id, OrderItem.product_id == product_id).count()
        return seen and not bought

    def calcular_precio(self, producto: PokemonProducto, user: User | None) -> Tuple[float, List[str], Dict]:
        base = float(producto.precio_base)
        factor = 0.0
        razones: List[str] = []
        feats: Dict = {"precio_base": base, "stock": producto.stock, "tipo": producto.tipo}

        if user:
            favs = [t.lower() for t in (user.get_favoritos() or [])]
            if producto.tipo.lower() in favs:
                factor += 0.10; razones.append("Favorito (+10%)")
            else:
                factor -= 0.05; razones.append("No favorito (-5%)")

            same_type = self._purchases_same_type(user.id, producto.tipo)
            bump = min(0.02 * same_type, 0.10)
            if bump > 0:
                factor += bump; razones.append(f"Historial mismo tipo (+{int(bump*100)}%)")
            feats["purchases_same_type"] = same_type

            if self._seen_not_bought(user.id, producto.id):
                factor -= 0.03; razones.append("Visto y no comprado (-3%)")
                feats["seen_not_bought"] = 1
            else:
                feats["seen_not_bought"] = 0
        else:
            razones.append("Invitado (sin personalización)")

        if producto.stock <= 5:
            factor += 0.12; razones.append("Stock bajo (+12%)")
        elif producto.stock >= 50:
            factor -= 0.08; razones.append("Stock alto (-8%)")

        precio = round(base * (1 + factor), 2)
        piso = round(base * 0.50, 2)
        techo = round(base * 1.80, 2)
        if precio < piso:
            razones.append(f"Ajustado a piso 50% (${piso})")
            precio = piso
        if precio > techo:
            razones.append(f"Ajustado a techo 180% (${techo})")
            precio = techo

        return precio, razones, feats