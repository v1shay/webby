(() => {
  'use strict';

  // One document stylesheet changes only surfaces selected below. Native AppKit
  // supplies the blur; this script never adds a per-element backdrop filter.
  const selector = 'data-webby-glass-surface';
  const variable = '--webby-glass-color';
  const css = `html, body { background-color: transparent !important; }
    [${selector}] { background-color: var(${variable}) !important; }
    [data-webby-glass-text] { color: rgba(238, 241, 244, 0.94) !important; }
    [data-webby-glass-gradient] { background-image: none !important; }`;
  const style = document.createElement('style');
  style.textContent = css;
  (document.head || document.documentElement)?.appendChild(style);

  const processed = new WeakSet();
  const ownStyle = new WeakMap();
  const pending = new Set();
  const forced = new WeakSet();
  const trees = [];
  const queuedTrees = new WeakMap();
  const rootAttributes = new WeakMap();
  let hiddenDirty = false;
  let scheduled = false;
  let batchLimit = 32;
  let documentRefreshTimer = null;
  let startupReady = document.readyState !== 'loading';
  let stylesheetSignature = '';
  const mainFrame = window === window.top;
  let interactingUntil = 0;

  const media = 'img, picture, video, canvas, svg, iframe, object, embed, pre, code';
  const nonvisual = 'head, script, style, link, meta, title, noscript, template';
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

  function surfaceAlpha(element, rect) {
    const tag = element.localName;
    if (tag === 'html' || tag === 'body') return 0;
    if (element.closest(media)) return null;

    const role = element.getAttribute('role') || '';
    const names = `${element.id} ${typeof element.className === 'string' ? element.className : ''} ${role}`;
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

  function prepare(element, force) {
    if (!element.isConnected || element === style || (!force && processed.has(element))) return false;
    processed.add(element);
    const root = element === document.documentElement || element === document.body;
    if (!root && (element.matches(nonvisual) || element.closest(media))) return false;
    const marked = element.hasAttribute(selector);
    element.removeAttribute('data-webby-glass-text');
    element.removeAttribute('data-webby-glass-gradient');
    if (marked) element.removeAttribute(selector);
    return { element, root, marked };
  }

  function measure(plan) {
    const { element, root } = plan;
    const computed = getComputedStyle(element);
    const foreground = colorParts(computed.color);
    const parts = colorParts(computed.backgroundColor);
    const backgroundImage = computed.backgroundImage;
    const rect = !root && parts && parts[3] > 0.015 ? element.getBoundingClientRect() : null;
    let alpha = root ? 0 : rect ? surfaceAlpha(element, rect) : null;
    const saturated = !root && parts && rect && Math.max(...parts.slice(0, 3)) - Math.min(...parts.slice(0, 3)) >= 40 &&
        rect.width * rect.height < innerWidth * innerHeight * 0.35;
    if (saturated) alpha = null;
    return { ...plan, parts, backgroundImage, alpha,
      lightText: !saturated && foreground && Math.max(...foreground.slice(0, 3)) - Math.min(...foreground.slice(0, 3)) < 32 &&
        foreground[0]*0.2126 + foreground[1]*0.7152 + foreground[2]*0.0722 < 135 };
  }

  function apply(plan) {
    const { element, root, marked, parts, backgroundImage, alpha, lightText } = plan;
    if (lightText) element.setAttribute('data-webby-glass-text', '');
    if (alpha === null) {
      if (marked) {
        element.style.removeProperty(variable);
        ownStyle.set(element, element.getAttribute('style'));
      }
      return;
    }
    const color = root ? 'rgba(0, 0, 0, 0)' : `rgba(42, 47, 51, ${Math.min(parts[3], alpha)})`;
    if (!root && backgroundImage.includes('gradient(') && !backgroundImage.includes('url(')) {
      element.setAttribute('data-webby-glass-gradient', '');
    }
    element.style.setProperty(variable, color);
    ownStyle.set(element, element.getAttribute('style'));
    element.setAttribute(selector, '');
  }

  function process(element, force) {
    const plan = prepare(element, force);
    if (plan) apply(measure(plan));
  }

  function schedule() {
    if (scheduled || document.hidden) return;
    scheduled = true;
    requestAnimationFrame(flush);
  }

  function queueOne(element, force = false) {
    if (!(element instanceof Element) || element === style) return;
    if (force) forced.add(element);
    pending.add(element);
    schedule();
  }

  function enqueueTree(node, force) {
    if (!(node instanceof Element) || node.matches(`${media},${nonvisual}`)) return;
    const existing = queuedTrees.get(node);
    if (existing) { existing.force ||= force; return; }
    const job = { element: node, force };
    queuedTrees.set(node, job);
    trees.push(job);
  }
  function queueTree(node, force = false) {
    enqueueTree(node, force);
    schedule();
  }

  function flush() {
    scheduled = false;
    if (document.hidden) { hiddenDirty = true; return; }
    const began = performance.now();
    let budget = Math.min(batchLimit, began < interactingUntil ? 8 : 64);
    const deadline = began + 4;
    const batch = [];
    while (budget > 0 && performance.now() < deadline && (pending.size || trees.length)) {
      if (pending.size) {
        const element = pending.values().next().value;
        pending.delete(element);
        const force = forced.has(element);
        forced.delete(element);
        const plan = prepare(element, force);
        if (plan) batch.push(plan);
      } else {
        const { element, force } = trees.pop();
        queuedTrees.delete(element);
        if (!element.isConnected) continue;
        // Added subtrees are walked once, within the per-frame budget.
        if (mainFrame) {
          for (let child = element.lastElementChild; child; child = child.previousElementSibling) enqueueTree(child, force);
        }
        const plan = prepare(element, force);
        if (plan) batch.push(plan);
      }
      budget--;
    }
    const measurements = batch.map(measure);
    measurements.forEach(apply);
    // Adapt using the complete prepare/read/write cost, not preparation alone.
    const elapsed = performance.now() - began;
    if (elapsed > 0.25) {
      const wanted = Math.max(4, Math.min(64, Math.floor(Math.max(1, batch.length) * 4 / elapsed)));
      batchLimit = Math.max(4, Math.round(batchLimit * 0.5 + wanted * 0.5));
    }
    if (pending.size || trees.length) schedule();
  }

  function refreshDocument() {
    if (documentRefreshTimer !== null) return;
    documentRefreshTimer = setTimeout(() => {
      documentRefreshTimer = null;
      processPageShell();
      queueTree(document.documentElement, true);
    }, 80);
  }
  function styleSignature() {
    return [...document.styleSheets].filter(sheet => sheet.ownerNode !== style).map(sheet => {
      let rules = '';
      try { rules = sheet.cssRules.length; } catch (_) {}
      return `${sheet.href || ''}:${sheet.disabled}:${rules}`;
    }).join('|');
  }

  const observer = new MutationObserver(records => {
    if (document.hidden) { hiddenDirty = true; return; }
    for (const record of records) {
      if (record.type === 'childList') {
        if (!mainFrame || !startupReady) continue;
        if (record.target.localName === 'style') refreshDocument();
        for (const node of record.addedNodes) {
          if (node instanceof Element && node.matches('style,link[rel~=stylesheet]')) refreshDocument();
          else queueTree(node);
        }
      } else if (record.target instanceof Element) {
        const element = record.target;
        if (record.attributeName === 'style' && ownStyle.get(element) === element.getAttribute('style')) continue;
        if (element === document.documentElement || element === document.body) {
          const attributes = rootAttributes.get(element) || new Map();
          const current = element.getAttribute(record.attributeName);
          if (attributes.has(record.attributeName) && attributes.get(record.attributeName) === current) continue;
          attributes.set(record.attributeName, current); rootAttributes.set(element, attributes);
          queueOne(element, true);
          if (startupReady) refreshDocument();
        } else if (mainFrame && startupReady) {
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

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
      if (hiddenDirty) { hiddenDirty = false; queueTree(document.documentElement, true); }
      schedule();
    }
  });

  function processPageShell() {
    const shallow = [{ element: document.documentElement, depth: 0 }];
    const batch = [];
    while (shallow.length && batch.length < (mainFrame ? 24 : 8)) {
      const { element, depth } = shallow.shift();
      if (!element || element.matches(`${media},${nonvisual}`)) continue;
      const plan = prepare(element, true);
      if (plan) batch.push(plan);
      if (depth < 2) {
        for (const child of element.children) shallow.push({ element: child, depth: depth + 1 });
      }
    }
    batch.map(measure).forEach(apply);
  }

  if (document.documentElement) processPageShell();
  function ready() {
    startupReady = true;
    stylesheetSignature = styleSignature();
    refreshDocument();
  }
  if (startupReady) ready();
  else document.addEventListener('DOMContentLoaded', ready, { once: true });
  window.addEventListener('load', () => {
    const current = styleSignature();
    if (current !== stylesheetSignature) { stylesheetSignature = current; refreshDocument(); }
  }, { once: true });
  // Async stylesheets can arrive after DOMContentLoaded. Recheck only on change.
  document.addEventListener('load', event => {
    if (event.target instanceof HTMLLinkElement && event.target.relList.contains('stylesheet')) {
      const current = styleSignature();
      if (startupReady && current !== stylesheetSignature) { stylesheetSignature = current; refreshDocument(); }
    }
  }, true);
  for (const name of ['wheel', 'pointerdown', 'keydown']) {
    document.addEventListener(name, () => { interactingUntil = performance.now() + 80; }, { passive: true, capture: true });
  }
  // Hover/focus colors can change without DOM mutations. Only revisit the
  // directly interactive target; no document-wide polling is used.
  document.addEventListener('mouseover', event => queueOne(event.target, true), true);
  document.addEventListener('focusin', event => queueOne(event.target, true), true);
})();
