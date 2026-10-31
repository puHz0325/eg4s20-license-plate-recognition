"""Evaluate CTC candidates with validation-only rejection calibration; no deployment."""
import argparse
import itertools
import json
import math
from pathlib import Path
import sys
import time

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))

from ctc_search import (prefix_beam_search,greedy_indices,plate_prefix_valid,log_softmax,
                        sequence_log_probability)
from lpr_common import CHARS
from prepare_highres import file_hash


POLICIES=('raw','free_beam','plate_beam','fallback')


def write_json(path,data):
    temporary=path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(data,ensure_ascii=False,indent=2,allow_nan=False)+'\n',encoding='utf-8')
    temporary.replace(path)


def candidate_features(probabilities,indices):
    valid=len(indices)==7 and plate_prefix_valid(indices)
    text=''.join(CHARS[i] for i in indices)
    if not valid:return dict(text=text,valid=False,nll=None,evidence=None,gap=None)
    score=sequence_log_probability(probabilities,indices,67)
    if not math.isfinite(score):return dict(text=text,valid=False,nll=None,evidence=None,gap=None)
    return dict(text=text,valid=True,log_probability=score,nll=-score/7,
        evidence=(score-float(probabilities[:,67].sum()))/7,
        gap=max(0.,float(probabilities.max(1).sum())-score)/len(probabilities))


def decode_frame(logits,beam_width=8,top_k=5):
    probabilities=log_softmax(logits)
    raw=greedy_indices(probabilities.argmax(1),67)
    free=prefix_beam_search(probabilities,67,beam_width,top_k,False)
    constrained=prefix_beam_search(probabilities,67,beam_width,top_k,True)
    completed=[row for row in constrained if len(row['indices'])==7]
    candidates={'raw':raw,'free_beam':free[0]['indices'] if free else (),
                'plate_beam':completed[0]['indices'] if completed else ()}
    features={};memo={}
    for policy,indices in candidates.items():
        if indices not in memo:memo[indices]=candidate_features(probabilities,indices)
        features[policy]=memo[indices]
    features['fallback']=features['raw'] if features['raw']['valid'] else features['plate_beam']
    if completed and features['plate_beam']['valid']:
        # Beam pruning may lose probability mass, but it must not invent extra mass.
        if completed[0]['log_probability']>features['plate_beam']['log_probability']+1e-6:
            raise AssertionError('Beam mass exceeds exact forward score')
    return features


def vectors(rows,policy):
    features=[row['candidates'][policy] for row in rows]
    return dict(valid=np.array([r['valid'] for r in features]),
        nll=np.array([r.get('nll') if r.get('nll') is not None else np.inf for r in features]),
        evidence=np.array([r.get('evidence') if r.get('evidence') is not None else -np.inf for r in features]),
        gap=np.array([r.get('gap') if r.get('gap') is not None else np.inf for r in features]),
        correct=np.array([r['text']==row['expected'] for r,row in zip(features,rows,strict=True)]),
        non_anhui=np.array([bool(row['expected']) and row['expected'][0]!='皖' for row in rows]))


def accepted(values,thresholds):
    nll,evidence,gap=thresholds
    return (values['valid'] & (values['nll']<=nll) & (values['evidence']>=evidence)
            & (values['gap']<=gap))


