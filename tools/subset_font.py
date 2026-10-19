"""Static Medium instance of Noto Sans JP, subset to Latin + JIS X 0208 (kana, symbols, level 1+2 kanji).

Rebuild assets/fonts/NotoSansJP-Medium-subset.ttf (needs fonttools) from the variable font
https://github.com/notofonts/noto-cjk (or Google Fonts):
  python tools/subset_font.py NotoSansJP-VF.ttf assets/fonts/NotoSansJP-Medium-subset.ttf
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools import subset

src, out = sys.argv[1], sys.argv[2]
chars = set(range(0x20, 0x7F)) | set(range(0xA0, 0x180)) | set(range(0x2000, 0x2070))
chars |= set(range(0x3000, 0x3100)) | set(range(0xFF00, 0xFFF0))
for hi in range(0x81, 0xF0):
    for lo in range(0x40, 0xFD):
        try:
            for ch in bytes([hi, lo]).decode("cp932"):
                chars.add(ord(ch))
        except UnicodeDecodeError:
            pass
f = TTFont(src)
f = instancer.instantiateVariableFont(f, {"wght": 500}, updateFontNames=True)
opts = subset.Options()
opts.layout_features = ["*"]
opts.name_IDs = ["*"]
opts.name_languages = ["*"]
opts.notdef_outline = True
s = subset.Subsetter(opts)
s.populate(unicodes=chars)
s.subset(f)
f.save(out)
print(len(chars), "codepoints")
