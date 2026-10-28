# The disk image's window, for dmgbuild (scripts/release.sh runs it): Starlight and an
# Applications shortcut on the picture from scripts/dmg-background.swift, and nothing else: no
# toolbar or sidebar, and an empty title bar (the volume's name is a zero-width space and its
# icon, Resources/DMG/volume.icns, is transparent). dmgbuild writes the window's layout itself,
# so nothing has to script Finder. The icon positions here and in the background script must match.
#
#   dmgbuild -s scripts/dmg-settings.py -D app=Starlight.app $'\xe2\x80\x8b' dist/Starlight.dmg
import os.path

app = defines["app"]
name = os.path.basename(app)

format = "ULFO"  # LZFSE: smaller than the old zlib images, opens on any Mac Starlight runs on
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [name]
icon = defines.get("icon", "Resources/DMG/volume.icns")

background = defines.get("background", "Resources/DMG/background.tiff")
window_rect = ((200, 140), (660, 428))  # 400 for the picture, 28 for the title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {name: (180, 190), "Applications": (480, 190)}