def metrics(values,mask,subset=None):
    if subset is None:subset=np.ones(len(mask),dtype=bool)
    total=int(subset.sum());active=mask&subset
    correct=int((active&values['correct']).sum());count=int(active.sum())
    return dict(samples=total,accepted=count,rejected=total-count,correct_accepted=correct,
        wrong_accepted=count-correct,correct_accept_rate=correct/total if total else 0.,
        coverage=count/total if total else 0.,accepted_only_accuracy=correct/count if count else None)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--beam-width',type=int,default=8)
    parser.add_argument('--top-k',type=int,default=5)
    parser.add_argument('--limit',type=int,default=0,help='Smoke only: deterministic prefix of each group')
    parser.add_argument('--resume',action='store_true')
    args=parser.parse_args()
    manifest=json.loads((args.cache/'manifest.json').read_text(encoding='utf-8'))
    config=dict(cache_manifest_sha256=file_hash(args.cache/'manifest.json'),beam_width=args.beam_width,
                top_k=args.top_k,limit=args.limit,negative_false_accept_target=.01)
    args.output.mkdir(parents=True,exist_ok=True)
    if (args.output/'config.json').exists():
        if not args.resume or json.loads((args.output/'config.json').read_text(encoding='utf-8'))!=config:
            raise ValueError('Existing output preserved; --resume requires identical configuration')
    else:write_json(args.output/'config.json',config)
    groups={};timing={};begin=time.monotonic()
    for tag,meta in manifest['groups'].items():
        path=args.output/(tag+'.json')
        if path.exists() and args.resume:
            groups[tag]=json.loads(path.read_text(encoding='utf-8'));continue
        if file_hash(args.cache/(tag+'.npy'))!=meta['logits'] or file_hash(args.cache/(tag+'.json'))!=meta['records']:
            raise ValueError('Logits/metadata cache changed')
        records=json.loads((args.cache/(tag+'.json')).read_text(encoding='utf-8'))
        values=np.load(args.cache/(tag+'.npy'),mmap_mode='r')
        count=min(len(records),args.limit) if args.limit else len(records)
        rows=[];started=time.monotonic()
        for index in range(count):
            row=dict(records[index],candidates=decode_frame(values[index],args.beam_width,args.top_k))
            rows.append(row)
            if (index+1)%200==0:print(json.dumps({'group':tag,'decoded':index+1,'total':count}),flush=True)
        groups[tag]=rows;timing[tag]=time.monotonic()-started;write_json(path,rows)
        print(json.dumps({'group_complete':tag,'samples':count,'seconds':timing[tag]}),flush=True)
    arrays={policy:{tag:vectors(rows,policy) for tag,rows in groups.items()} for policy in POLICIES}
    thresholds=list(itertools.product([.2,.35,.5,.75,1.,1.5,2.,3.,5.,8.,float('inf')],
                                      [-float('inf'),0.,1.,2.,4.,8.],
                                      [.01,.03,.06,.12,.25,.5,1.,float('inf')]))
    best=None;best_key=None;eligible_count=0
    for policy in POLICIES:
        data=arrays[policy]
        for threshold in thresholds:
            rates={tag:float(accepted(data[tag],threshold).mean()) for tag in ['negative_calibration','partial_calibration']}
            if any(rate>.01 for rate in rates.values()):continue
            eligible_count+=1
            a=metrics(data['val_main'],accepted(data['val_main'],threshold))
            b=metrics(data['val_province'],accepted(data['val_province'],threshold),data['val_province']['non_anhui'])
            objective=.5*(a['correct_accept_rate']+b['correct_accept_rate'])
            key=(objective,-max(rates.values()),-a['wrong_accepted']-b['wrong_accepted'],a['coverage']+b['coverage'])
            if best_key is None or key>best_key:
                best_key=key;best=dict(policy=policy,thresholds=threshold,calibration_false_accept=rates,
                                      validation_main=a,validation_non_anhui=b,objective=objective)
    if best is None:raise RuntimeError('No configuration meets calibration false acceptance target')
    # Freeze the validation-chosen decision before measuring the fixed regression/evaluation partitions.
    threshold=tuple(best['thresholds']);policy=best['policy']
    frozen=dict(best);frozen['thresholds']=[x if math.isfinite(x) else None for x in threshold]
    frozen['threshold_order']=['max_nll','min_evidence','max_gap'];frozen['none_means']='no bound'
    write_json(args.output/'selected_validation.json',frozen)
    report={};ungated={}
    for tag in groups:
        data=arrays[policy][tag];report[tag]=metrics(data,accepted(data,threshold))
        if tag in ['val_province','reg_province']:
            report[tag]['non_anhui']=metrics(data,accepted(data,threshold),data['non_anhui'])
        ungated[tag]={name:metrics(arrays[name][tag],arrays[name][tag]['valid']) for name in POLICIES}
        if tag in ['negative_calibration','negative_evaluation','partial_calibration','partial_evaluation']:
            report[tag]['false_accept_rate']=report[tag]['coverage']
    baseline_a=ungated['val_main']['raw']['correct_accept_rate']
    base_values=arrays['raw']['val_province']
    baseline_b=metrics(base_values,base_values['valid'],base_values['non_anhui'])['correct_accept_rate']
    baseline_objective=.5*(baseline_a+baseline_b)
    qualifies=(best['objective']>=baseline_objective+.005 and
               best['validation_main']['correct_accept_rate']>=baseline_a-.005)
    write_json(args.output/'summary.json',dict(status='COMPLETE',smoke=bool(args.limit),selected=frozen,
        evaluation=report,ungated_candidate_diagnostics=ungated,validation_qualified=qualifies,
        baseline_validation_objective=baseline_objective,eligible_configurations=eligible_count,
        decoding_seconds=timing,elapsed_seconds=time.monotonic()-begin,ccpd2020_used=False,
        caveat='Ungated grammar candidates are not safe system outputs. Thresholds selected only on calibration/validation partitions. Fixed positives were inspected in prior experiments; no phone capture, real-camera or FPGA validation.'))
    print(json.dumps({'qualified':qualifies,'policy':policy,'validation_main':best['validation_main']['correct_accept_rate'],
        'validation_non_anhui':best['validation_non_anhui']['correct_accept_rate'],
        'regression_main':report['reg_main']['correct_accept_rate'],
        'negative_eval_false_accept':report['negative_evaluation']['false_accept_rate'],
        'partial_eval_false_accept':report['partial_evaluation']['false_accept_rate']}),flush=True)


if __name__=='__main__':main()
