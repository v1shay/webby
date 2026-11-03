#!/usr/bin/env python3
"""Real HTTPS corpus, isolated profiles, ABBA comparison; no fixed-host assertions."""
import argparse,datetime,hashlib,json,os,platform,random,statistics,subprocess,time
from pathlib import Path
from urllib.parse import urlsplit

def capture(args):
    p=subprocess.run(args,capture_output=True,text=True)
    return {'exit':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline-app',type=Path,required=True)
    p.add_argument('--candidate-app',type=Path,required=True)
    p.add_argument('--corpus',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--rounds',type=int,default=2)
    p.add_argument('--seed',type=int,default=20261101)
    p.add_argument('--skip-controls',action='store_true')
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    urls=json.loads(a.corpus.read_text())
    if not isinstance(urls,list) or not urls or not all(isinstance(u,str) and urlsplit(u).scheme=='https' and urlsplit(u).hostname for u in urls):p.error('Corpus must be a nonempty JSON array of HTTPS URLs')
    if not 1<=a.rounds<=10:p.error('--rounds must be between 1 and 10')
    random.Random(a.seed).shuffle(urls)
    corpus=a.output/'ordered-corpus.json';corpus.write_text(json.dumps(urls,indent=2))
    manifest={'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'seed':a.seed,'corpusSHA256':hashlib.sha256(corpus.read_bytes()).hexdigest(),'os':platform.platform(),'hardware':capture(['sysctl','-n','hw.model']),'initialPower':capture(['pmset','-g','batt']),'runs':[],'limitations':['Logged-out isolated sessions, not personal signed-in workflows','Fresh ephemeral WebKit store per run; OS DNS/TLS caches uncontrolled','Server variation and user background activity uncontrolled','Host CPU/RSS excludes WebKit content, network and GPU processes','rAF gaps are opportunities, not compositor FPS or input-to-photon latency','Small sample: medians/ranges, no fastest-browser or zero-jitter conclusion','Challenge/error pages retained; load completion alone is not usable-page success']}
    runs=[('baseline-0',a.baseline_app,'webby'),('candidate-0',a.candidate_app,'webby'),('candidate-1',a.candidate_app,'webby'),('baseline-1',a.baseline_app,'webby')]
    if not a.skip_controls:runs += [('control-no-glass',a.candidate_app,'webby-no-glass'),('control-minimal-wk',a.candidate_app,'minimal-wk')]
    for name,app,variant in runs:
        env=dict(os.environ,WEBBY_REAL_CORPUS=str(corpus.resolve()),WEBBY_REAL_REPEATS=str(a.rounds),WEBBY_REAL_VARIANT=variant)
        output=a.output/(name+'.json');binary=app/'Contents/MacOS/Webby'
        row={'name':name,'variant':variant,'expectedSamples':len(urls)*a.rounds,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'powerBefore':capture(['pmset','-g','batt']),'thermalBefore':capture(['pmset','-g','therm'])}
        start=time.monotonic()
        with (a.output/(name+'.log')).open('w') as log:
            try:row['exit']=subprocess.run([str(binary.resolve()),'https://benchmark.invalid',str(output.resolve())],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=len(urls)*a.rounds*32+45).returncode
            except subprocess.TimeoutExpired:row['exit']='timeout'
        row['elapsedSeconds']=time.monotonic()-start
        row['samplesWritten']=len(json.loads(output.read_text()).get('samples',[])) if output.exists() else 0
        manifest['runs'].append(row)
        (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
        print(name,'exit',row['exit'],'samples',row['samplesWritten'],flush=True)
    summaries=[]
    for url in urls:
        row={'url':url}
        for label in ['baseline','candidate','control-no-glass','control-minimal-wk']:
            records=[]
            for run in manifest['runs']:
                if run['name'].startswith(label):
                    f=a.output/(run['name']+'.json')
                    if f.exists():records += [s for s in json.loads(f.read_text()).get('samples',[]) if s['url']==url]
            if not records:continue
            times=[s['nativeLoadWaitMs'] for s in records]
            titles=sorted(set(s.get('page',{}).get('title','') for s in records))
            row[label]={'samples':len(records),'medianLoadWaitMs':statistics.median(times),'rangeLoadWaitMs':[min(times),max(times)],'timeouts':sum(bool(s['timedOut']) for s in records),'navigationErrors':sum(bool(s.get('navigationError')) for s in records),'measurementErrors':sum(bool(s.get('measurementError')) for s in records),'titles':titles,'challengeSuspected':any(any(word in title.lower() for word in ['just a moment','access denied','verify you are human','security verification']) for title in titles)}
        summaries.append(row)
    (a.output/'summary.json').write_text(json.dumps(summaries,indent=2))
    viewports={}
    for run in manifest['runs']:
        f=a.output/(run['name']+'.json')
        if f.exists():
            viewports[run['name']]=sorted({json.dumps(s.get('page',{}).get('viewport'),sort_keys=True) for s in json.loads(f.read_text()).get('samples',[]) if s.get('page',{}).get('viewport')})
    reference=viewports.get('baseline-0',[])
    (a.output/'comparability.json').write_text(json.dumps({'viewports':viewports,'mismatchedViewportRuns':[name for name,values in viewports.items() if values!=reference],'note':'Controls with mismatched viewports are diagnostic only; exclude from matched comparisons.'},indent=2))
    print('Results:',a.output)
    if any(r['exit']!=0 or r['samplesWritten']!=r['expectedSamples'] for r in manifest['runs']):raise SystemExit(1)
if __name__=='__main__':main()
