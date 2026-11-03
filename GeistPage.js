/* Webby local Geist v1 */
(() => {
  'use strict';
  if (globalThis.__webbySetGeist) return;
  // CSS handles new DOM content automatically. No tree walks, observers or timers.
  const excluded = 'pre,pre *,code,code *,kbd,kbd *,samp,samp *,svg,svg *,math,math *,[class*="icon" i],[class*="icon" i] *,[class*="symbol" i],[class*="symbol" i] *,[class*="monaco" i],[class*="monaco" i] *,[class*="cm-"],[class*="cm-"] *,[class*="ace_"],[class*="ace_"] *,[data-webby-keep-font],[data-webby-keep-font] *';
  const css = `:where(html,body,body *):not(:where(${excluded})) { font-family: "Webby Geist", system-ui, sans-serif !important; }`;
  let sheet, style, loaded;
  let enabled = false;
  const ready = () => document.documentElement || document.head;
  function installStyle() {
    if (sheet || style || !ready()) return;
    try {
      sheet = new CSSStyleSheet(); sheet.replaceSync(css);
      // Constructed sheets also work on sites that disallow inline <style> tags.
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    } catch (_) {
      sheet = null; style = document.createElement('style');
      style.textContent = css; ready().appendChild(style);
    }
  }
  function font(bytes, italic) {
    // Native base64 decoding when available, with a bounded-allocation fallback.
    // Uint8Array.from(string, callback) otherwise invokes JS for every font byte.
    let data;
    if (typeof Uint8Array.fromBase64 === 'function') data = Uint8Array.fromBase64(bytes);
    else {
      const decoded = atob(bytes); data = new Uint8Array(decoded.length);
      for (let i = 0; i < decoded.length; i++) data[i] = decoded.charCodeAt(i);
    }
    const face = new FontFace('Webby Geist', data, {weight:'100 900',style:italic ? 'italic' : 'normal',display:'swap'});
    document.fonts.add(face);
    return face.load();
  }
  globalThis.__webbySetGeist = value => {
    enabled = !!value;
    if (enabled && !loaded) {
      // Font bytes come from the user's local download, bundled with Webby.
      loaded = new Promise(resolve => {
        const start = () => {
          const bridge = globalThis.webkit?.messageHandlers?.webbyGeistFont;
          if (!bridge) { resolve(Promise.reject(new Error('Local typography unavailable'))); return; }
          resolve(Promise.all([
            bridge.postMessage('regular').then(bytes => font(bytes, false)),
            bridge.postMessage('italic').then(bytes => font(bytes, true))
          ]));
        };
        // Yield a paint/input opportunity; hidden frames do not decode until shown.
        if (document.hidden) {
          const visible = () => { if (!document.hidden) { document.removeEventListener('visibilitychange',visible); requestAnimationFrame(() => setTimeout(start,0)); } };
          document.addEventListener('visibilitychange',visible);
        } else requestAnimationFrame(() => setTimeout(start,0));
      });
      loaded.then(() => { if (enabled) {installStyle(); if (sheet) sheet.disabled=false; if (style) style.disabled=false;} }).catch(() => {});
    }
    if (sheet) sheet.disabled = !enabled;
    if (style) style.disabled = !enabled;
    for (let i=0;i<window.frames.length;i++) {
      try {window.frames[i].postMessage({webbyGeistEnabled:enabled}, '*');} catch (_) {}
    }
  };
  window.addEventListener('message', event => {
    if (event.source === window.parent && event.source !== window && typeof event.data?.webbyGeistEnabled === 'boolean')
      globalThis.__webbySetGeist(event.data.webbyGeistEnabled);
  });
  document.addEventListener('DOMContentLoaded', () => {if (enabled && loaded) loaded.then(() => {if(enabled) installStyle();}).catch(() => {});}, {once:true});
})();
