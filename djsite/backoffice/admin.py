from django.contrib import admin
from django.apps import apps
from django.contrib.admin.sites import AlreadyRegistered

app = apps.get_app_config("backoffice")

def get_by_table(table_name: str):
    """Obtiene el modelo del app backoffice por nombre de tabla (db_table)."""
    for m in app.get_models():
        if getattr(m._meta, "db_table", "").lower() == table_name.lower():
            return m
    return None

def has_field(model, name: str) -> bool:
    try:
        model._meta.get_field(name)
        return True
    except Exception:
        return False

# ===== Productos =====
Productos = get_by_table("productos")
if Productos:
    class ProductoAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","nombre","tipo","categoria","stock","precio_base","market_price","tcg_card_id") if has_field(Productos,f)]
        search_fields = [f for f in ("nombre","tipo","categoria","tcg_card_id","expansion","rarity","language") if has_field(Productos,f)]
        list_filter = [f for f in ("categoria","tipo","expansion","rarity","language") if has_field(Productos,f)]
        list_per_page = 50
        ordering = ("-id",)

        readonly_fields = tuple(f for f in ("market_price","market_currency","market_source","market_updated_at") if has_field(Productos,f))
        basicos = [f for f in ("nombre","tipo","categoria","stock","precio_base","image_url","descripcion") if has_field(Productos,f)]
        tcg = [f for f in ("expansion","rarity","language","condition","card_number","tcg_card_id") if has_field(Productos,f)]
        mercado = list(readonly_fields)

        fieldsets = (
            ("Datos", {"fields": tuple(basicos)}),
            ("TCG", {"fields": tuple(tcg), "classes": ("collapse",)}) if tcg else (),
            ("Mercado", {"fields": tuple(mercado), "classes": ("collapse",)}) if mercado else (),
        )
        # Elimina secciones vacías
        fieldsets = tuple(fs for fs in fieldsets if fs)

    try:
        admin.site.register(Productos, ProductoAdmin)
    except AlreadyRegistered:
        pass

# ===== Promo codes =====
PromoCodes = get_by_table("promo_codes")
if PromoCodes:
    def promo_activate(modeladmin, request, queryset):
        queryset.update(active=True)
    promo_activate.short_description = "Activar cupones seleccionados"

    def promo_deactivate(modeladmin, request, queryset):
        queryset.update(active=False)
    promo_deactivate.short_description = "Desactivar cupones seleccionados"

    class PromoCodeAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","code","percent","active","used_count","max_uses","expires_at") if has_field(PromoCodes,f)]
        search_fields = [f for f in ("code",)]
        list_filter = [f for f in ("active",)]
        ordering = ("-id",)
        actions = [promo_activate, promo_deactivate]
        list_per_page = 50

    try:
        admin.site.register(PromoCodes, PromoCodeAdmin)
    except AlreadyRegistered:
        pass

# ===== Orders + items inline =====
Orders = get_by_table("orders")
OrderItems = get_by_table("order_items")
if Orders:
    if OrderItems:
        class OrderItemInline(admin.TabularInline):
            model = OrderItems
            extra = 0
            can_delete = False
            readonly_fields = tuple(f for f in ("product_id","product_name","unit_price","quantity") if has_field(OrderItems,f))

    class OrderAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","user_id","total","status","created_at") if has_field(Orders,f)]
        list_filter = [f for f in ("status",)]
        search_fields = [f for f in ("id","user_id")]
        date_hierarchy = "created_at" if has_field(Orders,"created_at") else None
        ordering = ("-id",)
        list_per_page = 50
        inlines = [OrderItemInline] if OrderItems else []

    try:
        admin.site.register(Orders, OrderAdmin)
    except AlreadyRegistered:
        pass

# ===== Resto de tablas útiles =====
Reviews = get_by_table("reviews")
if Reviews:
    class ReviewAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","product_id","user_id","rating","created_at") if has_field(Reviews,f)]
        list_filter = [f for f in ("rating",)]
        search_fields = [f for f in ("product_id","user_id")]
        date_hierarchy = "created_at" if has_field(Reviews,"created_at") else None
        ordering = ("-id",)
    try:
        admin.site.register(Reviews, ReviewAdmin)
    except AlreadyRegistered:
        pass

Wishlist = get_by_table("wishlist")
if Wishlist:
    class WishlistAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","user_id","product_id","created_at") if has_field(Wishlist,f)]
        search_fields = [f for f in ("user_id","product_id")]
        date_hierarchy = "created_at" if has_field(Wishlist,"created_at") else None
        ordering = ("-id",)
    try:
        admin.site.register(Wishlist, WishlistAdmin)
    except AlreadyRegistered:
        pass

CartItems = get_by_table("cart_items")
if CartItems:
    class CartItemAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","user_id","product_id","quantity","updated_at") if has_field(CartItems,f)]
        search_fields = [f for f in ("user_id","product_id")]
        date_hierarchy = "updated_at" if has_field(CartItems,"updated_at") else None
        ordering = ("-id",)
    try:
        admin.site.register(CartItems, CartItemAdmin)
    except AlreadyRegistered:
        pass

ProductViews = get_by_table("product_views")
if ProductViews:
    class ProductViewAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","user_id","product_id","ts") if has_field(ProductViews,f)]
        search_fields = [f for f in ("user_id","product_id")]
        date_hierarchy = "ts" if has_field(ProductViews,"ts") else None
        ordering = ("-id",)
    try:
        admin.site.register(ProductViews, ProductViewAdmin)
    except AlreadyRegistered:
        pass

Users = get_by_table("users")
if Users:
    class UsersAdmin(admin.ModelAdmin):
        list_display = [f for f in ("id","email","is_admin") if has_field(Users,f)]
        search_fields = [f for f in ("email",)]
        list_filter = [f for f in ("is_admin",)] if has_field(Users,"is_admin") else []
        ordering = ("-id",)
        list_per_page = 50
    try:
        admin.site.register(Users, UsersAdmin)
    except AlreadyRegistered:
        pass

# ===== Auto‑registro del resto (por si falta algo) =====
for m in app.get_models():
    try:
        admin.site.register(m)
    except AlreadyRegistered:
        pass