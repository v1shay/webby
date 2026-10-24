/* Webby top-edge color v1 */
(() => {
  'use strict';
  if (window !== top || window.__webbyChromeTone) return;
  let enabled=false, timer=0, x=0.5, base=[255,255,255], last='', lastSample=0;
  const canvas=document.createElement('canvas');canvas.width=canvas.height=1;
  const context=canvas.getContext('2d',{willReadFrequently:true});
  const observer=new MutationObserver(()=>schedule());
  const scheme=matchMedia('(prefers-color-scheme: dark)');
  function rgba(value) {
    if (!context) return [0,0,0,0];
    context.clearRect(0,0,1,1);context.fillStyle='transparent';context.fillStyle=value;
    context.fillRect(0,0,1,1);const p=context.getImageData(0,0,1,1).data;
    return [p[0],p[1],p[2],p[3]/255];
  }
  function sample() {
    timer=0;
    if (!enabled || document.hidden) return;
    lastSample=performance.now();observer.disconnect();
    const observed=new Set([document.documentElement,document.body].filter(Boolean));
    const samples=[];
    for (const dx of [0,-0.025,0.025]) {
      let node=document.elementFromPoint(Math.max(1,Math.min(innerWidth-2,innerWidth*(x+dx))),2);
      const stack=[];
      for (let depth=0;node && depth<14;depth++,node=node.parentElement) {
        observed.add(node);
        const style=getComputedStyle(node);
        const c=rgba(style.backgroundColor);c[3]*=Number(style.opacity);
        stack.push(c);
        if (c[3]>=0.995) break;
      }
      let rgb=base.slice();
      for (const c of stack.reverse()) rgb=rgb.map((v,i)=>c[i]*c[3]+v*(1-c[3]));
      samples.push(rgb.map(Math.round));
    }
    // Prefer the local majority, avoiding tiny badges or text hit targets at the edge.
    const key=c=>c.map(v=>Math.round(v/12)).join(',');
    const counts=new Map();for(const c of samples)counts.set(key(c),(counts.get(key(c))||0)+1);
    samples.sort((a,b)=>counts.get(key(b))-counts.get(key(a)));
    const rgb=samples[0], signature=rgb.join(',');
    if(signature!==last){last=signature;window.webkit.messageHandlers.browserChromeTone.postMessage(rgb);}
    for(const node of observed)observer.observe(node,{attributes:true,attributeFilter:['class','style','data-theme','data-webby-glass-surface'],childList:true});
  }
  function schedule() {
    if(!enabled || timer || document.hidden)return;
    // No style reads in scroll/mutation callbacks; at most eight small samples/sec.
    timer=setTimeout(sample,Math.max(24,125-(performance.now()-lastSample)));
  }
  const events=['scroll','resize','pageshow','popstate','hashchange','load','transitionend','animationend'];
  function visibility(){if(document.hidden){clearTimeout(timer);timer=0;}else schedule();}
  window.__webbyChromeTone=options=>{
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
