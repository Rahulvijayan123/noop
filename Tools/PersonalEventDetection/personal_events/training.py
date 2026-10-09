"""Weekly evaluation with an untouched later partition and a no-detector baseline."""
import io
import json
import time
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path
import joblib
import numpy as np
from threadpoolctl import threadpool_limits
from .data import VERSION, chronological_split
from .models import Detector, REGISTRY_VERSION, candidates
from .policy import Policy,evaluate


def pack(model):
    stream=io.BytesIO(); joblib.dump(model,stream,compress=3)
    if stream.tell()>16777216: raise ValueError('Model exceeds serving artifact budget')
    return stream.getvalue()


def unpack(blob):
    # Only private server-created artifacts are accepted. There is no model-upload API.
    return joblib.load(io.BytesIO(bytes(blob)))


def evaluate_model(model,times,raw,ids,positives,negatives,policy):
    lo,hi=float(times[ids].min())-8,float(times[ids].max())
    positive=[e for e in positives if lo<=e['start'] and e['end']<=hi]
    negative=[(max(a,lo),min(b,hi)) for a,b in negatives if min(b,hi)>max(a,lo)]
    return evaluate(times[ids],model.predict(raw[ids]),positive,negative,policy)


def fit_one(root,spec):
    payload=joblib.load(root/'input.joblib')
    times,raw,labels=(np.load(root/(name+'.npy'),mmap_mode='r') for name in ('times','raw','labels'))
    train_ids,validation=payload['train'],payload['validation']
    try:
        with threadpool_limits(limits=1):
            model=Detector(spec,payload['config'],root/'embeddings').fit(raw[train_ids],labels[train_ids])
            result=dict(id=spec['id'],status='evaluated',metrics=evaluate_model(model,times,raw,validation,
                payload['positives'],payload['negatives'],Policy(**payload['policy'])))
            if result['metrics']['eligible']: (root/(spec['id']+'.joblib')).write_bytes(pack(model))
    except (ImportError,ValueError,RuntimeError) as error:
        result=dict(id=spec['id'],status='skipped',reason=str(error)[:240])
    (root/(spec['id']+'.json')).write_text(json.dumps(result,allow_nan=False))


def train(times,raw,labels,positives,negatives,*,snapshot,cache,config=None,policy=None,
          current=None,progress=lambda _:None,max_seconds=10800,specs=None,previous_test_end=0,
          isolate=True,candidate_seconds=180):
    policy=policy or Policy(); parts=chronological_split(times,labels,positives)
    train_ids,validation,test=parts
    if not len(validation) or not len(test): raise ValueError('Need later reviewed evaluation windows')
    # An earlier protected test set cannot become the next weekly promotion scoreboard.
    test=test[times[test]>previous_test_end+32]
    if not len(test): raise ValueError('Waiting for new independent evaluation data')
    root=Path(cache)/snapshot; root.mkdir(parents=True,exist_ok=True)
    for name,array in [('times',times),('raw',raw),('labels',labels)]: np.save(root/(name+'.npy'),array,allow_pickle=False)
    joblib.dump(dict(train=train_ids,validation=validation,config=config,positives=positives,negatives=negatives,policy=asdict(policy)),root/'input.joblib')
    def score(model,ids): return evaluate_model(model,times,raw,ids,positives,negatives,policy)
    started=time.monotonic(); results=[]; best=None; best_score=0
    for spec in specs or candidates():
        progress(dict(candidate=spec['id'],completed=len(results)))
        if time.monotonic()-started>max_seconds: raise TimeoutError('Training budget reached; resume cached candidates')
        result_path=root/(spec['id']+'.json'); model_path=root/(spec['id']+'.joblib')
        if result_path.exists():
            result=json.loads(result_path.read_text())
        else:
            try:
                if isolate:
                    subprocess.run([sys.executable,'-m','personal_events.training',str(root),json.dumps(spec)],
                        check=True,timeout=candidate_seconds,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                else: fit_one(root,spec)
                result=json.loads(result_path.read_text())
            except (subprocess.TimeoutExpired,subprocess.CalledProcessError):
                result=dict(id=spec['id'],status='failed',reason='Candidate exceeded its time budget or failed in its isolated process.')
                result_path.write_text(json.dumps(result))
        results.append(result)
        value=result.get('metrics',{}).get('timeSavedSecondsPerDay',0)
        if result.get('metrics',{}).get('eligible') and value>best_score and model_path.exists():
            best,best_score=model_path,value
    report=dict(registry=REGISTRY_VERSION,featureVersion=VERSION,snapshot=snapshot,candidates=results,
                policy=asdict(policy),trainEnd=float(times[train_ids].max()),testEnd=float(times[test].max()),
                promotion=False,reason='No eligible model improves on manual logging.')
    if best is None: return None,report
    model=unpack(best.read_bytes()); heldout=score(model,test)
    report.update(candidate=model.spec['id'],evaluation=heldout)
    incumbent=score(current,test) if current else None
    report['incumbent']=incumbent
    # Require both useful held-out performance and a meaningful margin over the incumbent.
    baseline=max(0,incumbent['timeSavedSecondsPerDay']) if incumbent else 0
    if heldout['eligible'] and heldout['timeSavedSecondsPerDay']>baseline+max(5,abs(baseline)*.1):
        report.update(promotion=True,reason='Passed later held-out review and time-saved gates.')
        model.policy=policy; model.snapshot=snapshot
        return model,report
    report['reason']='Keep current model: later evidence does not support a change.'
    return None,report


if __name__=='__main__': fit_one(Path(sys.argv[1]),json.loads(sys.argv[2]))
