"""Generate Android icons from assets/branding/app-icon.png. Requires Pillow."""
from pathlib import Path
from PIL import Image

def main():
    root = Path(__file__).resolve().parents[1]
    res = root / "android/app/src/main/res"
    image = Image.open(root / "assets/branding/app-icon.png").convert("RGB")
    for density, size in {"mdpi":48, "hdpi":72, "xhdpi":96, "xxhdpi":144, "xxxhdpi":192}.items():
        target = res / ("mipmap-" + density) / "ic_launcher.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        image.resize((size,size), Image.Resampling.LANCZOS).save(target)
    foreground = Image.new("RGB",(432,432),"black")
    foreground.paste(image.resize((320,320),Image.Resampling.LANCZOS),(56,56))
    folder = res / "drawable-nodpi"
    folder.mkdir(parents=True,exist_ok=True)
    foreground.save(folder / "ic_fox_foreground.png")
    mono = Image.new("RGBA",(432,432),"white")
    mono.putalpha(foreground.convert("L"))
    mono.save(folder / "ic_fox_monochrome.png")
    for version in (26,33):
        target = res / ("mipmap-anydpi-v" + str(version)) / "ic_launcher.xml"
        target.parent.mkdir(parents=True,exist_ok=True)
        monochrome = '    <monochrome android:drawable="@drawable/ic_fox_monochrome"/>\n' if version == 33 else ""
        target.write_text('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@android:color/black"/>\n    <foreground android:drawable="@drawable/ic_fox_foreground"/>\n' + monochrome + '</adaptive-icon>\n')
if __name__ == "__main__":
    main()
