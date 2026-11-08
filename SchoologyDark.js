(() => {
  'use strict';
  let host = location.hostname.toLowerCase();
  // TinyMCE/srcdoc editors inherit Schoology's origin but have no hostname.
  if (!host && location.protocol === 'about:') {try {host = parent.location.hostname.toLowerCase();} catch (_) {}}
  if (host !== 'schoology.com' && !host.endsWith('.schoology.com')) return;
  const installed = Symbol.for('webby.schoology.theme');
  if (document[installed]) return;
  document[installed] = true;
  // Supplied lexically by GlassPageInjector, rather than a page-writable global.
  const glass = typeof webbySchoologyGlass !== 'undefined' && webbySchoologyGlass;
  const palette = glass ? {
    page: 'transparent', panel: 'rgba(24,24,24,.10)', raised: 'rgba(32,32,32,.18)',
    field: 'rgba(24,24,24,.24)', menu: 'rgba(18,18,18,.90)', hover: 'rgba(255,255,255,.09)'
  } : {
    page: '#000', panel: '#0d0d0d', raised: '#161616',
    field: '#191919', menu: '#181818', hover: '#222'
  };
  const shell = '#body,#wrapper,#container,#main,#main-inner,#main-content-wrapper,#content-wrapper,#center-wrapper,#center-inner,#center-top,#center-main,#center,#sidebar-left,#left-nav,#right-column,#right-column-inner,#footer,#footer-wrapper,footer';
  const panels = '.sgy-card,.sgy-card-context,#todo,#upcoming-events,.recently-completed-wrapper,.s-card,.card,.panel,.well,.block,.info-box,.feed-item,.feed-post,.s-edge-feed,.course-dashboard,.gradebook-course,[class*="Card-card-data"],[class*="CourseCard-course-card"],.upcoming-events,.recently-completed';
  const menus = '[role="dialog"],[role="menu"],[role="listbox"],dialog,.modal,.modal-content,.popups-box,.popups-body,.popups-title,.ui-dialog,.ui-dialog-content,.ui-dialog-titlebar,.dropdown-menu,.action-links,.s-js-dropdown,.ui-autocomplete,.tooltip,.popover,.popover-content,#TB_window';
  const fields = 'input:not([type="checkbox"]):not([type="radio"]):not([type="range"]):not([type="color"]):not([type="image"]),textarea,select,button,.link-btn,.form-submit,[role="button"]';
  // Course artwork, media, math and icon fonts keep their own rendering. Rich
  // text remains readable through color correction without changing formatting.
  const media = 'img,picture,video,canvas,svg,math,iframe,object,embed,[data-webby-keep-theme]';
  const sides = ['top','right','bottom','left'];
  const fontExcluded = `${media},${media.split(',').map(s => `${s} *`).join(',')},pre,pre *,code,code *,kbd,kbd *,[contenteditable],[contenteditable] *,[class*="icon" i],[class*="icon" i] *,[class*="symbol" i],[class*="symbol" i] *`;
  let css = `
    :root {
      ${Object.entries(palette).map(([key, value]) => `--webby-sgy-${key}:${value};`).join('')}
      --webby-sgy-text:#ededed; --webby-sgy-muted:#a3a3a3; --webby-sgy-line:rgba(160,160,160,.22);
      --webby-sgy-link:#a7caff; --webby-sgy-success:#8cdda5; --webby-sgy-danger:#ff9898; --webby-sgy-warning:#f3cf89;
      --sgy-background-color-default:var(--webby-sgy-page) !important;
      --sgy-font-default:"Webby Geist",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif !important;
      --sgy-font-light:var(--sgy-font-default) !important; --sgy-font-bold:var(--sgy-font-default) !important;
      color-scheme:dark !important;
    }
    html,body {background:var(--webby-sgy-page) !important;color:var(--webby-sgy-text) !important;}
    :where(body,body *):not(:where(${fontExcluded})) {font-family:var(--sgy-font-default) !important;}
    body { -webkit-font-smoothing:antialiased; }
    :is(${shell}) {background-color:transparent !important;color:var(--webby-sgy-text) !important;border-color:var(--webby-sgy-line) !important;}
    #header, #header header, header[role="navigation"], [class*="util-v2-header-background-color"] {
      background-color:var(--webby-sgy-panel) !important;color:var(--webby-sgy-text) !important;border-color:var(--webby-sgy-line) !important;
    }
    :is(${panels}) {background-color:var(--webby-sgy-panel) !important;border-color:var(--webby-sgy-line) !important;color:var(--webby-sgy-text) !important;}
    /* Grade summaries are revealed lazily; theme them before the correction pass. */
    .summary-course {background:var(--webby-sgy-panel) !important;border-color:var(--webby-sgy-line) !important;color:var(--webby-sgy-text) !important;}
    .summary-course .course-grade-wrapper {background:transparent !important;color:var(--webby-sgy-text) !important;}
    .summary-course .course-grade-text {color:var(--webby-sgy-text) !important;}
    .summary-course .no-grade {color:var(--webby-sgy-muted) !important;}
    :is(${menus}) {background-color:var(--webby-sgy-menu) !important;border-color:var(--webby-sgy-line) !important;color:var(--webby-sgy-text) !important;box-shadow:0 12px 36px #0006;}
    :is(${fields}) {background-color:var(--webby-sgy-field) !important;color:var(--webby-sgy-text) !important;border-color:var(--webby-sgy-line) !important;}
    #header svg {color:var(--webby-sgy-text) !important;}
    /* Schoology's shared UI sprites hard-code dark paths. Recolor only those
       monochrome paths; retain their blue accents and all course artwork. */
    symbol[id^="icon-"] :is([fill="#333"],[fill="#333333"],[fill="#444"],[fill="black"]) {fill:var(--webby-sgy-text) !important;}
    /* Header actions and course tiles are surfaces, not filled form buttons. */
    #header :is(button,a), .sgy-card[role="button"], [class*="Card-card-"][role="button"] {background-color:transparent !important;}
    :is(h1,h2,h3,h4,h5,h6,label,legend,.page-title,.course-title,.course-name,.course-dashboard__card-context-title,.sgy-multiline-ellipsis,.sgy-multiline-ellipsis__split-part,[class*="Card-card-data"]) {color:var(--webby-sgy-text) !important;}
    :is(.metadata,.meta,.timestamp,.date,.subtext,.help-block,.help-inline,.max-grade,.secondary-grade,[class*="due-date"],[class*="dueDate"],[class*="event-time"]) {color:var(--webby-sgy-muted) !important;}
    a,a:visited,[role="link"],.title-column.clickable {color:var(--webby-sgy-link) !important;}
    a:hover,[role="link"]:hover {color:#d3e3ff !important;}
    :is(button,.link-btn,[role="button"]):hover, #left-nav a:hover, .item-list li:hover, .report-row:hover > :is(th,td) {background-color:var(--webby-sgy-hover) !important;}
    .active-trail > a,[aria-current="page"],[aria-selected="true"],.tabs .active > a {background-color:var(--webby-sgy-raised) !important;color:var(--webby-sgy-text) !important;}
    :is(input,textarea)::placeholder {color:var(--webby-sgy-muted) !important;opacity:1;}
    option {background:var(--webby-sgy-menu);color:var(--webby-sgy-text);}
    :is(a,button,input,textarea,select,[tabindex]):focus-visible {outline:2px solid var(--webby-sgy-link) !important;outline-offset:3px;}
    :is(input[type="checkbox"],input[type="radio"],progress) {accent-color:var(--webby-sgy-link);}
    .sgy-card {border-radius:12px;overflow:hidden;}
    .sgy-card-context {border-radius:0 0 12px 12px;}
    ::selection {background:#404040;color:#fff;}
    /* Attribute rules cover legacy/hashed classes, inline styles, nested text,
       table cells and generated decorations without painting every nested div. */
    html:root [data-webby-sgy-bg] {background-color:var(--webby-sgy-panel) !important;}
    html:root [data-webby-sgy-bg="page"] {background-color:var(--webby-sgy-page) !important;}
    html:root [data-webby-sgy-bg="clear"] {background-color:transparent !important;}
    html:root [data-webby-sgy-bg="field"] {background-color:var(--webby-sgy-field) !important;}
    html:root [data-webby-sgy-bg="menu"] {background-color:var(--webby-sgy-menu) !important;}
    html:root [data-webby-sgy-ink] {color:var(--webby-sgy-text) !important;}
    ${['muted','link','success','danger','warning'].map(ink => `html:root [data-webby-sgy-ink="${ink}"] {color:var(--webby-sgy-${ink}) !important;}`).join('\n')}
    html:root [data-webby-sgy-ink="dark"] {color:#111 !important;}
    ${sides.map(side => `html:root [data-webby-sgy-border-${side}] {border-${side}-color:var(--webby-sgy-line) !important;}`).join('\n')}
    html:root [data-webby-sgy-gradient] {background-image:none !important;}
    html:root [data-webby-sgy-bg]:is(button,.link-btn,[role="button"]):hover,
    .report-row:hover > :is(th,td)[data-webby-sgy-bg] {background-color:var(--webby-sgy-hover) !important;}
    html:root [data-webby-sgy-shadow] {box-shadow:none !important;text-shadow:none !important;}
    ${['before','after'].map(pseudo => `
      html:root [data-webby-sgy-${pseudo}-bg]::${pseudo} {background-color:var(--webby-sgy-panel) !important;}
      html:root [data-webby-sgy-${pseudo}-ink]::${pseudo} {color:var(--webby-sgy-text) !important;}
      ${sides.map(side => `html:root [data-webby-sgy-${pseudo}-border-${side}]::${pseudo} {border-${side}-color:var(--webby-sgy-line) !important;}`).join('\n')}
      html:root [data-webby-sgy-${pseudo}-gradient]::${pseudo} {background-image:none !important;}
    `).join('\n')}
  `;
  // Legacy rules frequently use IDs plus !important. Give the correction
  // selectors two IDs of specificity without changing IDs in the document.
  css = css.replace(/html:root (\[data-webby-sgy-[^\]]+\])/g,
    'html:root :is(#__webby_sgy_specificity#__webby_sgy_specificity,$1)');
  let sheet, style;
  function install() {
    if (sheet || style || !document.documentElement) return;
    try {
      sheet = new CSSStyleSheet(); sheet.replaceSync(css);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    } catch (_) {
      sheet = null; style = document.createElement('style');style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
    }
  }
  install();

  // New Schoology components use generated class names; a fixed selector list
  // alone misses them. Correct their *painted* colors in small batches, without
  // geometry reads, continuous polling, filters, or touching image pixels.
  const skip = `${media},head,script,style,link,meta,noscript,template`;
  const paintAttrs = ['bg','ink','gradient',...sides.map(s => `border-${s}`)];
  const attrs = [...paintAttrs,'shadow', ...['before','after'].flatMap(p => paintAttrs.map(k => `${p}-${k}`))];
  const ownStyle = new WeakMap(), inlineEdits = new WeakMap();
  const jobs = [], queued = new WeakSet(), seen = new WeakSet();
  let scheduled = false, dirty = false, started = false, refreshTimer;
  const structural = /^(body|wrapper|container|main|main-inner|main-content-wrapper|content-wrapper|center-wrapper|center-inner|center-top|center-main|center|sidebar-left|left-nav|right-column|right-column-inner|footer|footer-wrapper)$/;
  function rgb(value) {
    const m = /^rgba?\(([^)]+)\)$/.exec(value);
    if (!m) return null;
    const v = m[1].split(/[,\s/]+/).filter(Boolean).map(Number);
    return v.length >= 3 ? [v[0],v[1],v[2],v[3] ?? 1] : null;
  }
  function neutral(c) {return c && Math.max(...c.slice(0,3))-Math.min(...c.slice(0,3)) < 42;}
  function light(c) {return c[0]*.2126+c[1]*.7152+c[2]*.0722;}
  function ink(c, bg) {
    if (!c || c[3] < .05) return null;
    if (bg && bg[3] > .5 && !neutral(bg) && light(bg) > 150) return 'dark';
    if (light(c) > 175) return null;
    if (neutral(c)) return light(c) >= 105 ? 'muted' : 'text';
    if (c[1] > c[0]*1.2 && c[1] > c[2]*1.1) return 'success';
    if (c[0] > c[1]*1.4 && c[0] > c[2]*1.15) return 'danger';
    if (c[0] > c[2]*1.4 && c[1] > c[2]*1.2) return 'warning';
    return 'link';
  }
  function enqueue(element, force = false) {
    if (!(element instanceof Element) || queued.has(element) || element.closest(skip)) return;
    queued.add(element);jobs.push({element,force,entered:false,child:null});schedule();
  }
  function schedule() {
    if (scheduled || document.hidden || !started) return;
    scheduled = true;requestAnimationFrame(flush);
  }
  function prepare(element) {
    // Temporarily restore only inline properties still owned by this script.
    // Page edits win; style mutations caused by us never re-enqueue themselves.
    const edits = inlineEdits.get(element);
    if (edits) for (const [property, saved] of edits) {
      if (element.style.getPropertyValue(property) === saved.output) {
        if (saved.value) element.style.setProperty(property,saved.value,saved.priority);
        else element.style.removeProperty(property);
      }
    }
    inlineEdits.delete(element);
    for (const attr of attrs) element.removeAttribute(`data-webby-sgy-${attr}`);
  }
  function borders(style) {
    return sides.filter(side => {
      const color = rgb(style.getPropertyValue(`border-${side}-color`));
      return neutral(color) && color[3] > .025 && style.getPropertyValue(`border-${side}-style`) !== 'none';
    });
  }
  function measure(element) {
    const s = getComputedStyle(element), bg = rgb(s.backgroundColor);
    let surface = element === document.documentElement || element === document.body ? 'page' : null;
    if (element !== document.documentElement && element !== document.body && bg && bg[3] > .025 && neutral(bg)) {
      surface = structural.test(element.id) || /^(thead|tbody|tr|th|td)$/.test(element.localName) || element.matches('.sgy-card[role="button"],#header button,#header a') ? 'clear' :
        element.matches(menus) ? 'menu' : element.matches(fields) ? 'field' : 'panel';
    }
    const pseudos = ['before','after'].map(p => {
      const ps = getComputedStyle(element,`::${p}`);
      if (!ps.content || ps.content === 'none' || ps.content === 'normal') return null;
      return {p,bg:neutral(rgb(ps.backgroundColor)) && rgb(ps.backgroundColor)[3]>.025,
        ink:!!ink(rgb(ps.color),null),borders:borders(ps),
        gradient:ps.backgroundImage.includes('gradient(') && !ps.backgroundImage.includes('url(')};
    });
    return {element,surface,ink:ink(rgb(s.color),bg), borders:borders(s),
      gradient:s.backgroundImage.includes('gradient(') && !s.backgroundImage.includes('url('),
      shadow:(s.boxShadow !== 'none' || s.textShadow !== 'none') && !element.matches(menus),pseudos,
      // Do not replace course art/sprite background images. The neutral fill
      // behind an image is corrected separately.
      inlineImportant:['background-color','color','background-image',...sides.map(s => `border-${s}-color`)].filter(p => element.style.getPropertyPriority(p) === 'important')};
  }
  function apply(plan) {
    const e = plan.element;
    const values = {bg:plan.surface,ink:plan.ink,gradient:plan.gradient,shadow:plan.shadow};
    for (const side of plan.borders) values[`border-${side}`] = true;
    for (const pseudo of plan.pseudos) if (pseudo) {
      for (const k of ['bg','ink','gradient']) values[`${pseudo.p}-${k}`] = pseudo[k];
      for (const side of pseudo.borders) values[`${pseudo.p}-border-${side}`] = true;
    }
    for (const [key,value] of Object.entries(values)) if (value) e.setAttribute(`data-webby-sgy-${key}`,value === true ? '' : value);
    const replacements = {
      'background-color':plan.surface ? (plan.surface === 'clear' ? 'transparent' : `var(--webby-sgy-${plan.surface === 'panel' ? 'panel' : plan.surface})`) : null,
      color:plan.ink ? (plan.ink === 'dark' ? '#111' : `var(--webby-sgy-${plan.ink})`) : null,
      'background-image':plan.gradient ? 'none' : null
    };
    for (const side of plan.borders) replacements[`border-${side}-color`] = 'var(--webby-sgy-line)';
    const edits = new Map();
    for (const property of plan.inlineImportant) if (replacements[property]) {
      const value = e.style.getPropertyValue(property),priority = e.style.getPropertyPriority(property);
      e.style.setProperty(property,replacements[property],'important');
      edits.set(property,{value,priority,output:e.style.getPropertyValue(property)});
    }
    if (edits.size) inlineEdits.set(e,edits);
    ownStyle.set(e,e.getAttribute('style'));
  }
  function flush() {
    scheduled = false;
    if (document.hidden) {dirty = true;return;}
    const batch = [], deadline = performance.now()+2;
    let steps = 0;
    while (jobs.length && steps++ < 80 && performance.now() < deadline) {
      const job = jobs[jobs.length-1],e = job.element;
      if (!e.isConnected || e.closest(skip)) {jobs.pop();queued.delete(e);continue;}
      if (!job.entered) {
        job.entered = true;job.child = e.firstElementChild;
        if (job.force || !seen.has(e)) {seen.add(e);prepare(e);batch.push(e);}
      } else if (job.child) {
        const child = job.child;job.child = child.nextElementSibling;
        if (child.parentElement === e) enqueue(child,job.force);
      } else {jobs.pop();queued.delete(e);}
    }
    // Read every style in the batch before writing the resulting attributes.
    batch.map(measure).forEach(apply);
    if (jobs.length) schedule();
  }
  function refresh() {
    if (refreshTimer) return;
    refreshTimer = setTimeout(() => {refreshTimer = null;install();enqueue(document.documentElement,true);},60);
  }
  const observer = new MutationObserver(records => {
    if (document.hidden) {dirty = true;return;}
    for (const r of records) {
      if (r.type === 'childList') {
        if (r.target === style) continue;
        if (r.target.localName === 'style') {refresh();continue;}
        for (const node of r.addedNodes) {
          if (node instanceof Element && node.matches('style,link[rel~="stylesheet"]')) refresh();
          else enqueue(node);
        }
      } else if (r.attributeName !== 'style' || ownStyle.get(r.target) !== r.target.getAttribute('style')) {
        enqueue(r.target,true);
      }
    }
    if (style && !style.isConnected) (document.head || document.documentElement)?.appendChild(style);
  });
  observer.observe(document,{subtree:true,childList:true,attributes:true,attributeFilter:['style','class','open','aria-expanded','aria-selected']});
  function ready() {install();started = true;enqueue(document.documentElement,true);}
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();
  document.addEventListener('load',e => {if (e.target.matches?.('link[rel~="stylesheet"]')) refresh();},true);
  window.addEventListener('load',refresh,{once:true});
  document.addEventListener('visibilitychange',() => {if (!document.hidden) {if (dirty) {dirty=false;refresh();}schedule();}});
  for (const event of ['mouseover','mouseout','focusin','focusout']) document.addEventListener(event,e => {if (e.target instanceof Element) enqueue(e.target,true);},true);
})();
