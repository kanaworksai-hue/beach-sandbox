"""Contact sheet: python tools/contact.py out.png cell_px cols img1 img2 ..."""
import sys
from PIL import Image

out, cell, cols = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
files = sys.argv[4:]
ims = []
for f in files:
    im = Image.open(f).convert("RGB")
    im.thumbnail((cell, cell))
    ims.append(im)
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (cell * cols, cell * rows), "white")
for i, im in enumerate(ims):
    sheet.paste(im, ((i % cols) * cell + (cell - im.width) // 2, (i // cols) * cell + (cell - im.height) // 2))
sheet.save(out)
