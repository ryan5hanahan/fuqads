#!/usr/bin/env python3
"""Generate spike data files (run from spikes/SpikeApp/).

- Spike/spike-data/s3-150k.json   150k distinct block rules (S3 worst case)
- Spike/spike-data/s3-trivial.json 3 rules (fast baseline)
- Spike/spike-data/s4-block.json   S4: block + cosmetic, no allowlist
- Spike/spike-data/s4-allow.json   S4: + ignore-previous-rules allowlist
- ContentBlocker/blockerList.json  appex default (s4-block)
- pages/ad.png                    1x1 red pixel (S4 ad)
"""
import json
import os
import struct
import zlib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def write_json(path, obj):
    full = os.path.join(HERE, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        json.dump(obj, f, separators=(",", ":"))
    print(f"wrote {os.path.relpath(full, HERE)} ({os.path.getsize(full) // 1024}KB)")


def block_rule(host_pattern):
    return {
        "trigger": {"url-filter": host_pattern},
        "action": {"type": "block"},
    }


def png_1x1_red():
    # minimal valid PNG: 1x1, RGB, red
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    raw = b"\x00\xff\x00\x00"  # filter byte + RGB
    idat = zlib.compress(raw)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def main():
    n = 150_000
    rules = [
        block_rule(f"spikeblock{i:06d}\\.example\\.com") for i in range(1, n + 1)
    ]
    write_json("Spike/spike-data/s3-150k.json", rules)
    write_json(
        "Spike/spike-data/s3-trivial.json",
        [block_rule("spiketrivial\\.example\\.com")],
    )

    s4_common = [
        {
            "trigger": {
                "url-filter": r"127\.0\.0\.1:8642/ad\.png",
                "load-type": ["image"],
            },
            "action": {"type": "block"},
        },
        {
            "trigger": {
                "if-domain": ["127.0.0.1"],
                "css-selector": "#cosmetic-test",
            },
            "action": {"type": "css-display-none"},
        },
    ]
    allow = [
        {
            "trigger": {"if-top-url": r"127\.0\.0\.1:8642"},
            "action": {"type": "ignore-previous-rules"},
        }
    ]
    write_json("Spike/spike-data/s4-block.json", s4_common)
    write_json("Spike/spike-data/s4-allow.json", s4_common + allow)
    write_json("ContentBlocker/blockerList.json", s4_common)

    ad_path = os.path.join(HERE, "pages", "ad.png")
    os.makedirs(os.path.dirname(ad_path), exist_ok=True)
    with open(ad_path, "wb") as f:
        f.write(png_1x1_red())
    print(f"wrote pages/ad.png")


if __name__ == "__main__":
    main()
