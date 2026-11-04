#!/usr/bin/env python3
import json
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
            payload = json.loads(PAYLOAD.read_text(encoding="utf-8"))
            rendered = markdown.read_text(encoding="utf-8")
            self.assertLess(rendered.index("## English"), rendered.index("## Українською"))
            for language in ("en", "uk"):
                self.assertIn(f"### {payload[language]['headline']}\n", rendered)
                for item in payload[language]["highlights"]:
                    self.assertIn(f"- {item}\n", rendered)

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
                '{"schemaVersion":1,"headline":" ","highlights":[]}',
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "validate", str(payload)],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("schemaVersion must be 2", result.stderr)

    def test_validate_requires_both_languages(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory) / "ReleaseHighlights.json"
            payload.write_text(
                '{"schemaVersion":2,"en":{"headline":"New","highlights":["One"]}}',
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "validate", str(payload)],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("uk must be an object", result.stderr)

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
