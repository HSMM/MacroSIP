#!/usr/bin/env python3
"""Build the public wiki site for GitHub Pages from a clone of the GitHub wiki.

Usage: scripts/build-wiki-site.py <wiki-clone> <output-dir>

Writes <output-dir>/<lang>/<slug>.html for English, Russian and Chinese, and <output-dir>/index.html, which
opens the reader's language. Markdown is rendered by the GitHub API (`gh api markdown`), so tables and code
look as they do in the wiki. The page order and the links between the languages come from the home pages,
whose lists name the pages in the same order. Every link is checked; a broken one stops the build.
"""
import html
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote, unquote

REPO = "HSMM/MacroSIP"
LANGS = {
    "en": {"home": "Home", "name": "English", "html": "en", "title": "MacroSIP documentation", "menu": "Contents"},
    "ru": {"home": "Главная", "name": "Русский", "html": "ru", "title": "Документация MacroSIP", "menu": "Содержание"},
    "zh": {"home": "首页", "name": "中文", "html": "zh-Hans", "title": "MacroSIP 文档", "menu": "目录"},
}
WIKILINK = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")


def key(name):
    return unquote(name).strip().replace(" ", "-").casefold()


def slugify(english_name):
    return "index" if key(english_name) == "home" else key(english_name)


def read_nav(path):
    """Sections of a home page: [(heading, [page name, ...])], in order. The title section is the home page."""
    sections, current, seen = [], None, set()
    for line in path.read_text(encoding="utf-8").splitlines():
        heading = re.match(r"^##\s+(.+)$", line) or re.match(r"^\*\*(.+)\*\*\s*$", line)
        if heading:
            current = (heading.group(1).strip(), [])
            sections.append(current)
        elif line.lstrip().startswith("- ") and current is not None:
            link = WIKILINK.search(line)
            if link and line.lstrip().startswith("- [["):
                name = (link.group(2) or link.group(1)).strip()
                if key(name) not in seen:       # some home pages list the guide twice
                    seen.add(key(name))
                    current[1].append(name)
    return [s for s in sections if s[1]]


def link_target(match):
    """`[[Text|Page]]` and `[[Page]]` as a Markdown link; the page goes through the same check as other links."""
    page = (match.group(2) or match.group(1)).strip()
    text = match.group(1).strip()
    return f"[{text}]({quote(page.replace(' ', '-'))})"


def render(markdown):
    with tempfile.NamedTemporaryFile("w", suffix=".md", encoding="utf-8") as f:
        f.write(markdown)
        f.flush()
        out = subprocess.run(["gh", "api", "markdown", "-f", "mode=gfm", "-f", f"context={REPO}", "-F", f"text=@{f.name}"],
                             check=True, capture_output=True, text=True)
    return out.stdout


CSS = """
:root{color-scheme:light dark;--bg:#fff;--soft:#f6f7f9;--line:#dfe3e8;--text:#1c2024;--muted:#5f6b76;--accent:#0a66d8;--code:#eff1f4}
@media (prefers-color-scheme:dark){:root{--bg:#15181c;--soft:#1c2025;--line:#31373e;--text:#e6e9ec;--muted:#9aa5b0;--accent:#6cb0ff;--code:#262b31}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Noto Sans SC",sans-serif}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
header{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:16px;min-height:56px;padding:8px 24px;background:var(--bg);border-bottom:1px solid var(--line)}
.brand{font-weight:650;color:var(--text);font-size:17px}.brand:hover{text-decoration:none}
.langs{margin-left:auto;display:flex;gap:4px}.langs a{padding:4px 10px;border-radius:7px;color:var(--muted);font-size:14px}
.langs a[aria-current]{background:var(--soft);color:var(--text);font-weight:600}
.layout{display:grid;grid-template-columns:270px minmax(0,1fr);max-width:1240px;margin:0 auto}
nav{position:sticky;top:57px;align-self:start;max-height:calc(100vh - 57px);overflow:auto;padding:20px 16px 32px 24px;font-size:14.5px}
nav summary{display:none}nav h2{margin:18px 0 6px;font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);font-weight:650}
nav ul{list-style:none;margin:0;padding:0}nav li a{display:block;padding:4px 10px;margin-left:-10px;border-radius:7px;color:var(--text)}
nav li a:hover{background:var(--soft);text-decoration:none}nav li a[aria-current]{background:var(--soft);color:var(--accent);font-weight:600}
main{min-width:0;padding:32px 40px 72px;max-width:900px}
main h1,main h2,main h3,main h4{line-height:1.25;scroll-margin-top:72px}main h1{font-size:2em;margin:0 0 .6em}
main h2{font-size:1.45em;margin:1.8em 0 .6em;padding-bottom:.25em;border-bottom:1px solid var(--line)}main h3{font-size:1.15em;margin:1.5em 0 .5em}
main a.anchor{display:none}main img{max-width:100%;height:auto;border-radius:10px}
code{font:.88em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.15em .35em;border-radius:5px}
pre{overflow:auto;background:var(--code);padding:14px 16px;border-radius:10px}pre code{padding:0;background:none}
.tablewrap{overflow-x:auto;margin:1em 0}table{border-collapse:collapse;width:100%;font-size:.95em}
th,td{border:1px solid var(--line);padding:7px 11px;text-align:left;vertical-align:top}th{background:var(--soft)}
blockquote{margin:1em 0;padding:.2em 1em;border-left:3px solid var(--line);color:var(--muted)}
footer{margin-top:56px;padding-top:16px;border-top:1px solid var(--line);color:var(--muted);font-size:14px}
@media (max-width:820px){header{padding:8px 16px}.layout{display:block}main{padding:20px 16px 56px}
nav{position:static;max-height:none;padding:10px 16px;border-bottom:1px solid var(--line)}nav summary{display:block;cursor:pointer;font-weight:600}nav details:not([open]) .links{display:none}}
"""

