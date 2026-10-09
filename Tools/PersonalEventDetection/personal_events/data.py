"""Stable-ID labels and causal windows. Unlabelled time remains unknown."""
import hashlib
import json
import numpy as np

WINDOW = 32
STRIDE = 8
VERSION = "causal-32s-8s-raw-temperature-v1"


def windows(heart, temperature, *, start, end):
    # Missing sensors are kept as NaN. No forward fill and no samples from the future.
    heart = {int(t):float(v) for t,v in heart if 20<=float(v)<=250}
    temperature = {int(t):float(v) for t,v in temperature if np.isfinite(v)}
    times = np.arange(int(start/STRIDE)*STRIDE+STRIDE, int(end)+1, STRIDE, dtype=float)
    raw = np.full((len(times),2,2,16), np.nan, dtype=np.float32)
    for i,t in enumerate(times):
        for channel,source in enumerate((temperature,heart)):
            raw[i,:,channel,:] = np.array([source.get(s,np.nan) for s in range(int(t)-WINDOW,int(t))]).reshape(2,16)
    return times,raw


def label_windows(times, positives, negatives):
    labels = np.full(len(times),-1,dtype=int)
    for i,t in enumerate(times):
        pos = any(e["start"] <= t-WINDOW and t <= e["end"] for e in positives)
        neg = any(a <= t-WINDOW and t <= b for a,b in negatives)
        # Conflicting reviews abstain rather than silently choosing a label.
        if pos != neg: labels[i] = int(pos)
    return labels


def chronological_split(times, labels, positives):
    # UTC days keep episodes and overlapping windows out of different partitions.
    days = sorted(set((times[labels>=0]//86400).astype(int)))
    if len(days)<5: raise ValueError("Review examples on at least five separate days.")
    cuts = (days[max(1,int(len(days)*.6))]*86400, days[max(2,int(len(days)*.8))]*86400)
    if cuts[0]>=cuts[1]: raise ValueError("Need independent evaluation days.")
    blocked = np.zeros(len(times),dtype=bool)
    for e in positives:
        if any(e["start"]<c<e["end"] for c in cuts):
            blocked |= (times>=e["start"]-WINDOW)&(times<=e["end"]+WINDOW)
    parts = [np.flatnonzero((times<cuts[0]-WINDOW)&~blocked),
             np.flatnonzero((times>=cuts[0]+WINDOW)&(times<cuts[1]-WINDOW)&~blocked),
             np.flatnonzero((times>=cuts[1]+WINDOW)&~blocked)]
    train = parts[0][labels[parts[0]]>=0]
    if len(set(labels[train]))<2: raise ValueError("Training needs both confirmed events and reviewed negative time.")
    return [train, parts[1], parts[2]]


def snapshot_id(owner, type_id, device, times, raw, labels, revisions):
    h=hashlib.sha256(json.dumps([str(owner),str(type_id),str(device),VERSION,revisions],sort_keys=True,default=str).encode())
    for array in (times,raw,labels): h.update(np.ascontiguousarray(array).tobytes())
    return h.hexdigest()
