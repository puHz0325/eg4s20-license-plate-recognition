"""Audit the selected QAT checkpoint on complete validation using exact INT8 math."""
import argparse
from collections import Counter,defaultdict
import json
from pathlib import Path
import time

import numpy as np
import torch

from exact_integer_gpu import ExactIntegerGPU
from integer_reference import IntegerNetwork,file_hash
from model import FPGA_LPRNet
from teacher_qat import FixedScaleTeacher
from robust_teacher import RobustPlates,pair_report
from train_highres import CachedPlates,decode_indices,alignment_counts,save_json

ROOT=Path(__file__).resolve().parents[2]


def metrics(rows):
    province=defaultdict(lambda:[0,0]); errors=Counter(); edits=insertions=deletions=0
    for r in rows:
        truth,text=r['expected'],r['prediction'];province[truth[0]][0]+=truth==text;province[truth[0]][1]+=1
        stat=alignment_counts(truth,text);errors.update(stat['substitutions'])
        edits+=stat['edits'];insertions+=stat['insertions'];deletions+=stat['deletions']
    n=len(rows); correct=sum(r['expected']==r['prediction'] for r in rows)
    non=sum(v[1] for k,v in province.items() if k!='皖'); non_correct=sum(v[0] for k,v in province.items() if k!='皖')
    result=dict(samples=n,exact_matches=correct,plate_accuracy=correct/n,
        non_anhui_samples=non,non_anhui_accuracy=non_correct/non if non else 0.,
        character_error_rate=edits/sum(len(r['expected']) for r in rows),insertions=insertions,deletions=deletions,
        substitutions=dict(errors),province={k:dict(correct=v[0],samples=v[1],accuracy=v[0]/v[1]) for k,v in province.items()})
    result['confusion_pairs']=pair_report(result,[r['expected'] for r in rows]);return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run',type=Path,required=True);p.add_argument('--package',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--split',choices=['val','test'],default='val');args=p.parse_args()
    if args.output.exists():raise FileExistsError('Preserve existing audit')
    args.output.mkdir(parents=True)
    torch.set_num_threads(4);torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    config=json.loads((args.run/'config.json').read_text(encoding='utf-8'))
    spec=json.loads((args.package/'model.json').read_text(encoding='utf-8'))
    if spec['metadata']['weights_sha256']!=file_hash(args.run/'model_state.pth'):raise ValueError('Wrong QAT source')
    models={tag:IntegerNetwork.load(path) for tag,path in [('parent',ROOT/'car_test/train/accuracy_stage2/teacher_int8'),('candidate',args.package)]}
    accelerators={tag:ExactIntegerGPU(model) for tag,model in models.items()}
    floating=FPGA_LPRNet(**config['model_options']).cuda().eval()
    floating.load_state_dict(torch.load(args.run/'model_state.pth',map_location='cpu',weights_only=True))
    qat=FixedScaleTeacher(floating,IntegerNetwork.load(Path(config['qat_package']))).eval()
    random=np.random.default_rng(2026102905).integers(0,256,(2,32,128),dtype=np.uint8)
    parity={tag:accelerator.verify(random) for tag,accelerator in accelerators.items()}
    roots=dict(main=Path(config['main_data']),province=Path(config['data']))
    datasets={tag:CachedPlates(root,'128x32',args.split) for tag,root in roots.items()}
    if args.split=='val':
        stress_ids=json.loads((args.run/'stress_validation_ids.json').read_text(encoding='utf-8'))
    else:
        stress_ids={};rng=np.random.default_rng(config['seed']+1)
        for source,dataset in datasets.items():
            eligible=[i for i,r in enumerate(dataset.records) if source=='main' or r['plate'][0]!='皖']
            chosen=sorted(rng.choice(eligible,min(512,len(eligible)),replace=False).tolist())
            stress_ids[source]=[dataset.records[i]['id'] for i in chosen]
    for source,root in roots.items():
        lookup={r['id']:i for i,r in enumerate(datasets[source].records)}
        ids=[lookup[k] for k in stress_ids[source]]
        for mode in ('inverted','low_contrast','soft_strokes'):
            datasets['stress_'+source+'_'+mode]=RobustPlates(root,args.split,config['seed']+17,mode,ids)
    reports={tag:{} for tag in models}; all_rows={tag:{} for tag in models};numeric={};begin=time.monotonic()
    for group,dataset in datasets.items():
        rows={tag:[] for tag in models};differences=0;first_differences=[]
        for start in range(0,len(dataset),32):
            subset=dataset.records[start:start+32]
            images=[]
            for i,r in enumerate(subset,start):
                if isinstance(dataset,RobustPlates):
                    tensor,_,_=dataset[i];image=np.rint(tensor.numpy()[0]*128.+127.5).astype(np.uint8)
                else:image=dataset.pixels[r['cache_index']]
                images.append(image)
            images=np.stack(images)
            texts={}
            for tag,accelerator in accelerators.items():
                logits,_=accelerator.forward(images);texts[tag]=decode_indices(logits[:,:,0,:].argmax(1))
                rows[tag].extend(dict(id=r['id'],expected=r['plate'],prediction=text) for r,text in zip(subset,texts[tag],strict=True))
            with torch.inference_mode():
                output=qat(torch.from_numpy((images.astype(np.float32)-127.5)/128.)[:,None].cuda())
                simulated=decode_indices(output.argmax(1).cpu().numpy())
            for r,a,b in zip(subset,simulated,texts['candidate'],strict=True):
                if a!=b:
                    differences+=1
                    if len(first_differences)<12:first_differences.append(dict(id=r['id'],qat=a,integer=b))
            if start%512==0:print(json.dumps(dict(group=group,done=min(start+32,len(dataset)),total=len(dataset))),flush=True)
        for tag in models:
            reports[tag][group]=metrics(rows[tag]);all_rows[tag][group]=rows[tag]
        numeric[group]=dict(samples=len(dataset),prediction_differences=differences,examples=first_differences)
        save_json(args.output/'progress.json',dict(group=group,metrics=reports,numeric=numeric))
    base,new=reports['parent'],reports['candidate']
    robustness={tag:float(np.mean([v['plate_accuracy'] for k,v in data.items() if k.startswith('stress_')])) for tag,data in reports.items()}
    gates=dict(main_retention=new['main']['plate_accuracy']>=base['main']['plate_accuracy']-.005,
        non_anhui_retention=new['province']['non_anhui_accuracy']>=base['province']['non_anhui_accuracy']-.015,
        robustness_gain=robustness['candidate']>=robustness['parent']+.10,
        qat_export_agreement=sum(v['prediction_differences'] for v in numeric.values())/sum(v['samples'] for v in numeric.values())<=.001)
    result=dict(status='COMPLETE',partition=args.split,passed=all(gates.values()),gates=gates,reports=reports,qat_integer=numeric,
        robust_mean=robustness,independent_cpu_int64_compared_values=parity,
        model_sha256=file_hash(args.package/'model_init.bin'),weights_sha256=file_hash(args.run/'model_state.pth'),
        elapsed_seconds=time.monotonic()-begin,
        audit_source_sha256=file_hash(Path(__file__)),accelerator_source_sha256=file_hash(Path(__file__).with_name('exact_integer_gpu.py')),
        explanation='Raw FP32 weights and fake-quantized QAT define different models. Both raw FP32 audits and their original failed small-sample gate remain preserved. This audit uses complete, paired validation and the actual deployable INT8 model; it does not use test/camera labels for tuning.')
    for tag,data in all_rows.items():save_json(args.output/(tag+'_predictions.json'),data)
    save_json(args.output/'summary.json',result)
    print(json.dumps(dict(passed=result['passed'],gates=gates,robust_mean=robustness,
        main={k:v['main']['plate_accuracy'] for k,v in reports.items()},
        non_anhui={k:v['province']['non_anhui_accuracy'] for k,v in reports.items()},numeric=numeric),ensure_ascii=False,indent=2),flush=True)


if __name__=='__main__':main()
