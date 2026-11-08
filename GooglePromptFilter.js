(() => {
  'use strict';
  // Hide only Google's browser nags and desktop-notification invitations.
  // Account, security, permission and delivery errors remain visible.
  // Editors share warning containers with title/menu controls. Never modify them.
  if (!/^(mail|calendar|drive|meet)\.google\.com$/i.test(location.hostname)) return;
  const pattern = /(?:this browser (?:version )?is (?:no longer |not )supported|(?:browser|browser version).{0,50}(?:no longer supported|unsupported)|enable desktop notifications for gmail|google chat in gmail doesn.t yet support the browser you.re using)/i;
  const roots = new Set();
  let scheduled = false, walker = null;
  function hideNotice(text) {
    const value = text.nodeValue || '';
    if (value.length > 800 || !pattern.test(value)) return;
    let node = text.parentElement, candidate = null;
    for (let depth = 0; node && depth < 7; depth++, node = node.parentElement) {
      if (/^(body|html|main)$/i.test(node.localName)) break;
      const rect = node.getBoundingClientRect();
      if (rect.height > 150 || (node.textContent || '').length > 1200) break;
      // Stop at the smallest notice-sized element. Climbing farther can
      // select Google Docs' entire title/menu/toolbar container.
      if (rect.width >= Math.min(250, innerWidth * 0.5) && rect.height > 10) {
        candidate = node;
        break;
      }
      if (node.matches('[role="alert"], [role="status"]') && candidate) break;
    }
    if (candidate) candidate.style.setProperty('display', 'none', 'important');
  }
  function schedule() {
    if (scheduled || document.hidden || (!walker && !roots.size)) return;
    scheduled = true;
    requestAnimationFrame(flush);
  }
  function flush() {
    scheduled = false;
    if (document.hidden) return;
    const started = performance.now();
    let visited = 0;
    // Large Gmail updates are spread over frames instead of scanning the whole
    // mailbox in one animation frame. No polling while the page is hidden.
    while (visited < 400 && performance.now() - started < 3) {
      if (!walker) {
        const root = roots.values().next().value;
        if (!root) break;
        roots.delete(root);
        if (!root.isConnected) continue;
        if (root.nodeType === Node.TEXT_NODE) { hideNotice(root); visited++; continue; }
        walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      }
      if (!walker.root.isConnected) { walker = null; continue; }
      const text = walker.nextNode();
      if (!text) { walker = null; continue; }
      hideNotice(text); visited++;
    }
    schedule();
  }
  function queue(root) {
    if (!root.isConnected) return;
    // Keep hidden tabs and mutation storms bounded. A later document scan
    // covers the discarded individual roots without retaining detached trees.
    if (roots.has(document.documentElement)) return;
    roots.add(root);
    if (roots.size > 128) { roots.clear(); roots.add(document.documentElement); }
    schedule();
  }
  document.addEventListener('visibilitychange', schedule);
  new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'characterData') queue(record.target);
      else for (const node of record.addedNodes) queue(node);
    }
  }).observe(document, {subtree: true, childList: true, characterData: true});
  document.addEventListener('DOMContentLoaded', () => queue(document.documentElement), {once: true});
  if (document.readyState !== 'loading') queue(document.documentElement);
})();
