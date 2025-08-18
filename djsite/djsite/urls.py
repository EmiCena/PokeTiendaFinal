from django.contrib import admin
from django.urls import path

urlpatterns = [
    path("admin/", admin.site.urls),
]

admin.site.site_header = "PokeShop Admin"
admin.site.site_title = "PokeShop Admin"
admin.site.index_title = "Panel de control"
