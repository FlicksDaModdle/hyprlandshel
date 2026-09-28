# Render the app icon to the PNG sizes Firefox and the desktop use.
#   python3 render.py <out-dir>
import sys, os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PyQt5.QtGui import QGuiApplication, QImage, QPainter
from PyQt5.QtSvg import QSvgRenderer
from PyQt5.QtCore import Qt
app = QGuiApplication(sys.argv[:1])
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else here
r = QSvgRenderer(os.path.join(here, "hyprshell-browser.svg"))
for s in (16, 32, 48, 64, 128, 256):
    img = QImage(s, s, QImage.Format_ARGB32_Premultiplied)
    img.fill(Qt.transparent)
    p = QPainter(img); p.setRenderHint(QPainter.Antialiasing); r.render(p); p.end()
    img.save(os.path.join(out, f"default{s}.png"))
print("rendered")
