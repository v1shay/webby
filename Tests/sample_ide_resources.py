from pathlib import Path
import json, os, subprocess, sys, time
root=Path(__file__).resolve().parents[2]
label=sys.argv[1]
log=root/'work'/('ide-'+label+'.log')
env=os.environ.copy();env['WEBBY_TEST_WORKBENCH']='only';env['WEBBY_IDE_SAMPLE_IDLE_SECONDS']='15'
command=[str(root/'work/performance-phase2/harness/WebbyTests.app/Contents/MacOS/Webby'),'http://127.0.0.1:1',str(root/'work/webby-workbench-live.json')]
def rows():
    result={}
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,rss=,time=,comm='],text=True).splitlines():
        fields=line.split(None,4)
        if len(fields)!=5:continue
        pid,parent,rss,cpu,name=fields
        parts=cpu.split(':');seconds=sum(float(n)*60**i for i,n in enumerate(reversed(parts)))
        result[int(pid)]=(int(parent),int(rss),seconds,name)
    return result
with log.open('w') as output:
    process=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,env=env)
    samples=[];seen=set();previous={};last=time.monotonic();began=last
    while process.poll() is None:
        current=rows();ids={process.pid}
        while True:
            grown=ids|{p for p,v in current.items() if v[0] in ids}
            if grown==ids:break
            ids=grown
        backend={p for p in ids if p!=process.pid and p in current}
        seen|=backend;now=time.monotonic();elapsed=now-last
        cpu=sum(max(0,current[p][2]-previous[p]) for p in backend if p in previous)/elapsed*100
        content=log.read_text(errors='replace')
        samples.append({'seconds':now-began,'backendRSSMiB':sum(current[p][1] for p in backend)/1024,'backendCPUPercent':cpu,'idle':'IDE_IDLE_BEGIN' in content and 'IDE_IDLE_END' not in content})
        previous={p:current[p][2] for p in backend};last=now
        if now-began>200:process.terminate();raise RuntimeError('Timed out')
        time.sleep(.5)
    status=process.wait()
    time.sleep(3)
    remaining=rows()
idle=[s for s in samples if s['idle']]
report={'scope':'Backend descendants only; excludes WebKit rendering/XPC and shared-memory accounting. CPU 100% is one logical core.','exitCode':status,'wallSeconds':samples[-1]['seconds'],'peakBackendRSSMiB':max(s['backendRSSMiB'] for s in samples),'idleBackendRSSMiB':sum(s['backendRSSMiB'] for s in idle)/max(1,len(idle)),'idleBackendCPUPercent':sum(s['backendCPUPercent'] for s in idle)/max(1,len(idle)),'leftoverBackendPIDs':[p for p in seen if p in remaining],'samples':samples}
path=root/'work'/('ide-'+label+'-resources.json');path.write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='samples'},indent=2));print(log.read_text(errors='replace')[-1000:]);sys.exit(status)
