"""CPU CTC prefix beam search. Raw outputs and candidate scores remain observable."""
import math

import numpy as np


NEG_INF=-float('inf')


def log_add(a,b):
    if a==NEG_INF:return b
    if b==NEG_INF:return a
    if a<b:a,b=b,a
    return a+math.log1p(math.exp(b-a))


def log_softmax(logits):
    values=np.asarray(logits,dtype=np.float64)
    if values.ndim!=2 or not np.isfinite(values).all():
        raise ValueError('Expected finite T by C logits')
    maximum=np.max(values,axis=1,keepdims=True)
    centered=values-maximum
    return centered-np.log(np.exp(centered).sum(axis=1,keepdims=True))


def greedy_indices(sequence,blank):
    prefix=[];previous=blank
    for value in sequence:
        value=int(value)
        if value!=blank and value!=previous:prefix.append(value)
        previous=value
    return tuple(prefix)


def plate_prefix_valid(prefix):
    if len(prefix)>7:return False
    for i,index in enumerate(prefix):
        if i==0 and not 0<=index<31:return False
        if i==1 and not 41<=index<65:return False
        if i>=2 and not 31<=index<65:return False
    return True


def _allowed_next(length,classes,blank,constrained):
    if not constrained:return [c for c in range(classes) if c!=blank]
    if length==0:return list(range(31))
    if length==1:return list(range(41,65))
    if length<7:return list(range(31,65))
    return []


def prefix_beam_search(log_probabilities,blank,beam_width=16,top_k=8,constrained=False):
    values=np.asarray(log_probabilities,dtype=np.float64)
    if values.ndim!=2 or np.isnan(values).any() or np.isposinf(values).any():
        raise ValueError('Expected finite or negative-infinite log probabilities')
    if not 0<=blank<values.shape[1] or beam_width<=0 or (top_k is not None and top_k<=0):
        raise ValueError('Invalid blank/beam/top-k configuration')
    if constrained and (values.shape[1]!=68 or blank!=67):
        raise ValueError('Plate grammar expects the existing 68-class alphabet')
    beams={():[0.,NEG_INF]}
    for scores in values:
        next_beams={}
        # Only eight distinct prefix lengths are possible for the seven-character grammar.
        choices={}
        def update(prefix,position,score):
            if score==NEG_INF:return
            row=next_beams.setdefault(prefix,[NEG_INF,NEG_INF])
            row[position]=log_add(row[position],score)
        for prefix,(pb,pnb) in beams.items():
            total=log_add(pb,pnb)
            update(prefix,0,total+float(scores[blank]))
            if prefix:
                # A repeated nonblank stays in this prefix even when next-position grammar differs.
                update(prefix,1,pnb+float(scores[prefix[-1]]))
            length=len(prefix)
            key=length if constrained else 0
            if key not in choices:
                allowed=_allowed_next(length,values.shape[1],blank,constrained)
                if top_k is not None:
                    allowed=sorted(allowed,key=lambda c:(-scores[c],c))[:top_k]
                choices[key]=allowed
            for char in choices[key]:
                # Appending the same symbol requires a preceding blank; other symbols use both states.
                source=pb if prefix and char==prefix[-1] else total
                update(prefix+(char,),1,source+float(scores[char]))
        ordered=sorted(next_beams.items(),key=lambda row:(-log_add(*row[1]),row[0]))
        beams=dict(ordered[:beam_width])
        if not beams:break
    return [dict(indices=prefix,log_probability=log_add(pb,pnb),
                 log_blank=pb,log_nonblank=pnb)
            for prefix,(pb,pnb) in sorted(beams.items(),key=lambda row:(-log_add(*row[1]),row[0]))]


def sequence_log_probability(log_probabilities,sequence,blank):
    """Exact CTC forward score for a model-proposed sequence, not a ground-truth correction."""
    values=np.asarray(log_probabilities,dtype=np.float64)
    if values.ndim!=2 or np.isnan(values).any() or np.isposinf(values).any():
        raise ValueError('Invalid log probabilities')
    if any(c==blank or c<0 or c>=values.shape[1] for c in sequence):
        raise ValueError('Candidate contains blank or an invalid class')
    if not sequence:return float(values[:,blank].sum())
    if len(values)==0:return NEG_INF
    symbols=[blank]
    for char in sequence:symbols.extend([int(char),blank])
    state=[NEG_INF]*len(symbols);state[0]=float(values[0,blank]);state[1]=float(values[0,symbols[1]])
    for scores in values[1:]:
        next_state=[NEG_INF]*len(state)
        for s,char in enumerate(symbols):
            total=state[s]
            if s:total=log_add(total,state[s-1])
            if s>1 and char!=blank and char!=symbols[s-2]:total=log_add(total,state[s-2])
            next_state[s]=total+float(scores[char])
        state=next_state
    return log_add(state[-1],state[-2])
