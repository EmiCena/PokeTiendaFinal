import os, time, requests
from datetime import datetime, timedelta
from typing import Optional, Tuple, List, Dict
from models import db, PokemonProducto

class MarketPriceService:
    BASE = "https://api.pokemontcg.io/v2"

    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key or os.getenv("POKEMONTCG_API_KEY", "")

    def _headers(self):
        h = {"Accept": "application/json"}
        if self.api_key:
            h["X-Api-Key"] = self.api_key
        return h

    def _get(self, path: str, params: dict | None = None, timeout: float = 20, retries: int = 3):
        url = f"{self.BASE}{path}"
        resp = None
        for i in range(retries):
            try:
                resp = requests.get(url, headers=self._headers(), params=params, timeout=timeout)
            except Exception:
                time.sleep(min(3, 0.5*(i+1)))
                continue
            if resp.status_code == 429:
                wait = resp.headers.get("Retry-After")
                try:
                    wait_s = float(wait) if wait else 1.0
                except Exception:
                    wait_s = 1.0
                time.sleep(min(5.0, max(0.5, wait_s)))
                continue
            return resp
        return resp

    def _fetch_set_cards(self, set_code: str, page_size: int = 250, sleep: float = 0.0) -> List[dict]:
        data: List[dict] = []
        page = 1
        set_code = (set_code or "").lower().strip()
        while True:
            resp = self._get(
                "/cards",
                params={
                    "q": f"set.id:{set_code}",
                    "pageSize": page_size,
                    "page": page,
                    "select": "number,tcgplayer,cardmarket"
                },
                timeout=25
            )
            if not resp or resp.status_code != 200:
                break
            arr = (resp.json() or {}).get("data") or []
            if not arr:
                break
            data.extend(arr)
            if len(arr) < page_size:
                break
            page += 1
            if sleep:
                time.sleep(sleep)
        return data

    def _fetch_card_json(self, set_code: str, number: int | str) -> Optional[dict]:
        for cid in (f"{set_code.upper()}-{number}", f"{set_code.lower()}-{number}"):
            r = self._get(f"/cards/{cid}", timeout=15)
            if r and r.status_code == 200:
                return r.json().get("data")
        q = f"set.id:{set_code.lower()} number:{number}"
        r = self._get("/cards", params={"q": q, "select": "number,tcgplayer,cardmarket"}, timeout=15)
        if r and r.status_code == 200:
            arr = r.json().get("data") or []
            return arr[0] if arr else None
        return None

    def _extract_market(self, card: dict) -> Tuple[Optional[float], Optional[str], Optional[str]]:
        if not card:
            return None, None, None
        tp = (card.get("tcgplayer") or {}).get("prices") or {}
        for k in ("holofoil", "reverseHolofoil", "normal"):
            pr = tp.get(k) or {}
            v = pr.get("market") or pr.get("mid") or pr.get("low")
            if v:
                return float(v), "USD", "tcgplayer"
        cm = (card.get("cardmarket") or {}).get("prices") or {}
        v = cm.get("trendPrice") or cm.get("averageSellPrice") or cm.get("avg1") or cm.get("avg7")
        if v:
            return float(v), "EUR", "cardmarket"
        return None, None, None

    @staticmethod
    def _parse_tcg_id(tcg_card_id: str):
        try:
            sc, n = (tcg_card_id or "").split("-", 1)
            return sc.lower(), n.strip()
        except Exception:
            return None, None

    @staticmethod
    def _number_keys(num_str: str) -> List[str]:
        if not num_str:
            return []
        s = str(num_str).strip()
        keys = {s.lower()}
        nz = s.lstrip("0") or "0"
        keys.add(nz.lower())
        if nz.isdigit():
            keys.add(nz.zfill(3).lower())
        return list(keys)

    def update_prices_by_set(self, set_code: str, sleep: float = 0.0, max_age_days: Optional[int] = None) -> int:
        set_code = (set_code or "").lower().strip()
        if not set_code:
            return 0
        api_cards = self._fetch_set_cards(set_code, page_size=250, sleep=sleep)
        mapping: Dict[str, Tuple[float, str, str]] = {}
        for c in api_cards:
            price, curr, src = self._extract_market(c)
            if not price:
                continue
            num = str((c.get("number") or "")).strip()
            for k in self._number_keys(num):
                mapping[k] = (float(price), curr, src)
        if not mapping:
            return 0

        q = PokemonProducto.query.filter(
            PokemonProducto.categoria == "tcg",
            PokemonProducto.tcg_card_id.isnot(None),
            PokemonProducto.tcg_card_id != "",
            PokemonProducto.tcg_card_id.like(f"{set_code}-%")
        )
        cutoff = datetime.utcnow() - timedelta(days=max_age_days) if max_age_days else None
        updated = 0
        for p in q:
            if cutoff and getattr(p, "market_updated_at", None):
                ts = p.market_updated_at
                try:
                    if ts and ts > cutoff:
                        continue
                except Exception:
                    pass
            _, num = self._parse_tcg_id(p.tcg_card_id or "")
            if not num:
                continue
            found = None
            for k in self._number_keys(num):
                v = mapping.get(k)
                if v:
                    found = v
                    break
            if not found:
                continue
            pr, curr, src = found
            p.market_price = round(pr, 2)
            p.market_currency = curr
            p.market_source = src
            p.market_updated_at = datetime.utcnow()
            db.session.add(p)
            updated += 1
        if updated:
            db.session.commit()
        return updated

    def update_prices(self, set_code: Optional[str] = None, sleep: float = 0.25, limit: Optional[int] = None, max_age_days: Optional[int] = None) -> int:
        q = PokemonProducto.query.filter(
            PokemonProducto.categoria == "tcg",
            PokemonProducto.tcg_card_id.isnot(None),
            PokemonProducto.tcg_card_id != ""
        ).order_by(PokemonProducto.id.asc())
        updated = 0; count = 0
        cutoff = datetime.utcnow() - timedelta(days=max_age_days) if max_age_days else None
        total = q.count()
        for p in q:
            if limit and count >= limit:
                break
            count += 1
            sc, num = self._parse_tcg_id(p.tcg_card_id or "")
            if not sc or not num:
                continue
            if set_code and sc.lower() != set_code.lower():
                continue
            if cutoff and getattr(p, "market_updated_at", None):
                ts = p.market_updated_at
                try:
                    if ts and ts > cutoff:
                        continue
                except Exception:
                    pass
            try:
                number_int = None
                try: number_int = int(str(num).lstrip("0") or "0")
                except Exception: number_int = num
                card = self._fetch_card_json(sc, number_int)
                price, curr, src = self._extract_market(card)
                if price:
                    p.market_price = round(float(price), 2)
                    p.market_currency = curr
                    p.market_source = src
                    p.market_updated_at = datetime.utcnow()
                    db.session.add(p); updated += 1
            except Exception:
                pass
            if sleep:
                time.sleep(sleep)
            if count % 50 == 0:
                print(f"[{count}/{total}] actualizadas: {updated}")
        if updated:
            db.session.commit()
        print(f"Fin. procesadas={count}, actualizadas={updated}")
        return updated
