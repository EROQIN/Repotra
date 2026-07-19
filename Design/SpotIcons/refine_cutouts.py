#!/usr/bin/env python3
"""Refine oil-icon grid cutouts when graphite details resemble the grey sheet.

Unlike the skill's flat flood-fill mode, this removes only grey pixels connected
to a cell edge. Internal graphite shadows and shield/monitor details remain.
"""

from pathlib import Path
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def cutout(cell: Image.Image, size: int = 512) -> Image.Image:
    rgb = np.asarray(cell.convert("RGB"), dtype=np.int16)
    h, w, _ = rgb.shape
    border = np.concatenate((rgb[:8].reshape(-1, 3), rgb[-8:].reshape(-1, 3),
                             rgb[:, :8].reshape(-1, 3), rgb[:, -8:].reshape(-1, 3)))
    neutral = border[(border.max(axis=1) - border.min(axis=1)) < 12]
    background = np.median(neutral if len(neutral) else border, axis=0)
    distance = np.abs(rgb - background).max(axis=2)

    permissive = distance < 58
    labels, count = ndimage.label(permissive)
    edge_labels = set(np.unique(np.concatenate((labels[0], labels[-1], labels[:, 0], labels[:, -1]))))
    background_region = np.isin(labels, list(edge_labels - {0}))
    feather = np.clip((distance.astype(np.float32) - 13.0) / 34.0, 0, 1)
    alpha = np.where(background_region, feather * 255, 255).astype(np.uint8)
    alpha[background_region & (distance < 14)] = 0

    # Remove tiny disconnected fragments from a neighboring grid cell while
    # keeping all meaningful parts of the centered icon.
    labels, count = ndimage.label(alpha > 18)
    if count:
        sizes = np.bincount(labels.ravel()); sizes[0] = 0
        largest = sizes.max()
        keep = sizes >= max(32, largest * 0.006)
        alpha[~keep[labels]] = 0

    ys, xs = np.where(alpha > 8)
    if not len(xs):
        return Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rgba = np.dstack((rgb.astype(np.uint8), alpha))[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    obj = Image.fromarray(rgba, "RGBA")
    side = int(max(obj.size) * 1.16)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(obj, ((side - obj.width) // 2, (side - obj.height) // 2))
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    sheet_path = Path(sys.argv[1])
    output = Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    sheet = Image.open(sheet_path).convert("RGB")
    width, height = sheet.size
    grid = 3
    cell_width, cell_height = width // grid, height // grid
    pad = int(0.04 * min(cell_width, cell_height))
    index = 1
    for row in range(grid):
        for column in range(grid):
            left = max(0, column * cell_width - pad)
            top = max(0, row * cell_height - pad)
            right = min(width, (column + 1) * cell_width + pad)
            bottom = min(height, (row + 1) * cell_height + pad)
            cutout(sheet.crop((left, top, right, bottom))).save(output / f"{index:02d}.png")
            index += 1
    print(f"refined {index - 1} connected-background cutouts")


if __name__ == "__main__":
    main()
