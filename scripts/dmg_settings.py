# dmgbuild settings for Mynah's installer disk image.
# Used by scripts/make_dmg.sh: dmgbuild -s scripts/dmg_settings.py -D app=... -D bg=... Mynah dist/Mynah.dmg
import os.path

app = defines["app"]  # noqa: F821  (injected by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"  # lzfse-compressed, macOS 10.11+
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {app_name: (165, 205), "Applications": (495, 205)}
background = defines["bg"]  # noqa: F821
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
hide_extension = [app_name]
