(() => {
  'use strict';
  // Hide only Google's browser nags and desktop-notification invitations.
  // Account, security, permission and delivery errors remain visible.
  if (!/^(mail|calendar|docs|drive|meet)\.google\.com$/i.test(location.hostname)) return;
  const pattern = /(?:this browser (?:version )?is (?:no longer |not )supported|(?:browser|browser version).{0,50}(?:no longer supported|unsupported)|enable desktop notifications for gmail|google chat in gmail doesn.t yet support the browser you.re using)/i;
  const roots = new Set();
  let scheduled = false;
  function hideNotice(text) {
    const value = text.nodeValue || '';
    if (value.length > 800 || !pattern.test(value)) return;
    let node = text.parentElement, candidate = null;
    for (let depth = 0; node && depth < 7; depth++, node = node.parentElement) {
      if (/^(body|html|main)$/i.test(node.localName)) break;
      const rect = node.getBoundingClientRect();
      if (rect.height > 150 || (node.textContent || '').length > 1200) break;
      if (rect.width >= Math.min(250, innerWidth * 0.5) && rect.height > 10) candidate = node;
      if (node.matches('[role="alert"], [role="status"]') && candidate) break;
    }
    if (candidate) candidate.style.setProperty('display', 'none', 'important');
  }
  function flush() {
    scheduled = false;
    for (const root of roots) {
      if (!root.isConnected) continue;
      if (root.nodeType === Node.TEXT_NODE) { hideNotice(root); continue; }
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let text;
      while ((text = walker.nextNode())) hideNotice(text);
    }
    roots.clear();
  }
  function queue(root) {
    roots.add(root);
    if (!scheduled) { scheduled = true; requestAnimationFrame(flush); }
  }
  new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'characterData') queue(record.target);
      else for (const node of record.addedNodes) queue(node);
    }
  }).observe(document, {subtree: true, childList: true, characterData: true});
  document.addEventListener('DOMContentLoaded', () => queue(document.documentElement), {once: true});
  if (document.readyState !== 'loading') queue(document.documentElement);
})();
