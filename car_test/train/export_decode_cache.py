"""Freeze logits and source-separated CCPD2019 negatives for offline decoder evaluation."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
import torch

from model import FPGA_LPRNet
from prepare_highres import file_hash
from train_highres import save_json


def infer(model,pixels,device):
    result=[]
    with torch.inference_mode():
        for start in range(0,len(pixels),256):
            x=torch.from_numpy((np.asarray(pixels[start:start+256],dtype=np.float32)-127.5)/128.)[:,None]
            result.append(model(x.to(device)).permute(0,2,1).cpu().numpy())
    values=np.concatenate(result)
    if not np.isfinite(values).all():raise ValueError('Nonfinite model logits')
    return values


def negative_source(path):
    encoded=path.read_bytes();sha=hashlib.sha256(encoded).hexdigest()
    image=cv2.imdecode(np.frombuffer(encoded,np.uint8),cv2.IMREAD_COLOR)
    if image is None:
        return None,dict(source=str(path.resolve()),sha256=sha,bytes=len(encoded),error='decode_failed'),None
    red=cv2.resize(image[:,:,2],(640,480),interpolation=cv2.INTER_LINEAR)
    pixels=cv2.resize(red[192:288,132:508],(128,32),interpolation=cv2.INTER_LINEAR)
    split='calibration' if int(sha[:8],16)%2==0 else 'evaluation'
    return split,dict(id=sha,source=str(path.resolve()),sha256=sha,expected=None,
                       kind='dataset_labeled_no_plate_center_roi'),pixels


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--weights',type=Path,required=True)
    parser.add_argument('--main-data',type=Path,required=True)
    parser.add_argument('--province-data',type=Path,required=True)
    parser.add_argument('--np-root',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();cv2.setNumThreads(1);torch.set_num_threads(2)
    if args.output.exists():raise FileExistsError('Existing cache preserved')
    args.output.mkdir(parents=True)
    device='cuda' if torch.cuda.is_available() else 'cpu'
    model=FPGA_LPRNet(68,input_height=32).to(device).eval()
    model.load_state_dict(torch.load(args.weights,map_location='cpu',weights_only=True))
    groups={};hashes={};positive_pixels={}
    for tag,root,split in [('val_main',args.main_data,'val'),('val_province',args.province_data,'val'),
                            ('reg_main',args.main_data,'test'),('reg_province',args.province_data,'test')]:
        rows=[json.loads(line) for line in (root/f'{split}.jsonl').read_text(encoding='utf-8').splitlines()]
        pixels=np.load(root/f'128x32/{split}.npy',mmap_mode='r')
        ordered=np.stack([pixels[row['cache_index']] for row in rows])
        values=infer(model,ordered,device)
        np.save(args.output/f'{tag}.npy',values)
        groups[tag]=[dict(id=row['id'],expected=row['plate'],source=row['source'],kind='positive') for row in rows]
        positive_pixels[tag]=ordered
        print(f'LOGITS {tag} {len(rows)}',flush=True)
    negatives={'calibration':[],'evaluation':[]};neg_pixels={'calibration':[],'evaluation':[]};seen=set();decode_errors=[]
    with ThreadPoolExecutor(max_workers=6) as pool:
        for split,row,pixels in pool.map(negative_source,sorted(args.np_root.glob('*.jpg'))):
            if pixels is None:decode_errors.append(row);continue
            if row['sha256'] in seen:continue
            seen.add(row['sha256']);negatives[split].append(row);neg_pixels[split].append(pixels)
    for split in negatives:
        tag='negative_'+split
        np.save(args.output/f'{tag}.npy',infer(model,np.stack(neg_pixels[split]),device))
        groups[tag]=negatives[split]
        print(f'LOGITS {tag} {len(negatives[split])}',flush=True)
    for split,source in [('calibration','val_province'),('evaluation','reg_province')]:
        tag='partial_'+split;rows=[];pixels=[]
        for index,original in enumerate(groups[source][:512]):
            image=positive_pixels[source][index].copy()
            # Remove half the input, rather than pretending a complete but blurred plate is negative.
            image[:,:64]=127
            pixels.append(image);rows.append(dict(original,id=original['id']+':left_half_occluded',
                expected=None,kind='synthetic_incomplete_plate',origin_positive_id=original['id']))
        np.save(args.output/f'{tag}.npy',infer(model,np.stack(pixels),device));groups[tag]=rows
        print(f'LOGITS {tag} {len(rows)}',flush=True)
    for tag,rows in groups.items():
        save_json(args.output/f'{tag}.json',rows)
        hashes[tag]=dict(logits=file_hash(args.output/f'{tag}.npy'),records=file_hash(args.output/f'{tag}.json'),samples=len(rows))
    save_json(args.output/'manifest.json',dict(format='lpr-logits-v1',weights_sha256=file_hash(args.weights),
        input_wh=[128,32],logits_layout='N,T,C',groups=hashes,ccpd2020_used=False,
        no_plate_decode_errors=decode_errors,
        caveat='No-plate images split by original SHA; scene/session membership unavailable. Undecodable sources are recorded and excluded, never replaced by blank pixels. Partial images are artificial and grouped with their source partition. Fixed positive regression sets were already inspected in earlier experiments; not new real-camera evidence.'))
    print('EXPORT_DECODE_CACHE_PASS',flush=True)


if __name__=='__main__':main()
