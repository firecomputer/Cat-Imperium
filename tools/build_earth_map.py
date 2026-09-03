#!/usr/bin/env python3
"""Bake Natural Earth + ETOPO into Cat Empire's fixed 440x200 earth map.

Runtime code reads only data/world/earth_map.bin. Raw source datasets stay out
of the repository; their download locations and exact local-file checksums are
kept here so the asset can be reproduced.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

import numpy as np
import rasterio
import shapefile
from PIL import Image, ImageDraw
from pyproj import CRS, Transformer
from shapely.geometry import Polygon, box, shape
from shapely.ops import transform
from shapely.strtree import STRtree


ROOT = Path(__file__).resolve().parents[1]
W = 440
H = 200
TOTAL = W * H
LAND_TARGET = 25000
LAT_MIN = -60.0
LAT_MAX = 90.0
SQRT3_2 = math.sqrt(3.0) / 2.0
HEX_RADIUS = 1.0 / math.sqrt(3.0)
MAGIC = b"CEMAP13\0"
VERSION = 2

SOURCES = {
    "land": {
        "path": ROOT / "ne_10m_land/ne_10m_land.shp",
        "url": "https://naturalearth.s3.amazonaws.com/10m_physical/ne_10m_land.zip",
        "sha256": "4cad3a49bc75c1a4c2f3d7efae04f2f8e63151c96764b2658effabf524331fa6",
    },
    "lakes": {
        "path": ROOT / "ne_10m_lakes/ne_10m_lakes.shp",
        "url": "https://naturalearth.s3.amazonaws.com/10m_physical/ne_10m_lakes.zip",
        "sha256": "11064fa55ed91b56a0d86733643c1a5bfcc137fdf044e83f471978a5b86617e1",
    },
    "admin_0": {
        "path": ROOT / "ne_10m_admin_0_countries/ne_10m_admin_0_countries.shp",
        "url": "https://naturalearth.s3.amazonaws.com/10m_cultural/ne_10m_admin_0_countries.zip",
        "sha256": "7ce119ef6342e43cff7c0c3004e0911ab7ec1988a14734372031d2012180e7bc",
    },
    "etopo": {
        "path": ROOT / "ETOPO_2022_v1_60s_N90W180_bed.tif",
        "url": (
            "https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO2022/data/60s/"
            "60s_bed_elev_gtif/ETOPO_2022_v1_60s_N90W180_bed.tif"
        ),
        "sha256": "a2cc72f8a4292dee928f439069457cdefc1fba319876807c626edce40258ba7a",
    },
}

# At this resolution an island can intersect a cell yet lose rank selection.
# One representative cell per named group is retained, then the lowest-ranked
# unforced land cell is removed so LAND_TARGET remains invariant.
ISLAND_ANCHORS = {
    "Hawaii": (-157.9, 20.8),
    "Iceland": (-18.8, 65.0),
    "Sri Lanka": (80.7, 7.6),
    "Taiwan": (121.0, 23.7),
    "Cuba": (-79.5, 21.8),
    "Hispaniola": (-71.0, 19.0),
    "Puerto Rico": (-66.4, 18.2),
    "Jamaica": (-77.3, 18.1),
    "Bahamas": (-76.0, 24.4),
    "Azores": (-27.9, 38.6),
    "Canary Islands": (-15.6, 28.3),
    "Cape Verde": (-23.7, 15.1),
    "Falkland Islands": (-59.0, -51.7),
    "Madagascar": (46.7, -19.0),
    "Mauritius": (57.6, -20.2),
    "Reunion": (55.5, -21.1),
    "Tasmania": (146.7, -42.0),
    "New Zealand North": (175.5, -38.8),
    "New Zealand South": (170.3, -44.0),
    "New Caledonia": (165.6, -21.3),
    "Fiji": (178.1, -17.8),
    "Samoa": (-172.1, -13.8),
    "Tahiti": (-149.4, -17.7),
    "Vanuatu": (167.7, -16.2),
    "Java": (110.0, -7.4),
    "Sumatra": (101.0, -0.5),
    "Borneo": (114.0, 0.8),
    "Sulawesi": (121.0, -2.0),
    "Philippines": (122.5, 12.2),
    "Hokkaido": (142.8, 43.4),
    "Papua New Guinea": (145.5, -6.5),
}

# FeatureTagger's generic topology rules cannot recognize Gibraltar or the
# Bosporus because both shores belong to the same Afro-Eurasian component.
# The earth asset therefore carries authoritative tags for six known places.
FEATURE_INLAND = 0
FEATURE_ISTHMUS = 2
FEATURE_STRAIT = 3
NO_FORCED_FEATURE = 255
CHOKEPOINTS = {
    "Suez": (32.55, 30.6, FEATURE_ISTHMUS),
    "Panama": (-79.7, 9.0, FEATURE_ISTHMUS),
    "Gibraltar": (-5.6, 35.95, FEATURE_STRAIT),
    "Bosporus": (29.05, 41.1, FEATURE_STRAIT),
    "Malacca": (100.5, 2.8, FEATURE_STRAIT),
    "Bering": (-169.0, 65.8, FEATURE_STRAIT),
}

REGION_NAMES = [
    "North America",
    "South America",
    "Europe",
    "North Africa & West Asia",
    "Sub-Saharan Africa",
    "South Asia",
    "East Asia",
    "Southeast Asia & Oceania",
    "North Eurasia",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_sources(skip_checksums: bool) -> None:
    for name, source in SOURCES.items():
        path = source["path"]
        if not path.is_file():
            raise FileNotFoundError(f"missing {name}: {path}\ndownload: {source['url']}")
        if not skip_checksums:
            actual = sha256(path)
            if actual != source["sha256"]:
                raise ValueError(f"checksum mismatch for {path}: {actual}")


def flatten_polygons(geometry):
    if geometry.is_empty:
        return []
    if geometry.geom_type == "Polygon":
        return [geometry]
    if geometry.geom_type in ("MultiPolygon", "GeometryCollection"):
        out = []
        for part in geometry.geoms:
            out.extend(flatten_polygons(part))
        return out
    return []


def load_projected_country_polygons(path: Path, project: Transformer):
    """Country polygons plus the ADMIN name each part belongs to.

    Real borders are used for province *shape* only. Which nation owns which
    province is still drawn from the world seed (see M13.5).
    """
    crop = box(-180.0, LAT_MIN, 180.0, LAT_MAX)
    polygons: list[Polygon] = []
    owners: list[str] = []
    for item in shapefile.Reader(str(path)).iterShapeRecords():
        geometry = shape(item.shape.__geo_interface__).intersection(crop)
        if geometry.is_empty:
            continue
        projected = transform(project.transform, geometry)
        for part in flatten_polygons(projected):
            if part.area > 0.0:
                polygons.append(part)
                owners.append(str(item.record["ADMIN"]))
    return polygons, owners


def load_projected_polygons(path: Path, project: Transformer) -> list[Polygon]:
    crop = box(-180.0, LAT_MIN, 180.0, LAT_MAX)
    polygons = []
    for item in shapefile.Reader(str(path)).iterShapes():
        geometry = shape(item.__geo_interface__).intersection(crop)
        if geometry.is_empty:
            continue
        projected = transform(project.transform, geometry)
        polygons.extend(part for part in flatten_polygons(projected) if part.area > 0.0)
    return polygons


def projected_grid():
    crs = CRS.from_proj4("+proj=cea +lat_ts=30 +lon_0=0 +datum=WGS84 +units=m +no_defs")
    project = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    unproject = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)
    x0, south = project.transform(-180.0, LAT_MIN)
    x1, north = project.transform(180.0, LAT_MAX)
    gx0, gx1 = -0.5, W
    gy0, gy1 = -HEX_RADIUS, (H - 1) * SQRT3_2 + HEX_RADIUS

    def to_projected(gx: float, gy: float):
        x = x0 + (gx - gx0) / (gx1 - gx0) * (x1 - x0)
        y = north - (gy - gy0) / (gy1 - gy0) * (north - south)
        return x, y

    cells = []
    centers = []
    lonlat = []
    for row in range(H):
        for col in range(W):
            cx = col + (0.5 if row & 1 else 0.0)
            cy = row * SQRT3_2
            center = to_projected(cx, cy)
            points = []
            for vertex in range(6):
                angle = math.radians(30.0 + vertex * 60.0)
                points.append(to_projected(
                    cx + math.cos(angle) * HEX_RADIUS,
                    cy + math.sin(angle) * HEX_RADIUS,
                ))
            cells.append(Polygon(points))
            centers.append(center)
            lon, lat = unproject.transform(*center)
            lonlat.append((max(-180.0, min(180.0, lon)), max(LAT_MIN, min(LAT_MAX, lat))))
    return project, cells, centers, lonlat


def coverage(cells: list[Polygon], polygons: list[Polygon]) -> np.ndarray:
    tree = STRtree(polygons)
    out = np.zeros(TOTAL, dtype=np.float64)
    for index, cell in enumerate(cells):
        area = 0.0
        for candidate in tree.query(cell):
            area += cell.intersection(polygons[int(candidate)]).area
        out[index] = min(area / cell.area, 1.0)
    return out


def sample_elevation(etopo_path: Path, cells: list[Polygon], centers, unproject) -> np.ndarray:
    points = []
    for cell, center in zip(cells, centers):
        sample_points = [center] + list(cell.exterior.coords)[:6]
        for point in sample_points:
            lon, lat = unproject.transform(*point)
            points.append((max(-179.9999, min(179.9999, lon)), max(-89.9999, min(89.9999, lat))))
    with rasterio.open(etopo_path) as dataset:
        values = np.fromiter((float(value[0]) for value in dataset.sample(points)), dtype=np.float64)
    values = values.reshape((TOTAL, 7))
    values[values < -1000.0] = 0.0
    return np.maximum(values, 0.0).mean(axis=1)


def assign_countries(cells, land, polygons, owners) -> tuple[np.ndarray, list[str]]:
    """Dominant ADMIN per land tile. 0 means "no country polygon reached this tile"."""
    names = sorted(set(owners))
    index = {name: i + 1 for i, name in enumerate(names)}
    tree = STRtree(polygons)
    out = np.zeros(TOTAL, dtype=np.uint16)
    for i in range(TOTAL):
        if not land[i]:
            continue
        cell = cells[i]
        areas: dict[str, float] = {}
        for candidate in tree.query(cell):
            c = int(candidate)
            area = cell.intersection(polygons[c]).area
            if area > 0.0:
                areas[owners[c]] = areas.get(owners[c], 0.0) + area
        if areas:
            # sorted() first so an exact area tie resolves by name, not by hash order.
            out[i] = index[max(sorted(areas), key=lambda name: areas[name])]

    # A selected land tile can sit entirely offshore of every country polygon.
    # Grow the nearest neighbour's country into it so no tile stays ownerless.
    while True:
        pending = [i for i in range(TOTAL) if land[i] and out[i] == 0]
        if not pending:
            break
        changed = False
        for i in pending:
            votes: dict[int, int] = {}
            for other in neighbors(i):
                if land[other] and out[other] != 0:
                    votes[int(out[other])] = votes.get(int(out[other]), 0) + 1
            if votes:
                out[i] = max(sorted(votes), key=lambda k: votes[k])
                changed = True
        if not changed:
            break
    return out, names


def geo_distance(a, b) -> float:
    lon_delta = abs(a[0] - b[0])
    lon_delta = min(lon_delta, 360.0 - lon_delta)
    return (lon_delta * math.cos(math.radians(b[1]))) ** 2 + (a[1] - b[1]) ** 2


def closest_tile(target, lonlat, allowed) -> int:
    candidates = [index for index in range(TOTAL) if allowed(index)]
    if not candidates:
        raise ValueError(f"no tile matches target {target}")
    return min(candidates, key=lambda index: (geo_distance(lonlat[index], target), index))


def select_land(land_coverage, lake_coverage, elevation, lonlat):
    normalized_elevation = np.log1p(np.minimum(elevation, 6000.0)) / math.log1p(6000.0)
    score = land_coverage - lake_coverage + normalized_elevation * 0.015
    forced_water = set(np.flatnonzero(lake_coverage >= 0.45).tolist())
    forced_islands = {}
    forced_land = set()
    for name, target in ISLAND_ANCHORS.items():
        tile = closest_tile(target, lonlat, lambda i: land_coverage[i] > 0.000001)
        forced_islands[name] = tile
        forced_land.add(tile)

    order = sorted(range(TOTAL), key=lambda i: (-score[i], i))
    # Keep the ranked order. Converting to a set before slicing silently turns
    # this into tile-index order and fills the northern rows first.
    selected = set([i for i in order if i not in forced_water][:LAND_TARGET])
    selected.update(forced_land)
    selected.difference_update(forced_water)
    if len(selected) > LAND_TARGET:
        removable = sorted(
            (i for i in selected if i not in forced_land),
            key=lambda i: (score[i], -i),
        )
        for tile in removable[: len(selected) - LAND_TARGET]:
            selected.remove(tile)
    elif len(selected) < LAND_TARGET:
        for tile in order:
            if tile not in selected and tile not in forced_water:
                selected.add(tile)
                if len(selected) == LAND_TARGET:
                    break

    land = np.zeros(TOTAL, dtype=np.uint8)
    land[list(selected)] = 1
    return land, forced_islands, score


def tag_chokepoints(land, lonlat):
    forced = np.full(TOTAL, NO_FORCED_FEATURE, dtype=np.uint8)
    tagged = {}
    for name, (lon, lat, feature) in CHOKEPOINTS.items():
        want_land = feature == FEATURE_ISTHMUS
        tile = closest_tile((lon, lat), lonlat, lambda i: bool(land[i]) == want_land)
        forced[tile] = feature
        tagged[name] = tile
    return forced, tagged


def region_id(lon: float, lat: float) -> int:
    if lon < -30.0:
        return 0 if lat >= 15.0 else 1
    if -25.0 <= lon <= 45.0 and lat >= 35.0:
        return 2
    if lon >= 45.0 and lat >= 50.0:
        return 8
    if -25.0 <= lon <= 55.0 and lat < 15.0:
        return 4
    if lon < 75.0 and lat >= 15.0:
        return 3
    if 55.0 <= lon < 92.0 and lat < 35.0:
        return 5
    if 92.0 <= lon < 150.0 and lat >= 20.0:
        return 6
    return 7


def neighbors(index: int):
    row, col = divmod(index, W)
    deltas = (
        ((1, 0), (0, -1), (-1, -1), (-1, 0), (-1, 1), (0, 1)),
        ((1, 0), (1, -1), (0, -1), (-1, 0), (0, 1), (1, 1)),
    )[row & 1]
    for dc, dr in deltas:
        nc, nr = col + dc, row + dr
        if 0 <= nc < W and 0 <= nr < H:
            yield nr * W + nc


def component_sizes(land) -> list[int]:
    seen = np.zeros(TOTAL, dtype=np.uint8)
    sizes = []
    for start in range(TOTAL):
        if not land[start] or seen[start]:
            continue
        seen[start] = 1
        stack = [start]
        size = 0
        while stack:
            current = stack.pop()
            size += 1
            for other in neighbors(current):
                if land[other] and not seen[other]:
                    seen[other] = 1
                    stack.append(other)
        sizes.append(size)
    return sorted(sizes, reverse=True)


## Provinces never cross a national border, so the splitter works on land runs that
## share both a landmass and a country. Counting them here catches a bake whose
## borders would shatter the map into far more provinces than the target.
def province_group_sizes(land, country) -> list[int]:
    seen = np.zeros(TOTAL, dtype=np.uint8)
    sizes = []
    for start in range(TOTAL):
        if not land[start] or seen[start]:
            continue
        seen[start] = 1
        stack = [start]
        size = 0
        while stack:
            current = stack.pop()
            size += 1
            for other in neighbors(current):
                if land[other] and not seen[other] and country[other] == country[current]:
                    seen[other] = 1
                    stack.append(other)
        sizes.append(size)
    return sorted(sizes, reverse=True)


def write_asset(path: Path, land, elevation, land_coverage, lonlat, regions, forced_features,
        country):
    path.parent.mkdir(parents=True, exist_ok=True)
    elevation_u16 = np.clip(np.rint(elevation), 0, 65535).astype("<u2")
    coverage_u8 = np.clip(np.rint(land_coverage * 255.0), 0, 255).astype(np.uint8)
    longitude_u16 = np.clip(np.rint((np.array([p[0] for p in lonlat]) + 180.0) * 100.0), 0, 36000).astype("<u2")
    latitude_u16 = np.clip(np.rint((np.array([p[1] for p in lonlat]) - LAT_MIN) * 100.0), 0, 15000).astype("<u2")
    with path.open("wb") as stream:
        stream.write(MAGIC)
        stream.write(struct.pack("<HHHH", VERSION, W, H, LAND_TARGET))
        stream.write(land.tobytes())
        stream.write(elevation_u16.tobytes())
        stream.write(coverage_u8.tobytes())
        stream.write(longitude_u16.tobytes())
        stream.write(latitude_u16.tobytes())
        stream.write(regions.tobytes())
        stream.write(forced_features.tobytes())
        stream.write(country.astype("<u2").tobytes())


def write_preview(path: Path, land, elevation, forced_features):
    scale = 7
    radius = scale / math.sqrt(3.0)
    width = int((W + 0.5) * scale) + 2
    height = int(((H - 1) * SQRT3_2 + 2.0 * HEX_RADIUS) * scale) + 2
    image = Image.new("RGB", (width, height), (5, 17, 38))
    draw = ImageDraw.Draw(image)
    high = max(float(elevation[land == 1].max()), 1.0)
    for index in range(TOTAL):
        row, col = divmod(index, W)
        cx = (col + (0.5 if row & 1 else 0.0) + 0.5) * scale
        cy = (row * SQRT3_2 + HEX_RADIUS) * scale
        points = []
        for vertex in range(6):
            angle = math.radians(30.0 + vertex * 60.0)
            points.append((cx + math.cos(angle) * radius, cy + math.sin(angle) * radius))
        if land[index]:
            value = math.log1p(float(elevation[index])) / math.log1p(high)
            color = (int(47 + value * 145), int(108 + value * 95), int(55 + value * 105))
        else:
            color = (9, 35, 73)
        if forced_features[index] == FEATURE_ISTHMUS:
            color = (235, 64, 52)
        elif forced_features[index] == FEATURE_STRAIT:
            color = (250, 205, 52)
        draw.polygon(points, fill=color)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=ROOT / "data/world/earth_map.bin")
    parser.add_argument("--manifest", type=Path, default=ROOT / "data/world/earth_map.json")
    parser.add_argument("--preview", type=Path, default=ROOT / "out/earth_map_preview.png")
    parser.add_argument("--skip-checksums", action="store_true")
    args = parser.parse_args()

    verify_sources(args.skip_checksums)
    project, cells, centers, lonlat = projected_grid()
    unproject = Transformer.from_crs(project.target_crs, "EPSG:4326", always_xy=True)
    land_polygons = load_projected_polygons(SOURCES["land"]["path"], project)
    lake_polygons = load_projected_polygons(SOURCES["lakes"]["path"], project)
    land_coverage = coverage(cells, land_polygons)
    lake_coverage = coverage(cells, lake_polygons)
    elevation = sample_elevation(SOURCES["etopo"]["path"], cells, centers, unproject)
    land, islands, score = select_land(land_coverage, lake_coverage, elevation, lonlat)
    forced_features, chokepoints = tag_chokepoints(land, lonlat)
    regions = np.array([region_id(lon, lat) for lon, lat in lonlat], dtype=np.uint8)
    admin_polygons, admin_owners = load_projected_country_polygons(
        SOURCES["admin_0"]["path"], project)
    country, country_names = assign_countries(cells, land, admin_polygons, admin_owners)
    sizes = component_sizes(land)
    groups = province_group_sizes(land, country)

    if int(land.sum()) != LAND_TARGET:
        raise AssertionError(f"land count {int(land.sum())} != {LAND_TARGET}")
    if not sizes or sizes[0] / LAND_TARGET > 0.70:
        raise AssertionError(f"largest component is too large: {sizes[:3]}")
    if int(np.count_nonzero(country[land == 1])) != LAND_TARGET:
        raise AssertionError("some land tile has no country")
    write_asset(args.out, land, elevation, land_coverage, lonlat, regions, forced_features,
        country)
    write_preview(args.preview, land, elevation, forced_features)
    manifest = {
        "format_version": VERSION,
        "projection": "Behrmann / World Cylindrical Equal Area, standard parallel 30 degrees",
        "width": W,
        "height": H,
        "land_target": LAND_TARGET,
        "lat_min": LAT_MIN,
        "lat_max": LAT_MAX,
        "sources": {
            name: {"url": item["url"], "sha256": item["sha256"], "file": item["path"].name}
            for name, item in SOURCES.items()
        },
        "stats": {
            "positive_land_coverage_tiles": int(np.count_nonzero(land_coverage > 0.0)),
            "component_count": len(sizes),
            "component_sizes": sizes,
            "largest_fraction": sizes[0] / LAND_TARGET,
            "lowest_selected_score": float(score[land == 1].min()),
            "country_count": len(country_names),
            "country_group_count": len(groups),
            "country_group_sizes": groups[:20],
        },
        "named_islands": {
            name: {"tile": tile, "longitude": lonlat[tile][0], "latitude": lonlat[tile][1]}
            for name, tile in islands.items()
        },
        "named_island_preservation": 1.0,
        "chokepoints": {
            name: {"tile": tile, "feature": int(forced_features[tile])}
            for name, tile in chokepoints.items()
        },
        "regions": REGION_NAMES,
        "countries": country_names,
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out} ({args.out.stat().st_size:,} bytes)")
    print(f"land={int(land.sum())} components={len(sizes)} largest={sizes[0]} ({sizes[0] / LAND_TARGET:.1%})")
    print(f"named islands={len(islands)} chokepoints={len(chokepoints)}")
    print(f"countries={len(country_names)} border-bounded groups={len(groups)}")
    print(f"preview={args.preview}")


if __name__ == "__main__":
    main()
