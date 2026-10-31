"""Merge parent raw training views with province augmentation; preserve the locked holdouts."""
import argparse
from collections import Counter
import json
from pathlib import Path
import shutil

import numpy as np

from prepare_highres import file_hash


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent',type=Path,required=True)
    parser.add_argument('--province',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists():raise FileExistsError(args.output)
    (args.output/'128x32').mkdir(parents=True)
    manifest=json.loads((args.province/'manifest.json').read_text(encoding='utf-8'))
    sets=[];caches=[]
    for root in [args.parent,args.province]:
        sets.append([json.loads(line) for line in (root/'train.jsonl').read_text(encoding='utf-8').splitlines()])
        caches.append(np.load(root/'128x32/train.npy',mmap_mode='r'))
    cache=np.lib.format.open_memmap(args.output/'128x32/train.npy',mode='w+',dtype=np.uint8,
                                    shape=(sum(map(len,sets)),32,128))
    rows=[];seen=set()
    for group,source in zip(sets,caches,strict=True):
        for original in group:
            row=dict(original);mode=row.get('crop_mode','raw');key=(row['id'],mode)
            if key in seen:continue
            seen.add(key);index=len(rows);cache[index]=source[row['cache_index']]
            row.update(source_id=row['id'],id=f"{row['id']}:{mode}",crop_mode=mode,cache_index=index)
            rows.append(row)
    cache.flush()
    target=args.output/'train.jsonl'
    target.write_text(''.join(json.dumps(row,ensure_ascii=False)+'\n' for row in rows),encoding='utf-8')
    for split in ['val','test']:
        shutil.copyfile(args.province/f'{split}.jsonl',args.output/f'{split}.jsonl')
        shutil.copyfile(args.province/f'128x32/{split}.npy',args.output/f'128x32/{split}.npy')
        eval_plates={json.loads(line)['plate'] for line in (args.output/f'{split}.jsonl').read_text(encoding='utf-8').splitlines()}
        assert not eval_plates & {row['plate'] for row in rows}
    manifest['variant']='parent_raw_rehearsal'
    manifest['component_manifests']={str(root.resolve()):file_hash(root/'manifest.json') for root in [args.parent,args.province]}
    manifest['splits']['train']=dict(samples=len(rows),distinct_plates=len({r['plate'] for r in rows}),
        provinces=dict(Counter(r['plate'][0] for r in rows)),crop_modes=dict(Counter(r['crop_mode'] for r in rows)),
        records_sha256=file_hash(target))
    manifest['cache_sha256']={f'128x32/{split}.npy':file_hash(args.output/f'128x32/{split}.npy') for split in ['train','val','test']}
    (args.output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(manifest['splits']['train'],ensure_ascii=False))
    print('PREPARE_REHEARSAL_PASS')


if __name__=='__main__':main()
