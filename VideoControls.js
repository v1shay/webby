(() => {
  if (window.__webbyVideoControlsInstalled) return;
  window.__webbyVideoControlsInstalled = true;

  let controls, selected, presentedVideo, hideTimer, frame = 0, opening = false;
  let pointerX = -1, pointerY = -1, pointerRoots = [];
  const inPiP = video => document.pictureInPictureElement === video ||
    video.webkitPresentationMode === 'picture-in-picture';
  const inFullscreen = video => document.fullscreenElement === video ||
    document.webkitFullscreenElement === video || video.webkitPresentationMode === 'fullscreen';
  const supportsNativePiP = video => typeof video.webkitSetPresentationMode === 'function' &&
    video.webkitSupportsPresentationMode?.('picture-in-picture');

  // Presentation never replaces the element, copies its URL, changes volume, seeks,
  // or calls load(). Native controls and the website therefore share one media session.
  function enterPiP(video) {
    presentedVideo = video;
    if (inPiP(video)) return Promise.resolve();
    if (supportsNativePiP(video)) {
      video.webkitSetPresentationMode('picture-in-picture');
      return Promise.resolve();
    }
    if (typeof video.requestPictureInPicture === 'function' && document.pictureInPictureEnabled !== false) {
      return video.requestPictureInPicture();
    }
    throw new Error('Picture in Picture is unavailable for this video');
  }

  function enterFullscreen(video) {
    if (inFullscreen(video)) return Promise.resolve();
    if (typeof video.requestFullscreen === 'function' && document.fullscreenEnabled !== false) {
      return video.requestFullscreen();
    }
    if (video.webkitSupportsPresentationMode?.('fullscreen') && typeof video.webkitSetPresentationMode === 'function') {
      video.webkitSetPresentationMode('fullscreen');
      return Promise.resolve();
    }
    if (typeof video.webkitEnterFullscreen === 'function') { video.webkitEnterFullscreen(); return Promise.resolve(); }
    throw new Error('Fullscreen is unavailable for this video');
  }

  // One bounded wait per deliberate click, not a permanent polling timer.
  function waitForPresentation(video, mode, enter) {
    const matches = () => mode === 'pip' ? inPiP(video) : inFullscreen(video);
    return new Promise((resolve, reject) => {
      let timer, finished = false;
      const events = ['webkitpresentationmodechanged', 'enterpictureinpicture', 'fullscreenchange', 'webkitfullscreenchange'];
      const finish = error => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        for (const name of events) { video.removeEventListener(name, changed); document.removeEventListener(name, changed); }
        error ? reject(error) : resolve();
      };
      const changed = () => { if (matches()) finish(); };
      for (const name of events) { video.addEventListener(name, changed); document.addEventListener(name, changed); }
      timer = setTimeout(() => finish(matches() ? null : new Error('Video presentation did not open')), 4000);
      // Invoke synchronously inside the trusted click, before yielding user activation.
      try { Promise.resolve(enter(video)).then(changed, finish); changed(); } catch (error) { finish(error); }
    });
  }

  // Switching tabs has no transient activation. Native PiP may allow it; failure
  // leaves playback alone and never turns the whole tab into a floating window.
  window.__webbyFollowPlayingVideo = () => {
    const video = [...document.querySelectorAll('video')].find(v =>
      !v.paused && !v.ended && v.readyState >= 2 && v.videoWidth >= 120 && v.videoHeight >= 70);
    if (!video || inPiP(video)) return false;
    try { Promise.resolve(enterPiP(video)).catch(() => {}); return true; } catch (_) { return false; }
  };

  // Called only after Webby has revealed the source tab. Each frame returns its
  // own player, so cross-origin embedded videos keep their original session too.
  function returnInline() {
    let nativeRequested = false;
    const videos = new Set([presentedVideo, selected, ...document.querySelectorAll('video')]);
    for (const video of videos) {
      if (!video || !inPiP(video)) continue;
      if (typeof video.webkitSetPresentationMode === 'function') {
        video.webkitSetPresentationMode('inline'); nativeRequested = true;
      }
    }
    if (!nativeRequested && document.pictureInPictureElement && document.exitPictureInPicture) {
      Promise.resolve(document.exitPictureInPicture()).catch(() => {});
    }
    for (const child of document.querySelectorAll('iframe,frame')) {
      try { child.contentWindow?.postMessage('__webby_return_video_inline', '*'); } catch (_) {}
    }
  }
  window.__webbyReturnVideoInline = returnInline;
  window.addEventListener('message', event => {
    if (window.parent !== window && event.source === window.parent && event.data === '__webby_return_video_inline') returnInline();
  });

  function ensureControls() {
    if (controls?.isConnected || !document.documentElement) return;
    controls = document.createElement('div');
    controls.id = '__webby-video-controls';
    controls.style.cssText = 'all:initial;position:fixed;display:none;gap:6px;z-index:2147483647;pointer-events:auto';
    const icons = {
      pip: '<rect x="2" y="3" width="20" height="16" rx="3" fill="none" stroke="currentColor" stroke-width="1.7"/><rect x="12" y="10" width="8" height="6" rx="1.2" fill="currentColor"/>',
      fullscreen: '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>'
    };
    for (const [mode, title] of [['pip', 'Picture in Picture'], ['fullscreen', 'Fullscreen']]) {
      const button = document.createElement('button');
      button.type = 'button'; button.dataset.webbyVideoAction = mode;
      button.title = title; button.setAttribute('aria-label', title);
      button.innerHTML = '<svg style="pointer-events:none" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true">'+icons[mode]+'</svg>';
      button.style.cssText = 'all:initial;display:grid;place-items:center;width:34px;height:30px;box-sizing:border-box;border-radius:8px;background:rgba(25,28,34,.8);backdrop-filter:blur(12px);border:1px solid rgba(255,255,255,.3);color:white;cursor:pointer;box-shadow:0 2px 8px #0004';
      button.addEventListener('pointerdown', event => event.stopPropagation());
      button.addEventListener('click', async event => {
        event.preventDefault(); event.stopPropagation();
        const video = selected;
        if (!video?.isConnected || opening) return;
        opening = true;
        clearTimeout(hideTimer);
        button.title = 'Opening '+title+'…';
        try {
          await waitForPresentation(video, mode, mode === 'pip' ? enterPiP : enterFullscreen);
          controls.style.display = 'none'; button.title = title;
        } catch (error) {
          button.title = error.message || title+' is unavailable for this video';
          // Report the failure truthfully. Never float a tab, reload, or duplicate audio.
        } finally { opening = false; }
      });
      controls.appendChild(button);
    }
    controls.addEventListener('pointerenter', () => clearTimeout(hideTimer));
    controls.addEventListener('pointerleave', () => {
      if (!opening) hideTimer = setTimeout(() => { controls.style.display = 'none'; }, 600);
    });
    document.documentElement.appendChild(controls);
  }

  // WebKit maintains this live collection as SPA videos are added or removed.
  // Pointer tracking should not run a document-wide selector every frame.
  const documentVideos = document.getElementsByTagName('video');
  function candidateAt(x, y) {
    if (selected?.isConnected) {
      const rect = selected.getBoundingClientRect();
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) return selected;
    }
    for (const root of [document, ...pointerRoots]) {
      for (const video of root === document ? documentVideos : root.querySelectorAll('video')) {
        const rect = video.getBoundingClientRect();
        if (rect.width >= 120 && rect.height >= 70 && x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) return video;
      }
    }
    return null;
  }

  function position() {
    frame = 0;
    if (opening) return;
    const video = candidateAt(pointerX, pointerY);
    if (!video || inPiP(video) || inFullscreen(video)) {
      clearTimeout(hideTimer);
      if (controls) hideTimer = setTimeout(() => { controls.style.display = 'none'; selected = null; }, 600);
      return;
    }
    clearTimeout(hideTimer);
    selected = video; ensureControls();
    if (!controls) return;
    const rect = video.getBoundingClientRect();
    const left = Math.max(4, Math.min(innerWidth - 80, rect.right - 88))+'px';
    const top = Math.max(4, Math.min(innerHeight - 34, rect.top + 10))+'px';
    if (controls.style.left !== left) controls.style.left = left;
    if (controls.style.top !== top) controls.style.top = top;
    if (controls.style.display !== 'flex') controls.style.display = 'flex';
  }

  document.addEventListener('pointermove', event => {
    if (controls?.contains(event.target)) { clearTimeout(hideTimer); return; }
    pointerX = event.clientX; pointerY = event.clientY;
    pointerRoots = event.composedPath().filter(node => node instanceof ShadowRoot);
    if (!frame) frame = requestAnimationFrame(position);
  }, { passive: true, capture: true });
  document.addEventListener('scroll', () => { if (controls && !opening) controls.style.display = 'none'; }, true);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden && controls) controls.style.display = 'none';
  });
})();
