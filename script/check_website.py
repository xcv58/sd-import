#!/usr/bin/env python3
"""Check catalog coverage, generated markup, internal links, and official assets."""
import hashlib
from html.parser import HTMLParser
import re
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
from build_website import APP_STORE, DOCS, LANGUAGES, PAGES, SITE, build, load_json, parse, translated


LITERAL_TOKENS = {
    '·', '→', '↗', 'SD-Import.dmg', 'SD-Import.zip', 'SD Import.app',
    'Applications', 'i@xcv58.com', '.sd-import', '.sd-import/imported-v1.jsonl',
    '~/Library/Application Support/SD Import/state.sqlite', 'appcast.xml',
    '~/Library/Logs/DiagnosticReports/',
    'Command-I', 'Command-1', 'Command-4', 'Control-Tab', 'Command-R', 'Command-,',
}


def check_token_copy(tokens):
    # Fragments can be opening/closing tags, so use the lenient HTML tokenizer.
    class CopyParser(HTMLParser):
        def handle_data(self, text):
            assert not text.strip() or text.strip() in LITERAL_TOKENS, ('untranslated token text', text)

        def handle_starttag(self, tag, attrs):
            for attr, value in attrs:
                assert attr not in {'aria-label', 'title', 'alt', 'data-title', 'data-caption'} or not value, ('untranslated token attribute', attr, value)

    for value in tokens.values():
        parser = CopyParser(convert_charrefs=True)
        parser.feed(value)
        parser.close()


