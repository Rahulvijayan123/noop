"""Versioned 25 x 18 candidate registry, adapted from the existing research matrix."""
from itertools import combinations
import hashlib
from pathlib import Path
import joblib
import numpy as np
from scipy.special import expit
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier, ExtraTreesClassifier
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis
from sklearn.svm import SVC
from .features import Encoder, usable
from .sparse_group import SparseGroupLogistic

BASE=('temperature','cardiac','normwear','normwear2')
EXTRA=('waveform','dynamics','catch24','minirocket','cnn')
GROUPS=[tuple(c) for n in range(1,5) for c in combinations(BASE,n)]+[(g,) for g in EXTRA]+[('temperature','cardiac',g) for g in EXTRA]
HEADS=('prevalence','ridge','lasso','elastic_net','sparse_group','boosted_trees','xgboost','random_forest',
       'stacking','lstm','gru','tcn','xlstm','extra_trees','catboost','rbf_svm','shrinkage_lda','mlp')
REGISTRY_VERSION='personal-matrix-1'


def candidates():
    return [dict(id='+'.join(g)+'__'+h,groups=g,head=h) for g in GROUPS for h in HEADS]


def tabular(x): return np.concatenate([x[:,0],x[:,1],x[:,1]-x[:,0]],axis=1)


class Detector:
    def __init__(self,spec,config=None,cache=None): self.spec=spec; self.config=config; self.cache=cache
    def fit(self,raw,y,encoder_bank=None):
        use=usable(raw,self.spec['groups']); raw=raw[use]; y=y[use]
        if len(set(y))<2: raise ValueError('Both reviewed classes need usable sensor windows')
        # A bank is shared only when the exact same training rows apply to every branch.
        self.encoders={}
        for g in self.spec['groups']:
            key=hashlib.sha256(g.encode()+raw.tobytes()+y.tobytes()).hexdigest()
            path=Path(self.cache)/('encoder-'+key+'.joblib') if self.cache else None
            if path and path.exists(): encoder=joblib.load(path)
            else:
                encoder=Encoder(g,self.config,self.cache).fit(raw,y)
                if path:
                    path.parent.mkdir(parents=True,exist_ok=True); joblib.dump(encoder,path)
            self.encoders[g]=encoder
        x=self.sequence(raw); xx=tabular(x); head=self.spec['head']
        self.constant=None; self.branches=None
        if head=='prevalence': self.constant=float(y.mean()); return self
        if head in ('lstm','gru','tcn','xlstm','mlp'):
            from .neural import NeuralHead
            self.model=NeuralHead(head).fit(x,y); return self
        spans={}; offset=0
        for g,enc in self.encoders.items():
            width=enc.transform(raw[:1]).shape[-1]
            for step in range(3): spans[f'{g}:{step}']=slice(offset+step*x.shape[-1],offset+width+step*x.shape[-1])
            offset+=width
        if head=='stacking':
            self.branches=[]
            for g in self.spec['groups']:
                take=np.concatenate([np.arange(spans[f'{g}:{step}'].start,spans[f'{g}:{step}'].stop) for step in range(3)])
                model=LogisticRegression(C=.2,class_weight='balanced',max_iter=1000,random_state=42).fit(xx[:,take],y)
                self.branches.append((take,model))
            return self
        common=dict(random_state=42)
        if head in ('ridge','lasso','elastic_net'):
            self.model=LogisticRegression(C=.2,penalty={'ridge':'l2','lasso':'l1','elastic_net':'elasticnet'}[head],
                solver='saga' if head=='elastic_net' else 'liblinear',l1_ratio=.5 if head=='elastic_net' else None,
                class_weight='balanced',max_iter=1500,**common)
        elif head=='random_forest': self.model=RandomForestClassifier(n_estimators=100,max_depth=8,min_samples_leaf=3,class_weight='balanced',n_jobs=1,**common)
        elif head=='extra_trees': self.model=ExtraTreesClassifier(n_estimators=150,max_depth=10,min_samples_leaf=3,class_weight='balanced',n_jobs=1,**common)
        elif head=='boosted_trees': self.model=HistGradientBoostingClassifier(max_iter=80,max_leaf_nodes=7,class_weight='balanced',early_stopping=False,**common)
        elif head=='shrinkage_lda': self.model=LinearDiscriminantAnalysis(solver='lsqr',shrinkage='auto',priors=[.5,.5])
        elif head=='rbf_svm': self.model=SVC(C=1,kernel='rbf',class_weight='balanced',cache_size=128,**common)
        elif head=='xgboost':
            from xgboost import XGBClassifier
            self.model=XGBClassifier(n_estimators=100,max_depth=4,n_jobs=1,scale_pos_weight=float((y==0).sum()/(y==1).sum()),**common)
        elif head=='catboost':
            from catboost import CatBoostClassifier
            self.model=CatBoostClassifier(iterations=120,depth=4,auto_class_weights='Balanced',thread_count=1,verbose=False,allow_writing_files=False,random_seed=42)
        elif head=='sparse_group':
            rng=np.random.default_rng(42); pos=np.flatnonzero(y==1); neg=np.flatnonzero(y==0); n=min(2048,len(neg))
            take=np.r_[rng.choice(pos,n,replace=True),rng.choice(neg,n,replace=False)]
            self.model=SparseGroupLogistic(strength=.01,max_iter=4000,tol=1e-4).fit(xx[take],y[take],spans)
            if not self.model.converged_: raise ValueError('Sparse-group optimizer did not converge')
            return self
        else: raise ValueError('Unknown head')
        self.model.fit(xx,y); return self
    def sequence(self,raw): return np.concatenate([e.transform(raw) for e in self.encoders.values()],axis=-1)
    def predict(self,raw):
        use=usable(raw,self.spec['groups']); out=np.full(len(raw),np.nan)
        if not use.any(): return out
        if self.constant is not None: out[use]=self.constant; return out
        x=self.sequence(raw[use]); xx=tabular(x)
        if self.branches is not None: p=np.mean([m.predict_proba(xx[:,take])[:,1] for take,m in self.branches],axis=0)
        elif self.spec['head'] in ('lstm','gru','tcn','xlstm','mlp'): p=self.model.predict(x)
        elif self.spec['head']=='rbf_svm': p=expit(self.model.decision_function(xx))
        else: p=self.model.predict_proba(xx)[:,1]
        out[use]=p; return out
