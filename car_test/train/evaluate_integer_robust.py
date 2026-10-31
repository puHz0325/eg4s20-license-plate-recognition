"""Check exact INT8 on frozen photometric validation variants and saved camera pixels."""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np
import torch

from integer_reference import IntegerNetwork
from evaluate_robust_teacher import load_model, camera_examples
from train_highres import save_json, decode_indices
from robust_teacher import photometric
from lpr_common import decode_ctc
from prepare_highres import file_hash

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run', type=Path, required=True)
    p.add_argument('--package', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--per-source', type=int, default=32)
    args = p.parse_args()
    if args.output.exists(): raise FileExistsError('Preserve integer evaluation evidence')
    spec = json.loads((args.package/'model.json').read_text(encoding='utf-8'))
    if spec['metadata']['weights_sha256'] != file_hash(args.run/'model_state.pth'):
        raise ValueError('INT8 source differs from floating checkpoint')
    torch.set_num_threads(4); cv2.setNumThreads(1)
    floating = load_model(args.run); integer = IntegerNetwork.load(args.package)
    cases = []
    for source, root in [('main', ROOT/'car_test/train/highres_v2/data_quad'),
                         ('province', ROOT/'car_test/train/highres_v3/data_rehearsal')]:
        rows = [json.loads(s) for s in (root/'val.jsonl').read_text(encoding='utf-8').splitlines()]
        if source == 'province': rows = [r for r in rows if r['plate'][0] != '皖']
        chosen = np.random.default_rng(2026102904).choice(len(rows), min(args.per_source, len(rows)), replace=False)
        pixels = np.load(root/'128x32/val.npy', mmap_mode='r')
        for mode in ('inverted', 'low_contrast', 'soft_strokes'):
            for i in chosen:
                row = rows[i]; image = photometric(pixels[row['cache_index']], np.random.default_rng(2026102904+int(i)), mode)
                cases.append((dict(group=mode, source=source, id=row['id'], expected=row['plate']), image))
    for row in camera_examples():
        image = cv2.imread(row['image'], cv2.IMREAD_GRAYSCALE)
        cases.append((dict(group='camera_'+row['group'], source=row['image'], expected=row['expected']), image))
    report = dict(status='IN_PROGRESS', model_sha256=file_hash(args.package/'model_init.bin'), cases=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for start in range(0, len(cases), 4):
        group = cases[start:start+4]; images = np.stack([image for _, image in group])
        with torch.inference_mode():
            fp = decode_indices(floating(torch.from_numpy((images.astype(np.float32)-127.5)/128.)[:, None].cuda()).argmax(1).cpu().numpy())
        output, _ = integer.forward(images); qp = decode_ctc(output)
        for (row, _), a, b in zip(group, fp, qp, strict=True):
            report['cases'].append(dict(**row, floating=a, integer=b, float_correct=a == row['expected'], integer_correct=b == row['expected']))
        if start % 32 == 0:
            save_json(args.output, report); print(f'Exact INT8 stress/camera {min(start+4,len(cases))}/{len(cases)}', flush=True)
    groups = {}
    for name in sorted({r['group'] for r in report['cases']}):
        subset = [r for r in report['cases'] if r['group'] == name]; n = len(subset)
        f = sum(r['float_correct'] for r in subset); q = sum(r['integer_correct'] for r in subset)
        groups[name] = dict(samples=n, float_exact=f, integer_exact=q, float_accuracy=f/n,
            integer_accuracy=q/n, accuracy_drop_percentage_points=100*(f-q)/n)
    # A 64-image stress group allows at most one integer-only error. Camera remains
    # diagnostic: 3/4 frames of one scene cannot establish generalization.
    passed = all(v['float_exact']-v['integer_exact'] <= 1 for k, v in groups.items() if not k.startswith('camera_'))
    report.update(status='COMPLETE', stress_quantization_passed=passed, groups=groups,
        caveat='192 validation variants plus seven correlated camera frames; not full fixed-test integer accuracy.')
    save_json(args.output, report); print(json.dumps(groups, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__': main()
