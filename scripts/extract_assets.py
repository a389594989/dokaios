#!/usr/bin/env python3
"""M0: 从解包后的安卓 APK 提取可复用资产。

- assets/luts/*.png (512x512, 8x8 个 64x64 图块: 图块序号=B, 块内 x=R, y=G) -> Resources/luts/
- res 下的位图 (png/webp/jpg) 和字体 -> ExtractedUI/ (暂不打包, 后续 M4 挑选转入 Assets.xcassets)
- 生成 ExtractedUI/manifest.json (文件名/尺寸), 便于挑选
"""
import json
import shutil
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None

APK = Path(sys.argv[1] if len(sys.argv) > 1 else "../work/doka_apk").resolve()
ROOT = Path(__file__).resolve().parent.parent

lut_dst = ROOT / "Resources" / "luts"
ui_dst = ROOT / "ExtractedUI"
lut_dst.mkdir(parents=True, exist_ok=True)
ui_dst.mkdir(parents=True, exist_ok=True)

n_lut = 0
for f in sorted((APK / "assets" / "luts").glob("lut_*.png")):
    shutil.copy2(f, lut_dst / f.name)
    n_lut += 1
print(f"LUT: {n_lut} -> {lut_dst}")

manifest = []
for f in sorted((APK / "res").rglob("*")):
    if not f.is_file():
        continue
    ext = f.suffix.lower()
    if ext not in (".png", ".webp", ".jpg", ".ttf"):
        continue
    # 同名文件可能来自不同 drawable 目录, 加上父目录名避免覆盖
    name = f"{f.parent.name}__{f.name}" if f.parent.name != "res" else f.name
    shutil.copy2(f, ui_dst / name)
    item = {"file": name, "ninepatch": f.name.endswith(".9.png")}
    if Image and ext != ".ttf":
        try:
            with Image.open(f) as im:
                item["size"] = list(im.size)
        except Exception:
            pass
    manifest.append(item)

(ui_dst / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
print(f"UI/字体: {len(manifest)} -> {ui_dst}")
