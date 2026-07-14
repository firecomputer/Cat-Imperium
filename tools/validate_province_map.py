#!/usr/bin/env python3
"""Validate bitmap/JSON linkage and core province-map invariants."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image
from rasterio.features import shapes as connected_shapes


ROOT = Path(__file__).resolve().parents[1]
JSON_PATH = ROOT / "data/province_map.json"
IMAGE_PATH = ROOT / "data/province_map.png"


def rgb_key(red: int, green: int, blue: int) -> int:
    return (red << 16) | (green << 8) | blue


def main() -> None:
    database = json.loads(JSON_PATH.read_text(encoding="utf-8"))
    map_info = database["map"]
    provinces = database["provinces"]
    expected_count = int(map_info["province_count"])
    assert len(provinces) == expected_count
    assert [province["id"] for province in provinces] == list(range(1, expected_count + 1))

    image = np.asarray(Image.open(IMAGE_PATH).convert("RGB"))
    assert image.shape == (int(map_info["height"]), int(map_info["width"]), 3)
    packed = (
        image[:, :, 0].astype(np.int32) << 16
        | image[:, :, 1].astype(np.int32) << 8
        | image[:, :, 2].astype(np.int32)
    )
    unique_colors, color_counts = np.unique(packed, return_counts=True)
    expected_colors = {0}
    record_by_color: dict[int, dict[str, object]] = {}
    for province in provinces:
        color = province["color"]
        key = rgb_key(int(color[0]), int(color[1]), int(color[2]))
        assert key != 0 and key not in expected_colors
        expected_colors.add(key)
        record_by_color[key] = province
    assert set(int(value) for value in unique_colors) == expected_colors
    for key, pixel_count in zip(unique_colors, color_counts):
        if key:
            assert int(record_by_color[int(key)]["pixel_count"]) == int(pixel_count)

    component_counts: Counter[int] = Counter()
    for _geometry, value in connected_shapes(
        packed, mask=packed != 0, connectivity=4
    ):
        component_counts[int(value)] += 1
    disconnected = [key for key, count in component_counts.items() if count != 1]
    assert not disconnected, f"Disconnected province colors: {disconnected[:10]}"

    neighbor_sets = [set()] + [set(int(value) for value in p["neighbors"]) for p in provinces]
    for province in provinces:
        province_id = int(province["id"])
        assert province_id not in neighbor_sets[province_id]
        for neighbor_id in neighbor_sets[province_id]:
            assert 1 <= neighbor_id <= expected_count
            assert province_id in neighbor_sets[neighbor_id]
        label_x, label_y = province["label_pixel"]
        assert int(packed[int(label_y), int(label_x)]) == rgb_key(*province["color"])

    print(
        f"OK: {expected_count:,} connected provinces, {len(expected_colors):,} bitmap colors, "
        f"{sum(len(values) for values in neighbor_sets) // 2:,} adjacency edges"
    )


if __name__ == "__main__":
    main()
