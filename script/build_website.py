#!/usr/bin/env python3
"""Build every public page as static, localized HTML using only Python's stdlib."""
from collections import Counter
from html import escape
from html.parser import HTMLParser
import argparse
import json
from pathlib import Path
import re
from urllib.parse import urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "website"
DOCS = ROOT / "docs"
LANGUAGES = {
    "en": "English", "zh-Hans": "简体中文", "zh-Hant": "繁體中文", "ja": "日本語",
    "ko": "한국어", "de": "Deutsch", "fr": "Français", "es": "Español",
    "pt-BR": "Português (Brasil)", "it": "Italiano",
}
PAGES = ["index", "install", "user-guide", "support", "privacy", "eula", "updates"]
APP_STORE = "https://apps.apple.com/us/app/sd-card-import/id6807178069?mt=12"
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
TOKEN = re.compile(r"\{/?\d+\}")


class Node:
    def __init__(self, tag=None, attrs=None, text=""):
        self.tag, self.attrs, self.text = tag, dict(attrs or []), text
        self.children = []

    def all(self):
        yield self
        for child in self.children:
            yield from child.all()

    def content(self):
        return "".join(child.html() for child in self.children)

    def html(self):
        if self.tag is None:
            return escape(self.text, quote=False)
        if self.tag == "!raw":
            return self.text
        if self.tag == "!root":
            return self.content()
        attrs = "".join(f' {key}' if value is None else f' {key}="{escape(value, quote=True)}"' for key, value in self.attrs.items())
        opening = f"<{self.tag}{attrs}>"
        return opening if self.tag in VOID else opening + self.content() + f"</{self.tag}>"


class Parser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("!root")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if len(self.stack) == 1 or self.stack[-1].tag != tag:
            raise ValueError(f"Unbalanced HTML closing tag: {tag}")
        self.stack.pop()

    def handle_data(self, value):
        tag = "!raw" if self.stack[-1].tag in {"script", "style"} else None
        self.stack[-1].children.append(Node(tag, text=value))

    def handle_decl(self, value):
        self.stack[-1].children.append(Node("!raw", text=f"<!{value}>"))

    def handle_comment(self, value):
        self.stack[-1].children.append(Node("!raw", text=f"<!--{value}-->"))


def parse(value):
    parser = Parser()
    parser.feed(value)
    assert len(parser.stack) == 1, "Unclosed HTML element"
    return parser.root


def load_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            assert key not in result, f"Duplicate catalog key: {key}"
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique)


def translated(value, source, tokens):
    assert Counter(TOKEN.findall(value)) == Counter(TOKEN.findall(source)), f"Translation placeholders differ: {source}"
    # Only markup captured from the English template can become HTML.
    output = escape(value, quote=False)
    output = TOKEN.sub(lambda match: tokens[match.group()], output)
    return parse(output).children


def local_link(value, language):
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc or not parsed.path or parsed.path.startswith("/"):
        return value
    if parsed.path in {page + ".html" for page in PAGES}:
        query = "lang=en" if language == "en" else ""
        return urlunsplit(("", "", parsed.path, query, parsed.fragment))
    if parsed.path.startswith("assets/") and language != "en":
        return "../" + value
    return value


