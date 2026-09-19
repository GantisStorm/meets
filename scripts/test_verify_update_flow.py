#!/usr/bin/env python3
"""Check the source-only fork's empty feed without weakening release gates."""

from pathlib import Path
import base64
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
EMPTY_FEED = """<rss version="2.0"><channel>
<title>Meets</title><link>https://github.com/GantisStorm/meets</link>
</channel></rss>"""


class UpdateFeedTests(unittest.TestCase):
    def verify(self, feed, *args):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(feed)
            return subprocess.run(
                ["bash", str(ROOT / "scripts/verify_update_flow.sh"),
                 "--appcast", str(path), *args],
                capture_output=True, text=True,
            )

    def test_empty_feed_metadata(self):
        result = self.verify(EMPTY_FEED, "--skip-dmg")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no releases published", result.stdout)

    def test_published_feed_metadata(self):
        signature = base64.b64encode(bytes(64)).decode()
        feed = EMPTY_FEED.replace(
            '<rss version="2.0">',
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
        ).replace("</channel>", f"""<item>
<sparkle:version>1.0</sparkle:version>
<sparkle:shortVersionString>1.0</sparkle:shortVersionString>
<description>Release notes for a test fixture.</description>
<enclosure url="https://github.com/GantisStorm/meets/releases/download/v1.0/Meets-1.0.dmg"
 length="42" sparkle:edSignature="{signature}"/>
</item></channel>""")
        result = self.verify(feed, "--skip-dmg", "--version", "1.0", "--require-release-notes")
        self.assertEqual(result.returncode, 0, result.stderr)
        for invalid in [
            feed.replace("GantisStorm/meets", "someone-else/meets"),
            feed.replace(signature, "invalid-signature"),
            feed.replace('length="42"', 'length="0"'),
        ]:
            self.assertNotEqual(self.verify(invalid, "--skip-dmg").returncode, 0)

    def test_empty_feed_cannot_verify_a_release(self):
        for args in [
            [],
            ["--skip-dmg", "--version", "1.0"],
            ["--skip-dmg", "--short-version", "1.0"],
            ["--skip-dmg", "--artifact-version", "1.0"],
            ["--skip-dmg", "--dmg", "missing.dmg"],
            ["--skip-dmg", "--require-notarized"],
            ["--skip-dmg", "--require-release-notes"],
        ]:
            with self.subTest(args=args):
                result = self.verify(EMPTY_FEED, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no update items", result.stderr)

    def test_invalid_feeds_still_fail(self):
        for feed in [
            "<rss",
            '<rss version="2.0"/>',
            '<rss version="2.0"><channel/></rss>',
            EMPTY_FEED.replace("rss", "html"),
            EMPTY_FEED.replace("</channel>", "<item/></channel>"),
        ]:
            with self.subTest(feed=feed):
                self.assertNotEqual(self.verify(feed, "--skip-dmg").returncode, 0)


if __name__ == "__main__":
    unittest.main()
