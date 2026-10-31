"""One final frozen-test/camera audit after validation-only checkpoint selection."""
import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import DataLoader

from model import FPGA_LPRNet
from train_highres import CachedPlates, collate, save_json, decode_indices
from finetune_province import metrics_on
from robust_lpr8 import RobustPlates, pair_report
from prepare_highres import file_hash

ROOT = Path(__file__).resolve().parents[2]


def load_model(run):
    options = json.loads((run/'config.json').read_text(encoding='utf-8'))['model_options']
    model = FPGA_LPRNet(**options).cuda().eval()
    model.load_state_dict(torch.load(run/'model_state.pth', map_location='cpu', weights_only=True))
    return model


def camera_examples():
    base = ROOT/'car_test/PL/lpr8/video'
    review = json.loads((base/'verification_alignment_20261029/scene_presence_review.json').read_text(encoding='utf-8'))
    examples = [dict(image=r['image'], expected='浙CS8417', sha256=r['roi_sha256'], group='aligned_dark_plate')
                for r in review['samples'] if r['full_plate_visible']]
    bright = json.loads((base/'diagnosis_bright_20261029_01/report.json').read_text(encoding='utf-8'))
    examples += [dict(image=r['image'], expected=bright['expected'], sha256=r['roi_sha256'], group='bright_plate')
                 for r in bright['samples']]
    return examples


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run', type=Path, required=True)
    p.add_argument('--parent-run', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--data', type=Path, default=ROOT/'car_test/train/highres_v3/data_rehearsal')
    p.add_argument('--main-data', type=Path, default=ROOT/'car_test/train/highres_v2/data_quad')
    args = p.parse_args()
    if args.output.exists(): raise FileExistsError('Preserve previous fixed-test audit')
    qualification = json.loads((args.run/'summary.json').read_text(encoding='utf-8'))
    if not qualification['validation_qualified']: raise ValueError('First recover the validation retention gate')
    args.output.mkdir(parents=True)
    torch.set_num_threads(4); cv2.setNumThreads(1)
    models = dict(parent=load_model(args.parent_run), candidate=load_model(args.run))
    reports = {tag:{} for tag in models}
    for source, root in [('main_test', args.main_data), ('province_test', args.data)]:
        dataset = CachedPlates(root, '128x32', 'test')
        loader = DataLoader(dataset, batch_size=256, num_workers=0, pin_memory=True, collate_fn=collate)
        for tag, model in models.items():
            report = metrics_on(model, loader, 'cuda', dataset.records)
            report['confusion_pairs'] = pair_report(report, [r['plate'] for r in dataset.records])
            reports[tag][source] = report
            print(json.dumps(dict(model=tag, group=source, accuracy=report['plate_accuracy'],
                                  non_anhui=report['non_anhui_plate_accuracy']), ensure_ascii=False), flush=True)
        eligible = [i for i, r in enumerate(dataset.records) if source == 'main_test' or r['plate'][0] != '皖']
        ids = sorted(np.random.default_rng(2026102902).choice(eligible, min(512, len(eligible)), replace=False).tolist())
        for mode in ('inverted', 'low_contrast', 'soft_strokes'):
            stress = RobustPlates(root, 'test', 2026102902, mode, ids)
            loader = DataLoader(stress, batch_size=256, num_workers=0, pin_memory=True, collate_fn=collate)
            for tag, model in models.items():
                report = metrics_on(model, loader, 'cuda', stress.records)
                report['confusion_pairs'] = pair_report(report, [r['plate'] for r in stress.records])
                reports[tag]['stress_'+source+'_'+mode] = report
    camera = camera_examples()
    pixels = []
    for row in camera:
        image = cv2.imread(row['image'], cv2.IMREAD_GRAYSCALE)
        if image is None or image.shape != (32, 128): raise ValueError('Invalid camera validation image')
        if hashlib.sha256(image.tobytes()).hexdigest() != row['sha256']: raise ValueError('Changed camera pixels')
        pixels.append(image)
    with torch.inference_mode():
        images = torch.from_numpy((np.stack(pixels).astype(np.float32)-127.5)/128.)[:, None].cuda()
        for tag, model in models.items():
            decoded = decode_indices(model(images).argmax(1).cpu().numpy())
            for row, text in zip(camera, decoded, strict=True):
                row[tag] = text; row[tag+'_correct'] = text == row['expected']
    base, new = reports['parent'], reports['candidate']
    fixed_gate = (new['main_test']['plate_accuracy'] >= base['main_test']['plate_accuracy']-.005 and
                  new['province_test']['non_anhui_plate_accuracy'] >= base['province_test']['non_anhui_plate_accuracy']-.015)
    summary = dict(status='COMPLETE', fixed_retention_passed=fixed_gate, validation_qualified=True,
        weights_sha256={tag:file_hash(run/'model_state.pth') for tag, run in [('parent',args.parent_run), ('candidate',args.run)]},
        metrics={tag:dict(main=values['main_test']['plate_accuracy'], non_anhui=values['province_test']['non_anhui_plate_accuracy'],
            robust_mean=float(np.mean([v['plate_accuracy'] for k,v in values.items() if k.startswith('stress_')])))
            for tag, values in reports.items()},
        camera=camera, caveat='Camera frames cover two scenes only, are never used for training/checkpoint selection, and do not estimate field accuracy.')
    for tag, values in reports.items(): save_json(args.output/(tag+'.json'), values)
    save_json(args.output/'summary.json', summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__': main()
