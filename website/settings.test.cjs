const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const policy = require('../docs/assets/site-settings-20260912.js');
const source = fs.readFileSync(require.resolve('../docs/assets/site-settings-20260912.js'), 'utf8');

test('regional languages and Chinese scripts select the supported catalog', () => {
  const cases = {'zh-TW':'zh-Hant','zh-HK':'zh-Hant','zh-MO':'zh-Hant','zh_CN':'zh-Hans','zh-SG':'zh-Hans','zh-Hans-TW':'zh-Hans','zh-Hant-CN':'zh-Hant','ja-JP':'ja','ko-KR':'ko','DE-at':'de','fr-CA':'fr','es-MX':'es','pt-PT':'pt-BR','pt-BR':'pt-BR','it-CH':'it','en-AU':'en','ru-RU':null,'':null};
  for (const [input, output] of Object.entries(cases)) assert.equal(policy.matchLanguage(input), output, input);
  assert.equal(policy.matchLanguage(null), null);
});
test('explicit English, localized links, saved choice, then browser fallback', () => {
  assert.equal(policy.chooseLanguage('ja','en','de',['zh-TW']), 'en');
  assert.equal(policy.chooseLanguage('ja',null,'de',['zh-TW']), 'ja');
  assert.equal(policy.chooseLanguage('en',null,'de',['zh-TW']), 'de');
  assert.equal(policy.chooseLanguage('en','unknown','bad',['ru-RU','zh-HK']), 'zh-Hant');
  assert.equal(policy.chooseLanguage('en',null,null,['ru-RU']), 'en');
  assert.equal(policy.chooseLanguage('en',null,null,[]), 'en');
});
test('language navigation preserves the page, section and unrelated query parameters', () => {
  assert.equal(policy.localizedURL('https://example.com/docs/fr/support.html?ref=help#purchases','fr','en','support'), 'https://example.com/docs/support.html?ref=help&lang=en#purchases');
  assert.equal(policy.localizedURL('https://example.com/?lang=en#workflow','en','ja','index'), 'https://example.com/ja/#workflow');
  assert.equal(policy.localizedURL('https://example.com/de/index.html?lang=fr','de','fr','index'), 'https://example.com/fr/');
});
function browser({stored={}, denied=false, language='en', preferred=['en'], url='https://example.com/?lang=en', dark=false}={}) {
  const events = {}, domEvents = {}, mediaEvents = {}, buttonEvents = {};
  const button = {hidden:true, attrs:{}, addEventListener:(key,fn)=>buttonEvents[key]=fn, setAttribute(key,value){this.attrs[key]=value;}, getAttribute(key){return this.attrs[key];}};
  const picker = {querySelectorAll:()=>[],addEventListener(){}};
  const config = {language,page:'index',messages:{'ui.themeDark':'Go dark','ui.themeLight':'Go light'}};
  const document = {documentElement:{dataset:{}},getElementById:()=>({textContent:JSON.stringify(config)}),querySelector:selector=>selector==='[data-theme-toggle]'?button:picker,addEventListener:(key,fn)=>domEvents[key]=fn};
  const media = {matches:dark,addEventListener:(key,fn)=>mediaEvents[key]=fn};
  const redirects = [];
  const window = {document,navigator:{languages:preferred},location:{href:url,replace:value=>redirects.push(value)},localStorage:{getItem:key=>{if(denied)throw Error('Denied');return stored[key]??null;},setItem:(key,value)=>{if(denied)throw Error('Denied');stored[key]=value;}},matchMedia:()=>media,addEventListener:(key,fn)=>events[key]=fn,dispatchEvent(){}};
  vm.runInNewContext(source,{window,URL,CustomEvent:class {constructor(type,options){this.type=type;this.detail=options.detail;}}});
  domEvents.DOMContentLoaded();
  return {window,button,stored,redirects,toggle:()=>buttonEvents.click(),system:(value)=>{media.matches=value;mediaEvents.change();},storage:(value)=>events.storage({key:'theme',newValue:value})};
}
test('theme starts from the system and an explicit toggle survives system changes', () => {
  const b=browser({dark:true}); assert.equal(b.window.document.documentElement.dataset.resolvedTheme,'dark');
  assert.equal(b.button.attrs['aria-label'],'Go light'); assert.equal(b.button.hidden,false);
  b.toggle(); assert.equal(b.stored.theme,'light'); b.system(false);b.system(true);
  assert.equal(b.window.document.documentElement.dataset.resolvedTheme,'light');
  const reload=browser({stored:b.stored,dark:true});assert.equal(reload.window.document.documentElement.dataset.resolvedTheme,'light');
});
test('system mode tracks changes; other tabs can update or clear a saved preference', () => {
  const b=browser();b.system(true);assert.equal(b.button.attrs['aria-label'],'Go light');
  b.storage('light');assert.equal(b.button.attrs['aria-label'],'Go dark');
  b.storage(null);assert.equal(b.button.attrs['aria-label'],'Go light');
});
test('storage denial keeps the toggle functional and does not reset an explicit choice', () => {
  const b=browser({denied:true,dark:false});b.toggle();b.system(true);b.system(false);
  assert.equal(b.window.document.documentElement.dataset.resolvedTheme,'dark');b.toggle();
  assert.equal(b.button.attrs['aria-label'],'Go dark');
});
test('browser preference redirect retains a safe API while the old page unloads', () => {
  const b=browser({url:'https://example.com/#workflow',preferred:['zh-TW']});
  assert.deepEqual(b.redirects,['https://example.com/zh-Hant/#workflow']);
  assert.equal(typeof b.window.SDWebsite.message,'function');
  assert.equal(b.stored.language,'zh-Hant');
  assert.equal(browser({preferred:['ja'],denied:true}).redirects.length,0);
});
