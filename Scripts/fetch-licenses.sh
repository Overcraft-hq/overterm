#!/usr/bin/env bash
# Resources/licenses: the third-party software Overterm ships, and each one's
# licence as its authors wrote it — what Settings ▸ About lists
# (Acknowledgements). Checked in; run again when a dependency moves (the
# weekly dependency check's issues say so). AcknowledgementsTests fails when
# Package.resolved, Ghostty's or tree-sitter's pin no longer matches it.
#
# Reads what the builds left on disk — run after `make ghosttykit`,
# `make treesitter` and a `swift build` (Package.resolved's checkouts):
#   - Ghostty and what it links into libghostty: its Zig packages, from Zig's
#     global cache (~/.cache/zig/p, by the hash its build.zig.zon pins);
#   - tree-sitter, its grammars and Helix's queries (vendor/tree-sitter);
#   - the Swift packages (.build/checkouts), LICENSE and NOTICE both;
#   - the notes' web libraries and Excalidraw, whose licences their own
#     scripts already bundle (Resources/notes/…/licenses) — listed, not copied;
#   - the fonts Excalidraw draws with, and simdutf (vendored by Ghostty as one
#     file, without its licence), from their repositories at a pinned ref.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -I - "$ROOT" <<'PY'
import json, os, re, subprocess, sys, tarfile, urllib.request

root = sys.argv[1]
out = os.path.join(root, "Resources", "licenses")
zig = os.path.expanduser(os.environ.get("ZIG_GLOBAL_CACHE_DIR", "~/.cache/zig")) + "/p"
entries = []

def fail(message):
    sys.exit(f"error: {message}")

def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()

def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

def kind(text):
    """The licence's SPDX name, from its text."""
    checks = [
        ("Apache License", "Apache-2.0"), ("Mozilla Public License", "MPL-2.0"),
        ("SIL OPEN FONT LICENSE", "OFL-1.1"), ("The FreeType Project LICENSE", "FTL"),
        ("Permission is hereby granted, free of charge", "MIT"),
        ("Redistribution and use in source and binary forms", "BSD"),
    ]
    upper = text.upper()
    for needle, spdx in checks:
        if needle.upper() in upper:
            return spdx
    fail(f"can't tell the licence of:\n{text[:300]}")

def add(group, name, version, url, text=None, file=None, license=None):
    """A licence text kept here, or `file`: one the app already carries,
    relative to Contents/Resources."""
    if file is None:
        file = f"licenses/{slug(name)}.txt"
        with open(os.path.join(root, "Resources", file), "w", encoding="utf-8") as f:
            f.write(text.strip() + "\n")
    entries.append({"group": group, "name": name, "version": version, "license": license or kind(text or read(os.path.join(root, "Resources", file))),
                    "url": url, "file": file})

def zon_hash(zon, url_part):
    text = read(zon)
    match = re.search(r'\.url = "[^"]*' + re.escape(url_part) + r'[^"]*",\s*\.hash = "([^"]+)"', text)
    if not match:
        fail(f"no {url_part} in {zon}")
    return match.group(1)

def from_zig(package, inner):
    path = f"{zig}/{package}.tar.gz" if os.path.exists(f"{zig}/{package}.tar.gz") else f"{zig}/{package}"
    if os.path.isdir(path):
        return read(os.path.join(path, inner))
    if not os.path.exists(path):
        fail(f"{package} isn't in Zig's cache — run `make ghosttykit` first")
    with tarfile.open(path) as tar:
        for member in tar.getmembers():
            if member.name.split("/", 1)[-1] == inner:
                return tar.extractfile(member).read().decode("utf-8", "replace")
    fail(f"no {inner} in {path}")

def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode("utf-8", "replace")

os.makedirs(out, exist_ok=True)
for old in os.listdir(out):
    os.remove(os.path.join(out, old))

# ── Ghostty, and what it links into libghostty ────────────────────────────
ghostty = os.path.join(root, "vendor", "ghostty")
ghostty_ref = re.search(r'GHOSTTY_REF="v([^"]+)"', read(os.path.join(root, "Scripts", "build-ghosttykit.sh"))).group(1)
if not os.path.exists(os.path.join(ghostty, "LICENSE")):
    fail("vendor/ghostty is missing — run `make ghosttykit` first")
