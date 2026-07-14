#!/usr/bin/env python3
"""Build a deterministic 9,900-province bitmap and its JSON database.

The generator intentionally only depends on NumPy, Pillow, and Rasterio.  A
small SHP/DBF reader is included so the Natural Earth source files in this
repository remain the only geographic input required.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator, Sequence

import numpy as np
import rasterio
from PIL import Image
from rasterio.enums import Resampling
from rasterio.features import rasterize, shapes as connected_shapes
from rasterio.transform import from_bounds
from rasterio.warp import reproject


ROOT = Path(__file__).resolve().parents[1]
COUNTRIES_SHP = ROOT / "ne_10m_admin_0_countries/ne_10m_admin_0_countries.shp"
COUNTRIES_DBF = ROOT / "ne_10m_admin_0_countries/ne_10m_admin_0_countries.dbf"
LAKES_SHP = ROOT / "ne_10m_lakes/ne_10m_lakes.shp"
GLACIERS_SHP = ROOT / "ne_10m_glaciated_areas/ne_10m_glaciated_areas.shp"
CLIMATE_TIF = ROOT / "Beck_KG_V1/Beck_KG_V1_present_0p083.tif"

DEFAULT_WIDTH = 4096
DEFAULT_HEIGHT = 2048
DEFAULT_PROVINCES = 9900
EARTH_RADIUS_KM = 6371.0088
COLOR_MULTIPLIER = 0x9E3779B1  # Odd, so it is a permutation modulo 2^24.

CLIMATES = {
    0: ("Unknown", "No climate data"),
    1: ("Af", "Tropical, rainforest"),
    2: ("Am", "Tropical, monsoon"),
    3: ("Aw", "Tropical, savannah"),
    4: ("BWh", "Arid, desert, hot"),
    5: ("BWk", "Arid, desert, cold"),
    6: ("BSh", "Arid, steppe, hot"),
    7: ("BSk", "Arid, steppe, cold"),
    8: ("Csa", "Temperate, dry summer, hot summer"),
    9: ("Csb", "Temperate, dry summer, warm summer"),
    10: ("Csc", "Temperate, dry summer, cold summer"),
    11: ("Cwa", "Temperate, dry winter, hot summer"),
    12: ("Cwb", "Temperate, dry winter, warm summer"),
    13: ("Cwc", "Temperate, dry winter, cold summer"),
    14: ("Cfa", "Temperate, no dry season, hot summer"),
    15: ("Cfb", "Temperate, no dry season, warm summer"),
    16: ("Cfc", "Temperate, no dry season, cold summer"),
    17: ("Dsa", "Cold, dry summer, hot summer"),
    18: ("Dsb", "Cold, dry summer, warm summer"),
    19: ("Dsc", "Cold, dry summer, cold summer"),
    20: ("Dsd", "Cold, dry summer, very cold winter"),
    21: ("Dwa", "Cold, dry winter, hot summer"),
    22: ("Dwb", "Cold, dry winter, warm summer"),
    23: ("Dwc", "Cold, dry winter, cold summer"),
    24: ("Dwd", "Cold, dry winter, very cold winter"),
    25: ("Dfa", "Cold, no dry season, hot summer"),
    26: ("Dfb", "Cold, no dry season, warm summer"),
    27: ("Dfc", "Cold, no dry season, cold summer"),
    28: ("Dfd", "Cold, no dry season, very cold winter"),
    29: ("ET", "Polar, tundra"),
    30: ("EF", "Polar, frost"),
}


def read_dbf(path: Path) -> list[dict[str, object]]:
    """Read the simple dBASE table paired with a Natural Earth shapefile."""
    with path.open("rb") as handle:
        header = handle.read(32)
        record_count = struct.unpack_from("<I", header, 4)[0]
        header_length = struct.unpack_from("<H", header, 8)[0]
        record_length = struct.unpack_from("<H", header, 10)[0]
        fields: list[tuple[str, str, int, int]] = []
        while handle.tell() < header_length - 1:
            descriptor = handle.read(32)
            if not descriptor or descriptor[0] == 0x0D:
                break
            name = descriptor[:11].split(b"\0", 1)[0].decode("ascii")
            fields.append((name, chr(descriptor[11]), descriptor[16], descriptor[17]))
        handle.seek(header_length)
        records: list[dict[str, object]] = []
        for _ in range(record_count):
            raw = handle.read(record_length)
            if len(raw) != record_length:
                raise ValueError(f"Truncated DBF record in {path}")
            if raw[:1] == b"*":
                records.append({})
                continue
            offset = 1
            record: dict[str, object] = {}
            for name, field_type, length, decimals in fields:
                text = raw[offset : offset + length].decode("utf-8", "replace").strip(" \0")
                offset += length
                if field_type in ("N", "F"):
                    if not text:
                        value: object = None
                    else:
                        try:
                            value = float(text) if decimals or "." in text else int(text)
                        except ValueError:
                            value = None
                else:
                    value = text
                record[name] = value
            records.append(record)
    return records


def read_polygon_shp(path: Path) -> list[list[np.ndarray]]:
    """Return records as lists of polygon rings from a Polygon SHP file."""
    records: list[list[np.ndarray]] = []
    with path.open("rb") as handle:
        header = handle.read(100)
        if len(header) != 100 or struct.unpack_from(">I", header, 0)[0] != 9994:
            raise ValueError(f"Invalid shapefile header: {path}")
        while True:
            record_header = handle.read(8)
            if not record_header:
                break
            if len(record_header) != 8:
                raise ValueError(f"Truncated shapefile record header: {path}")
            _record_number, word_length = struct.unpack(">II", record_header)
            content = handle.read(word_length * 2)
            if len(content) != word_length * 2:
                raise ValueError(f"Truncated shapefile record: {path}")
            shape_type = struct.unpack_from("<I", content, 0)[0]
            if shape_type == 0:
                records.append([])
                continue
            if shape_type not in (5, 15, 25):
                raise ValueError(f"Expected polygon shapefile, got type {shape_type}: {path}")
            part_count, point_count = struct.unpack_from("<II", content, 36)
            part_offset = 44
            parts = list(struct.unpack_from(f"<{part_count}I", content, part_offset))
            points_offset = part_offset + part_count * 4
            points = np.frombuffer(
                content, dtype="<f8", count=point_count * 2, offset=points_offset
            ).reshape((-1, 2)).copy()
            rings: list[np.ndarray] = []
            for part_index, start in enumerate(parts):
                end = parts[part_index + 1] if part_index + 1 < part_count else point_count
                ring = points[start:end]
                if len(ring) >= 4:
                    rings.append(ring)
            records.append(rings)
    return records


def signed_area(ring: np.ndarray) -> float:
    x = ring[:, 0]
    y = ring[:, 1]
    return float(0.5 * np.sum(x[:-1] * y[1:] - x[1:] * y[:-1]))


def point_in_ring(point: Sequence[float], ring: np.ndarray) -> bool:
    x, y = float(point[0]), float(point[1])
    inside = False
    previous = ring[-1]
    for current in ring:
        x1, y1 = float(previous[0]), float(previous[1])
        x2, y2 = float(current[0]), float(current[1])
        if (y1 > y) != (y2 > y):
            crossing_x = (x2 - x1) * (y - y1) / (y2 - y1) + x1
            if x < crossing_x:
                inside = not inside
        previous = current
    return inside


def rings_to_geometry(rings: Sequence[np.ndarray]) -> dict[str, object] | None:
    """Group SHP rings into a GeoJSON MultiPolygon, retaining interior holes."""
    if not rings:
        return None
    areas = np.asarray([signed_area(ring) for ring in rings])
    largest_index = int(np.argmax(np.abs(areas)))
    outer_sign = -1.0 if areas[largest_index] < 0.0 else 1.0
    outer_indices = [i for i, area in enumerate(areas) if area * outer_sign > 0.0]
    hole_indices = [i for i, area in enumerate(areas) if area * outer_sign <= 0.0]
    if not outer_indices:
        outer_indices = [largest_index]
        hole_indices = [i for i in range(len(rings)) if i != largest_index]

    polygons: list[list[list[list[float]]]] = [
        [rings[index].tolist()] for index in outer_indices
    ]
    outer_sizes = [abs(areas[index]) for index in outer_indices]
    for hole_index in hole_indices:
        point = rings[hole_index][0]
        candidates = [
            (outer_sizes[position], position)
            for position, outer_index in enumerate(outer_indices)
            if point_in_ring(point, rings[outer_index])
        ]
        if candidates:
            _, polygon_index = min(candidates)
            polygons[polygon_index].append(rings[hole_index].tolist())
        else:
            # A malformed/orientation-inconsistent ring is safer as its own island
            # than as a hole in an unrelated polygon.
            polygons.append([rings[hole_index][::-1].tolist()])
    return {"type": "MultiPolygon", "coordinates": polygons}


def load_geometries(path: Path) -> list[dict[str, object] | None]:
    return [rings_to_geometry(rings) for rings in read_polygon_shp(path)]


def allocate_with_caps(weights: np.ndarray, total: int, caps: np.ndarray) -> np.ndarray:
    """Give every component one province, then use weighted largest remainders."""
    count = len(weights) - 1
    if total < count:
        raise ValueError(f"{count} land components require at least {count} provinces")
    allocation = np.ones(count + 1, dtype=np.int32)
    allocation[0] = 0
    remaining = total - count
    available = caps.astype(np.int64) - allocation
    while remaining:
        active = available > 0
        active[0] = False
        if not np.any(active):
            raise ValueError("Not enough land pixels for requested province count")
        active_weights = np.where(active, weights, 0.0)
        if float(active_weights.sum()) <= 0.0:
            active_weights = active.astype(np.float64)
        quota = remaining * active_weights / active_weights.sum()
        addition = np.minimum(np.floor(quota).astype(np.int64), available)
        used = int(addition.sum())
        if used:
            allocation += addition.astype(np.int32)
            available -= addition
            remaining -= used
            continue
        fractions = quota - np.floor(quota)
        fractions[~active] = -1.0
        take = min(remaining, int(np.count_nonzero(active)))
        chosen = np.argpartition(fractions, -take)[-take:]
        allocation[chosen] += 1
        available[chosen] -= 1
        remaining -= take
    return allocation


def morton_codes(x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """2D Morton ordering gives deterministic, spatially stratified seeds."""
    def spread(values: np.ndarray) -> np.ndarray:
        result = values.astype(np.uint32, copy=True) & np.uint32(0x0000FFFF)
        result = (result | (result << np.uint32(8))) & np.uint32(0x00FF00FF)
        result = (result | (result << np.uint32(4))) & np.uint32(0x0F0F0F0F)
        result = (result | (result << np.uint32(2))) & np.uint32(0x33333333)
        result = (result | (result << np.uint32(1))) & np.uint32(0x55555555)
        return result

    return spread(x) | (spread(y) << np.uint32(1))


def pick_seeds(
    component_grid: np.ndarray,
    component_country: np.ndarray,
    allocation: np.ndarray,
    province_count: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return seed flat indices plus province-to-country/component tables."""
    height, width = component_grid.shape
    flat_components = component_grid.ravel()
    land_indices = np.flatnonzero(flat_components)
    order = np.argsort(flat_components[land_indices], kind="stable")
    grouped_indices = land_indices[order]
    grouped_labels = flat_components[grouped_indices]
    boundaries = np.searchsorted(grouped_labels, np.arange(1, len(allocation) + 1))

    seeds = np.empty(province_count, dtype=np.int64)
    province_country = np.zeros(province_count + 1, dtype=np.int32)
    province_component = np.zeros(province_count + 1, dtype=np.int32)
    cursor = 0
    province_id = 1
    for component_id in range(1, len(allocation)):
        end = int(boundaries[component_id])
        pixels = grouped_indices[cursor:end]
        cursor = end
        amount = int(allocation[component_id])
        if amount <= 0 or len(pixels) < amount:
            raise AssertionError(f"Invalid allocation for component {component_id}")
        ys = pixels // width
        xs = pixels - ys * width
        spatial_order = np.argsort(morton_codes(xs, ys), kind="stable")
        ordered_pixels = pixels[spatial_order]
        positions = ((np.arange(amount) + 0.5) * len(ordered_pixels) / amount).astype(np.int64)
        chosen = ordered_pixels[positions]
        ids = np.arange(province_id, province_id + amount, dtype=np.int32)
        seeds[province_id - 1 : province_id + amount - 1] = chosen
        province_country[ids] = component_country[component_id]
        province_component[ids] = component_id
        province_id += amount
    if province_id != province_count + 1:
        raise AssertionError("Seed count does not match requested province count")
    return seeds, province_country, province_component


