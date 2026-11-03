const fs=require('fs'),vm=require('vm'),assert=require('assert');
function run(path,rootBackground,scheme='normal') {
 let pending, result;
 const html={parentElement:null,style:{backgroundColor:'rgba(0,0,0,0)',opacity:'1',colorScheme:scheme}};
 const body={parentElement:html,style:{backgroundColor:rootBackground,opacity:'1'}};
 let hit=body;
 for(let i=0;i<24;i++)hit={parentElement:hit,style:{backgroundColor:'rgba(0,0,0,0)',opacity:'1'}};
 const document={documentElement:html,body,hidden:false,elementFromPoint:()=>hit,createElement:()=>({getContext:()=>null}),addEventListener(){},removeEventListener(){}};
 const window={webkit:{messageHandlers:{browserChromeTone:{postMessage:v=>result=v}}},addEventListener(){},removeEventListener(){}};
 const context={document,window,top:window,MutationObserver:class{observe(){}disconnect(){}},matchMedia:()=>({matches:true,addEventListener(){},removeEventListener(){}}),getComputedStyle:n=>n.style,performance:{now:()=>200},setTimeout:f=>(pending=f,1),clearTimeout(){},innerWidth:1200,innerHeight:800};
 vm.runInNewContext(fs.readFileSync(path,'utf8'),context);
 window.__webbyChromeTone({enabled:true,left:true,glass:false});pending();return Array.from(result.edge);
}
const path=process.argv[2];
assert.deepStrictEqual(run(path,'rgb(13,17,23)'),[13,17,23]);
assert.deepStrictEqual(run(path,'rgb(220,230,240)'),[220,230,240]);
assert.deepStrictEqual(run(path,'rgba(0,0,0,0)','dark'),[18,18,18]);
console.log('PASS: deep dark/light roots and transparent dark color-scheme canvas');