add("Terminal", "Ghostty", ghostty_ref, "https://ghostty.org", read(os.path.join(ghostty, "LICENSE")))
inside = f"in Ghostty {ghostty_ref}"
pkg = lambda name: os.path.join(ghostty, "pkg", name, "build.zig.zon")
top = os.path.join(ghostty, "build.zig.zon")
for name, zon, url_part, inner, home, spdx in [
    ("FreeType", pkg("freetype"), "freetype-", "docs/FTL.TXT", "https://freetype.org", "FTL"),
    ("libpng", pkg("libpng"), "libpng-", "LICENSE", "http://www.libpng.org/pub/png/libpng.html", "libpng-2.0"),
    ("zlib", pkg("zlib"), "zlib-", "LICENSE", "https://zlib.net", "Zlib"),
    ("Oniguruma", pkg("oniguruma"), "oniguruma-", "COPYING", "https://github.com/kkos/oniguruma", "BSD-2-Clause"),
    ("Highway", pkg("highway"), "highway-", "LICENSE", "https://github.com/google/highway", "Apache-2.0"),
    ("glslang", pkg("glslang"), "glslang-", "LICENSE.txt", "https://github.com/KhronosGroup/glslang", "BSD-3-Clause and others"),
    ("SPIRV-Cross", pkg("spirv-cross"), "spirv_cross-", "LICENSE", "https://github.com/KhronosGroup/SPIRV-Cross", "Apache-2.0"),
    ("Wuffs", pkg("wuffs"), "wuffs-", "LICENSE-MIT", "https://github.com/google/wuffs", "Apache-2.0 OR MIT"),
    ("Sentry Native", pkg("sentry"), "sentry-", "LICENSE", "https://github.com/getsentry/sentry-native", "MIT"),
    ("Breakpad", pkg("breakpad"), "breakpad-", "LICENSE", "https://chromium.googlesource.com/breakpad/breakpad", "BSD-3-Clause"),
    ("Dear ImGui", pkg("dcimgui"), "/N-V-__8AAEbO", "LICENSE.txt", "https://github.com/ocornut/imgui", "MIT"),
    ("libxev", top, "libxev-", "LICENSE", "https://github.com/mitchellh/libxev", "MIT"),
    ("z2d", top, "z2d-", "LICENSE", "https://github.com/vancluever/z2d", "MPL-2.0"),
    ("zig-objc", top, "zig_objc-", "LICENSE", "https://github.com/mitchellh/zig-objc", "MIT"),
    ("uucode", top, "uucode-", "LICENSE.md", "https://github.com/jacobsandlund/uucode", "MIT"),
    ("JetBrains Mono", top, "JetBrainsMono-", "OFL.txt", "https://www.jetbrains.com/lp/mono/", "OFL-1.1"),
    ("Symbols Nerd Font", top, "NerdFontsSymbolsOnly-", "LICENSE", "https://www.nerdfonts.com", "MIT"),
]:
    add("Terminal", name, inside, home, from_zig(zon_hash(zon, url_part), inner), license=spdx)
simdutf = re.search(r'#define SIMDUTF_VERSION "([^"]+)"', read(os.path.join(ghostty, "pkg", "simdutf", "vendor", "simdutf.h"))).group(1)
add("Terminal", "simdutf", f"{simdutf}, {inside}", "https://github.com/simdutf/simdutf",
    fetch(f"https://raw.githubusercontent.com/simdutf/simdutf/v{simdutf}/LICENSE-MIT"), license="Apache-2.0 OR MIT")
add("Terminal", "iTerm2 Color Schemes", "themes", "https://github.com/mbadolato/iTerm2-Color-Schemes",
    read(os.path.join(root, "Resources", "themes", "LICENSE")))

# ── The editor: tree-sitter, its grammars, Helix's queries ────────────────
ts_script = read(os.path.join(root, "Scripts", "build-treesitter.sh"))
vendor = os.path.join(root, "vendor", "tree-sitter")
if not os.path.isdir(os.path.join(vendor, "repos")):
    fail("vendor/tree-sitter is missing — run `make treesitter` first")
ts_ref = re.search(r'TREE_SITTER_REF="v([^"]+)"', ts_script).group(1)
helix_ref = re.search(r'HELIX_REF="([^"]+)"', ts_script).group(1)
add("Editor", "tree-sitter", ts_ref, "https://tree-sitter.github.io", read(os.path.join(vendor, "tree-sitter", "LICENSE")))
add("Editor", "Helix queries", helix_ref, "https://github.com/helix-editor/helix", read(os.path.join(vendor, "helix", "LICENSE")))
seen = set()
for repo, rev in re.findall(r'^\s+"[^|]+\|(https://[^|]+)\|([0-9a-f]{40})\|', ts_script, re.M):
    if repo in seen:
        continue
    seen.add(repo)
    folder = os.path.join(vendor, "repos", f"{os.path.basename(repo)}-{rev[:12]}")
    names = [n for n in os.listdir(folder) if re.match(r"(?i)^licen[cs]e", n)]
    if not names:
        fail(f"no licence in {folder}")
    add("Editor", os.path.basename(repo), rev[:12], repo, read(os.path.join(folder, sorted(names)[0])))

