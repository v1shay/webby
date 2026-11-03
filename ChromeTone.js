/* Webby top-edge color v1 */
(() => {
  'use strict';
  if (window !== top || window.__webbyChromeTone) return;
  let enabled=false, left=false, timer=0, x=0.5, base=[255,255,255], last='', lastSample=0;
  const canvas=document.createElement('canvas');canvas.width=canvas.height=1;
  const context=canvas.getContext('2d',{willReadFrequently:true});
  const observer=new MutationObserver(()=>schedule());
  const scheme=matchMedia('(prefers-color-scheme: dark)');
  const colors=new Map();
  function rgba(value) {
    if(colors.has(value))return colors.get(value).slice();
    const rgb=/^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+))?\s*\)$/i.exec(value);
    if(rgb) {
      const result=[Number(rgb[1]),Number(rgb[2]),Number(rgb[3]),rgb[4]===undefined ? 1:Number(rgb[4])];
      if(colors.size>=128)colors.clear();colors.set(value,result);return result.slice();
    }
    if (!context) return [0,0,0,0];
    context.clearRect(0,0,1,1);context.fillStyle='transparent';context.fillStyle=value;
    context.fillRect(0,0,1,1);const p=context.getImageData(0,0,1,1).data;
    const result=[p[0],p[1],p[2],p[3]/255];
    if(colors.size>=128)colors.clear();colors.set(value,result);return result.slice();
  }
  function sample() {
    timer=0;
    if (!enabled || document.hidden) return;
    lastSample=performance.now();observer.disconnect();
    const observed=new Set([document.documentElement,document.body].filter(Boolean));
    const measured=new Map();
    const rootStyle=getComputedStyle(document.documentElement);
    // Transparent page roots paint the UA canvas in their own color scheme.
    // Do not composite dark pages onto the browser's default white fallback.
    const schemes=rootStyle.colorScheme.split(/\s+/);
    const canvasBase=schemes.includes('dark') && (!schemes.includes('light') || scheme.matches)
      ? [18,18,18] : base;
    function measuredColor(node) {
      let c=measured.get(node);
      if(!c) {const style=getComputedStyle(node);c=rgba(style.backgroundColor);c[3]*=Number(style.opacity);measured.set(node,c);}
      return c;
    }
    function edgeColor(atLeft) {
    const samples=[];
    for (const dx of [0,-0.025,0.025]) {
      let node=document.elementFromPoint(atLeft ? 2 : Math.max(1,Math.min(innerWidth-2,innerWidth*(x+dx))),atLeft ? Math.max(1,Math.min(innerHeight-2,innerHeight*(0.5+dx))) : 2);
      const stack=[], visited=new Set();
      let opaque=false;
      for (let depth=0;node && depth<14;depth++,node=node.parentElement) {
        observed.add(node);
        visited.add(node);
        const c=measuredColor(node);stack.push(c);
        if (c[3]>=0.995) {opaque=true;break;}
      }
      // Deep app wrappers must not exhaust the budget before body/html paint.
      if(!opaque) for(const root of [document.body,document.documentElement]) {
        if(!root || visited.has(root))continue;
        observed.add(root);const c=measuredColor(root);stack.push(c);
        if(c[3]>=0.995)break;
      }
      let rgb=canvasBase.slice();
      for (const c of stack.reverse()) rgb=rgb.map((v,i)=>c[i]*c[3]+v*(1-c[3]));
      samples.push(rgb.map(Math.round));
    }
    // Prefer the local majority, avoiding tiny badges or text hit targets at the edge.
    const key=c=>c.map(v=>Math.round(v/12)).join(',');
    const counts=new Map();for(const c of samples)counts.set(key(c),(counts.get(key(c))||0)+1);
    samples.sort((a,b)=>counts.get(key(b))-counts.get(key(a)));
    return samples[0];
    }
    const edge=edgeColor(left), top=left ? edgeColor(false) : edge;
    const signature=edge.join(',')+'|'+top.join(',');
    if(signature!==last){last=signature;window.webkit.messageHandlers.browserChromeTone.postMessage({edge,top});}
    for(const node of observed)observer.observe(node,{attributes:true,attributeFilter:['class','style','data-theme','data-color-mode','data-dark-theme','data-light-theme','data-webby-glass-surface'],childList:true});
  }
  function schedule() {
    if(!enabled || timer || document.hidden)return;
    // No style reads in scroll/mutation callbacks; at most eight small samples/sec.
    timer=setTimeout(sample,Math.max(24,125-(performance.now()-lastSample)));
  }
  const events=['scroll','resize','pageshow','popstate','hashchange','load','transitionend','animationend'];
  function visibility(){if(document.hidden){clearTimeout(timer);timer=0;}else schedule();}
  window.__webbyChromeTone=options=>{
    left=!!options.left;
    x=Math.max(0,Math.min(1,Number(options.x)||0.5));base=options.glass?[42,47,51]:[255,255,255];
    const next=!!options.enabled;
    if(next!==enabled){
      enabled=next;
      for(const event of events) {
        if(enabled)window.addEventListener(event,schedule,{passive:true,capture:true});
        else window.removeEventListener(event,schedule,true);
      }
      if(enabled){document.addEventListener('visibilitychange',visibility);scheme.addEventListener('change',schedule);}
      else{document.removeEventListener('visibilitychange',visibility);scheme.removeEventListener('change',schedule);observer.disconnect();clearTimeout(timer);timer=0;}
    }
    if(enabled){last='';schedule();}
  };
})();
