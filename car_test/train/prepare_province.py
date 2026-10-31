"""Build a seven-character province-focused set with new, parent-unseen holdout plates."""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path

import cv2
import numpy as np

from prepare_highres import decode_annotation, full_crop_box, digest, file_hash, plate_split
from lpr_common import CHARS
from lpr8_preprocess import resize_plate_red


def rectify_red(image, corners):
    br,bl,tl,tr = corners
    src = np.asarray([tl,tr,br,bl],dtype=np.float32)
    dst = np.asarray([[2,1],[125,1],[125,30],[2,30]],dtype=np.float32)
    matrix = cv2.getPerspectiveTransform(src,dst)
    return cv2.warpPerspective(image[:,:,2],matrix,(128,32),flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_REPLICATE)


def process_item(record):
    encoded = Path(record['source']).read_bytes()
    image = cv2.imdecode(np.frombuffer(encoded,np.uint8),cv2.IMREAD_COLOR)
    if image is None: raise ValueError('decode')
    h,w = image.shape[:2]
    if any(not(0<=x<w and 0<=y<h) for x,y in record['corners']):raise ValueError('vertices_outside_image')
    x0,y0,x1,y1 = record['bbox'];x0,y0,x1,y1=max(x0,0),max(y0,0),min(x1,w),min(y1,h)
    if x1-x0<128 or y1-y0<32:raise ValueError('native_resolution')
    red = np.ascontiguousarray(image[y0:y1,x0:x1,2])
    if np.percentile(red,95)-np.percentile(red,5)<12:raise ValueError('almost_no_R8_contrast')
    pixels = (rectify_red(image,record['corners']) if record['crop_mode']=='rectified'
              else resize_plate_red(red))
    meta = dict(record,crop_bbox=[x0,y0,x1,y1],source_sha256=hashlib.sha256(encoded).hexdigest(),
                native_hw=list(red.shape),crop_sha256=hashlib.sha256(pixels.tobytes()).hexdigest())
    return meta,pixels


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--parent-data',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--seed',type=int,default=2026102603)
    parser.add_argument('--workers',type=int,default=8)
    args=parser.parse_args();cv2.setNumThreads(1)
    if args.output.exists():raise FileExistsError(args.output)
    args.output.mkdir(parents=True)
    parent = {};seen_parent=set()
    for split in ['train','val','test']:
        rows=[json.loads(line) for line in (args.parent_data/f'{split}.jsonl').read_text(encoding='utf-8').splitlines()]
        parent[split]={x['plate'] for x in rows};seen_parent|=parent[split]
    forbidden=parent['val']|parent['test'];records=[];seen_names=set();rejected=Counter();subsets=Counter()
    for folder in sorted(args.source.glob('ccpd_*')):
        if not folder.is_dir():continue
        for entry in sorted(os.scandir(folder),key=lambda x:x.name):
            if not entry.name.lower().endswith('.jpg'):continue
            subsets[folder.name]+=1
            try:
                item=decode_annotation(entry.name)
                if entry.name in seen_names:rejected['duplicate_name']+=1;continue
                seen_names.add(entry.name)
                if item['plate'] in forbidden:rejected['locked_parent_val_test_plate']+=1;continue
                split='train' if item['plate'] in parent['train'] else plate_split(item['plate'],args.seed)
                br,bl,tl,tr=map(np.asarray,item['corners'])
                polygon=np.asarray([tl,tr,br,bl],dtype=np.int32)
                if not cv2.isContourConvex(polygon):rejected['nonconvex_quad']+=1;continue
                if min(np.linalg.norm(tr-tl),np.linalg.norm(br-bl))<128 or min(np.linalg.norm(bl-tl),np.linalg.norm(br-tr))<32:
                    rejected['insufficient_native_quad_resolution']+=1;continue
                controlled=item['horizontal']<=12 and item['vertical']<=15
                if split!='train' and not controlled:rejected['holdout_fixed_roi_scope']+=1;continue
                if item['horizontal']>35 or item['vertical']>45:rejected['extreme_pose']+=1;continue
                item['annotation_bbox']=list(item['bbox']);item['bbox']=full_crop_box(item)
                ident=digest(entry.name)[:24]
                mode='rectified' if split=='train' and (not controlled or int(ident[:2],16)%2==0) else 'raw'
                item.update(id=ident,source=str(Path(entry.path).resolve()),subset=folder.name,split=split,
                            crop_mode=mode,parent_plate_seen=item['plate'] in seen_parent)
                records.append(item)
            except (ValueError,IndexError):rejected['annotation']+=1
        print(json.dumps({'scanned':folder.name,'candidates':len(records)}),flush=True)
    records.sort(key=lambda r:digest(f"{args.seed}:{r['id']}"))
    per_plate=Counter();capped=[]
    for row in records:
        if per_plate[row['plate']]<3:capped.append(row);per_plate[row['plate']]+=1
        else:rejected['per_plate_cap']+=1
    result={};split_plates={};crop_hashes=set()
    for split in ['train','val','test']:
        buckets=defaultdict(list)
        for row in capped:
            if row['split']==split:buckets[row['plate'][0]].append(row)
        selected=[]
        for province,group in sorted(buckets.items()):
            cap=(6000 if province=='皖' else 5000) if split=='train' else (400 if province=='皖' else 200)
            selected.extend(group[:cap])
        selected.sort(key=lambda r:digest(f"{args.seed}:order:{r['id']}"))
        if not selected:raise ValueError('Empty split')
        folder=args.output/'128x32';folder.mkdir(exist_ok=True)
        cache=np.lib.format.open_memmap(folder/f'{split}.npy',mode='w+',dtype=np.uint8,shape=(len(selected),32,128))
        def safe(row):
            try:return process_item(row)
            except (ValueError,OSError) as exc:return str(exc),None
        accepted=[]
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            for index,(meta,pixels) in enumerate(pool.map(safe,selected),1):
                if pixels is None:rejected[f'image:{meta}']+=1;continue
                if meta['crop_sha256'] in crop_hashes:rejected['duplicate_pixels']+=1;continue
                crop_hashes.add(meta['crop_sha256']);meta['cache_index']=len(accepted)
                cache[len(accepted)]=pixels;accepted.append(meta)
                if index%2000==0:print(f'{split} {index}/{len(selected)} accepted {len(accepted)}',flush=True)
        cache.flush()
        target=args.output/f'{split}.jsonl'
        target.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in accepted),encoding='utf-8')
        split_plates[split]={r['plate'] for r in accepted}
        if split!='train':assert not split_plates[split]&seen_parent
        result[split]=dict(samples=len(accepted),distinct_plates=len(split_plates[split]),
            provinces=dict(Counter(r['plate'][0] for r in accepted)),
            crop_modes=dict(Counter(r['crop_mode'] for r in accepted)),
            records_sha256=file_hash(target))
        print(json.dumps({split:result[split]},ensure_ascii=False),flush=True)
    assert all(not split_plates[a]&split_plates[b] for a,b in [('train','val'),('train','test'),('val','test')])
    manifest=dict(format='lpr-province-dataset-v3',chars=CHARS,seed=args.seed,sizes_wh=[[128,32]],
        source=str(args.source.resolve()),parent_manifest_sha256=file_hash(args.parent_data/'manifest.json'),
        parent_seen_plate_counts={key:len(value) for key,value in parent.items()},
        holdout_parent_plate_overlap=0,source_subset_counts=dict(subsets),rejected=dict(rejected),splits=result,
        cache_sha256={f'128x32/{s}.npy':file_hash(args.output/f'128x32/{s}.npy') for s in result},
        caveat='Province-focused custom distribution. New holdout plates exclude every parent train/val/test plate; not the official benchmark or real-camera validation. Only training may use perspective rectification.')
    (args.output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PREPARE_PROVINCE_PASS',flush=True)


if __name__=='__main__':main()