# ── Swift packages ────────────────────────────────────────────────────────
checkouts = os.path.join(root, ".build", "checkouts")
for pin in json.load(open(os.path.join(root, "Package.resolved")))["pins"]:
    folder = os.path.join(checkouts, pin["identity"])
    if not os.path.isdir(folder):
        fail(f"{folder} is missing — run `swift build` first")
    files = sorted(os.listdir(folder))
    licence = [n for n in files if re.match(r"(?i)^licen[cs]e(\.txt|\.md)?$", n)]
    notice = [n for n in files if re.match(r"(?i)^notice(\.txt)?$", n)]
    if not licence:
        fail(f"no licence in {folder}")
    text = read(os.path.join(folder, licence[0]))
    if notice:
        text = read(os.path.join(folder, notice[0])).strip() + "\n\n" + "-" * 72 + "\n\n" + text
    add("Swift packages", pin["identity"], pin["state"].get("version") or pin["state"]["revision"][:12],
        re.sub(r"\.git$", "", pin["location"]), text, license=kind(read(os.path.join(folder, licence[0]))))

# ── Notes: the reading view's libraries, Excalidraw and its fonts ─────────
web = read(os.path.join(root, "Scripts", "fetch-notes-web.sh"))
homes = {"markdown-it": "https://github.com/markdown-it/markdown-it", "markdown-it-footnote": "https://github.com/markdown-it/markdown-it-footnote",
         "dompurify": "https://github.com/cure53/DOMPurify", "katex": "https://katex.org", "highlight.js": "https://highlightjs.org",
         "mermaid": "https://mermaid.js.org"}
spdx = {"dompurify": "MPL-2.0 OR Apache-2.0", "highlight.js": "BSD-3-Clause"}
for name, path in re.findall(r'^  "([^|"]+)\|([^|"]+)\|', web, re.M):
    version = path.rsplit("-", 1)[-1]
    add("Notes", name, version, homes.get(name, f"https://www.npmjs.com/package/{name}"), file=f"notes/vendor/licenses/{name}.txt", license=spdx.get(name))
lock = json.load(open(os.path.join(root, "Scripts", "excalidraw", "package-lock.json")))["packages"]
for name, package, home in [("Excalidraw", "@excalidraw/excalidraw", "https://excalidraw.com"), ("React", "react", "https://react.dev"),
                            ("lz-string", "lz-string", "https://github.com/pieroxy/lz-string")]:
    version = lock[f"node_modules/{package}"]["version"]
    if package.startswith("@"):
        # Its bundled note only points at the licence: the text, from the tag.
        add("Notes", name, version, home, fetch(f"https://raw.githubusercontent.com/excalidraw/excalidraw/v{version}/LICENSE"))
        continue
    add("Notes", name, version, home, file=f"notes/excalidraw/licenses/{package}.txt")
excalidraw = lock["node_modules/@excalidraw/excalidraw"]["version"]
fonts = os.listdir(os.path.join(root, "Resources", "notes", "excalidraw", "fonts"))
# Excalifont's licence is in its font's metadata, kept in the source beside it.
source = fetch(f"https://raw.githubusercontent.com/excalidraw/excalidraw/v{excalidraw}/packages/excalidraw/fonts/Excalifont/index.ts")
meta = re.search(r"\ncopyright: (.*?)\n.*?\nlicense: (.*?)\nlicenseURL:", source, re.S)
if not meta:
    fail("Excalifont's licence moved in Excalidraw's source")
excalifont = meta.group(1).strip() + "\n\n" + meta.group(2).strip()
font_sources = {
    "Virgil": ("https://github.com/excalidraw/virgil", fetch("https://raw.githubusercontent.com/excalidraw/virgil/main/LICENSE.md")),
    "Excalifont": ("https://plus.excalidraw.com/excalifont", excalifont),
    "Assistant": ("https://fonts.google.com/specimen/Assistant", fetch("https://raw.githubusercontent.com/google/fonts/main/ofl/assistant/OFL.txt")),
    "Nunito": ("https://fonts.google.com/specimen/Nunito", fetch("https://raw.githubusercontent.com/google/fonts/main/ofl/nunito/OFL.txt")),
    "Lilita": ("https://fonts.google.com/specimen/Lilita+One", fetch("https://raw.githubusercontent.com/google/fonts/main/ofl/lilitaone/OFL.txt")),
    "Cascadia": ("https://github.com/microsoft/cascadia-code", fetch("https://raw.githubusercontent.com/microsoft/cascadia-code/main/LICENSE")),
    "Liberation": ("https://github.com/liberationfonts/liberation-fonts", fetch("https://raw.githubusercontent.com/liberationfonts/liberation-fonts/main/LICENSE")),
    "ComicShanns": ("https://github.com/shannpersand/comic-shanns", fetch("https://raw.githubusercontent.com/shannpersand/comic-shanns/master/LICENSE")),
}
for font in sorted(fonts):
    if font not in font_sources:
        fail(f"Excalidraw bundles {font}: add where its licence is")
    home, text = font_sources[font]
    pretty = {"Lilita": "Lilita One", "Cascadia": "Cascadia Code", "ComicShanns": "Comic Shanns", "Liberation": "Liberation Sans"}.get(font, font)
    add("Notes", f"{pretty} (font)", f"in Excalidraw {excalidraw}", home, text)

with open(os.path.join(out, "index.json"), "w", encoding="utf-8") as f:
    json.dump(entries, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"==> {len(entries)} acknowledgements in Resources/licenses")
PY
