(() => {
  if (window.__webKitBrowserVideoControl) return;
  window.__webKitBrowserVideoControl = true;

  let button;
  let video;
  let hideTimer;
  let frame = 0;
  let pointerX = -1;
  let pointerY = -1;

  // Called by the host before a tab/profile becomes hidden. WebKit's native
  // picture-in-picture stays visible across the browser and other macOS apps.
  window.__webbyFollowPlayingVideo = () => {
    const playing = [...document.querySelectorAll('video')].find(candidate =>
      !candidate.paused && !candidate.ended && candidate.readyState >= 2 &&
      candidate.videoWidth >= 120 && candidate.videoHeight >= 70);
    if (!playing || document.pictureInPictureElement === playing ||
        playing.webkitPresentationMode === 'picture-in-picture') return false;
    try {
      if (playing.webkitSupportsPresentationMode?.('picture-in-picture')) {
        playing.webkitSetPresentationMode('picture-in-picture');
      } else if (typeof playing.requestPictureInPicture === 'function') {
        Promise.resolve(playing.requestPictureInPicture()).catch(() => {});
      } else return false;
      return true;
    } catch (_) { return false; }
  };
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) window.__webbyFollowPlayingVideo();
  });

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
    button.addEventListener('click', event => {
      event.preventDefault();
      event.stopPropagation();
      const selected = video;
      if (!selected || !selected.isConnected) return;
      try {
        if (selected.webkitSupportsPresentationMode?.('picture-in-picture') &&
            typeof selected.webkitSetPresentationMode === 'function') {
          selected.webkitSetPresentationMode('picture-in-picture');
        } else if (typeof selected.requestPictureInPicture === 'function') {
          Promise.resolve(selected.requestPictureInPicture()).catch(() => {
            button.title = 'This site does not allow pop-out video';
          });
        } else {
          button.title = 'This site does not allow pop-out video';
        }
      } catch (_) {
        button.title = 'This site does not allow pop-out video';
      }
      button.style.display = 'none';
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
    if (!button) return;
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
