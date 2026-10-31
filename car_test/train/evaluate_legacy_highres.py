"""Diagnostic legacy94 comparison on the same raw-crop holdout; old training membership is unknown."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset, DataLoader

from model import FPGA_LPRNet
from prepare_highres import file_hash
from train_highres import CHAR_INDEX, collate, evaluate, save_json


class LegacyPixels(Dataset):
    def __init__(self, records, pixels):
        self.records, self.pixels = records, pixels

    def __len__(self):
        return len(self.records)

    def __getitem__(self, index):
        plate = self.records[index]['plate']
        normalized = (self.pixels[index].astype(np.float32)-127.5)/128.
        return torch.from_numpy(normalized[None]), tuple(CHAR_INDEX[c] for c in plate), plate


def original_pixels(record):
    encoded = Path(record['source']).read_bytes()
    import hashlib
    if hashlib.sha256(encoded).hexdigest() != record['source_sha256']:
        raise ValueError('Original image changed since preparation')
    image = cv2.imdecode(np.frombuffer(encoded,np.uint8),cv2.IMREAD_COLOR)
    x0,y0,x1,y1 = record['crop_bbox']
    return cv2.resize(image[y0:y1,x0:x1,2],(94,24),interpolation=cv2.INTER_LINEAR)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--weights',type=Path,default=Path(__file__).with_name('weights')/'fpga_best_model.pth')
    args = parser.parse_args()
    cv2.setNumThreads(1); torch.set_num_threads(2)
    records = [json.loads(line) for line in (args.data/'test.jsonl').read_text(encoding='utf-8').splitlines()]
    with ThreadPoolExecutor(max_workers=6) as pool:
        pixels = np.stack(list(pool.map(original_pixels,records)))
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    model = FPGA_LPRNet(68).to(device)
    model.load_state_dict(torch.load(args.weights,map_location=device,weights_only=True))
    loader = DataLoader(LegacyPixels(records,pixels),batch_size=128,shuffle=False,
                        num_workers=0,collate_fn=collate)
    metrics = evaluate(model,loader,device,include_predictions=True)
    for prediction,record in zip(metrics['predictions'],records,strict=True):
        prediction.update(id=record['id'],source=record['source'])
    old_dir = Path(__file__).with_name('train_data1')
    known_old_plates = {path.stem.split('_')[0] for path in old_dir.glob('*.jpg')}
    overlap = {r['plate'] for r in records} & known_old_plates
    report = dict(model='legacy_94x24',model_sha256=file_hash(args.weights),
        dataset_manifest_sha256=file_hash(args.data/'manifest.json'),
        metrics=metrics,known_old_directory_plate_overlap=len(overlap),
        caveat='Legacy training split/checkpoint history is unknown; this diagnostic score is not certified independent validation and is not used to select the new models.')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    save_json(args.output,report)
    print(json.dumps({'legacy_accuracy':metrics['plate_accuracy'],'legacy_CER':metrics['character_error_rate'],
                      'known_legacy_plate_overlap':len(overlap)},ensure_ascii=False),flush=True)


if __name__ == '__main__':
    main()
