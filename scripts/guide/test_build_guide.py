#!/usr/bin/env python3
"""Tests for build_guide.py:  /usr/bin/python3 scripts/guide/test_build_guide.py  (stdlib unittest, no dependencies)."""
import contextlib, io, os, re, struct, sys, tempfile, unittest, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_guide as bg


def png(path, w, h):
    """A w×h grey PNG."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + b"\x80" * w for _ in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Guide(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        os.makedirs(os.path.join(self.dir, "images"))
        self.src = os.path.join(self.dir, "guide.md")

    def tearDown(self):
        self.tmp.cleanup()

    def page(self, md):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            page, images, shots = bg.build(self.src, md)
        body = re.search(r"<main class=\"guide\">\n(.*)\n</main>", page, re.S).group(1)
        return body, err.getvalue(), images, shots

    # Blocks

    def test_ordered_list_keeps_its_first_number(self):
        body, *_ = self.page("**On the sender:**\n\n4. Play the clip.\n\n**Then:**\n\n5. Wait.\n6. Read it.\n")
        self.assertIn('<ol start="4"><li>Play the clip.</li></ol>', body)
        self.assertIn('<ol start="5"><li>Wait.</li><li>Read it.</li></ol>', body)

    def test_list_from_one_has_no_start(self):
        body, *_ = self.page("1. a\n2. b\n")
        self.assertIn("<ol><li>a</li><li>b</li></ol>", body)

    def test_nested_and_loose_lists(self):
        body, *_ = self.page("- a\n  - a1\n  - a2\n- b\n")
        self.assertEqual(body, "<ul><li>a\n<ul><li>a1</li><li>a2</li></ul></li><li>b</li></ul>")
        body, *_ = self.page("- a\n\n- b\n")
        self.assertEqual(body, "<ul><li><p>a</p></li><li><p>b</p></li></ul>")

    def test_callout_holds_blocks(self):
        body, *_ = self.page("> **Only tick it** if it is.\n> Manifold trusts it.\n>\n> - one\n")
        self.assertEqual(body, '<blockquote class="callout"><p><strong>Only tick it</strong> if it is.\nManifold trusts it.'
                               '</p>\n<ul><li>one</li></ul></blockquote>')

    def test_headings_get_unique_ids(self):
        body, *_ = self.page("## Part 1 · Live stream sync\n\n### Notes\n\n### Notes\n")
        self.assertIn('<h2 id="part-1-live-stream-sync">', body)
        self.assertIn('<h3 id="notes">', body)
        self.assertIn('<h3 id="notes-1">', body)

    def test_table(self):
        body, *_ = self.page("| Key | Does |\n|:--|--:|\n| **⌥]** | later |\n| `x` | y |\n")
        self.assertIn('<th style="text-align:left">Key</th><th style="text-align:right">Does</th>', body)
        self.assertIn("<td style=\"text-align:left\"><strong>⌥]</strong></td>", body)
        self.assertIn("<code>x</code>", body)

    # Inline

    def test_inline(self):
        body, *_ = self.page('Use **Reference**, *not* `a <b>` and [docs](https://x.y/a?b=1&c=2) & 3 < 4.\n')
        self.assertEqual(body, '<p>Use <strong>Reference</strong>, <em>not</em> <code>a &lt;b&gt;</code> and '
                               '<a href="https://x.y/a?b=1&amp;c=2">docs</a> &amp; 3 &lt; 4.</p>')

    def test_raw_html_is_text(self):
        body, *_ = self.page("<script>alert(1)</script>\n")
        self.assertEqual(body, "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")

    def test_version_token(self):
        body, *_ = self.page("**Manifold {{VERSION}} · October 2026**\n")
        self.assertIn('Manifold <span class="guide-version">{{VERSION}}</span>', body)

    # Comments and shots

    def test_comments_never_reach_the_page_and_shots_are_listed(self):
        md = ("Para.\n<!-- IMAGE: the A/V menu, control bar ▸ A/V, av-menu.png -->\n\n1. one\n"
              "<!-- IMAGE: the sheet,\n  A/V ▸ Calibrate…, calibration-result.png -->\n2. two\n<!-- a note -->\n")
        body, err, images, shots = self.page(md)
        self.assertNotIn("IMAGE", body)
        self.assertNotIn("<!--", body)
        self.assertEqual(body, "<p>Para.</p>\n<ol><li>one</li><li>two</li></ol>")
        self.assertEqual(shots, [(2, "the A/V menu, control bar ▸ A/V, av-menu.png"),
                                 (5, "the sheet, A/V ▸ Calibrate…, calibration-result.png")])
        png(os.path.join(self.dir, "images", "av-menu@2x.png"), 4, 4)
        listing = bg.shot_list(shots, self.src, images.dir)
        self.assertIn("1. line 2: the A/V menu, control bar ▸ A/V, av-menu.png [taken]", listing)
        self.assertIn("2. line 5: the sheet, A/V ▸ Calibrate…, calibration-result.png\n", listing + "\n")

    # Images

    def test_placeholder_image_1x_2x_dark(self):
        d = os.path.join(self.dir, "images")
        png(os.path.join(d, "placeholder.png"), 320, 180)
        png(os.path.join(d, "placeholder@2x.png"), 640, 360)
        png(os.path.join(d, "placeholder-dark.png"), 320, 180)
        body, err, images, _ = self.page('![The A/V menu](images/placeholder.png "Caption")\n')
        self.assertEqual(err, "")
        self.assertEqual(body, '<figure><picture><source media="(prefers-color-scheme: dark)" '
                               'srcset="images/placeholder-dark.png 1x"><img src="images/placeholder.png" '
                               'srcset="images/placeholder.png 1x, images/placeholder@2x.png 2x" alt="The A/V menu" '
                               'width="320" height="180" title="Caption"></picture><figcaption>Caption</figcaption></figure>')
        self.assertEqual(images.copies, {"placeholder.png", "placeholder@2x.png", "placeholder-dark.png"})

    def test_2x_only_is_drawn_at_half_size(self):
        png(os.path.join(self.dir, "images", "shot@2x.png"), 1000, 600)
        body, err, *_ = self.page("![x](images/shot.png)\n")
        self.assertIn('src="images/shot@2x.png" srcset="images/shot@2x.png 2x" alt="x" width="500" height="300"', body)

    def test_mismatched_2x_warns(self):
        png(os.path.join(self.dir, "images", "s.png"), 100, 100)
        png(os.path.join(self.dir, "images", "s@2x.png"), 150, 150)
        _, err, *_ = self.page("![x](images/s.png)\n")
        self.assertIn("warning: image s@2x.png is 150×150, not twice s.png (100×100)", err)

    def test_missing_image_shows_alt_and_warns_with_line(self):
        body, err, images, _ = self.page("Intro.\n\nSee ![The calibration sheet](images/nope.png) here.\n")
        self.assertIn('<span class="image-missing" role="img" aria-label="The calibration sheet">The calibration sheet</span>',
                      body)
        self.assertRegex(err, r"guide\.md:3: warning: image images/nope\.png: missing .* shown as its alt text")
        self.assertEqual(images.copies, set())

    def test_image_outside_images_is_refused(self):
        body, err, *_ = self.page("![x](../secret.png)\n")
        self.assertIn('class="image-missing"', body)
        self.assertIn("must be images/<name>", err)

    # The real guide

    def test_the_bundled_guide_builds_cleanly(self):
        src = os.path.join(os.path.dirname(bg.HERE), "..", "docs", "guides", "manifold-0.9-sync-and-color-guide.md")
        with open(src, encoding="utf-8") as f:
            md = f.read()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            page, images, shots = bg.build(src, md)
        self.assertEqual(err.getvalue(), "")
        self.assertNotIn("<!--", page)
        self.assertNotRegex(page, r"\*\*|(?<!<code>)`")
        self.assertEqual(page.count("{{VERSION}}"), 1)
        self.assertEqual(page.count("<li>"), len(re.findall(r"^\s*(?:-|\d+\.) ", re.sub(r"<!--.*?-->", "", md, flags=re.S),
                                                         re.M)))


if __name__ == "__main__":
    unittest.main(verbosity=1)
