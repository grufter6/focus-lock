"""Generate the dark ambient focus wallpapers (2560 x 1664, this Mac's native resolution).
Everything is drawn from code, so there is nothing to license. Run: python3 src/make_wallpapers.py"""
import os
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter, zoom

W, H = 2560, 1664
w, h = W // 2, H // 2                          # draw at half size, upscale, then add grain at full size
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "wallpapers", "generated")
rng = np.random.default_rng(7)
yy, xx = np.mgrid[0:h, 0:w] / np.array([h, w])[:, None, None]


def vgrad(top, bottom, curve=1.0):
    t = (yy ** curve)[..., None]
    return np.array(top) * (1 - t) + np.array(bottom) * t


def glow(cx, cy, r, color, strength=1.0):
    d = np.sqrt(((xx - cx) * w / h) ** 2 + (yy - cy) ** 2)
    return np.exp(-(d / r) ** 2)[..., None] * np.array(color) * strength


def stars(img, n, bright=1.0, band=None):
    for _ in range(n):
        x, y = rng.integers(0, w), rng.integers(0, int(h * 0.75))
        if band is not None and abs((y / h) - (band[0] + band[1] * x / w)) > band[2] * rng.random() ** 0.5:
            continue
        img[y, x] += rng.uniform(80, 230) * bright
    return img


def ridge(base, amp, freq, seed):
    r = np.random.default_rng(seed)
    x = np.linspace(0, 1, w)
    y = np.full(w, float(base))
    for k in range(1, 7):
        y += amp / k * np.sin(2 * np.pi * (freq * k * x + r.random()))
    return y


def layer(img, line_y, color, fog=None):
    mask = (np.arange(h)[:, None] >= line_y[None, :])[..., None]
    out = np.where(mask, np.array(color), img)
    if fog is not None:
        f = np.clip(1 - (np.arange(h)[:, None] - line_y[None, :]) / fog, 0, 1)[..., None] * mask
        out = out + f * 18
    return out


def finish(img, name, blur=0.6):
    img = np.stack([gaussian_filter(img[..., c], blur) for c in range(3)], -1)
    img = zoom(img, (H / h, W / w, 1), order=1)
    img += rng.normal(0, 2.2, img.shape)                     # film grain hides banding in dark gradients
    vig = 1 - 0.35 * (((np.mgrid[0:H, 0:W][1] / W - 0.5) ** 2 + (np.mgrid[0:H, 0:W][0] / H - 0.5) ** 2) * 2.2)
    img *= vig[..., None]
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(os.path.join(OUT, name + ".jpg"), quality=92)
    print(f"{name:22} mean brightness {img.mean():5.1f}")


def aurora():
    img = vgrad([4, 8, 18], [6, 14, 20])
    a = np.zeros((h, w))
    for k, (c, amp) in enumerate([(0.32, 0.06), (0.4, 0.05), (0.28, 0.04)]):
        x = np.linspace(0, 1, w)
        center = c + amp * np.sin(2 * np.pi * (1.3 * x + k)) + 0.02 * np.sin(2 * np.pi * 5 * x + k)
        a += np.exp(-((yy - center[None, :]) / 0.035) ** 2) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * x + k))[None, :]
        a += 0.5 * np.exp(-np.clip(yy - center[None, :], 0, None) / 0.03) * (yy < center[None, :]) * 0.0
    a = gaussian_filter(a, (6, 2))
    img += a[..., None] * np.array([20, 90, 70])
    img += gaussian_filter(a, 25)[..., None] * np.array([10, 40, 50])
    img = stars(img, 900, 0.5)
    img = layer(img, ridge(h * 0.78, 18, 1.2, 3), [3, 6, 9], fog=40)
    finish(img, "01-aurora")


def milky_way():
    img = vgrad([3, 4, 12], [10, 9, 22])
    band = gaussian_filter(rng.random((h, w)), 6)
    d = np.abs(yy - (0.15 + 0.5 * xx))
    neb = np.exp(-(d / 0.12) ** 2) * (0.5 + band)
    img += neb[..., None] * np.array([22, 18, 34])
    img = stars(img, 2600, 0.45)
    img = stars(img, 2600, 0.35, band=(0.15, 0.5, 0.12))
    img = layer(img, ridge(h * 0.86, 10, 0.8, 5), [2, 2, 5])
    finish(img, "02-milky-way", blur=0.5)


def misty_mountains():
    img = vgrad([14, 20, 34], [30, 40, 56])
    img += glow(0.7, 0.35, 0.25, [40, 38, 50], 0.6)
    for i, (base, col) in enumerate([(0.45, [26, 34, 50]), (0.55, [19, 26, 40]), (0.66, [13, 18, 30]), (0.78, [7, 10, 18])]):
        img = layer(img, ridge(h * base, 30 - i * 5, 1.0 + i * 0.4, 10 + i), col, fog=60)
    finish(img, "03-misty-mountains", blur=1.2)


def deep_ocean():
    img = vgrad([6, 26, 40], [1, 4, 10], curve=0.7)
    rays = np.zeros((h, w))
    for k in range(9):
        x0 = 0.2 + 0.6 * rng.random()
        rays += np.exp(-((xx - x0 - (yy * (x0 - 0.5) * 0.4)) / (0.01 + 0.02 * rng.random())) ** 2) * (1 - yy) ** 2
    img += gaussian_filter(rays, 8)[..., None] * np.array([10, 30, 34])
    for _ in range(160):
        x, y, r = rng.random(), rng.random(), rng.uniform(0.001, 0.004)
        img += glow(x, y, r, [30, 50, 60], 0.5 * (1 - y))
    finish(img, "04-deep-ocean", blur=1.0)