PAGE = """<!doctype html>
<html lang="{html_lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{page_title}</title>
<meta name="description" content="{site_title}">
<link rel="stylesheet" href="../wiki.css">
{alternates}
</head>
<body>
<header><a class="brand" href="index.html">MacroSIP</a><div class="langs">{switcher}</div></header>
<div class="layout">
<nav aria-label="{menu}"><details{open}><summary>{menu}</summary><div class="links">{nav}</div></details></nav>
<main>
{body}
<footer><a href="https://github.com/{repo}">github.com/{repo}</a> · © HSMM</footer>
</main>
</div>
<script>if(matchMedia('(min-width:821px)').matches)document.querySelector('nav details').open=true</script>
</body>
</html>
"""

INDEX = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>MacroSIP documentation</title>
<meta http-equiv="refresh" content="0; url=en/index.html">
<script>
var l=(navigator.language||'en').toLowerCase();
location.replace((l.startsWith('ru')?'ru':l.startsWith('zh')?'zh':'en')+'/index.html'+location.hash);
</script>
</head>
<body><a href="en/index.html">English</a> · <a href="ru/index.html">Русский</a> · <a href="zh/index.html">中文</a></body>
</html>
"""


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    wiki, out = Path(sys.argv[1]), Path(sys.argv[2])
    files = {key(p.stem): p for p in wiki.glob("*.md") if not p.stem.startswith("_")}

    navs = {lang: read_nav(wiki / f"{meta['home']}.md") for lang, meta in LANGS.items()}
    orders = {lang: [meta["home"]] + [p for _, pages in navs[lang] for p in pages] for lang, meta in LANGS.items()}
    counts = {lang: len(o) for lang, o in orders.items()}
    if len(set(counts.values())) != 1:
        sys.exit(f"the home pages list different numbers of pages: {counts}")

    pages = {}      # key of a wiki page -> (lang, slug, position in the order)
    for lang, order in orders.items():
        for position, name in enumerate(order):
            k = key(name)
            if k not in files:
                sys.exit(f"{LANGS[lang]['home']} links to a missing page: {name}")
            pages[k] = (lang, slugify(orders["en"][position]), position)
    missing = sorted(set(files) - set(pages))
    if missing:
        sys.exit("pages not listed on any home page: " + ", ".join(missing))

    (out).mkdir(parents=True, exist_ok=True)
    (out / "wiki.css").write_text(CSS.strip() + "\n", encoding="utf-8")
    (out / "index.html").write_text(INDEX, encoding="utf-8")

    problems = []
    for k, path in files.items():
        lang, slug, position = pages[k]
        source = WIKILINK.sub(link_target, path.read_text(encoding="utf-8"))
        body = render(source)
        body = body.replace('id="user-content-', 'id="')

        def fix_href(match):
            href = html.unescape(match.group(1))
            if re.match(r"^(https?:|mailto:|#)", href):
                return match.group(0)
            page, _, fragment = href.partition("#")
            page = re.sub(r"^.*?/wiki/", "", page)
            target = pages.get(key(page))
            if target is None:
                problems.append(f"{path.name}: {href}")
                return match.group(0)
            url = f"../{target[0]}/{target[1]}.html" if target[0] != lang else f"{target[1]}.html"
            return f'href="{html.escape(url + ("#" + fragment if fragment else ""), quote=True)}"'

        body = re.sub(r'href="([^"]*)"', fix_href, body)
        body = re.sub(r"<table\b", '<div class="tablewrap"><table', body).replace("</table>", "</table></div>")
        for m in re.finditer(r'href="#([^"]+)"', body):
            if f'id="{m.group(1)}"' not in body and f'id="{unquote(m.group(1))}"' not in body:
                problems.append(f"{path.name}: #{m.group(1)}")

        title = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
        heading = re.sub(r"<[^>]+>", "", title.group(1)).strip() if title else path.stem.replace("-", " ")
        if not title:
            body = f"<h1>{html.escape(heading)}</h1>\n" + body

        meta = LANGS[lang]
        nav = [f'<ul><li><a href="index.html"{" aria-current=page" if position == 0 else ""}>{html.escape(meta["home"])}</a></li></ul>']
        for section, names in navs[lang]:
            items = "".join(
                f'<li><a href="{pages[key(n)][1]}.html"{" aria-current=page" if key(n) == k else ""}>{html.escape(n.replace("-", " "))}</a></li>'
                for n in names)
            nav.append(f"<h2>{html.escape(section)}</h2><ul>{items}</ul>")
        switcher = "".join(
            f'<a href="../{other}/{slug}.html" hreflang="{m["html"]}"{" aria-current=true" if other == lang else ""}>{m["name"]}</a>'
            for other, m in LANGS.items())
        alternates = "\n".join(f'<link rel="alternate" hreflang="{m["html"]}" href="../{o}/{slug}.html">' for o, m in LANGS.items())
        page_title = meta["title"] if position == 0 else f"{heading} · {meta['title']}"
        document = PAGE.format(html_lang=meta["html"], page_title=html.escape(page_title), site_title=html.escape(meta["title"]),
                               alternates=alternates, switcher=switcher, menu=html.escape(meta["menu"]), nav="".join(nav),
                               body=body, repo=REPO, open="")
        target = out / lang / f"{slug}.html"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(document, encoding="utf-8")

    if problems:
        sys.exit("broken links:\n  " + "\n  ".join(sorted(set(problems))))
    print(json.dumps({"pages": len(files), "languages": list(LANGS), "output": str(out)}))


if __name__ == "__main__":
    main()
