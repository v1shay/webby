(() => {
  if (location.protocol !== 'https:') return;
  let queued = false;
  const notified = new WeakSet();
  const selector = 'input[type=password],input[autocomplete="username"],input[type=email][name=identifier]';
  const observer = new MutationObserver(() => {
    if (queued) return;
    queued = true;
    setTimeout(() => { queued = false; check(); }, 120);
  });
  function check() {
    const field = document.querySelector('input[type=password]') || document.querySelector(selector);
    if (!field) return;
    if (!notified.has(field)) {
      notified.add(field);
      window.webkit.messageHandlers.browserPasswordField.postMessage(location.host);
    }
    // Stop watching unrelated mutations once the password step is available.
    // A replacement SPA form is checked on focus; navigation gets a new probe.
    if (field.type === 'password') observer.disconnect();
  }
  observer.observe(document, {childList:true, subtree:true});
  document.addEventListener('focusin', event => {
    if (event.target instanceof Element && event.target.matches(selector)) check();
  }, true);
  window.addEventListener('pageshow', check);
  check();
})();