def flood_provinces(country_grid: np.ndarray, seeds: np.ndarray) -> np.ndarray:
    """Multi-source four-neighbor flood constrained by national borders."""
    height, width = country_grid.shape
    flat_country = country_grid.ravel()
    flat_province = np.zeros(height * width, dtype=np.int32)
    queue = np.empty(int(np.count_nonzero(flat_country)), dtype=np.int64)
    province_ids = np.arange(1, len(seeds) + 1, dtype=np.int32)
    flat_province[seeds] = province_ids
    queue[: len(seeds)] = seeds
    head = 0
    tail = len(seeds)
    while head < tail:
        pixel = int(queue[head])
        head += 1
        country = flat_country[pixel]
        province = flat_province[pixel]
        x = pixel % width
        if x and flat_country[pixel - 1] == country and flat_province[pixel - 1] == 0:
            flat_province[pixel - 1] = province
            queue[tail] = pixel - 1
            tail += 1
        if x + 1 < width and flat_country[pixel + 1] == country and flat_province[pixel + 1] == 0:
            flat_province[pixel + 1] = province
            queue[tail] = pixel + 1
            tail += 1
        if pixel >= width and flat_country[pixel - width] == country and flat_province[pixel - width] == 0:
            flat_province[pixel - width] = province
            queue[tail] = pixel - width
            tail += 1
        if pixel + width < len(flat_country) and flat_country[pixel + width] == country and flat_province[pixel + width] == 0:
            flat_province[pixel + width] = province
            queue[tail] = pixel + width
            tail += 1
    if tail != len(queue) or np.any((flat_country > 0) & (flat_province == 0)):
        raise AssertionError("Province flood did not cover every land pixel")
    return flat_province.reshape((height, width))


