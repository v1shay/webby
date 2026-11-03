const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../VideoControls.js'), 'utf8');
class Node {
  constructor(tag='node') { this.tagName=tag.toUpperCase();this.children=[];this.events={};this.style={};this.dataset={};this.isConnected=true; }
  appendChild(child) {this.children.push(child);child.parent=this;}
  addEventListener(name,fn) {(this.events[name] ||= new Set()).add(fn);}
  removeEventListener(name,fn) {this.events[name]?.delete(fn);}
  fire(name,event={}) { return [...(this.events[name]||[])].map(fn=>fn(event)); }
  setAttribute(name,value) {this[name]=value;}
  contains(node) {return this===node || this.children.some(child=>child.contains(node));}
  getBoundingClientRect(){return {left:10,top:10,right:650,bottom:370,width:640,height:360};}
}
async function fixture(mode) {
  const document=new Node(),video=new Node('video');
  document.documentElement=new Node('html'); document.hidden=false;
  document.createElement=tag=>new Node(tag);
  document.querySelectorAll=selector=>selector==='video' && mode!=='empty' ? [video] : [];
  const liveVideos=mode==='empty' ? []:[video];
  document.getElementsByTagName=tag=>tag==='video' ? liveVideos:[];
  document.fullscreenEnabled=true; document.pictureInPictureEnabled=mode==='standard';
  Object.assign(video,{paused:false,ended:false,readyState:4,videoWidth:640,videoHeight:360,
    volume:.37,muted:false,playbackRate:1.25,currentTime:123.4,webkitPresentationMode:'inline'});
  let enters=0,floatRequests=0,raf;
  if(mode==='native') {
    video.webkitSupportsPresentationMode=()=>true;
    video.webkitSetPresentationMode=value=>{enters++;video.webkitPresentationMode=value;video.fire('webkitpresentationmodechanged');};
  }
  if(mode==='standard') video.requestPictureInPicture=()=>{enters++;document.pictureInPictureElement=video;video.fire('enterpictureinpicture');return Promise.resolve();};
  document.exitPictureInPicture=()=>{document.pictureInPictureElement=null;return Promise.resolve();};
  video.requestFullscreen=()=>{document.fullscreenElement=video;document.fire('fullscreenchange');return Promise.resolve();};
  const context={document,innerWidth:1000,innerHeight:700,setTimeout,clearTimeout,
    requestAnimationFrame:fn=>{raf=fn;return 1;},ShadowRoot:class {},
    window:{addEventListener(){},webkit:{messageHandlers:{browserVideoFloat:{postMessage(){floatRequests++;}}}}}};
  vm.createContext(context);vm.runInContext(source,context);vm.runInContext(source,context);
  assert.equal(document.events.pointermove.size,1,'Installing twice duplicated pointer tracking');
  document.fire('pointermove',{target:video,clientX:100,clientY:100,composedPath:()=>[video,document]});raf();
  if(mode==='empty') {
    assert.equal(document.documentElement.children.length,0,'Non-video page acquired controls');
    liveVideos.push(video);
    document.fire('pointermove',{target:video,clientX:100,clientY:100,composedPath:()=>[video,document]});raf();
    assert.equal(document.documentElement.children[0]?.children.length,2,'A video inserted by an SPA was missed');
    return;
  }
  const controls=document.documentElement.children[0];assert.equal(controls.children.length,2);
  const state=[video.volume,video.muted,video.playbackRate,video.currentTime];
  await Promise.all(controls.children[0].fire('click',{preventDefault(){},stopPropagation(){}}));
  assert.deepEqual([video.volume,video.muted,video.playbackRate,video.currentTime],state,'PiP mutated media state');
  assert.equal(floatRequests,0,'PiP failure floated the tab');
  if(mode==='unsupported') {assert.equal(enters,0);assert.match(controls.children[0].title,/unavailable/);}
  else {assert.equal(enters,1);assert.equal(controls.style.display,'none');}
  context.window.__webbyReturnVideoInline();
  if(mode==='native') assert.equal(video.webkitPresentationMode,'inline','Native return did not reattach video');
  if(mode==='standard') assert.equal(document.pictureInPictureElement,null,'Standard return did not reattach video');
  assert.deepEqual([video.volume,video.muted,video.playbackRate,video.currentTime],state,'Return changed playback state');
  await Promise.all(controls.children[1].fire('click',{preventDefault(){},stopPropagation(){}}));
  assert.equal(document.fullscreenElement,video,'Fullscreen used a different video');
  assert.deepEqual([video.volume,video.muted,video.playbackRate,video.currentTime],state);
}
(async()=>{for(const mode of ['native','standard','unsupported','empty']) await fixture(mode);
 console.log('PASS: native/standard PiP, true fullscreen, exact media state, truthful unsupported state, no floating fallback, no controls on non-video pages, idempotent installation');
})().catch(error=>{console.error(error);process.exitCode=1;});
