(() => {
  if (window.__webbyVideoControlsInstalled) return;
  window.__webbyVideoControlsInstalled = true;

  let button;
  let video;
  let hideTimer;
  let frame = 0;
  let pointerX = -1;
  let pointerY = -1;
  let opening = false;

  const isInPiP = candidate =>
    document.pictureInPictureElement === candidate ||
    candidate.webkitPresentationMode === 'picture-in-picture';

  // Changing tabs is not a user gesture. This remains best effort; the visible
  // button is the reliable gesture path, with a Floating fallback on failure.
  window.__webbyFollowPlayingVideo = () => {
    const playing = [...document.querySelectorAll('video')].find(candidate =>
      !candidate.paused && !candidate.ended && candidate.readyState >= 2 &&
      candidate.videoWidth >= 120 && candidate.videoHeight >= 70);
    if (!playing || isInPiP(playing)) return false;
    try {
      if (typeof playing.requestPictureInPicture === 'function') {
        Promise.resolve(playing.requestPictureInPicture()).catch(() => {});
        return true;
      }
      if (playing.webkitSupportsPresentationMode?.('picture-in-picture') &&
          typeof playing.webkitSetPresentationMode === 'function') {
        playing.webkitSetPresentationMode('picture-in-picture');
        return true;
      }
    } catch (_) { /* WebKit requires a real gesture on many pages. */ }
    return false;
  };

  function floatingFallback() {
    // Only Webby's isolated content world has this native message handler.
    // A protected player cannot be moved into another WKWebView, so keep its
    // original tab and media session in the Floating window instead.
    try {
      window.webkit.messageHandlers.browserVideoFloat.postMessage('video-pip-fallback');
    } catch (_) {
      if (button) {
        button.title = 'Picture in Picture is unavailable for this video';
        button.style.display = 'block';
      }
    }
  }

  async function openPiP(candidate) {
    if (isInPiP(candidate)) return true;
    if (typeof candidate.requestPictureInPicture === 'function') {
      const request = candidate.requestPictureInPicture();
      await Promise.race([
        request,
        new Promise((_, reject) => setTimeout(() => reject(new Error('PiP timed out')), 1200))
      ]);
    } else if (candidate.webkitSupportsPresentationMode?.('picture-in-picture') &&
               typeof candidate.webkitSetPresentationMode === 'function') {
      candidate.webkitSetPresentationMode('picture-in-picture');
    } else {
      return false;
    }
    // The prefixed API returns void before the native player is visible.
    // Never treat that return as success without checking the actual mode.
    if (isInPiP(candidate)) return true;
    await new Promise(resolve => setTimeout(resolve, 350));
    return isInPiP(candidate);
  }

  function ensureButton() {
    if (button?.isConnected || !document.documentElement) return;
    button = document.createElement('button');
    button.type = 'button';
    button.textContent = '▣';
    button.setAttribute('aria-label', 'Pop out video');
    button.title = 'Pop out video';
    button.style.cssText = [
      'all:initial', 'position:fixed', 'display:none', 'box-sizing:border-box',
      'width:36px', 'height:30px', 'border-radius:8px',
      'background:rgba(20,22,28,.85)', 'border:1px solid rgba(255,255,255,.42)',
      'color:#fff', 'font:20px system-ui', 'text-align:center', 'line-height:27px',
      'cursor:pointer', 'z-index:2147483647', 'box-shadow:0 3px 12px rgba(0,0,0,.38)'
    ].join(';');
    button.addEventListener('pointerdown', event => event.stopPropagation());
    button.addEventListener('click', async event => {
      event.preventDefault();
      event.stopPropagation();
      const selected = video;
      if (!selected?.isConnected || opening) return;
      opening = true;
      button.title = 'Opening Picture in Picture…';
      try {
        // Call the API directly from the click handler, before any await,
        // while WebKit still has transient user activation.
        if (await openPiP(selected)) {
          button.style.display = 'none';
          button.title = 'Pop out video';
        } else {
          floatingFallback();
        }
      } catch (_) {
        floatingFallback();
      } finally {
        opening = false;
      }
    });
    document.documentElement.appendChild(button);
  }

  function candidateAt(x, y) {
    for (const candidate of document.querySelectorAll('video')) {
      const rect = candidate.getBoundingClientRect();
      if (rect.width < 120 || rect.height < 70) continue;
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
        return candidate;
      }
    }
    return null;
  }

  function position() {
    frame = 0;
    ensureButton();
    if (!button || opening) return;
    const selected = candidateAt(pointerX, pointerY);
    if (!selected) {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => { button.style.display = 'none'; video = null; }, 600);
      return;
    }
    clearTimeout(hideTimer);
    video = selected;
    const rect = selected.getBoundingClientRect();
    button.style.left = Math.max(0, Math.min(innerWidth - 38, rect.right - 46)) + 'px';
    button.style.top = Math.max(0, Math.min(innerHeight - 32, rect.top + 10)) + 'px';
    button.style.display = 'block';
  }

  document.addEventListener('pointermove', event => {
    pointerX = event.clientX;
    pointerY = event.clientY;
    if (!frame) frame = requestAnimationFrame(position);
  }, { passive: true, capture: true });
  document.addEventListener('scroll', () => { if (button) button.style.display = 'none'; }, true);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden && button) button.style.display = 'none';
  });
})();
