#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "release_highlights.py"
PAYLOAD = ROOT / "Diduny" / "Resources" / "ReleaseHighlights.json"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class ReleaseHighlightsPipelineTests(unittest.TestCase):
    def test_render_and_appcast_upsert_share_curated_release(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            markdown = output / "2.2.0.md"
            appcast = output / "appcast.xml"
            appcast.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                f'<rss version="2.0" xmlns:sparkle="{SPARKLE}"><channel>'
                "<title>Diduny Updates</title>"
                "<item><title>Version 2.1.0</title>"
                f"<sparkle:shortVersionString>2.1.0</sparkle:shortVersionString>"
                "<sparkle:releaseNotesLink> </sparkle:releaseNotesLink>"
                '<enclosure url="https://github.com/example/Diduny/releases/download/v2.1.0/Diduny-2.1.0.dmg" />'
                "</item></channel></rss>\n",
                encoding="utf-8",
            )

            self.run_script("render", str(PAYLOAD), str(markdown))
            expected = (
                "# Flexible live meeting transcripts\n\n"
                "- Minimize a live transcript to a red-dot edge tab and restore it with one click.\n"
                "- Choose whether the floating transcript opens when recording starts.\n"
                "- Meeting translations now show advancing speaker timestamps.\n"
            )
            self.assertEqual(markdown.read_text(encoding="utf-8"), expected)

            arguments = (
                "upsert-appcast",
                str(appcast),
                "--version", "2.2.0",
                "--build-number", "102",
                "--download-url", "https://example.com/Diduny-2.2.0.dmg",
                "--signature", "signature",
                "--length", "123",
                "--release-notes-url", "https://example.com/release-notes/2.2.0.md",
                "--pub-date", "Mon, 03 Aug 2026 12:00:00 +0000",
            )
            self.run_script(*arguments)
            first_upsert = appcast.read_bytes()
            self.run_script(*arguments)
            self.assertEqual(appcast.read_bytes(), first_upsert)

            items = ET.parse(appcast).getroot().findall("channel/item")
            self.assertEqual(len(items), 2)
            item = next(
                item for item in items
                if item.findtext(f"{{{SPARKLE}}}shortVersionString") == "2.2.0"
            )
            self.assertIsNotNone(item)
            self.assertEqual(item.findtext(f"{{{SPARKLE}}}shortVersionString"), "2.2.0")
            self.assertEqual(
                item.findtext(f"{{{SPARKLE}}}releaseNotesLink"),
                "https://example.com/release-notes/2.2.0.md",
            )
            previous_item = next(
                item for item in items
                if item.findtext(f"{{{SPARKLE}}}shortVersionString") == "2.1.0"
            )
            self.assertEqual(
                previous_item.findtext(f"{{{SPARKLE}}}releaseNotesLink"),
                "https://github.com/example/Diduny/releases/tag/v2.1.0",
            )

    def test_validate_rejects_malformed_curated_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory) / "ReleaseHighlights.json"
            payload.write_text(
                '{"schemaVersion":2,"headline":" ","highlights":[]}',
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "validate", str(payload)],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("schemaVersion must be 1", result.stderr)

    def test_release_workflow_serializes_gh_pages_writers(self):
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("  group: release\n", workflow)
        self.assertNotIn("group: release-${{ github.ref }}", workflow)

    def run_script(self, *arguments):
        subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        )


if __name__ == "__main__":
    unittest.main()