def check():
    build(check=True)
    english = load_json(SITE / 'locales/en.json')
    units = load_json(SITE / 'units.json')
    for key, unit in units.items():
        try:
            check_token_copy(unit['tokens'])
        except AssertionError as error:
            raise AssertionError((key, *error.args)) from error
    # Regression: buttons and formatted command names must remain translatable.
    for markup in ['<a href="mailto:i@xcv58.com">Email support</a>', '<code>Import Anyway</code>', '<span title="Help">']:
        try:
            check_token_copy({'{0}': markup})
        except AssertionError:
            pass
        else:
            raise AssertionError(('Opaque copy accepted', markup))
    referenced = set()
    exempt = {'SD Card Import', 'SD Import', 'GitHub', 'RAW', 'JPEG'} | LITERAL_TOKENS
    for page in PAGES:
        def coverage(node, covered=False):
            covered = covered or 'data-i18n' in node.attrs or node.tag in {'script', 'style', 'svg'} or any(key in node.attrs for key in ['data-language-name', 'data-language-short', 'data-language-menu'])
            if node.tag is None and re.search('[A-Za-z]', node.text) and not covered:
                assert node.text.strip() in exempt, (page, 'untranslated text', node.text)
            for attr, value in node.attrs.items():
                if attr == 'data-i18n' or attr.startswith('data-i18n-attr-'):
                    assert value in english, (page, value)
                    referenced.add(value)
                if attr in {'aria-label', 'title', 'alt', 'data-title', 'data-caption'} and value and not covered:
                    assert 'data-i18n-attr-' + attr in node.attrs, (page, attr, value)
            for child in node.children:
                coverage(child, covered)
        coverage(parse((SITE / 'templates' / f'{page}.html').read_text()))
    assert referenced == set(units), ('unused messages', set(units) - referenced)
    # A translator can supply text and known placeholders, never executable markup.
    assert '&lt;script&gt;' in ''.join(n.html() for n in translated('<script>alert(1)</script>', 'plain', {}))
    try:
        translated('{0}bad{/1}', '{0}ok{/0}', {'{0}': '<em>', '{/0}': '</em>'})
    except AssertionError:
        pass
    else:
        raise AssertionError('Invalid placeholders accepted')
    badges = load_json(SITE / 'apple-badges.json')
    assert set(badges) == set(LANGUAGES)
    for language, badge in badges.items():
        path = DOCS.parent / badge['path']
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == badge['sha256'], language
        svg = ET.fromstring(data)
        assert svg.tag == '{http://www.w3.org/2000/svg}svg'
        assert float(svg.attrib['height']) == 40 and float(svg.attrib['width']) > 100
        assert badge['url'].startswith('https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-mac-app-store/black/')
    parsed_pages = {}
    for language in LANGUAGES:
        catalog = load_json(SITE / 'locales' / f'{language}.json')
        for page in PAGES:
            path = DOCS / ('' if language == 'en' else language) / f'{page}.html'
            content = path.read_text()
            tree = parse(content)
            nodes = list(tree.all())
            assert next(n for n in nodes if n.tag == 'html').attrs['lang'] == language
            ids = [n.attrs['id'] for n in nodes if 'id' in n.attrs]
            assert len(ids) == len(set(ids)), (path, 'duplicate id')
            assert len([n for n in nodes if n.tag == 'h1']) == 1
            assert len([n for n in nodes if 'data-theme-toggle' in n.attrs]) == 1
            assert not any('data-theme-value' in n.attrs for n in nodes)
            theme = next(n for n in nodes if 'data-theme-toggle' in n.attrs)
            assert 'hidden' in theme.attrs and theme.attrs['aria-label'] == catalog['ui.themeDark']
            menu = next(n for n in nodes if 'data-language-menu' in n.attrs)
            assert [n.attrs.get('hreflang') for n in menu.children] == list(LANGUAGES)
            assert [n.attrs['hreflang'] for n in menu.children if 'aria-current' in n.attrs] == [language]
            alternates = [n.attrs['hreflang'] for n in nodes if n.tag == 'link' and n.attrs.get('rel') == 'alternate']
            assert alternates == [*LANGUAGES, 'x-default']
            for n in nodes:
                for attr in ['aria-labelledby', 'aria-describedby']:
                    if attr in n.attrs:
                        assert all(value in ids for value in n.attrs[attr].split()), (path, attr)
                if n.tag == 'script' and n.attrs.get('type') == 'application/ld+json':
                    import json
                    schema = json.loads(n.children[0].text)
                    assert schema['name'] == 'SD Card Import' and schema['downloadUrl'] == APP_STORE
                    assert schema['inLanguage'] == language and schema['description'] == catalog['m002']
            badge_images = [n for n in nodes if 'data-store-badge' in n.attrs]
            assert len(badge_images) == (1 if page in {'index', 'install'} else 0)
            for n in badge_images:
                assert n.attrs['alt'] == catalog['m015'] and int(n.attrs['height']) >= 40
                assert f'mac-app-store-{language}-20260912.svg' in n.attrs['src']
            if page == 'index':
                assert len([n for n in nodes if n.tag == 'a' and n.attrs.get('href') == APP_STORE]) == 3
                assert next(n for n in nodes if n.tag == 'video').attrs.get('controls') is None
                assert 'controls' in next(n for n in nodes if n.tag == 'video').attrs
                assert len([n for n in nodes if 'data-gallery-choice' in n.attrs]) == 7
            if language == 'en':
                assert not re.search(r'coming to the app store|not available to download yet|upcoming app store', content, re.I)
            parsed_pages[path.resolve()] = (tree, set(ids))
    links = 0
    for path, (tree, ids) in parsed_pages.items():
        for node in tree.all():
            values = [node.attrs[attr] for attr in ['href', 'src', 'poster', 'data-light-src', 'data-dark-src', 'data-light-poster', 'data-dark-poster'] if attr in node.attrs]
            for attr in ['srcset', 'imagesrcset', 'data-light-srcset', 'data-dark-srcset']:
                values.extend(part.strip().split()[0] for part in node.attrs.get(attr, '').split(',') if part.strip())
            for value in values:
                url = urlsplit(value)
                if url.scheme or url.netloc:
                    continue
                target = (path.parent / unquote(url.path)).resolve() if url.path else path
                if target.is_dir():
                    target /= 'index.html'
                assert target.is_file(), (path, 'missing link', value)
                assert target.is_relative_to(DOCS.resolve()), (path, 'link outside site', value)
                if url.fragment and target in parsed_pages:
                    assert unquote(url.fragment) in parsed_pages[target][1], (path, 'missing anchor', value)
                if url.path.endswith('.html') and target.parent == path.parent:
                    assert url.query == ('lang=en' if path.parent == DOCS.resolve() else ''), (path, value)
                links += 1
    sitemap = ET.parse(DOCS / 'sitemap.xml')
    assert len(sitemap.findall('{http://www.sitemaps.org/schemas/sitemap/0.9}url')) == 70
    print(f'PASS: 10 complete catalogs, 70 pages, {links} local references, 10 unmodified Apple badges')


if __name__ == '__main__':
    check()
