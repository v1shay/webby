(() => {
  if (window.__webbyLinkPreview || window.top !== window) return;
  window.__webbyLinkPreview = true;
  let timer;
  let current;
  document.addEventListener('pointerover', event => {
    const link = event.target.closest?.('a[href]');
    if (link === current) return;
    clearTimeout(timer);
    current = link;
    if (!link) return;
    const url = link.href;
    if (!/^https?:\/\//i.test(url) || url.split('#')[0] === location.href.split('#')[0]) return;
    timer = setTimeout(() => {
      if (current !== link) return;
      const rect = link.getBoundingClientRect();
      window.webkit.messageHandlers.browserLinkPreview.postMessage({
        url, x: rect.left, y: rect.bottom, width: Math.max(rect.width, 1)
      });
    }, 320);
  }, true);
  document.addEventListener('pointerout', event => {
    if (current && !current.contains(event.relatedTarget)) {
      clearTimeout(timer);
      current = null;
    }
  }, true);
})();
