#!/usr/bin/env python3
"""Render the release "What's new" GIF from release-demo/scenario.json.

Each scene is a slice of a real screen recording of the app (start/end seconds, optional speed-up)
with a big two-line subtitle (Ukrainian on top, English below) in a bar under the frame.
Output: Diduny/Resources/ReleaseDemo.gif — shown in the app's What's New card, attached to the
GitHub Release as whats-new.gif, and embedded at the top of the release PR.

  python3 scripts/render_release_gif.py [--out path.gif]
Needs ffmpeg and Pillow.
"""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
DEMO = ROOT / "release-demo"
FONT = "/System/Library/Fonts/SFNS.ttf"
BG, FG, FG2, ACCENT = (24, 24, 24), (245, 245, 245), (170, 170, 175), (214, 80, 108)


def subtitle_bar(width: int, uk: str, en: str, path: Path) -> int:
    big = ImageFont.truetype(FONT, round(width * 0.033))
    small = ImageFont.truetype(FONT, round(width * 0.024))
    pad = round(width * 0.022)
    height = (pad * 2 + big.size + small.size + 10 + 1) // 2 * 2  # even, for yuv420p
    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, 6, height], fill=ACCENT)
    draw.text((pad + 8, pad), uk, font=big, fill=FG)
    draw.text((pad + 8, pad + big.size + 10), en, font=small, fill=FG2)
    img.save(path)
    return height


def run(*cmd: str) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=ROOT / "Diduny/Resources/ReleaseDemo.gif")
    args = parser.parse_args()
    scenario = json.loads((DEMO / "scenario.json").read_text())
    width, fps = scenario["width"], scenario["fps"]

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        segments = []
        for i, scene in enumerate(scenario["scenes"]):
            bar = tmp / f"bar{i}.png"
            bar_h = subtitle_bar(width, scene["uk"], scene["en"], bar)
            speed = scene.get("speed", 1.0)
            seg = tmp / f"seg{i}.mp4"
            run(
                "ffmpeg", "-loglevel", "error", "-y",
                "-ss", str(scene["start"]), "-to", str(scene["end"]), "-i", str(DEMO / scene["clip"]),
                "-loop", "1", "-i", str(bar),
                "-filter_complex",
                f"[0:v]setpts=PTS/{speed},fps={fps},scale={width}:-2:flags=lanczos[v];"
                f"[v][1:v]vstack=inputs=2:shortest=1",
                "-an", "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", str(seg),
            )
            segments.append(seg)

        listing = tmp / "list.txt"
        listing.write_text("".join(f"file '{s}'\n" for s in segments))
        joined = tmp / "joined.mp4"
        run("ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy", str(joined))
        palette = tmp / "palette.png"
        run("ffmpeg", "-loglevel", "error", "-y", "-i", str(joined), "-vf", "palettegen=stats_mode=diff:max_colors=160", str(palette))
        run(
            "ffmpeg", "-loglevel", "error", "-y", "-i", str(joined), "-i", str(palette),
            "-lavfi", f"fps={fps}[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
            "-loop", "0", str(args.out),
        )

    size = args.out.stat().st_size
    print(f"{args.out} {size // 1024} KB")
    if size > 6_000_000:
        print("warning: over 6 MB — shorten scenes, lower fps or width")


if __name__ == "__main__":
    main()
