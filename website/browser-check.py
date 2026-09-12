#!/usr/bin/env python3
"""Real interaction checks using agent-browser 0.37.1 and a local static server.
Usage: AGENT_BROWSER_BIN=/path/to/agent-browser python3 website/browser-check.py URL OUTPUT_DIR
Uses an isolated browser session; never connects to an existing user browser.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

BASE = sys.argv[1].rstrip('/')
OUT = Path(sys.argv[2]); OUT.mkdir(parents=True, exist_ok=True)
BIN = os.environ.get('AGENT_BROWSER_BIN', 'agent-browser')
SESSION = f'sd-import-website-check-{os.getpid()}'
LANGUAGES = ['en','zh-Hans','zh-Hant','ja','ko','de','fr','es','pt-BR','it']
PAGES = ['install','user-guide','support','privacy','eula','updates']
CATALOGS = {code:json.loads((Path(__file__).parent/'locales'/f'{code}.json').read_text()) for code in LANGUAGES}
SCREENCAST = json.loads((Path(__file__).parent/'screencast-edit.json').read_text())
COUNT = 0

def command(*args):
    global COUNT
    result = subprocess.run([BIN,'--session',SESSION,*args,'--json'],capture_output=True,text=True,timeout=45)
    if result.returncode:
        raise AssertionError((args,result.stdout,result.stderr))
    data=json.loads(result.stdout)
    assert data['success'], (args,data)
    COUNT += 1
    return data.get('data',{})

def evaluate(js):
    return command('eval',js)['result']

def open_page(path,language):
    command('open',BASE+path)
    command('wait','--fn',f'document.readyState === "complete" && document.documentElement.lang === {json.dumps(language)}')

def layout(language):
    result=evaluate('''(() => {
      const button=document.querySelector('[data-theme-toggle]'), header=document.querySelector('.site-header');
      const a=button.getBoundingClientRect(), b=header.getBoundingClientRect();
      return {lang:document.documentElement.lang, overflow:document.documentElement.scrollWidth>innerWidth+1,
        topRight:Math.abs(a.right-b.right)<2 && a.top-b.top<55, buttons:document.querySelectorAll('[data-theme-toggle]').length,
        broken:[...document.images].filter(i=>i.complete && !i.naturalWidth).map(i=>i.src),
        menuLinks:document.querySelectorAll('.language-menu a').length, title:document.title,
        badge:document.querySelector('[data-store-badge]')?.getBoundingClientRect().height};
    })()''')
    assert result['lang']==language and not result['overflow'] and result['topRight'],result
    assert result['buttons']==1 and result['menuLinks']==10 and not result['broken'],result
    if result.get('badge') is not None: assert result['badge']>=40,result
    assert command('errors').get('errors',[])==[],command('errors')
    return result

try:
    command('open',BASE+'/?lang=en')
    command('wait','--load','networkidle')
    command('screenshot',str(OUT/'first-render.png'))
    (OUT/'first-snapshot.json').write_text(json.dumps(command('snapshot','-i'),ensure_ascii=False,indent=2))
    command('eval','localStorage.clear()')
    command('set','media','light')
    command('set','viewport','1280','900')
    open_page('/?lang=en','en')
    layout('en')
    command('focus','[data-theme-toggle]');command('press','Enter')
    assert evaluate('document.documentElement.dataset.resolvedTheme')=='dark'
    command('reload');command('wait','--load','networkidle')
    assert evaluate('document.documentElement.dataset.resolvedTheme')=='dark'
    command('set','media','dark');command('set','media','light')
    assert evaluate('document.documentElement.dataset.resolvedTheme')=='dark'
    command('click','.language-picker summary')
    command('snapshot','-i')
    command('click','.language-menu a[hreflang="fr"]')
    command('wait','--fn','document.documentElement.lang === "fr" && document.readyState === "complete"')
    command('click','.site-header .nav-links a[href^="user-guide.html"]')
    command('wait','--load','networkidle')
    assert evaluate('document.documentElement.lang')=='fr'
    assert evaluate('document.documentElement.dataset.resolvedTheme')=='dark'
    assert evaluate('location.pathname').endswith('/fr/user-guide.html')
    command('screenshot',str(OUT/'french-guide-dark.png'))
    # All locales at both desktop and small phone widths, plus every help page.
    for index,language in enumerate(LANGUAGES):
        path='/?lang=en' if language=='en' else '/'+language+'/'
        for width in [1280,375,320]:
            command('set','viewport',str(width),'900');open_page(path,language);layout(language)
        command('screenshot',str(OUT/f'{language}-mobile-dark.png'))
        command('click','[data-theme-toggle]')
        assert evaluate('document.querySelector("[data-theme-toggle]").getAttribute("aria-label")')==CATALOGS[language]['ui.themeDark']
        command('wait','350')
        command('screenshot',str(OUT/f'{language}-mobile-light.png'))
        command('click','[data-theme-toggle]')
        for page in PAGES:
            target=('/' if language=='en' else '/'+language+'/')+page+'.html'+('?lang=en' if language=='en' else '')
            open_page(target,language);layout(language)
        print('PASS locale and layouts:',language,flush=True)
    # Gallery and player remain functional on a translated nested URL.
    command('set','viewport','1280','900');open_page('/ja/','ja')
    command('click','[data-gallery-choice="1"]')
    assert evaluate('document.querySelector("[data-gallery-title]").textContent')==CATALOGS['ja']['m072']
    command('focus','[data-gallery-choice="1"]');command('press','ArrowRight')
    assert evaluate('document.querySelector("[data-gallery-choice=\\"2\\"]").getAttribute("aria-current")')=='true'
    command('click','[data-gallery-open]')
    assert evaluate('document.querySelector("dialog").open')
    command('screenshot',str(OUT/'japanese-gallery.png'))
    command('press','Escape')
    assert evaluate('document.activeElement.hasAttribute("data-gallery-open")')
    command('click','[data-video-play]')
    command('wait','--fn','!document.querySelector("video").paused && document.querySelector("video").currentTime>0')
    assert evaluate('document.querySelector("video").duration') == SCREENCAST['duration_seconds']
    assert evaluate('document.querySelector("video").currentSrc').endswith('/' + SCREENCAST['output'].removeprefix('docs/'))
    assert evaluate('document.querySelector("[data-video-duration]").textContent') == '0:20'
    assert evaluate('document.querySelector("[data-video-play]").getAttribute("aria-label")')==CATALOGS['ja']['ui.pause']
    command('click','[data-video-play]');command('focus','[data-video-scrubber]');command('press','ArrowRight')
    assert evaluate('document.querySelector("video").currentTime')>=5
    assert '中' in evaluate('document.querySelector("[data-video-scrubber]").getAttribute("aria-valuetext")')
    # Verify the new ending can be reached, played through, and replayed.
    command('eval', 'document.querySelector("video").currentTime = 18.25')
    command('wait', '--fn', '!document.querySelector("video").seeking && document.querySelector("video").readyState >= 2')
    command('screenshot', str(OUT/'video-receipt.png'))
    command('click', '[data-video-play]')
    command('wait', '--fn', 'document.querySelector("video").ended')
    assert evaluate('document.querySelector("[data-video-scrubber]").getAttribute("aria-valuenow")') == '1000'
    assert evaluate('document.querySelector("[data-video-play]").getAttribute("aria-label")') == CATALOGS['ja']['ui.play']
    command('click', '[data-video-play]')
    command('wait', '--fn', '!document.querySelector("video").paused && document.querySelector("video").currentTime > 0 && document.querySelector("video").currentTime < 2')
    command('click', '[data-video-play]')
    assert not evaluate('[...document.images].filter(i=>i.complete&&!i.naturalWidth).length')
    # Browser regional preference and English override with localStorage denied.
    command('close')
    SESSION += '-preferences'
    command('open',BASE+'/#workflow','--init-script',str(Path(__file__).resolve().parent/'browser-preference-fixture.js'))
    open_page('/#workflow','zh-Hant')
    assert evaluate('location.hash')=='#workflow'
    assert evaluate("(()=>{try{localStorage.getItem('theme');return false}catch{return true}})()")
    command('set','media','dark');command('wait','--fn',"document.documentElement.dataset.resolvedTheme === 'dark'")
    command('set','media','light');command('wait','--fn',"document.documentElement.dataset.resolvedTheme === 'light'")
    command('focus','[data-theme-toggle]');command('press','Enter')
    assert evaluate('document.documentElement.dataset.resolvedTheme')=='dark'
    command('set','media','dark');command('set','media','light')
    assert evaluate('document.documentElement.dataset.resolvedTheme')=='dark'
    command('focus','.language-picker summary');command('press','Enter')
    command('focus','.language-menu a[hreflang="en"]');command('press','Enter')
    command('wait','--fn','document.documentElement.lang === "en" && document.readyState === "complete"')
    assert evaluate('location.search')=='?lang=en'
    command('focus','.site-header .nav-links a[href^="user-guide.html"]');command('press','Enter');command('wait','--load','networkidle')
    assert evaluate('document.documentElement.lang')=='en'
    print('PASS gallery, playback, keyboard, persistence, regional choice, denied storage and explicit English',flush=True)
    # Fresh session: block every script so native links and controls prove the fallback.
    command('close');SESSION += '-nojs';command('open')
    command('network','route','**/*.js','--abort')
    open_page('/ko/','ko')
    assert evaluate('typeof window.SDWebsite')=='undefined'
    assert evaluate('document.querySelector("[data-theme-toggle]").hidden')
    assert evaluate('document.querySelector("video").controls')
    command('click','.language-picker summary');command('click','.language-menu a[hreflang="de"]')
    command('wait','--load','networkidle')
    assert evaluate('document.documentElement.lang')=='de'
    assert evaluate('typeof window.SDWebsite')=='undefined'
    command('screenshot',str(OUT/'german-no-javascript.png'))
    assert command('errors').get('errors',[])==[],command('errors')
    print('PASS without JavaScript: translated content, native language links and video controls',flush=True)
    print(f'PASS: {COUNT} browser commands; 10 languages; 70 pages; desktop and mobile; real interactions',flush=True)
finally:
    command('close')
