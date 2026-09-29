"""Generates SafeScreen's icons.

    python tool/generate_icons.py

Writes:
    windows/runner/resources/app_icon.ico   executable, window and taskbar icon
    assets/tray_icon.ico                    notification-area icon
    docs/icon.png                           website and README

The mark is a monitor whose screen has gone black, with the camera light lit in
its bezel: the product in one picture. It uses the same palette as the app and
the website -- paper, ink, one signal red -- and the same square corners.

It is drawn on a 16-unit grid and every size is rendered directly from that grid
rather than downscaled from a large master. Downscaling blurs a 16 px tray icon
into mush; rendering each size with whole-pixel edges keeps it crisp. The paper
bezel is what keeps it visible on a dark taskbar, where a black icon would
disappear.
"""

from pathlib import Path

from PIL import Image, ImageDraw

INK = (22, 22, 26, 255)  # #16161A
PAPER = (233, 229, 221, 255)  # #E9E5DD
SCREEN = (10, 10, 11, 255)  # #0A0A0B
SIGNAL = (179, 53, 15, 255)  # #B3350F
# The stand sits outside the bezel, against the taskbar itself. In ink it
# vanished on a dark taskbar; mid-grey reads on dark and light alike.
STAND = (111, 107, 99, 255)  # #6F6B63

# (x0, y0, x1, y1) in 16-unit grid space, end-exclusive, painted in order.
SHAPES = [
    ((0, 1, 16, 13), INK),  # monitor outline
    ((1, 2, 15, 12), PAPER),  # bezel
    ((2, 5, 14, 11), SCREEN),  # the screen, gone dark
    ((7, 3, 9, 4), SIGNAL),  # camera light
    ((7, 13, 9, 14), STAND),  # neck
    ((4, 14, 12, 15), STAND),  # base
]

ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 256]

ROOT = Path(__file__).resolve().parent.parent


def render(size: int) -> Image.Image:
    """Renders the mark at [size] px with every edge on a whole pixel."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    def edge(v: int) -> int:
        return round(v * size / 16)

    for (x0, y0, x1, y1), colour in SHAPES:
        # Never let a shape collapse to nothing at small sizes.
        left, top = edge(x0), edge(y0)
        right, bottom = max(edge(x1), left + 1), max(edge(y1), top + 1)
        draw.rectangle((left, top, right - 1, bottom - 1), fill=colour)
    return img


def write_ico(path: Path) -> None:
    frames = [render(s) for s in ICO_SIZES]
    path.parent.mkdir(parents=True, exist_ok=True)
    # Pillow picks the supplied frame matching each size instead of resampling.
    frames[-1].save(
        path,
        format="ICO",
        sizes=[(s, s) for s in ICO_SIZES],
        append_images=frames[:-1],
    )
    print(f"wrote {path.relative_to(ROOT)}  ({', '.join(map(str, ICO_SIZES))} px)")


def main() -> None:
    write_ico(ROOT / "windows" / "runner" / "resources" / "app_icon.ico")
    write_ico(ROOT / "assets" / "tray_icon.ico")
    png = ROOT / "docs" / "icon.png"
    render(256).save(png)
    print(f"wrote {png.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
