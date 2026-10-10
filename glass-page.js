(() => {
  'use strict';

  // One document stylesheet changes only surfaces selected below. Native AppKit
  // supplies the blur; this script never adds a per-element backdrop filter.
  const selector = 'data-webby-glass-surface';
  const variable = '--webby-glass-color';
  const css = `html, body { background-color: transparent !important; }
    [${selector}] { background-color: var(${variable}) !important; }`;
  const style = document.createElement('style');
  style.textContent = css;
  (document.head || document.documentElement)?.appendChild(style);

  const processed = new WeakSet();
  const ownStyle = new WeakMap();
  const pending = new Set();
  const forced = new WeakSet();
  const trees = [];
  let scheduled = false;

  const media = 'img, picture, video, canvas, svg, iframe, object, embed, pre, code';
  const dialogWords = /(?:^|[\s_-])(dialog|modal|popover|popup|menu|dropdown|tooltip|overlay)(?:$|[\s_-])/i;
  const structuralWords = /(?:^|[\s_-])(root|app|page|layout|wrapper|container|sidebar|navbar|header|footer|content|shell)(?:$|[\s_-])/i;
  const cardWords = /(?:^|[\s_-])(card|panel|tile|surface|sheet|field|input|button|toolbar)(?:$|[\s_-])/i;

  const colorCanvas = document.createElement('canvas');
  colorCanvas.width = colorCanvas.height = 1;
  const colorContext = colorCanvas.getContext('2d', { willReadFrequently: true });
  const colorCache = new Map();

  function colorParts(value) {
    const match = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+))?\s*\)$/i.exec(value);
    if (!match) {
      // Modern CSS colors (oklch, oklab and color(srgb)) are common in app shells.
      // Let WebKit convert them to sRGB rather than silently leaving them opaque.
      if (!colorContext) return null;
      if (colorCache.has(value)) return colorCache.get(value);
      colorContext.clearRect(0, 0, 1, 1);
      colorContext.fillStyle = 'transparent';
      colorContext.fillStyle = value;
      colorContext.fillRect(0, 0, 1, 1);
      const pixel = colorContext.getImageData(0, 0, 1, 1).data;
      const parts = [pixel[0], pixel[1], pixel[2], pixel[3] / 255];
      if (colorCache.size >= 256) colorCache.clear();
      colorCache.set(value, parts);
      return parts;
    }
    return [Number(match[1]), Number(match[2]), Number(match[3]),
      match[4] === undefined ? 1 : Number(match[4])];
  }

  function surfaceAlpha(element) {
    const tag = element.localName;
    if (tag === 'html' || tag === 'body') return 0;
    if (element.closest(media)) return null;

    const role = element.getAttribute('role') || '';
    const names = `${element.id} ${typeof element.className === 'string' ? element.className : ''} ${role}`;
    const rect = element.getBoundingClientRect();
    if (rect.width < 20 || rect.height < 14) return null;
    const viewport = Math.max(1, innerWidth * innerHeight);
    const area = rect.width * rect.height;
    const modal = tag === 'dialog' || element.matches('[aria-modal="true"], [role="dialog"], [role="menu"]') || dialogWords.test(names);
    if (modal) return 0.28;

    const pageRoot = element.parentElement === document.body && area > viewport * 0.55;
    if (pageRoot) return 0;
    const structural = /^(main|nav|aside|header|footer|section)$/.test(tag) || structuralWords.test(names);
    if (structural || area > viewport * 0.35) return area > viewport * 0.75 ? 0.05 : 0.09;
    const control = /^(input|textarea|select|button)$/.test(tag);
    if (control || cardWords.test(names) || area > 4800) return 0.15;
    return null;
  }

  function process(element, force) {
    if (!element.isConnected || element === style || (!force && processed.has(element))) return;
    processed.add(element);
    const root = element === document.documentElement || element === document.body;
    if (!root && element.closest(media)) return;

    const previouslyMarked = element.hasAttribute(selector);
    if (previouslyMarked) element.removeAttribute(selector);
    const computed = getComputedStyle(element);
    const parts = colorParts(computed.backgroundColor);
    const targetAlpha = root ? 0 : parts && parts[3] > 0.015 ? surfaceAlpha(element) : null;
    if (targetAlpha === null) {
      if (previouslyMarked) {
        element.style.removeProperty(variable);
        ownStyle.set(element, element.getAttribute('style'));
      }
      return;
    }

    const alpha = root ? 0 : Math.min(parts[3], targetAlpha);
    const color = root ? 'rgba(0, 0, 0, 0)'
      : `rgba(${parts[0]}, ${parts[1]}, ${parts[2]}, ${alpha})`;
    element.style.setProperty(variable, color);
    ownStyle.set(element, element.getAttribute('style'));
    element.setAttribute(selector, '');
  }

  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(flush);
  }

  function queueOne(element, force = false) {
    if (!(element instanceof Element) || element === style) return;
    if (force) forced.add(element);
    pending.add(element);
    schedule();
  }

  function queueTree(node, force = false) {
    if (!(node instanceof Element)) return;
    trees.push({ element: node, force });
    schedule();
  }

  function flush() {
    scheduled = false;
    let budget = 180;
    while (budget > 0 && (pending.size || trees.length)) {
      if (pending.size) {
        const element = pending.values().next().value;
        pending.delete(element);
        const force = forced.has(element);
        forced.delete(element);
        process(element, force);
      } else {
        const { element, force } = trees.pop();
        // Added subtrees are walked once, within the per-frame budget.
        for (let child = element.lastElementChild; child; child = child.previousElementSibling) {
          trees.push({ element: child, force });
        }
        process(element, force);
      }
      budget--;
    }
    if (pending.size || trees.length) schedule();
  }

  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'childList') {
        for (const node of record.addedNodes) queueTree(node);
      } else if (record.target instanceof Element) {
        const element = record.target;
        if (record.attributeName === 'style' && ownStyle.get(element) === element.getAttribute('style')) continue;
        if (element === document.documentElement || element === document.body) {
          queueTree(document.documentElement, true);
        } else {
          queueOne(element, true);
        }
      }
    }
    if (!style.isConnected) (document.head || document.documentElement)?.appendChild(style);
  });
  observer.observe(document, {
    subtree: true, childList: true, attributes: true,
    attributeFilter: ['class', 'style', 'role', 'aria-modal', 'open']
  });

  function processPageShell() {
    // Clear the few broad surfaces before the frame-batched deep walk. This
    // prevents an opaque app wrapper from flashing over the native material.
    const shallow = [{ element: document.documentElement, depth: 0 }];
    let count = 0;
    while (shallow.length && count < 32) {
      const { element, depth } = shallow.shift();
      if (!element) continue;
      process(element, true);
      count++;
      if (depth < 3) {
        for (const child of element.children) shallow.push({ element: child, depth: depth + 1 });
      }
    }
  }

  if (document.documentElement) {
    processPageShell();
    queueTree(document.documentElement);
  }
  // The document-start pass can run before a page's stylesheets exist. Recheck
  // once after parsing, when blocking stylesheets have been applied.
  document.addEventListener('DOMContentLoaded', () => {
    processPageShell();
    queueTree(document.documentElement, true);
  }, { once: true });
  window.addEventListener('load', () => {
    processPageShell();
    queueTree(document.documentElement, true);
  }, { once: true });
  // Hover/focus colors can change without DOM mutations. Only revisit the
  // directly interactive target; no document-wide polling is used.
  document.addEventListener('mouseover', event => queueOne(event.target, true), true);
  document.addEventListener('focusin', event => queueOne(event.target, true), true);
})();
