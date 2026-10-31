"""Read-only audit of reported confusions, frozen metrics and training coverage."""
import argparse
from collections import Counter,defaultdict
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
PAIRS=[('T','1'),('Z','4'),('C','G'),('0','8'),('黑','冀'),('湘','浙')]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    if args.output.exists():raise FileExistsError('Preserve previous audit')
    run=ROOT/'train/accuracy_stage2/teacher_run'
    config=json.loads((run/'config.json').read_text(encoding='utf-8'))
    fixed=json.loads((run/'fixed_regression.json').read_text(encoding='utf-8'))
    best=json.loads((run/'best_validation.json').read_text(encoding='utf-8'))
    path=Path(config['data'])/'train.jsonl'
    char_images=Counter();char_occurrences=Counter();provinces=Counter();unique=defaultdict(set);unique_all=set();total=0
    for line in path.read_text(encoding='utf-8').splitlines():
        r=json.loads(line);plate=r['plate'];total+=1;unique_all.add(plate)
        char_images.update(set(plate));char_occurrences.update(plate)
        provinces[plate[0]]+=1;unique[plate[0]].add(plate)
    sets={tag:value for tag,value in fixed['reports'].items()}
    sets['validation_main']=best['main_metrics'];sets['validation_province']=best['province_metrics']
    pairs=[]
    for a,b in PAIRS:
        observed={}
        for tag,data in sets.items():
            errors=data.get('substitutions',{})
            observed[tag]=dict(samples=data['samples'],a_to_b=errors.get(a+'>'+b,0),b_to_a=errors.get(b+'>'+a,0))
        pairs.append(dict(pair=[a,b],training_images={a:char_images[a],b:char_images[b]},
            training_occurrences={a:char_occurrences[a],b:char_occurrences[b]},observed_substitutions=observed,
            province_training_unique={c:len(unique[c]) for c in [a,b] if c in provinces}))
    province_metrics={}
    for c in ['黑','冀','湘','浙','苏','皖']:
        province_metrics[c]=dict(training_images=provinces[c],training_unique_plates=len(unique[c]),
            validation=best['province_metrics']['province_results'].get(c))
    report=dict(status='AUDIT_COMPLETE',pairs=pairs,province_metrics=province_metrics,
        training_rows=total,training_unique_plates=len(unique_all),source=str(path),
        notes=['Counts are observed substitutions, not conditional confusion rates; missing errors do not prove robustness.',
               'Current training includes raw and rectified views; image counts overstate unique-plate diversity.',
               'No new camera sampling, training, firmware or model modifications in this audit.'])
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
