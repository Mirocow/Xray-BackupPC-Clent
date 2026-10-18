"""Render the BackupPC VPN desktop icons (shield with up/down arrows).

The shape is the Android launcher icon
(android/app/src/main/res/drawable/ic_foreground.xml, 432x432 viewport);
the background colors are those of assets/app_icon/*.png.

    uv run --no-project --with pillow python tool/render_icons.py

Writes windows/runner/resources/app_icon.ico, assets/icon/tray_*.{ico,png},
assets/logo.png and assets/macos_icon/*.png.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]

PRIMARY = (15, 110, 86)
WHITE = (255, 255, 255)
COLORS = {
    "blue": PRIMARY,
    "black": (28, 28, 30),
    "green": (46, 158, 68),
    "orange": (242, 140, 40),
    "purple": (126, 87, 194),
    "red": (217, 59, 59),
}
ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)

# ic_foreground.xml, viewport units.
_SHIELD_TOP = [(216, 100), (304, 132), (304, 212)]
_SHIELD_RIGHT = ((304, 212), (304, 268), (266, 308), (216, 332))
_SHIELD_LEFT = ((216, 332), (166, 308), (128, 268), (128, 212))
_ARROWS = [
    [(190, 268), (190, 166)],
    [(168, 190), (190, 166), (212, 190)],
    [(242, 166), (242, 268)],
    [(220, 244), (242, 268), (264, 244)],
]
_STROKE = 18
_CENTER = 216
_SHIELD_WIDTH = 176


def _bezier(p0, p1, p2, p3, steps=48):
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        yield (
            u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
            u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1],
        )


_SHIELD = [*_SHIELD_TOP, *_bezier(*_SHIELD_RIGHT), *_bezier(*_SHIELD_LEFT), (128, 132)]


def render(size, background, shield, *, plate=1.0, radius=0.2, width=0.42, stroke=1.0):
    """One icon: a rounded plate of `plate` x size, the shield `width` x size wide.

    Small sizes pass a wider shield and a heavier `stroke` so the arrows
    stay readable at 16 px.
    """
    scale = 8
    canvas = size * scale
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    inset = canvas * (1 - plate) / 2
    draw.rounded_rectangle(
        (inset, inset, canvas - inset, canvas - inset),
        radius=canvas * plate * radius,
        fill=background,
    )

    k = canvas * width / _SHIELD_WIDTH
    def point(p):
        return (canvas / 2 + (p[0] - _CENTER) * k, canvas / 2 + (p[1] - _CENTER) * k)

    draw.polygon([point(p) for p in _SHIELD], fill=shield)
    line = _STROKE * k * stroke
    for path in _ARROWS:
        points = [point(p) for p in path]
        draw.line(points, fill=background, width=round(line), joint="curve")
        for x, y in points:
            draw.ellipse((x - line / 2, y - line / 2, x + line / 2, y + line / 2), fill=background)
    return image.resize((size, size), Image.LANCZOS)


def _small(size):
    """Wider shield and heavier arrows below 48 px."""
    if size <= 24:
        return {"width": 0.62, "stroke": 1.5}
    if size <= 40:
        return {"width": 0.55, "stroke": 1.3}
    return {}


def save_ico(path, background, shield, **options):
    images = [render(s, background, shield, **options, **_small(s)) for s in ICO_SIZES]
    images[-1].save(path, format="ICO", sizes=[(s, s) for s in ICO_SIZES], append_images=images[:-1])


def main():
    save_ico(ROOT / "windows/runner/resources/app_icon.ico", PRIMARY, WHITE)

    tray = ROOT / "assets/icon"
    # Running: the colored icon; stopped: inverted on a white plate.
    save_ico(tray / "tray_running.ico", PRIMARY, WHITE)
    save_ico(tray / "tray_not_running.ico", WHITE, PRIMARY)
    render(64, PRIMARY, WHITE).save(tray / "tray_running.png")
    render(64, WHITE, PRIMARY).save(tray / "tray_not_running.png")

    # MSIX logo: a full-bleed square, the Store adds its own plate.
    render(1024, PRIMARY, WHITE, radius=0).save(ROOT / "assets/logo.png")

    # macOS app icon grid: 824 px plate inside a 1024 px canvas.
    for name, color in COLORS.items():
        render(1024, color, WHITE, plate=824 / 1024, radius=0.225, width=0.34).save(
            ROOT / f"assets/macos_icon/{name}.png"
        )


if __name__ == "__main__":
    main()