def render(page, language, catalog, english, units):
    tree = parse((SITE / "templates" / f"{page}.html").read_text())
    for node in list(tree.all()):
        key = node.attrs.get("data-i18n")
        if key:
            node.children = translated(catalog[key], english[key], units[key]["tokens"])
        for attr, attr_key in list(node.attrs.items()):
            if attr.startswith("data-i18n-attr-"):
                target = attr.removeprefix("data-i18n-attr-")
                node.attrs[target] = catalog[attr_key]
        if node.tag == "html":
            node.attrs.update(lang=language, **{"data-page": page})
        if "data-language-menu" in node.attrs:
            # Native links keep language navigation usable without JavaScript.
            prefix = "../" if language != "en" else ""
            links = []
            for code, name in LANGUAGES.items():
                path = ("" if code == "en" else code + "/") + ("" if page == "index" else page + ".html")
                href = prefix + (path or "./") + ("?lang=en" if code == "en" else "")
                current = ' aria-current="page"' if code == language else ""
                links.append(f'<a href="{href}" lang="{code}" hreflang="{code}"{current}>{name}</a>')
            node.children = parse("".join(links)).children
        if "data-language-name" in node.attrs:
            node.children = [Node(text=LANGUAGES[language])]
        if "data-language-short" in node.attrs:
            node.children = [Node(text={"zh-Hans": "简", "zh-Hant": "繁", "pt-BR": "PT"}.get(language, language.upper()))]
        if "data-store-badge" in node.attrs:
            node.attrs["src"] = f"assets/badges/mac-app-store-{language}-20260912.svg"
        if node.tag == "script" and node.attrs.get("id") == "site-config":
            config = {"language": language, "page": page, "messages": {key: value for key, value in catalog.items() if key.startswith("ui.")}}
            node.children = [Node("!raw", text=json.dumps(config, ensure_ascii=False).replace("<", "\\u003c"))]
    for node in tree.all():
        for attr in ["href", "src", "poster", "data-light-src", "data-dark-src", "data-light-poster", "data-dark-poster"]:
            if attr in node.attrs:
                node.attrs[attr] = local_link(node.attrs[attr], language)
        for attr in ["srcset", "imagesrcset", "data-light-srcset", "data-dark-srcset"]:
            if attr in node.attrs and language != "en":
                node.attrs[attr] = re.sub(r"(?<![\w/])assets/", "../assets/", node.attrs[attr])
        if node.tag == "link" and node.attrs.get("rel") == "canonical" or node.tag == "meta" and node.attrs.get("property") == "og:url":
            target = "https://sd.jenny.media/" + ("" if language == "en" else language + "/") + ("" if page == "index" else page + ".html")
            node.attrs["href" if node.tag == "link" else "content"] = target
    head = next(node for node in tree.all() if node.tag == "head")
    for node in head.children:
        if node.tag == "script" and node.attrs.get("type") == "application/ld+json":
            schema = json.loads(node.children[0].text)
            schema.update(description=catalog["m002"], inLanguage=language)
            node.children = [Node("!raw", text=json.dumps(schema, ensure_ascii=False).replace("<", "\\u003c"))]
    for code in [*LANGUAGES, "x-default"]:
        path = ("" if code in {"en", "x-default"} else code + "/") + ("" if page == "index" else page + ".html")
        head.children.append(Node("link", {"rel": "alternate", "hreflang": code, "href": "https://sd.jenny.media/" + path}))
    return "\n".join(line.rstrip() for line in tree.html().splitlines()).rstrip() + "\n"


def build(check=False):
    units = load_json(SITE / "units.json")
    english = load_json(SITE / "locales/en.json")
    assert set(units) == {key for key in english if not key.startswith("ui.")}
    failures = []
    for language in LANGUAGES:
        catalog = load_json(SITE / "locales" / f"{language}.json")
        assert set(catalog) == set(english), f"Incomplete {language} catalog"
        assert all(isinstance(value, str) and value.strip() for value in catalog.values())
        for key in english:
            assert Counter(re.findall(r"\{/?[\w]+\}", catalog[key])) == Counter(re.findall(r"\{/?[\w]+\}", english[key])), (language, key)
        for page in PAGES:
            output = render(page, language, catalog, english, units)
            path = DOCS / ("" if language == "en" else language) / f"{page}.html"
            if check:
                if not path.is_file() or path.read_text() != output:
                    failures.append(str(path.relative_to(ROOT)))
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(output)
    sitemap = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
    for language in LANGUAGES:
        for page in PAGES:
            url = "https://sd.jenny.media/" + ("" if language == "en" else language + "/") + ("" if page == "index" else page + ".html")
            sitemap += f"  <url><loc>{url}</loc></url>\n"
    sitemap += "</urlset>\n"
    if check:
        if (DOCS / "sitemap.xml").read_text() != sitemap:
            failures.append("docs/sitemap.xml")
    else:
        (DOCS / "sitemap.xml").write_text(sitemap)
    assert not failures, f"Generated pages are stale: {failures}"
    print(f"70 static pages, {len(english)} messages across 10 languages: {'current' if check else 'generated'}")


if __name__ == "__main__":
    options = argparse.ArgumentParser()
    options.add_argument("--check", action="store_true")
    build(options.parse_args().check)
