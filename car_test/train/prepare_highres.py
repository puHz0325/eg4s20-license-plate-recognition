"""Prepare disjoint, plate-grouped CCPD2019 caches directly from full-size originals."""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import heapq
import json
import math
import os
from pathlib import Path
import sys

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lpr_common import CHARS
from lpr8_preprocess import resize_plate_red

PROVINCES = list('皖沪津渝冀晋蒙辽吉黑苏浙京闽赣鲁豫鄂湘粤桂琼川贵云藏陕甘青宁新') + ['警', '学', 'O']
ALPHANUMERIC = list('ABCDEFGHJKLMNPQRSTUVWXYZ0123456789O')
SIZES = ((128, 32), (188, 48))


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def file_hash(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def decode_annotation(name):
    fields = Path(name).stem.split('-')
    if len(fields) != 7:
        raise ValueError('annotation_fields')
    indices = [int(x) for x in fields[4].split('_')]
    if (len(indices) != 7 or not 0 <= indices[0] < 31 or not 0 <= indices[1] < 24
            or any(not 0 <= x < 34 for x in indices[2:])):
        raise ValueError('not_standard_seven_character_plate')
    plate = PROVINCES[indices[0]] + ''.join(ALPHANUMERIC[x] for x in indices[1:])
    if any(c not in CHARS for c in plate):
        raise ValueError('unknown_character')
    bbox = [int(x) for vertex in fields[2].split('_') for x in vertex.split('&')]
    corners = [[int(x) for x in v.split('&')] for v in fields[3].split('_')]
    if len(bbox) != 4 or len(corners) != 4 or any(len(v) != 2 for v in corners):
        raise ValueError('coordinates')
    br, bl, tl, tr = corners
    horizontal = sum(abs(math.degrees(math.atan2(b[1]-a[1], b[0]-a[0])))
                     for a, b in [(tl, tr), (bl, br)]) / 2
    vertical = sum(abs(abs(math.degrees(math.atan2(b[1]-a[1], b[0]-a[0])))-90)
                   for a, b in [(tl, bl), (tr, br)]) / 2
    return dict(plate=plate, bbox=bbox, corners=corners, horizontal=horizontal, vertical=vertical)


def plate_split(plate, seed):
    value = int(digest(f'{seed}:plate:{plate}')[:16], 16) / 2**64
    return 'train' if value < .8 else 'val' if value < .9 else 'test'


def full_crop_box(record):
    """CCPD boxes can clip annotated vertices; include both, with a small margin."""
    x0, y0, x1, y1 = record['bbox']
    xs = [point[0] for point in record['corners']]
    ys = [point[1] for point in record['corners']]
    x0, y0 = min(x0, min(xs)), min(y0, min(ys))
    x1, y1 = max(x1, max(xs)+1), max(y1, max(ys)+1)
    mx, my = max(2, round((x1-x0)*.01)), max(2, round((y1-y0)*.01))
    return [x0-mx, y0-my, x1+mx, y1+my]


def select_balanced(records, limit, seed):
    """Deterministic sqrt-frequency province quotas; never changes the group split."""
    groups = defaultdict(list)
    for record in records:
        groups[record['plate'][0]].append(record)
    for group in groups.values():
        group.sort(key=lambda x: digest(f"{seed}:selection:{x['id']}"))
    queue = [(0., province, 0) for province in sorted(groups)]
    heapq.heapify(queue)
    selected = []
    while queue and len(selected) < limit:
        _, province, index = heapq.heappop(queue)
        group = groups[province]
        selected.append(group[index])
        index += 1
        if index < len(group):
            heapq.heappush(queue, (index / math.sqrt(len(group)), province, index))
    return sorted(selected, key=lambda x: digest(f"{seed}:order:{x['id']}"))


def process_record(record):
    encoded = Path(record['source']).read_bytes()
    image = cv2.imdecode(np.frombuffer(encoded, np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError('decode_failed')
    x0, y0, x1, y1 = record['bbox']
    h, w = image.shape[:2]
    if any(not (0 <= x < w and 0 <= y < h) for x, y in record['corners']):
        raise ValueError('out_of_bounds_plate_vertices')
    x0, y0, x1, y1 = max(0,x0), max(0,y0), min(w,x1), min(h,y1)
    if not (0 <= x0 < x1 <= w and 0 <= y0 < y1 <= h):
        raise ValueError('out_of_bounds_bbox')
    gray = np.ascontiguousarray(image[y0:y1, x0:x1, 2])
    if gray.shape[1] < 188 or gray.shape[0] < 48:
        raise ValueError('insufficient_clipped_resolution')
    resized = {f'{width}x{height}': resize_plate_red(gray, (width, height))
               for width, height in SIZES}
    meta = dict(record, crop_bbox=[x0,y0,x1,y1], source_sha256=hashlib.sha256(encoded).hexdigest(),
                native_hw=list(gray.shape),
                crop_sha256=hashlib.sha256(str(gray.shape).encode()+gray.tobytes()).hexdigest())
    return meta, resized


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--train-count', type=int, default=40000)
    parser.add_argument('--val-count', type=int, default=4000)
    parser.add_argument('--test-count', type=int, default=4000)
    parser.add_argument('--seed', type=int, default=20261026)
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Use a new output directory; existing prepared data is preserved')
    if not args.source.is_dir():
        raise FileNotFoundError(args.source)
    args.output.mkdir(parents=True)
    cv2.setNumThreads(1)
    candidates = []; rejected = Counter(); subsets = Counter(); duplicate_names = set()
    for folder in sorted(args.source.glob('ccpd_*')):
        if not folder.is_dir():
            continue
        for entry in sorted(os.scandir(folder), key=lambda x: x.name):
            if not entry.name.lower().endswith('.jpg'):
                continue
            subsets[folder.name] += 1
            if folder.name == 'ccpd_np':
                rejected['no_plate_subset'] += 1; continue
            try:
                item = decode_annotation(entry.name)
                if entry.name in duplicate_names:
                    rejected['duplicate_filename_across_subsets'] += 1; continue
                duplicate_names.add(entry.name)
                item['annotation_bbox'] = list(item['bbox'])
                item['bbox'] = full_crop_box(item)
                x0, y0, x1, y1 = item['bbox']
                if x1-x0 < 188 or y1-y0 < 48:
                    rejected['insufficient_native_resolution'] += 1; continue
                if item['horizontal'] > 12 or item['vertical'] > 15:
                    rejected['outside_fixed_roi_angle_scope'] += 1; continue
                if not 2.5 <= (x1-x0)/(y1-y0) <= 6:
                    rejected['extreme_crop_aspect'] += 1; continue
                item.update(source=str(Path(entry.path).resolve()), subset=folder.name,
                            id=digest(entry.name)[:24], split=plate_split(item['plate'], args.seed))
                candidates.append(item)
            except (ValueError, IndexError):
                rejected['invalid_annotation'] += 1
        print(json.dumps({'scanned':folder.name,'candidates_so_far':len(candidates)},ensure_ascii=False),flush=True)
    # Keep at most three different photos per plate; selection remains deterministic.
    candidates.sort(key=lambda x: digest(f"{args.seed}:cap:{x['id']}"))
    by_plate = Counter(); limited = []
    for item in candidates:
        if by_plate[item['plate']] < 3:
            limited.append(item); by_plate[item['plate']] += 1
        else:
            rejected['per_plate_cap'] += 1
    groups = {}; seen_crops = {}; report_splits = {}
    for split, count in [('train', args.train_count), ('val', args.val_count), ('test', args.test_count)]:
        selected = select_balanced([x for x in limited if x['split'] == split], count, args.seed)
        if not selected:
            raise ValueError(f'Empty split: {split}')
        caches = {}
        for width, height in SIZES:
            target = args.output/f'{width}x{height}'
            target.mkdir(exist_ok=True)
            caches[f'{width}x{height}'] = np.lib.format.open_memmap(
                target/f'{split}.npy', mode='w+', dtype=np.uint8, shape=(len(selected), height, width))
        records = []
        def safe_process(item):
            try:
                return process_record(item)
            except (ValueError, OSError) as exc:
                return str(exc), None
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            for index, (meta, images) in enumerate(pool.map(safe_process, selected), 1):
                if images is None:
                    rejected[f'image:{meta}'] += 1; continue
                previous = seen_crops.get(meta['crop_sha256'])
                if previous is not None:
                    if previous != meta['plate']:
                        raise ValueError('Identical pixels carry conflicting labels')
                    rejected['duplicate_crop_pixels'] += 1; continue
                seen_crops[meta['crop_sha256']] = meta['plate']
                row = len(records)
                for key, cache in caches.items():
                    cache[row] = images[key]
                meta['cache_index'] = row
                records.append(meta)
                if index % 2000 == 0:
                    print(f'{split}: processed {index}/{len(selected)}, accepted {len(records)}', flush=True)
        for cache in caches.values():
            cache.flush()
        records_path = args.output/f'{split}.jsonl'
        records_path.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in records),encoding='utf-8')
        groups[split] = set(x['plate'] for x in records)
        report_splits[split] = dict(samples=len(records), distinct_plates=len(groups[split]),
            provinces=dict(Counter(x['plate'][0] for x in records)),
            characters=dict(Counter(''.join(x['plate'] for x in records))),
            subsets=dict(Counter(x['subset'] for x in records)),
            records_sha256=file_hash(records_path))
        print(json.dumps({split:report_splits[split]},ensure_ascii=False),flush=True)
    assert all(not groups[a] & groups[b] for a,b in [('train','val'),('train','test'),('val','test')])
    hashes = {str(p.relative_to(args.output)):file_hash(p) for p in sorted(args.output.glob('*/*.npy'))}
    manifest = dict(format='lpr-highres-dataset-v2',source=str(args.source.resolve()),seed=args.seed,
        sizes_wh=SIZES,chars=CHARS,grayscale='R8',normalization='(pixel-127.5)/128',
        crop_policy='axis_aligned_union_of_box_and_four_vertices_plus_1_percent_margin',
        split_strategy='SHA256(plate,seed), 80/10/10, before capped sqrt-province selection',
        fresh_training_required=True,source_subset_counts=dict(subsets),rejected=dict(rejected),
        splits=report_splits,cache_sha256=hashes,
        caveat='Custom controlled-angle CCPD holdout; not the official benchmark or an independent real-camera test. Arrays may have unused tail rows; jsonl cache_index is authoritative.')
    (args.output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PREPARE_HIGHRES_PASS',flush=True)


if __name__ == '__main__':
    main()
