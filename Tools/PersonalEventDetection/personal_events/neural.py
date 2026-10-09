"""Small, deterministic CPU neural candidates; all fitted on training rows only."""
import numpy as np
import torch
from torch import nn


def fit_network(model,x,y,epochs=12):
    torch.set_num_threads(1); torch.manual_seed(42)
    x=torch.as_tensor(x,dtype=torch.float32); y=torch.as_tensor(y,dtype=torch.float32)
    opt=torch.optim.AdamW(model.parameters(),lr=.003,weight_decay=.01)
    weight=(len(y)-y.sum())/y.sum().clamp(min=1)
    generator=torch.Generator().manual_seed(42)
    for _ in range(epochs):
        model.train()
        for ids in torch.randperm(len(x),generator=generator).split(256):
            opt.zero_grad(); loss=nn.functional.binary_cross_entropy_with_logits(model(x[ids]).flatten(),y[ids],pos_weight=weight)
            loss.backward(); nn.utils.clip_grad_norm_(model.parameters(),1); opt.step()
    model.eval(); return model


class TemporalNetwork(nn.Module):
    def __init__(self,width,kind):
        super().__init__(); self.kind=kind
        self.project=nn.Sequential(nn.Linear(width,32),nn.Tanh())
        if kind in ('lstm','gru'): self.core=(nn.LSTM if kind=='lstm' else nn.GRU)(32,32,batch_first=True)
        elif kind=='tcn': self.core=nn.Conv1d(32,32,2)
        elif kind=='mlp': self.core=nn.Sequential(nn.Flatten(),nn.Linear(64,32),nn.GELU())
        else:
            from xlstm import xLSTMBlockStack,xLSTMBlockStackConfig,mLSTMBlockConfig,mLSTMLayerConfig
            self.core=xLSTMBlockStack(xLSTMBlockStackConfig(mlstm_block=mLSTMBlockConfig(mlstm=mLSTMLayerConfig(
                conv1d_kernel_size=2,qkv_proj_blocksize=4,num_heads=4)),context_length=2,num_blocks=1,embedding_dim=32,slstm_at=[]))
        self.out=nn.Linear(32,1)
    def forward(self,x):
        h=self.project(x)
        if self.kind in ('lstm','gru'): h,_=self.core(h)
        elif self.kind=='tcn': h=torch.relu(self.core(nn.functional.pad(h.transpose(1,2),(1,0)))).transpose(1,2)
        elif self.kind=='mlp': return self.out(self.core(h))
        else: h=self.core(h)
        return self.out(h[:,-1])


class NeuralHead:
    def __init__(self,kind): self.kind=kind
    def fit(self,x,y):
        torch.manual_seed(42)
        self.model=fit_network(TemporalNetwork(x.shape[-1],self.kind),x,y); return self
    def predict(self,x):
        with torch.inference_mode():
            return np.concatenate([torch.sigmoid(self.model(torch.tensor(chunk))).numpy().flatten() for chunk in np.array_split(x,max(1,len(x)//256))])


class MultiScale(nn.Module):
    def __init__(self):
        super().__init__()
        self.branches=nn.ModuleList([nn.Conv1d(2,8,k,padding=k//2) for k in (3,5,9)])
        self.out=nn.Linear(96,1)
    def encode(self,x):
        n=len(x); h=torch.cat([torch.relu(b(x.reshape(-1,2,16))) for b in self.branches],dim=1)
        return torch.cat([h.mean(-1),h.amax(-1)],dim=1).reshape(n,2,48)
    def forward(self,x): return self.out(self.encode(x).flatten(1))


class CNNEncoder:
    def fit(self,raw,y):
        self.mean=raw.mean(axis=(0,1,3),keepdims=True)
        self.scale=np.maximum(raw.std(axis=(0,1,3),keepdims=True),1e-4)
        torch.manual_seed(42)
        self.model=fit_network(MultiScale(),(raw-self.mean)/self.scale,y); return self
    def transform(self,raw):
        with torch.inference_mode():
            return np.concatenate([self.model.encode(torch.tensor((x-self.mean)/self.scale)).numpy() for x in np.array_split(raw,max(1,len(raw)//256))])
