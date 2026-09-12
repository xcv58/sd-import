/* Shared preference policy; also importable by the Node regression tests. */
(function (host) {
  'use strict';
  const languages = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es', 'pt-BR', 'it'];
  function matchLanguage(value) {
    if (typeof value !== 'string') return null;
    const parts = value.toLowerCase().replaceAll('_', '-').split('-');
    if (parts[0] === 'zh') {
      if (parts.includes('hant')) return 'zh-Hant';
      if (parts.includes('hans')) return 'zh-Hans';
      return parts.some(part => ['tw', 'hk', 'mo'].includes(part)) ? 'zh-Hant' : 'zh-Hans';
    }
    if (parts[0] === 'pt') return 'pt-BR';
    return languages.includes(parts[0]) ? parts[0] : null;
  }
  function chooseLanguage(pageLanguage, explicit, saved, preferred) {
    if (languages.includes(explicit)) return explicit;
    if (pageLanguage !== 'en' && languages.includes(pageLanguage)) return pageLanguage;
    if (languages.includes(saved)) return saved;
    return (preferred || []).map(matchLanguage).find(Boolean) || 'en';
  }
  function resolveTheme(preference, systemDark) {
    return preference === 'dark' || (preference !== 'light' && systemDark) ? 'dark' : 'light';
  }
  function localizedURL(current, pageLanguage, targetLanguage, page) {
    const url = new URL(current);
    // Resolve relative to the current generated page, including under a subpath.
    const base = new URL(pageLanguage === 'en' ? './' : '../', url);
    const target = new URL((targetLanguage === 'en' ? '' : targetLanguage + '/') + (page === 'index' ? './' : page + '.html'), base);
    target.search = url.search;
    target.searchParams.delete('lang');
    if (targetLanguage === 'en') target.searchParams.set('lang', 'en');
    target.hash = url.hash;
    return target.href;
  }
  const policy = {languages, matchLanguage, chooseLanguage, resolveTheme, localizedURL};
  if (typeof module !== 'undefined' && module.exports) module.exports = policy;
  if (!host.document) return;
  const document = host.document;
  const config = JSON.parse(document.getElementById('site-config').textContent);
  const root = document.documentElement;
  const read = key => { try { return host.localStorage.getItem(key); } catch { return null; } };
  const save = (key, value) => { try { host.localStorage.setItem(key, value); } catch { /* Private modes may deny storage. */ } };
  const requested = new URL(host.location.href).searchParams.get('lang');
  const language = config.language;
  const preferredLanguage = chooseLanguage(language, requested, read('language'), host.navigator.languages);
  if (preferredLanguage !== language) {
    host.location.replace(localizedURL(host.location.href, language, preferredLanguage, config.page));
  }
  save('language', preferredLanguage);
  const media = host.matchMedia('(prefers-color-scheme: dark)');
  let preference = read('theme');
  if (!['light', 'dark', 'system'].includes(preference)) preference = 'system';
  const message = (key, values = {}) => (config.messages['ui.' + key] || key).replace(/\{(\w+)\}/g, (token, name) => values[name] ?? token);
  function applyTheme() {
    const resolved = resolveTheme(preference, media.matches);
    root.dataset.theme = preference;
    root.dataset.resolvedTheme = resolved;
    const button = document.querySelector('[data-theme-toggle]');
    if (button) {
      button.hidden = false;
      button.setAttribute('aria-label', message(resolved === 'dark' ? 'themeLight' : 'themeDark'));
      button.title = button.getAttribute('aria-label');
    }
    host.dispatchEvent(new CustomEvent('sdimport:theme', {detail: resolved}));
  }
  host.SDWebsite = {...policy, message, assetPrefix: language === 'en' ? 'assets/' : '../assets/'};
  applyTheme();
  media.addEventListener('change', () => { if (preference === 'system') applyTheme(); });
  host.addEventListener('storage', event => {
    if (event.key !== 'theme' && event.key !== null) return;
    preference = ['light', 'dark'].includes(event.newValue) ? event.newValue : 'system';
    applyTheme();
  });
  document.addEventListener('DOMContentLoaded', () => {
    applyTheme();
    document.querySelector('[data-theme-toggle]').addEventListener('click', () => {
      preference = resolveTheme(preference, media.matches) === 'dark' ? 'light' : 'dark';
      save('theme', preference);
      applyTheme();
    });
    const picker = document.querySelector('.language-picker');
    picker.querySelectorAll('a[hreflang]').forEach(link => {
      // Keep the same section and incidental query parameters on a language change.
      link.href = localizedURL(host.location.href, language, link.hreflang, config.page);
      link.addEventListener('click', () => save('language', link.hreflang));
    });
    document.addEventListener('click', event => { if (!picker.contains(event.target)) picker.open = false; });
    picker.addEventListener('keydown', event => {
      if (event.key === 'Escape') { picker.open = false; picker.querySelector('summary').focus(); }
    });
  });
}(typeof window === 'undefined' ? globalThis : window));
