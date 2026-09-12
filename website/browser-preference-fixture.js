// Synthetic browser preferences for the isolated regression session only.
Object.defineProperty(navigator, 'languages', {get: () => ['zh-TW', 'en-US']});
Object.defineProperty(window, 'localStorage', {
  get() { throw new DOMException('Test: storage denied', 'SecurityError'); }
});