def province_colors(province_count: int) -> np.ndarray:
    ids = np.arange(province_count + 1, dtype=np.uint64)
    packed = (ids * np.uint64(COLOR_MULTIPLIER)) & np.uint64(0xFFFFFF)
    colors = np.empty((province_count + 1, 3), dtype=np.uint8)
    colors[:, 0] = (packed >> np.uint64(16)).astype(np.uint8)
    colors[:, 1] = (packed >> np.uint64(8)).astype(np.uint8)
    colors[:, 2] = packed.astype(np.uint8)
    colors[0] = 0
    return colors


def add_border_data(
    first: np.ndarray,
    second: np.ndarray,
    province_count: int,
    neighbor_keys: set[int],
    water_border: np.ndarray,
) -> None:
    different = first != second
    land_pair = different & (first > 0) & (second > 0)
    if np.any(land_pair):
        a = np.minimum(first[land_pair], second[land_pair]).astype(np.int64)
        b = np.maximum(first[land_pair], second[land_pair]).astype(np.int64)
        keys = np.unique(a * (province_count + 1) + b)
        neighbor_keys.update(int(key) for key in keys)
    first_water = different & (first > 0) & (second == 0)
    second_water = different & (second > 0) & (first == 0)
    water_border[np.unique(first[first_water])] = True
    water_border[np.unique(second[second_water])] = True


