"""Optional head/encoder smoke test; synthetic plumbing, not validation of accuracy."""
import json
import subprocess
import sys
import numpy as np
from personal_events.models import Detector,HEADS,EXTRA
from personal_events.training import pack,unpack


def one(head,group):
    rng=np.random.default_rng(42)
    raw=rng.normal(60,3,size=(80,2,2,16)).astype('float32'); y=np.tile([0,1],40)
    raw[y==1]+=20
    model=Detector(dict(groups=[group],head=head)).fit(raw,y)
    a=model.predict(raw);b=unpack(pack(model)).predict(raw)
    assert np.isfinite(a).all() and ((0<=a)&(a<=1)).all()
    np.testing.assert_allclose(a,b,rtol=1e-6,atol=1e-6)


if __name__=='__main__':
    if len(sys.argv)>1: one(*sys.argv[1:])
    else:
        results=[]
        for head,group in [(h,'cardiac') for h in HEADS]+[('ridge',g) for g in EXTRA]:
            try:
                result=subprocess.run([sys.executable,__file__,head,group],capture_output=True,text=True,timeout=180)
                results.append(dict(head=head,encoder=group,passed=result.returncode==0,error=result.stderr[-400:] if result.returncode else None))
            except subprocess.TimeoutExpired:
                results.append(dict(head=head,encoder=group,passed=False,error='time budget'))
            print(json.dumps(results[-1]),flush=True)
        sys.exit(0 if all(r['passed'] for r in results) else 1)
