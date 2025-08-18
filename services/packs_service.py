import json, random, datetime
from typing import List, Dict
from models import db, PokemonProducto, User
from models_packs import PackRule, PackAllowance, PackOpen, UserCard, StarLedger

def rarity_tier(r: str) -> str:
    if not r: return "common"
    rl = r.lower()
    if "illustration" in rl: return "illustration"
    if "double rare" in rl or "ultra" in rl or "gold" in rl or "secret" in rl: return "rare"
    if "rare" in rl: return "rare"
    if "uncommon" in rl: return "uncommon"
    return "common"

STAR_POINTS = {"common":1, "uncommon":2, "rare":5, "illustration":25}

def today_str() -> str:
    return datetime.date.today().strftime("%Y-%m-%d")

def get_set_code_from_tcg_id(tid: str) -> str:
    return (tid.split("-")[0].lower()) if tid and "-" in tid else ""

def get_or_create_rule(set_code: str) -> PackRule:
    r = PackRule.query.filter_by(set_code=set_code).first()
    if not r:
        r = PackRule(set_code=set_code, pack_size=10,
                     weights_json='{"Common":0.7,"Uncommon":0.25,"Rare":0.05}',
                     god_chance=0.001, enabled=True)
        db.session.add(r); db.session.commit()
    return r

def get_or_create_allowance(user_id: int, set_code: str) -> PackAllowance:
    a = PackAllowance.query.filter_by(user_id=user_id, set_code=set_code).first()
    if not a:
        a = PackAllowance(user_id=user_id, set_code=set_code, last_daily_open_date=None, bonus_tokens=0)
        db.session.add(a); db.session.commit()
    return a

def universe_for_set(set_code: str) -> List[PokemonProducto]:
    like_prefix = f"{set_code.lower()}-%"
    rows = db.session.query(PokemonProducto).filter(
        PokemonProducto.categoria=="tcg",
        PokemonProducto.tcg_card_id.isnot(None),
        PokemonProducto.tcg_card_id.like(like_prefix)
    ).all()
    return rows

def pick_pack_cards(rule: PackRule, set_code: str, rng: random.Random) -> List[PokemonProducto]:
    cards = universe_for_set(set_code)
    if not cards: return []
    # God pack
    try: g = float(rule.god_chance or 0.0)
    except: g = 0.0
    if rng.random() < g:
        illus = [c for c in cards if rarity_tier(c.rarity) == "illustration"]
        if illus:
            rng.shuffle(illus)
            need = rule.pack_size or 10
            return illus[:need] if len(illus)>=need else (illus + rng.sample(cards, need-len(illus)))

    try: weights = json.loads(rule.weights_json or "{}")
    except: weights = {"Common":0.7,"Uncommon":0.25,"Rare":0.05}
    commons = [c for c in cards if rarity_tier(c.rarity) == "common"]
    uncommons = [c for c in cards if rarity_tier(c.rarity) == "uncommon"]
    rares = [c for c in cards if rarity_tier(c.rarity) in ("rare","illustration")]

    k = rule.pack_size or 10
    out: List[PokemonProducto] = []
    for _ in range(k):
        r = rng.random()
        if r < weights.get("Common",0.7) and commons:
            out.append(rng.choice(commons))
        elif r < weights.get("Common",0.7)+weights.get("Uncommon",0.25) and uncommons:
            out.append(rng.choice(uncommons))
        else:
            if rares: out.append(rng.choice(rares))
            elif uncommons: out.append(rng.choice(uncommons))
            elif commons: out.append(rng.choice(commons))
    if not any(rarity_tier(c.rarity) in ("rare","illustration") for c in out) and rares:
        out[-1] = rng.choice(rares)
    return out

def open_pack(user_id: int, set_code: str, admin_unlimited: bool = False) -> Dict:
    set_code = set_code.lower()
    rule = get_or_create_rule(set_code)
    if not rule.enabled and not admin_unlimited:
        return {"ok": False, "error": "Pack deshabilitado para este set."}

    allow = get_or_create_allowance(user_id, set_code)
    today = today_str()

    can_daily = (allow.last_daily_open_date != today)
    used_bonus = False

    if not admin_unlimited:
        if not can_daily:
            if allow.bonus_tokens > 0:
                allow.bonus_tokens -= 1
                used_bonus = True
            else:
                return {"ok": False, "error": "Sin pack diario ni bonus tokens."}
    # Admin ilimitado: no consume diario ni tokens

    seed = int(datetime.datetime.utcnow().strftime("%Y%m%d")) ^ (user_id * 131) ^ (hash(set_code) & 0xffffffff)
    rng = random.Random(seed)

    picks = pick_pack_cards(rule, set_code, rng)
    if not picks:
        return {"ok": False, "error": "No hay cartas para ese set."}

    owned_ids = {uc.tcg_card_id for uc in UserCard.query.filter_by(user_id=user_id, set_code=set_code).all()}
    dup_points = 0; results = []
    for c in picks:
        is_dup = (c.tcg_card_id in owned_ids)
        results.append({
            "id": c.id, "tcg_card_id": c.tcg_card_id, "name": c.nombre,
            "rarity": c.rarity, "image_url": c.image_url, "duplicate": is_dup
        })
        db.session.add(UserCard(user_id=user_id, tcg_card_id=c.tcg_card_id, set_code=set_code,
                                name=c.nombre, rarity=c.rarity, image_url=c.image_url))
        if is_dup:
            dup_points += STAR_POINTS.get(rarity_tier(c.rarity), 1)

    if can_daily and not admin_unlimited:
        allow.last_daily_open_date = today
    db.session.add(allow)

    # No otorgar puntos al admin cuando abre ilimitado
    award_points = not admin_unlimited
    if dup_points and award_points:
        u = User.query.get(user_id)
        if u:
            try:
                u.star_points = (getattr(u,"star_points",0) or 0) + dup_points
                db.session.add(u)
            except Exception:
                pass
        db.session.add(StarLedger(user_id=user_id, points=dup_points, reason=f"Duplicados {set_code}"))

    db.session.add(PackOpen(user_id=user_id, set_code=set_code, cards_json=json.dumps(results)))
    db.session.commit()
    return {"ok": True, "set_code": set_code, "cards": results, "dup_points": (dup_points if award_points else 0), "used_bonus": used_bonus}