def clean_country_code(record: dict[str, object], country_id: int) -> str:
    for field in ("ADM0_A3", "ISO_A3_EH", "SOV_A3"):
        value = str(record.get(field) or "").strip()
        if value and value != "-99":
            return value
    return f"NE{country_id:03d}"


def generate(width: int, height: int, province_count: int, output_dir: Path) -> None:
    if width < 512 or height < 256:
        raise ValueError("Map resolution is too small for meaningful provinces")
    if width != height * 2:
        raise ValueError("Equirectangular output must use a 2:1 aspect ratio")
    output_dir.mkdir(parents=True, exist_ok=True)
    transform = from_bounds(-180.0, -90.0, 180.0, 90.0, width, height)

    print("Loading Natural Earth country geometry...")
    country_records = read_dbf(COUNTRIES_DBF)
    country_geometries = load_geometries(COUNTRIES_SHP)
    if len(country_records) != len(country_geometries):
        raise ValueError("Country SHP and DBF record counts differ")
    country_items = [
        (geometry, index + 1)
        for index, geometry in enumerate(country_geometries)
        if geometry is not None and country_records[index]
    ]
    country_grid = rasterize(
        country_items,
        out_shape=(height, width),
        transform=transform,
        fill=0,
        all_touched=False,
        dtype=np.uint16,
    )

    print("Cutting Natural Earth lakes from the land mask...")
    lake_geometries = [geometry for geometry in load_geometries(LAKES_SHP) if geometry]
    lake_mask = rasterize(
        ((geometry, 1) for geometry in lake_geometries),
        out_shape=(height, width),
        transform=transform,
        fill=0,
        all_touched=False,
        dtype=np.uint8,
    )
    country_grid[lake_mask > 0] = 0
    if np.count_nonzero(country_grid) < province_count:
        raise ValueError("Output resolution has fewer land pixels than provinces")

    print("Loading climate and glacier data...")
    climate_grid = np.zeros((height, width), dtype=np.uint8)
    with rasterio.open(CLIMATE_TIF) as climate_source:
        reproject(
            source=rasterio.band(climate_source, 1),
            destination=climate_grid,
            src_transform=climate_source.transform,
            src_crs=climate_source.crs,
            dst_transform=transform,
            dst_crs="EPSG:4326",
            resampling=Resampling.nearest,
        )
    glacier_geometries = [geometry for geometry in load_geometries(GLACIERS_SHP) if geometry]
    glacier_grid = rasterize(
        ((geometry, 1) for geometry in glacier_geometries),
        out_shape=(height, width),
        transform=transform,
        fill=0,
        all_touched=False,
        dtype=np.uint8,
    )

    print("Finding country-constrained land components...")
    component_features = list(
        connected_shapes(
            country_grid,
            mask=country_grid > 0,
            connectivity=4,
            transform=transform,
        )
    )
    component_items = [
        (geometry, component_id)
        for component_id, (geometry, _country) in enumerate(component_features, start=1)
    ]
    component_country = np.zeros(len(component_features) + 1, dtype=np.int32)
    for component_id, (_geometry, country) in enumerate(component_features, start=1):
        component_country[component_id] = int(country)
    component_grid = rasterize(
        component_items,
        out_shape=(height, width),
        transform=transform,
        fill=0,
        all_touched=False,
        dtype=np.int32,
    )
    if np.any((country_grid > 0) & (component_grid == 0)):
        raise AssertionError("Component reconstruction lost land pixels")

    lat_edges = np.linspace(90.0, -90.0, height + 1)
    delta_lon = math.radians(360.0 / width)
    row_pixel_area = (
        EARTH_RADIUS_KM**2
        * delta_lon
        * (np.sin(np.radians(lat_edges[:-1])) - np.sin(np.radians(lat_edges[1:])))
    )
    flat_components = component_grid.ravel()
    land_indices = np.flatnonzero(flat_components)
    land_rows = land_indices // width
    component_pixels = np.bincount(
        flat_components[land_indices], minlength=len(component_features) + 1
    ).astype(np.int64)
    component_area = np.bincount(
        flat_components[land_indices],
        weights=row_pixel_area[land_rows],
        minlength=len(component_features) + 1,
    )
    allocation = allocate_with_caps(component_area, province_count, component_pixels)
    print(
        f"Allocating {province_count:,} provinces across "
        f"{len(component_features):,} land components..."
    )
    seeds, province_country, province_component = pick_seeds(
        component_grid, component_country, allocation, province_count
    )
    province_grid = flood_provinces(country_grid, seeds)

    print("Calculating province statistics and adjacency...")
    flat_province = province_grid.ravel()
    land_indices = np.flatnonzero(flat_province)
    land_provinces = flat_province[land_indices]
    ys = land_indices // width
    xs = land_indices - ys * width
    pixel_counts = np.bincount(land_provinces, minlength=province_count + 1)
    if len(np.flatnonzero(pixel_counts)) != province_count:
        raise AssertionError("Not every requested province appears in the bitmap")
    pixel_area = row_pixel_area[ys]
    areas = np.bincount(
        land_provinces, weights=pixel_area, minlength=province_count + 1
    )
    center_lon = (xs + 0.5) * 360.0 / width - 180.0
    center_lat = 90.0 - (ys + 0.5) * 180.0 / height
    centroid_lon = np.bincount(
        land_provinces, weights=pixel_area * center_lon, minlength=province_count + 1
    ) / np.maximum(areas, 1e-12)
    centroid_lat = np.bincount(
        land_provinces, weights=pixel_area * center_lat, minlength=province_count + 1
    ) / np.maximum(areas, 1e-12)

    min_x = np.full(province_count + 1, width, dtype=np.int32)
    min_y = np.full(province_count + 1, height, dtype=np.int32)
    max_x = np.full(province_count + 1, -1, dtype=np.int32)
    max_y = np.full(province_count + 1, -1, dtype=np.int32)
    np.minimum.at(min_x, land_provinces, xs)
    np.minimum.at(min_y, land_provinces, ys)
    np.maximum.at(max_x, land_provinces, xs)
    np.maximum.at(max_y, land_provinces, ys)

    climate_values = np.clip(climate_grid.ravel()[land_indices], 0, 30).astype(np.int64)
    climate_pairs = land_provinces.astype(np.int64) * 31 + climate_values
    climate_histogram = np.bincount(
        climate_pairs,
        weights=pixel_area,
        minlength=(province_count + 1) * 31,
    ).reshape((province_count + 1, 31))
    dominant_climate = np.argmax(climate_histogram, axis=1)
    glacier_area = np.bincount(
        land_provinces[glacier_grid.ravel()[land_indices] > 0],
        weights=pixel_area[glacier_grid.ravel()[land_indices] > 0],
        minlength=province_count + 1,
    )

    neighbors: list[list[int]] = [[] for _ in range(province_count + 1)]
    neighbor_keys: set[int] = set()
    water_border = np.zeros(province_count + 1, dtype=np.bool_)
    add_border_data(
        province_grid[:, :-1], province_grid[:, 1:], province_count, neighbor_keys, water_border
    )
    add_border_data(
        province_grid[:-1, :], province_grid[1:, :], province_count, neighbor_keys, water_border
    )
    # The equirectangular map wraps horizontally at the international date line.
    add_border_data(
        province_grid[:, -1], province_grid[:, 0], province_count, neighbor_keys, water_border
    )
    for key in sorted(neighbor_keys):
        first = key // (province_count + 1)
        second = key % (province_count + 1)
        neighbors[first].append(second)
        neighbors[second].append(first)

    colors = province_colors(province_count)
    rgb = colors[province_grid]
    bitmap_path = output_dir / "province_map.png"
    Image.fromarray(rgb).save(bitmap_path, optimize=True, compress_level=9)

    seed_y = seeds // width
    seed_x = seeds - seed_y * width
    countries: list[dict[str, object]] = []
    for country_id, record in enumerate(country_records, start=1):
        country_provinces = np.flatnonzero(province_country == country_id)
        countries.append(
            {
                "id": country_id,
                "code": clean_country_code(record, country_id),
                "name": str(record.get("ADMIN") or record.get("NAME_EN") or "Unknown"),
                "name_ko": str(record.get("NAME_KO") or ""),
                "continent": str(record.get("CONTINENT") or ""),
                "subregion": str(record.get("SUBREGION") or ""),
                "sovereign": str(record.get("SOVEREIGNT") or ""),
                "population_estimate": record.get("POP_EST"),
                "gdp_million_usd": record.get("GDP_MD"),
                "province_ids": [int(value) for value in country_provinces],
            }
        )

    provinces: list[dict[str, object]] = []
    for province_id in range(1, province_count + 1):
        country_id = int(province_country[province_id])
        country = countries[country_id - 1]
        climate_id = int(dominant_climate[province_id])
        climate_code, climate_name = CLIMATES[climate_id]
        color = [int(value) for value in colors[province_id]]
        provinces.append(
            {
                "id": province_id,
                "color": color,
                "color_hex": "#" + "".join(f"{value:02X}" for value in color),
                "country_id": country_id,
                "country_code": country["code"],
                "country_name": country["name"],
                "country_name_ko": country["name_ko"],
                "component_id": int(province_component[province_id]),
                "climate_id": climate_id,
                "climate_code": climate_code,
                "climate_name": climate_name,
                "pixel_count": int(pixel_counts[province_id]),
                "area_km2": round(float(areas[province_id]), 3),
                "glaciated_fraction": round(
                    float(glacier_area[province_id] / max(areas[province_id], 1e-12)), 6
                ),
                "centroid_lon_lat": [
                    round(float(centroid_lon[province_id]), 6),
                    round(float(centroid_lat[province_id]), 6),
                ],
                "label_pixel": [int(seed_x[province_id - 1]), int(seed_y[province_id - 1])],
                "bbox_pixel": [
                    int(min_x[province_id]),
                    int(min_y[province_id]),
                    int(max_x[province_id]),
                    int(max_y[province_id]),
                ],
                "water_border": bool(water_border[province_id]),
                "neighbors": neighbors[province_id],
            }
        )

    database = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "map": {
            "image": "res://data/province_map.png",
            "width": width,
            "height": height,
            "projection": "equirectangular",
            "bounds_lon_lat": [-180.0, -90.0, 180.0, 90.0],
            "wrap_x": True,
            "province_count": province_count,
            "water_rgb": [0, 0, 0],
            "color_rule": (
                "RGB is the low 24 bits of province_id * 0x9E3779B1; "
                "the explicit color field is authoritative"
            ),
            "connectivity": 4,
        },
        "generation": {
            "allocation": "one per land component, then proportional spherical area",
            "seed_order": "Morton (Z-order) spatial stratification",
            "growth": "multi-source Manhattan flood constrained by country and water",
            "lake_pixels_are_water": True,
        },
        "sources": {
            "countries": "res://ne_10m_admin_0_countries/ne_10m_admin_0_countries.shp",
            "lakes": "res://ne_10m_lakes/ne_10m_lakes.shp",
            "glaciated_areas": "res://ne_10m_glaciated_areas/ne_10m_glaciated_areas.shp",
            "climate": "res://Beck_KG_V1/Beck_KG_V1_present_0p083.tif",
            "climate_citation": (
                "Beck et al. (2018), Present and future Koppen-Geiger climate "
                "classification maps at 1-km resolution, Scientific Data."
            ),
        },
        "climates": [
            {"id": climate_id, "code": values[0], "name": values[1]}
            for climate_id, values in CLIMATES.items()
        ],
        "countries": countries,
        "provinces": provinces,
    }
    json_path = output_dir / "province_map.json"
    json_path.write_text(
        json.dumps(database, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    print(f"Wrote {bitmap_path.relative_to(ROOT)} ({bitmap_path.stat().st_size:,} bytes)")
    print(f"Wrote {json_path.relative_to(ROOT)} ({json_path.stat().st_size:,} bytes)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT)
    parser.add_argument("--count", type=int, default=DEFAULT_PROVINCES)
    parser.add_argument("--output", type=Path, default=ROOT / "data")
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    generate(arguments.width, arguments.height, arguments.count, arguments.output.resolve())
