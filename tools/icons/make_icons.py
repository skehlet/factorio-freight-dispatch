# Draws the destination icon layers (0.9.0): a white disc that data.lua tints per destination,
# and number badges 1..20. Run: python3 tools/icons/make_icons.py (needs Pillow).
import os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "freight-dispatch", "graphics", "dest")
os.makedirs(OUT, exist_ok=True)
S = 64
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

big = Image.new("RGBA", (S * 4, S * 4), (0, 0, 0, 0))
d = ImageDraw.Draw(big)
d.ellipse((4, 4, S * 4 - 5, S * 4 - 5), fill=(150, 150, 150, 255))
d.ellipse((20, 20, S * 4 - 21, S * 4 - 21), fill=(255, 255, 255, 255))
big.resize((S, S), Image.LANCZOS).save(os.path.join(OUT, "disc.png"))

for n in range(1, 21):
    t = str(n)
    big = Image.new("RGBA", (S * 4, S * 4), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    size = 150 if len(t) == 1 else 116
    f = ImageFont.truetype(FONT, size)
    box = d.textbbox((0, 0), t, font=f, stroke_width=22)
    w, h = box[2] - box[0], box[3] - box[1]
    x, y = S * 4 - w - box[0] - 2, S * 4 - h - box[1] - 2
    d.text((x, y), t, font=f, fill=(255, 255, 255, 255), stroke_width=22, stroke_fill=(0, 0, 0, 255))
    big.resize((S, S), Image.LANCZOS).save(os.path.join(OUT, "num-%d.png" % n))
print("ok", OUT)
