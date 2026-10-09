"""Renders the $PAIR token logo (PNG sizes) from the same geometry as pair-logo.svg."""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).parent
S = 4096  # supersampled canvas, downsampled for anti-aliasing

BG_TOP = (24, 33, 31)
BG_BOTTOM = (10, 14, 13)
INK = (233, 231, 226)
ACCENT = (95, 191, 159)
LENS = (95, 191, 159, 70)


def render() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # circular badge with a vertical gradient
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        c = tuple(round(BG_TOP[i] * (1 - t) + BG_BOTTOM[i] * t) for i in range(3))
        gd.line([(0, y), (S, y)], fill=c + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, S - 1, S - 1], fill=255)
    img.paste(grad, (0, 0), mask)

    # two interlocking rings: the pair
    r = int(S * 0.235)
    w = int(S * 0.062)
    cy = S // 2
    cx_l = int(S * 0.385)
    cx_r = int(S * 0.615)

    # overlap lens (the spread)
    lens = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    a = Image.new("L", (S, S), 0)
    b = Image.new("L", (S, S), 0)
    ImageDraw.Draw(a).ellipse([cx_l - r, cy - r, cx_l + r, cy + r], fill=255)
    ImageDraw.Draw(b).ellipse([cx_r - r, cy - r, cx_r + r, cy + r], fill=255)
    inter = Image.composite(a, Image.new("L", (S, S), 0), b)
    lens.paste(Image.new("RGBA", (S, S), LENS), (0, 0), inter)
    img = Image.alpha_composite(img, lens)

    d = ImageDraw.Draw(img)
    d.ellipse([cx_l - r, cy - r, cx_l + r, cy + r], outline=INK + (255,), width=w)
    d.ellipse([cx_r - r, cy - r, cx_r + r, cy + r], outline=ACCENT + (255,), width=w)
    # weave: redraw the left ring's upper crossing on top so the rings interlock
    d.arc([cx_l - r, cy - r, cx_l + r, cy + r], start=-79, end=-43, fill=INK + (255,), width=w)
    return img


if __name__ == "__main__":
    big = render()
    for size in (1024, 512, 256):
        big.resize((size, size), Image.LANCZOS).save(OUT / f"pair-logo-{size}.png")
    # square, non-transparent variant for platforms that reject transparency
    flat = Image.new("RGB", (1024, 1024), (10, 14, 13))
    flat.paste(big.resize((1024, 1024), Image.LANCZOS), (0, 0), big.resize((1024, 1024), Image.LANCZOS))
    flat.save(OUT / "pair-logo-1024-solid.png")
    print("wrote", sorted(p.name for p in OUT.glob("pair-logo-*.png")))
