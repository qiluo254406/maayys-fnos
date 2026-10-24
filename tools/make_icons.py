#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从源图生成飞牛 fpk 需要的全部图标尺寸。

fnpack 的硬性要求：
  - 包根 ICON.PNG（64x64）与 ICON_256.PNG（256x256）
  - manifest 声明 desktop_uidir = ui，则 app/ui/ 下要有实际图标文件

用法：
    python tools/make_icons.py [源图路径]

默认源图：tools/assets/logo.png（MaaYYs 官方 logo）
"""
import sys
from pathlib import Path

from PIL import Image

SIZES = [16, 24, 32, 48, 64, 72, 96, 128, 144, 256, 512]

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "tools" / "assets" / "logo.png"
IMAGES_DIR = ROOT / "fnos-app" / "app" / "ui" / "images"


def main() -> int:
    if not SRC.is_file():
        print(f"源图不存在：{SRC}", file=sys.stderr)
        return 1

    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    # 统一转成正方形 RGBA：先按短边居中裁切，避免拉变形
    img = Image.open(SRC).convert("RGBA")
    side = min(img.size)
    left = (img.width - side) // 2
    top = (img.height - side) // 2
    img = img.crop((left, top, left + side, top + side))

    for size in SIZES:
        out = IMAGES_DIR / f"icon_{size}.png"
        img.resize((size, size), Image.LANCZOS).save(out, "PNG", optimize=True)
        print(f"  {out.relative_to(ROOT)}  {size}x{size}")

    # 包根的两张
    img.resize((64, 64), Image.LANCZOS).save(ROOT / "fnos-app" / "ICON.PNG", "PNG", optimize=True)
    img.resize((256, 256), Image.LANCZOS).save(ROOT / "fnos-app" / "ICON_256.PNG", "PNG", optimize=True)
    print("  fnos-app/ICON.PNG  64x64")
    print("  fnos-app/ICON_256.PNG  256x256")

    # ui/config 里写的是 images/icon_{0}.png，其中 {0} 由飞牛按尺寸替换。
    # 保留一份同名的实体文件做兜底（与 MAA-FnOS 的做法一致）。
    fallback = IMAGES_DIR / "icon_{0}.png"
    img.resize((256, 256), Image.LANCZOS).save(fallback, "PNG", optimize=True)
    print(f"  {fallback.relative_to(ROOT)}  (兜底)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
