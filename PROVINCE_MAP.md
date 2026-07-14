# Province map

`data/province_map.png` is the authoritative RGB province bitmap. Black pixels
are water; every other color maps to exactly one of the 9,900 records in
`data/province_map.json`.

The Godot autoload `ProvinceMapDB` loads both files, verifies their dimensions,
and exposes `province_id_at_pixel()`, `province_id_at_uv()`, `get_province()`,
and `get_country()`. The main scene renders the bitmap as a gray political map
with bounded WASD movement, cursor-centered wheel zoom, and province selection.

Regenerate the two data files from the Natural Earth and Köppen–Geiger sources:

```bash
python3 tools/generate_province_map.py
python3 tools/validate_province_map.py
godot4 --headless --path . --script res://tools/verify_godot_map.gd
```

Generation is deterministic apart from the informational timestamp in JSON.
Provinces cannot cross water or country borders. Each disconnected national
land component receives at least one province; remaining provinces are assigned
by spherical land area. JSON also stores dominant climate, glaciated fraction,
area, neighbors, bounding box, and a safe label pixel.
