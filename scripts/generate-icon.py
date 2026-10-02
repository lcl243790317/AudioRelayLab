"""生成项目自有的无透明通道 App 图标，需要 Pillow。"""
from pathlib import Path
from PIL import Image, ImageDraw
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

size = 2048
image = Image.new("RGB", (size, size), (18, 37, 77))
draw = ImageDraw.Draw(image)
draw.ellipse((210, 210, 1838, 1838), fill=(29, 89, 172))
heights = [170, 350, 590, 790, 610, 360, 190]
for index, height in enumerate(heights):
    x = 514 + index * 140
    draw.rounded_rectangle((x, 1024 - height // 2, x + 80, 1024 + height // 2), radius=40, fill=(245, 252, 255))
draw.line([(650, 540), (1320, 540)], fill=(89, 225, 219), width=48)
draw.polygon([(1320, 440), (1440, 540), (1320, 640)], fill=(89, 225, 219))
draw.line([(730, 1510), (1400, 1510)], fill=(89, 225, 219), width=48)
draw.polygon([(730, 1410), (610, 1510), (730, 1610)], fill=(89, 225, 219))
path = Path(__file__).resolve().parents[1] / "AudioRelayLab/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
image.resize((1024, 1024), Image.Resampling.LANCZOS).save(path)
print(f"已生成：{path}")
