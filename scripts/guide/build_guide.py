#!/usr/bin/env python3
"""A guide's Markdown to the page Help ▸ <guide> shows: one index.html per guide, one shared guide.css. Stdlib only.

    build_guide.py --src docs/guides/manifold-0.9-sync-and-color-guide.md --slug sync-and-color --out <Resources>/Guides
    build_guide.py --src … --shots            # the shot list only, nothing written

Run by the "Bundle the guides" build phase (project.yml) on every build, so the bundle always matches the doc.

Writes <out>/guide.css (from scripts/guide/guide.css) and <out>/<slug>/index.html, plus <out>/<slug>/images/ for the
images the guide uses. <out>/<slug> is rebuilt every time, so a removed image never lingers in a build.

THE MARKDOWN IT READS is the guides' own subset: ATX headings, paragraphs, - and 1. lists (an ordered list keeps its first
number: a "4." after a paragraph renders as 4), nesting by indent, > callouts (any blocks inside), ``` code, pipe
tables, **bold**, *italic*, `code`, [links](url) and ![images](images/name.png "optional caption"). Raw HTML is shown as
text, not passed through.

{{VERSION}} is left for the app to fill (CFBundleShortVersionString), wrapped in <span class="guide-version">.

IMAGES come from images/ beside the Markdown (docs/guides/images/):
  * name.png, and name@2x.png for Retina: either alone, or both (the @2x then twice the 1x's size, or a warning);
  * name-dark.png (and name-dark@2x.png), optional, shown while the window is in dark appearance;
  * shown at the 1x size and scaled down to the window's width, never above it;
  * a missing image shows its alt text, and the build warns with the guide's file and line.

SHOTS: <!-- IMAGE: what the shot should show, which window/menu, suggested filename --> marks a place for a screenshot.
Every build prints them as a shot list; a shot whose file is already in images/ is marked taken. Comments never reach
the page.
"""
import argparse, html, os, re, shutil, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE_RE = re.compile(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)')
LINK_RE = re.compile(r'\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)')
LIST_RE = re.compile(r'^( *)([-*+]|\d{1,9}[.)])(?: +(.*)|$)')
HEADING_RE = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
TABLE_RULE_RE = re.compile(r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$')
FENCE_RE = re.compile(r'^\s*```')
SHOT_FILE_RE = re.compile(r'([\w./@-]+\.(?:png|jpe?g))\s*$', re.I)


def warn(path, line, msg):
    # file:line: warning: — Xcode lists it as a build warning, clickable.
    print(f"{path}:{line}: warning: {msg}", file=sys.stderr)


# MARK: comments and the shot list

def strip_comments(text, src):
    """The text without its HTML comments, and the IMAGE shots as (line, text). A comment alone on its lines goes with
    them, so it leaves no stray blank line inside a list or a paragraph."""
    shots = []
    for m in re.finditer(r'<!--(.*?)-->', text, re.S):
        body = " ".join(m.group(1).split())
        if body.upper().startswith("IMAGE:"):
            shots.append((text.count("\n", 0, m.start()) + 1, body[6:].strip()))
    text = re.sub(r'^[ \t]*<!--.*?-->[ \t]*(?:\n|$)', '', text, flags=re.S | re.M)
    text = re.sub(r'<!--.*?-->', '', text, flags=re.S)
    if '<!--' in text:
        warn(src, text.count("\n", 0, text.index('<!--')) + 1, "unclosed <!-- comment: shown as text")
    return text, shots


def shot_list(shots, src, images_dir):
    out = [f"Guide shot list for {os.path.basename(src)}: {len(shots)} shot(s)"]
    for n, (line, body) in enumerate(shots, 1):
        m = SHOT_FILE_RE.search(body)
        taken = ""
        if m:
            base, ext = os.path.splitext(os.path.basename(m.group(1)))
            if any(os.path.exists(os.path.join(images_dir, base + s + ext)) for s in ("", "@2x")):
                taken = " [taken]"
        out.append(f"  {n:2}. line {line}: {body}{taken}")
    return "\n".join(out)


# MARK: images

def image_size(path):
    """(width, height) in pixels of a PNG or JPEG, or None."""
    with open(path, "rb") as f:
        head = f.read(26)
        if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
            return struct.unpack(">II", head[16:24])
        if head[:2] != b"\xff\xd8":
            return None
        f.seek(2)
        while True:
            b = f.read(1)
            while b and b != b"\xff":
                b = f.read(1)
            while b == b"\xff":
                b = f.read(1)
            if not b:
                return None
            marker = b[0]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                continue
            seg = f.read(2)
            if len(seg) < 2:
                return None
            length = struct.unpack(">H", seg)[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">xHH", f.read(5))
                return w, h
            f.seek(length - 2, 1)


class Images:
    """Every image the guide references, resolved once (with the line of its first use, for warnings)."""

    def __init__(self, src, text):
        self.src = src
        self.dir = os.path.join(os.path.dirname(os.path.abspath(src)), "images")
        self.resolved = {}      # src → dict, or None when missing
        self.copies = set()     # file names to copy into <slug>/images
        for i, line in enumerate(text.split("\n"), 1):
            for m in IMAGE_RE.finditer(line):
                if m.group(2) not in self.resolved:
                    self.resolved[m.group(2)] = self.resolve(m.group(2), i)

    def resolve(self, ref, line):
        if not ref.startswith("images/") or ".." in ref or "/" in ref[len("images/"):]:
            warn(self.src, line, f"image {ref}: must be images/<name>, beside the guide — shown as its alt text")
            return None
        base, ext = os.path.splitext(ref[len("images/"):])
        found = {}
        for key, suffix in (("1x", ""), ("2x", "@2x"), ("dark1x", "-dark"), ("dark2x", "-dark@2x")):
            name = base + suffix + ext
            path = os.path.join(self.dir, name)
            if os.path.isfile(path):
                size = image_size(path)
                if size is None:
                    warn(self.src, line, f"image images/{name}: not a PNG or JPEG — ignored")
                    continue
                found[key] = (name, size)
        if "1x" not in found and "2x" not in found:
            warn(self.src, line, f"image {ref}: missing (looked for {base}{ext} and {base}@2x{ext} in "
                                 f"{os.path.relpath(self.dir)}) — shown as its alt text")
            return None
        for one, two in (("1x", "2x"), ("dark1x", "dark2x")):
            if one in found and two in found:
                (w1, h1), (w2, h2) = found[one][1], found[two][1]
                if (w2, h2) != (2 * w1, 2 * h1):
                    warn(self.src, line, f"image {found[two][0]} is {w2}×{h2}, not twice {found[one][0]} ({w1}×{h1})")
        if ("dark1x" in found or "dark2x" in found) and ("dark1x" in found) != ("1x" in found):
            warn(self.src, line, f"image {ref}: the light and dark versions have different @2x/1x files")
        if "1x" in found:
            w, h = found["1x"][1]
        else:
            w, h = (v // 2 for v in found["2x"][1])
        self.copies.update(name for name, _ in found.values())
        return {"found": found, "width": w, "height": h}

    def html(self, ref, alt, title):
        r = self.resolved.get(ref)
        a = html.escape(alt, quote=True)
        if r is None:
            return f'<span class="image-missing" role="img" aria-label="{a}">{html.escape(alt) or html.escape(ref)}</span>'
        f = r["found"]

        def srcset(one, two):
            parts = []
            if one in f: parts.append(f'images/{f[one][0]} 1x')
            if two in f: parts.append(f'images/{f[two][0]} 2x')
            return html.escape(", ".join(parts), quote=True)

        dark = ""
        if "dark1x" in f or "dark2x" in f:
            dark = f'<source media="(prefers-color-scheme: dark)" srcset="{srcset("dark1x", "dark2x")}">'
        src = f["1x"][0] if "1x" in f else f["2x"][0]
        t = f' title="{html.escape(title, quote=True)}"' if title else ""
        return (f'<picture>{dark}<img src="images/{html.escape(src, quote=True)}" srcset="{srcset("1x", "2x")}" '
                f'alt="{a}" width="{r["width"]}" height="{r["height"]}"{t}></picture>')


# MARK: inline

def inline(text, images):
    """One paragraph's text, as HTML."""
    held = []

    def hold(s):
        held.append(s)
        return f"\x00{len(held) - 1}\x00"

    text = re.sub(r'\\([\\`*_{}\[\]()#+\-.!|>~])', lambda m: hold(html.escape(m.group(1))), text)
    text = re.sub(r'(`+)(.+?)\1', lambda m: hold(f"<code>{html.escape(m.group(2).strip())}</code>"), text)
    text = IMAGE_RE.sub(lambda m: hold(images.html(m.group(2), m.group(1), m.group(3))), text)

    def link(m):
        url = m.group(2)
        t = f' title="{html.escape(m.group(3), quote=True)}"' if m.group(3) else ""
        return hold(f'<a href="{html.escape(url, quote=True)}"{t}>') + m.group(1) + hold("</a>")

    text = LINK_RE.sub(link, text)
    text = html.escape(text, quote=False)
    text = re.sub(r'\*\*(?=\S)(.+?)(?<=\S)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'(?<![\w])__(?=\S)(.+?)(?<=\S)__(?![\w])', r'<strong>\1</strong>', text)
    text = re.sub(r'(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])', r'<em>\1</em>', text)
    text = re.sub(r'(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])', r'<em>\1</em>', text)
    text = text.replace("{{VERSION}}", '<span class="guide-version">{{VERSION}}</span>')
    text = re.sub(r' {2,}\n', '<br>\n', text)
    while "\x00" in text:
        text = re.sub(r'\x00(\d+)\x00', lambda m: held[int(m.group(1))], text)
    return text


def plain(html_text):
    return html.unescape(re.sub(r'<[^>]+>', '', html_text))


# MARK: blocks

class Blocks:
    def __init__(self, images):
        self.images = images
        self.slugs = {}

    def slug(self, text):
        s = re.sub(r'[^\w\s-]', '', plain(text).lower())
        s = re.sub(r'[\s_]+', '-', s).strip('-') or "section"
        n = self.slugs.get(s, 0)
        self.slugs[s] = n + 1
        return s if n == 0 else f"{s}-{n}"

    @staticmethod
    def starts_block(line):
        return bool(HEADING_RE.match(line) or line.lstrip().startswith(">") or LIST_RE.match(line)
                    or FENCE_RE.match(line))

    def render(self, lines):
        out, i = [], 0
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            m = HEADING_RE.match(line)
            if m:
                n, body = len(m.group(1)), inline(m.group(2), self.images)
                out.append(f'<h{n} id="{self.slug(body)}">{body}</h{n}>')
                i += 1
                continue
            if re.match(r'^ {0,3}([-*_])( *\1){2,} *$', line):
                out.append("<hr>")
                i += 1
                continue
            if FENCE_RE.match(line):
                j = i + 1
                while j < len(lines) and not FENCE_RE.match(lines[j]):
                    j += 1
                out.append("<pre><code>" + html.escape("\n".join(lines[i + 1:j])) + "</code></pre>")
                i = j + 1
                continue
            if line.lstrip().startswith(">"):
                quoted = []
                while i < len(lines) and lines[i].strip():
                    s = lines[i].lstrip()
                    quoted.append(re.sub(r'^> ?', '', s) if s.startswith(">") else s)
                    i += 1
                out.append('<blockquote class="callout">' + self.render(quoted) + "</blockquote>")
                continue
            if "|" in line and i + 1 < len(lines) and TABLE_RULE_RE.match(lines[i + 1]) and "-" in lines[i + 1]:
                i = self.table(lines, i, out)
                continue
            if LIST_RE.match(line):
                i = self.list(lines, i, out)
                continue
            para = []
            while i < len(lines) and lines[i].strip() and (not para or not self.starts_block(lines[i])):
                para.append(lines[i])
                i += 1
            body = inline("\n".join(para), self.images)
            if IMAGE_RE.fullmatch("\n".join(para).strip()):
                m = IMAGE_RE.fullmatch("\n".join(para).strip())
                cap = f"<figcaption>{inline(m.group(3), self.images)}</figcaption>" if m.group(3) else ""
                out.append(f"<figure>{body}{cap}</figure>")
            else:
                out.append(f"<p>{body}</p>")
        return "\n".join(out)

    def list(self, lines, i, out):
        first = LIST_RE.match(lines[i])
        indent, marker = len(first.group(1)), first.group(2)
        ordered = marker[0].isdigit()
        items, loose = [], False
        while i < len(lines):
            m = LIST_RE.match(lines[i])
            if not m or len(m.group(1)) != indent or m.group(2)[0].isdigit() != ordered:
                break
            content_indent = indent + len(m.group(2)) + 1
            item = [m.group(3) or ""]
            i += 1
            while i < len(lines):
                line = lines[i]
                if not line.strip():
                    # A blank line continues the item only when an indented line follows.
                    j = i
                    while j < len(lines) and not lines[j].strip():
                        j += 1
                    if j < len(lines) and len(lines[j]) - len(lines[j].lstrip()) >= content_indent:
                        item.extend([""] * (j - i))
                        i = j
                        loose = True
                        continue
                    break
                lead = len(line) - len(line.lstrip())
                lm = LIST_RE.match(line)
                if lm and lead <= indent:
                    break
                if lead < content_indent and (HEADING_RE.match(line) or line.lstrip().startswith(">")):
                    break
                item.append(line[min(lead, content_indent):])
                i += 1
            items.append(item)
            # A blank line between two items of the same list makes it loose.
            j = i
            while j < len(lines) and not lines[j].strip():
                j += 1
            nxt = LIST_RE.match(lines[j]) if j < len(lines) else None
            if j > i and nxt and len(nxt.group(1)) == indent and nxt.group(2)[0].isdigit() == ordered:
                loose = True
                i = j
            elif j > i:
                break
        tag = "ol" if ordered else "ul"
        start = int(re.match(r'\d+', marker).group()) if ordered else 1
        attr = f' start="{start}"' if ordered and start != 1 else ""
        parts = []
        for item in items:
            body = self.render(item)
            if not loose:
                body = re.sub(r'^<p>(.*?)</p>', r'\1', body, count=1, flags=re.S)
            parts.append(f"<li>{body}</li>")
        out.append(f"<{tag}{attr}>" + "".join(parts) + f"</{tag}>")
        return i

    def table(self, lines, i, out):
        def cells(line):
            s = line.strip()
            if s.startswith("|"): s = s[1:]
            if s.endswith("|") and not s.endswith("\\|"): s = s[:-1]
            return [c.strip() for c in re.split(r'(?<!\\)\|', s)]

        head = cells(lines[i])
        aligns = []
        for c in cells(lines[i + 1]):
            aligns.append("center" if c.startswith(":") and c.endswith(":") else
                          "right" if c.endswith(":") else "left" if c.startswith(":") else "")
        i += 2

        def row(tag, cs):
            tds = []
            for k, c in enumerate(cs[:len(head)] + [""] * (len(head) - len(cs))):
                a = f' style="text-align:{aligns[k]}"' if k < len(aligns) and aligns[k] else ""
                tds.append(f"<{tag}{a}>{inline(c, self.images)}</{tag}>")
            return "<tr>" + "".join(tds) + "</tr>"

        body = []
        while i < len(lines) and lines[i].strip() and "|" in lines[i]:
            body.append(row("td", cells(lines[i])))
            i += 1
        out.append('<div class="table"><table><thead>' + row("th", head) + "</thead><tbody>" + "".join(body)
                   + "</tbody></table></div>")
        return i


# MARK: the page

def build(src, text):
    """(page HTML, Images, shots) for one guide's Markdown."""
    text = text.replace("\r\n", "\n").replace("\t", "    ")
    text, shots = strip_comments(text, src)
    images = Images(src, text)
    body = Blocks(images).render(text.split("\n"))
    m = re.search(r'<h1[^>]*>(.*?)</h1>', body, re.S)
    title = html.escape(plain(m.group(1))) if m else "Manifold"
    page = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<meta name="color-scheme" content="light dark">\n'
            f'<title>{title}</title>\n<link rel="stylesheet" href="../guide.css">\n</head>\n'
            f'<body>\n<main class="guide">\n{body}\n</main>\n</body>\n</html>\n')
    return page, images, shots


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", required=True, help="the guide's Markdown")
    ap.add_argument("--slug", help="the guide's folder under --out, e.g. sync-and-color")
    ap.add_argument("--out", help="the bundle's Guides folder")
    ap.add_argument("--shots", action="store_true", help="print the shot list only; write nothing")
    a = ap.parse_args()
    with open(a.src, encoding="utf-8") as f:
        text = f.read()
    page, images, shots = build(a.src, text)
    print(shot_list(shots, a.src, images.dir))
    if a.shots:
        return 0
    if not (a.slug and a.out):
        ap.error("--slug and --out are required unless --shots")
    dest = os.path.join(a.out, a.slug)
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    shutil.copyfile(os.path.join(HERE, "guide.css"), os.path.join(a.out, "guide.css"))
    with open(os.path.join(dest, "index.html"), "w", encoding="utf-8") as f:
        f.write(page)
    if images.copies:
        os.makedirs(os.path.join(dest, "images"))
        for name in sorted(images.copies):
            shutil.copyfile(os.path.join(images.dir, name), os.path.join(dest, "images", name))
    missing = sum(1 for r in images.resolved.values() if r is None)
    print(f"Guide {a.slug}: index.html, {len(images.copies)} image file(s), {missing} missing image(s) → "
          f"{os.path.relpath(dest) if not os.path.isabs(a.out) else dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
