# Third-party code

## REBOOT16 "Realistic Shoreline Waves" (GoDot RSW)

The KP07 water step in `shaders/compute/beach.compute` (`KERNEL_STEP`, `KERNEL_BOUNDARY`) is ported from
https://reboot16.itch.io/godot-rsw (code under the MIT license below). The foam model in `KERNEL_FX`
(breaking / bore / swash sources, foam stranded on the sand) and the two-phase flow-advected lace,
refraction depth test and shoreline convergence in `shaders/render/water.gdshader` follow RSW's
`pass_step.glsl`, `pass_ground.glsl` and `water.gdshader`.

The RSW license text is reproduced verbatim below. Its last paragraph (Poly Haven
textures, rock scans and HDRIs under `assets/textures`, `assets/models`, `assets/hdri`)
describes assets bundled with RSW itself; **it does not apply to this repository**, which
contains none of those assets and no other RSW files.

```
MIT License

Copyright (c) 2026 Reboot16 / Enrico K. www.thinknerd.de

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Bundled third-party assets: the texture sets, 3D rock scans, and HDRI sky
panoramas under assets/textures, assets/models, and assets/hdri originate
from Poly Haven (polyhaven.com) and are dedicated to the public domain under
CC0 1.0. They may be redistributed and used without restriction.
```

## 3D props

The props in `assets/props/` (shells, starfish, pebbles, driftwood, palm, beach grass,
bucket, spade, rocks) were generated for this project with [Meshy](https://www.meshy.ai/)
under a paid plan and cleaned with `tools/blender/prep_prop.py`. They are released with the
rest of this repository under its MIT license.

## Font: Noto Sans JP

`assets/fonts/NotoSansJP-Medium-subset.ttf` (the default UI font, so the HUD shows Japanese
on any OS) is Noto Sans JP by Adobe and Google, © 2014-2021 Adobe, licensed under the SIL Open
Font License 1.1 (full text in `assets/fonts/OFL.txt`). It is a modified version: a static
Medium (wght 500) instance of the variable font, subset to Latin and JIS X 0208 (kana, symbols,
level 1 and 2 kanji) by `tools/subset_font.py`. The font keeps the OFL; it is not covered by
this repository's MIT license.
