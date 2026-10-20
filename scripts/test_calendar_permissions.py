#!/usr/bin/env python3
"""Guard the permission contract before packaging hardened calendar builds."""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEY = "com.apple.security.personal-information.calendars"


class CalendarPermissionPackagingTests(unittest.TestCase):
    def test_signed_entitlements_allow_calendar_requests(self):
        with (ROOT / "Diduny/Resources/Diduny.entitlements").open("rb") as source:
            self.assertIs(plistlib.load(source).get(KEY), True)

    def test_project_generation_preserves_calendar_entitlement(self):
        project = (ROOT / "project.yml").read_text()
        entitlement_block = project.split("    entitlements:\n", 1)[1].split("    postBuildScripts:", 1)[0]
        self.assertRegex(entitlement_block, rf"(?m)^        {re.escape(KEY)}: true$")

    def test_calendar_read_usage_description_is_present(self):
        with (ROOT / "Diduny/Resources/Info.plist").open("rb") as source:
            self.assertTrue(plistlib.load(source).get("NSCalendarsFullAccessUsageDescription", "").strip())


if __name__ == "__main__":
    unittest.main()
