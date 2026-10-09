"""Fold-fitted encoders. Frozen branches require explicit, pinned local weights."""
import hashlib
import json
import warnings
from pathlib import Path
import numpy as np
from sklearn.decomposition import PCA
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import StandardScaler


def statistics(raw):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return np.stack([np.nanmean(raw,axis=-1),np.nanstd(raw,axis=-1),
                         np.nanmin(raw,axis=-1),np.nanmax(raw,axis=-1),
                         raw[...,-1]-raw[...,0]],axis=-1)


def fixed_features(name, raw, config=None, cache=None):
    if name in ('temperature','cardiac'):
        return statistics(raw[:,:,0 if name=='temperature' else 1,:])
    if name=='waveform': return raw.reshape(len(raw),2,32)
    if name=='dynamics':
        return np.concatenate([statistics(raw[:,:,:, -n:]).reshape(len(raw),2,-1) for n in (4,8,16)],axis=-1)
    if name=='catch24':
        import pycatch22
        out=[]
        for window in raw:
            out.append([[v for channel in step for v in pycatch22.catch22_all(channel,catch24=True)['values']] for step in window])
        return np.asarray(out,dtype=np.float32)
    if name in ('normwear','normwear2'):
        from .frozen import FrozenEncoder
        cfg=(config or {}).get(name)
        if not cfg: raise ValueError(f"{name}: pinned local checkpoint is not configured")
        encoder=FrozenEncoder(name,source=cfg.get('source'),checkpoint=cfg['checkpoint'])
        digest=hashlib.sha256(json.dumps(encoder.provenance,sort_keys=True).encode()).hexdigest()
        if digest != cfg.get('provenance_sha256'): raise ValueError(f"{name}: checkpoint provenance does not match configured digest")
        out=[]
        for window in raw:
            steps=[]
            for step in window:
                key=hashlib.sha256(digest.encode()+step.tobytes()).hexdigest()
                path=Path(cache)/f'{key}.npy' if cache else None
                if path and path.exists(): value=np.load(path,allow_pickle=False)
                else:
                    value=encoder.encode(step.T,1,('temperature_raw','heart_rate'),('strap_raw','bpm'))
                    if path:
                        path.parent.mkdir(parents=True,exist_ok=True); np.save(path,value,allow_pickle=False)
                steps.append(value)
            out.append(steps)
        return np.asarray(out,dtype=np.float32)
    raise ValueError(f"Unknown encoder {name}")


class Encoder:
    def __init__(self,name,config=None,cache=None): self.name=name; self.config=config; self.cache=cache
    def fit(self,raw,y):
        self.learned=None
        if self.name=='minirocket':
            from .vendor import minirocket_multivariate as mr
            import numba
            numba.set_num_threads(1)
            @numba.njit
            def seed(): np.random.seed(42)
            seed()
            self.learned=mr.fit(np.ascontiguousarray(raw.reshape(-1,2,16)),num_features=504)
        elif self.name=='cnn':
            from .neural import CNNEncoder
            self.learned=CNNEncoder().fit(raw,y)
        values=self._raw(raw)
        self.imputer=SimpleImputer(strategy='median',keep_empty_features=True).fit(values.reshape(-1,values.shape[-1]))
        x=self.imputer.transform(values.reshape(-1,values.shape[-1]))
        self.scaler=StandardScaler().fit(x); x=self.scaler.transform(x)
        self.pca=None
        if self.name in ('normwear','normwear2','minirocket'):
            self.pca=PCA(n_components=min(16,x.shape[0],x.shape[1]),random_state=42).fit(x)
        return self
    def _raw(self,raw):
        if self.name=='minirocket':
            from .vendor import minirocket_multivariate as mr
            return mr.transform(np.ascontiguousarray(raw.reshape(-1,2,16)),self.learned).reshape(len(raw),2,-1)
        if self.name=='cnn': return self.learned.transform(raw)
        return fixed_features(self.name,raw,self.config,self.cache)
    def transform(self,raw):
        values=self._raw(raw); x=self.scaler.transform(self.imputer.transform(values.reshape(-1,values.shape[-1])))
        if self.pca is not None: x=self.pca.transform(x)
        return x.reshape(len(raw),2,-1).astype(np.float32)


def usable(raw,groups):
    channels=([0] if set(groups)=={'temperature'} else [1] if set(groups)=={'cardiac'} else [0,1])
    # Require all samples for waveform/frozen/learned branches; statistics tolerate up to 20% missing.
    coverage=np.isfinite(raw[:,:,channels,:]).mean(axis=(1,2,3))
    return coverage >= (0.8 if set(groups)<={'temperature','cardiac'} else 1.0)
