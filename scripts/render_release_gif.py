#!/usr/bin/env python3
"""Render the release "What's new" montage (release-demo/player.html + scenario.js) to a GIF.

Frames are captured deterministically through one headless Chrome (render_release_frames.mjs seeks
every Web Animation), then ffmpeg builds a palette-optimised looping GIF:
Diduny/Resources/ReleaseDemo.gif — shown in the app's What's New card, attached to the GitHub
Release as whats-new.gif, and embedded at the top of the release PR.

  python3 scripts/render_release_gif.py [--out path.gif] [--fps 15]
Needs node, ffmpeg and Google Chrome (override with CHROME=/path/to/chrome).
"""

import argparse
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=ROOT / "Diduny/Resources/ReleaseDemo.gif")
    parser.add_argument("--fps", type=int, default=12)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["node", str(ROOT / "scripts/render_release_frames.mjs"),
             f"file://{ROOT / 'release-demo/player.html'}", tmp, str(args.fps), CHROME],
            check=True,
        )
        frames = f"{tmp}/f%05d.png"
        palette = f"{tmp}/palette.png"
        ff = ["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(args.fps), "-i", frames]
        subprocess.run([*ff, "-vf", "palettegen=stats_mode=diff:max_colors=192", palette], check=True)
        subprocess.run(
            [*ff, "-i", palette, "-lavfi", "paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
             "-loop", "0", str(args.out)],
            check=True,
        )

    size = args.out.stat().st_size
    print(f"{args.out} {size // 1024} KB")
    if size > 6_000_000:
        print("warning: over 6 MB — shorten scenes or lower --fps")


if __name__ == "__main__":
    main()
