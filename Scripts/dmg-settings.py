from pathlib import Path

app = Path(defines["app"]).resolve()
format = "UDZO"
filesystem = "HFS+"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
background = str(Path(defines["resources"]) / "dmg-background.png")
window_rect = ((120, 120), (600, 360))
default_view = "icon-view"
icon_locations = {app.name: (160, 180), "Applications": (440, 180)}
icon_size = 100
text_size = 13
label_pos = "bottom"
arrange_by = None
show_status_bar = False
show_toolbar = False
show_sidebar = False
show_pathbar = False
show_tab_view = False