def dusk_dunes():
    img = vgrad([22, 12, 30], [52, 24, 34])
    img += glow(0.5, 0.62, 0.3, [70, 30, 20], 0.6)
    for i, (base, col) in enumerate([(0.6, [30, 16, 26]), (0.7, [20, 11, 20]), (0.83, [11, 7, 13])]):
        x = np.linspace(0, 1, w)
        y = h * base + 22 * np.sin(2 * np.pi * (0.7 + i * 0.3) * x + i) + 10 * np.sin(2 * np.pi * 2.3 * x + 2 * i)
        img = layer(img, y, col, fog=50)
    finish(img, "05-dusk-dunes", blur=1.2)


def bokeh():
    img = vgrad([8, 8, 14], [4, 4, 8])
    for _ in range(70):
        col = [[60, 40, 90], [30, 60, 90], [80, 50, 40], [40, 70, 70]][rng.integers(0, 4)]
        img += glow(rng.random(), rng.random(), rng.uniform(0.02, 0.07), col, rng.uniform(0.15, 0.45))
    finish(img, "06-bokeh", blur=2.5)


def pine_fog():
    img = vgrad([18, 26, 26], [10, 16, 16])
    img += glow(0.3, 0.3, 0.35, [30, 40, 36], 0.6)
    for i, (n, base, col) in enumerate([(40, 0.62, [22, 32, 30]), (30, 0.72, [14, 22, 20]), (22, 0.85, [6, 11, 10])]):
        line = np.full(w, h * base)
        for _ in range(n):
            cx, th, tw = rng.integers(0, w), rng.uniform(0.12, 0.3) * h, rng.uniform(14, 30)
            xs = np.arange(w)
            tri = h * base - th * np.clip(1 - np.abs(xs - cx) / tw, 0, 1)
            line = np.minimum(line, tri)
        img = layer(img, line, col, fog=70)
    finish(img, "07-pine-fog", blur=1.0)


def moon_lake():
    img = vgrad([6, 10, 22], [10, 16, 30])
    img += glow(0.62, 0.28, 0.05, [200, 200, 190], 0.9) + glow(0.62, 0.28, 0.25, [30, 34, 50], 0.6)
    img = stars(img, 500, 0.3)
    horizon = int(h * 0.62)
    img = layer(img, ridge(horizon - 6, 8, 1.5, 21), [5, 8, 14])
    refl = img[:horizon][::-1][: h - horizon] * 0.35
    ripple = 1 + 0.3 * np.sin(np.arange(h - horizon)[:, None] * 0.9 + rng.random((1, w)) * 0.5)
    img[horizon:] = refl[: h - horizon] * ripple[..., None] + np.array([2, 4, 8])
    finish(img, "08-moon-lake", blur=0.8)


def indigo_flow():
    img = vgrad([10, 8, 26], [20, 6, 24])
    f = gaussian_filter(rng.random((h // 8, w // 8)), 4)
    f = zoom(f, (h / f.shape[0], w / f.shape[1]), order=3)
    f = (f - f.min()) / (f.max() - f.min())
    img += (np.sin(f * 18) * 0.5 + 0.5)[..., None] * np.array([18, 10, 34]) * 0.8
    finish(img, "09-indigo-flow", blur=3)


def nebula():
    img = np.zeros((h, w, 3)) + [4, 3, 8]
    for col, s in (([40, 14, 50], 70), ([10, 26, 50], 55), ([50, 20, 30], 40)):
        n = gaussian_filter(rng.random((h, w)), s)
        n = np.clip((n - n.mean()) / n.std(), 0, None)
        img += (n ** 1.5)[..., None] * np.array(col) * 0.3
    img += glow(0.55, 0.45, 0.35, [24, 12, 34], 0.8)
    img = stars(img, 2000, 0.4)
    finish(img, "10-nebula", blur=0.6)


def ember_horizon():
    img = vgrad([5, 6, 10], [8, 8, 12])
    img += glow(0.5, 1.05, 0.45, [80, 34, 10], 0.7)
    img = layer(img, ridge(h * 0.9, 6, 0.6, 33), [3, 3, 5])
    finish(img, "11-ember-horizon", blur=1.0)


def rain_city():
    img = vgrad([8, 10, 18], [14, 12, 22])
    for _ in range(140):
        col = [[90, 60, 30], [40, 60, 90], [80, 40, 70], [90, 80, 50]][rng.integers(0, 4)]
        img += glow(rng.random(), 0.55 + 0.4 * rng.random(), rng.uniform(0.005, 0.02), col, rng.uniform(0.3, 0.8))
    img = np.stack([gaussian_filter(img[..., c], 9) for c in range(3)], -1)
    streak = np.zeros((h, w))
    for _ in range(500):
        x, y, L = rng.integers(0, w), rng.integers(0, h), rng.integers(10, 40)
        streak[y:y + L, x] += 10
    img += gaussian_filter(streak, (2, 0.6))[..., None] * np.array([1.0, 1.1, 1.3])
    finish(img, "12-rain-city", blur=0.5)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for f in (aurora, milky_way, misty_mountains, deep_ocean, dusk_dunes, bokeh, pine_fog, moon_lake,
              indigo_flow, nebula, ember_horizon, rain_city):
        f()
