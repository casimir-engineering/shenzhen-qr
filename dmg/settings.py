# dmgbuild settings: the app on the left, Applications on the right, ShenzhenPDF's arrow background.
import os
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
window_rect = ((400, 120), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (150, 200), "Applications": (450, 200)}
