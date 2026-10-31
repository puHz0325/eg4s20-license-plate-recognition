"""Fine-tune the deployed teacher using train-only mining and photometric diversity."""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import time

import cv2
import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, WeightedRandomSampler

from model import FPGA_LPRNet
from prepare_highres import file_hash
from train_highres import (CachedPlates, collate, worker_init, seed_all, save_json,
                           atomic_checkpoint, finish_amp_step, decode_indices, alignment_counts)
from finetune_province import sampling_weights, metrics_on, province_aux_loss
from train_teacher import distillation_loss

PAIRS = [('T', '1'), ('Z', '4'), ('C', 'G'), ('0', '8'), ('黑', '冀'), ('湘', '浙')]
PAIR_SUBSTITUTIONS = {a+'>'+b for pair in PAIRS for a, b in (pair, pair[::-1])}


def photometric(pixels, rng, mode):
    """Label-preserving polarity/contrast stress; no binary thresholding."""
    values = pixels.astype(np.float32)
    if mode == 'inverted':
        values = 255. - values
    elif mode == 'low_contrast':
        if rng.random() < .5:
            values = 255. - values
        values = (values-127.5)*rng.uniform(.22, .55)+rng.uniform(135., 190.)
    elif mode == 'soft_strokes':
        values = cv2.GaussianBlur(values, (3, 3), .75)
        if rng.random() < .5:
            values = 255. - values
        values = (values-127.5)*.65+145.
    elif mode != 'ordinary':
        raise ValueError(mode)
    return np.clip(np.rint(values), 0, 255).astype(np.uint8)


def augment_robust(pixels, rng, strength=1.):
    h, w = pixels.shape
    out = pixels.copy()
    if rng.random() < .7:
        matrix = cv2.getRotationMatrix2D((w/2, h/2), rng.uniform(-2., 2.), rng.uniform(.96, 1.035))
        matrix[:, 2] += [rng.uniform(-.015, .015)*w, rng.uniform(-.025, .025)*h]
        out = cv2.warpAffine(out, matrix, (w, h), flags=cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_REPLICATE)
    draw = rng.random()
    if draw < .30*strength:
        out = photometric(out, rng, 'inverted')
    elif draw < .58*strength:
        out = photometric(out, rng, 'low_contrast')
    elif draw < .70*strength:
        out = photometric(out, rng, 'soft_strokes')
    # A one-pixel local morphology models imperfect focus/thin strokes, not new labels.
    if rng.random() < .10*strength:
        kernel = np.ones((1, 2), np.uint8)
        out = cv2.erode(out, kernel) if rng.random() < .5 else cv2.dilate(out, kernel)
    if rng.random() < .25:
        out = cv2.GaussianBlur(out, (3, 3), rng.uniform(.2, .7))
    values = out.astype(np.float32)*rng.uniform(.88, 1.12)+rng.uniform(-9., 9.)
    if rng.random() < .25*strength:
        shade = np.linspace(-1., 1., w, dtype=np.float32)[None, :]*rng.uniform(-18., 18.)
        values += shade
    if rng.random() < .25:
        values += rng.normal(0., rng.uniform(.5, 2.), values.shape)
    return np.clip(np.rint(values), 0, 255).astype(np.uint8)


class RobustPlates(CachedPlates):
    def __init__(self, root, split, seed, mode='train', indices=None, strength=1.):
        super().__init__(root, '128x32', split, False, seed)
        self.mode = mode
        self.strength = strength
        if indices is not None:
            self.records = [self.records[i] for i in indices]
            self.labels = [self.labels[i] for i in indices]

    def __getitem__(self, index):
        record = self.records[index]
        image = self.pixels[record['cache_index']]
        epoch = int(self.epoch)
        rng = np.random.default_rng(self.seed+index*1009+epoch*1000003)
        if self.mode == 'train':
            image = augment_robust(image, rng, self.strength*min(1., .4+.2*epoch))
        else:
            image = photometric(image, rng, self.mode)
        image = (image.astype(np.float32)-127.5)/128.
        return torch.from_numpy(image[None]), self.labels[index], record['plate']


def retained(metrics, baseline):
    return (metrics['main'] >= baseline['main']-.005 and
            metrics['non_anhui'] >= baseline['non_anhui']-.015)


def candidate_key(metrics, baseline):
    score = .40*metrics['main']+.30*metrics['non_anhui']+.30*metrics['robust_mean']
    return (int(retained(metrics, baseline)), score, metrics['supported_macro'])


def hard_weights(records, mined):
    """Keep province/view mass fixed while prioritizing errors within each stratum."""
    base = np.asarray(sampling_weights(records, .4, .2), np.float64)
    result = base.copy()
    groups = defaultdict(list)
    for i, (row, stat) in enumerate(zip(records, mined, strict=True)):
        if row['id'] != stat['id']:
            raise ValueError('Mining order mismatch')
        groups[(row['plate'][0], row.get('crop_mode', 'raw'))].append(i)
        factor = 1.+.8*(not stat['correct'])+.6*stat['pair_error']+.25*stat['low_margin']
        result[i] *= min(factor, 2.65)
    for indices in groups.values():
        result[indices] *= base[indices].sum()/result[indices].sum()
    return result


def mine(model, loader, records, device):
    model.eval(); rows = []; cursor = 0
    with torch.inference_mode():
        for images, _, _, plates in loader:
            logits = model(images.to(device, non_blocking=True)).float()
            decoded = decode_indices(logits.argmax(1).cpu().numpy())
            top = logits.topk(2, dim=1)
            margins = (top.values[:, 0]-top.values[:, 1]).cpu().numpy()
            symbols = top.indices[:, 0].cpu().numpy()
            for j, (truth, prediction) in enumerate(zip(plates, decoded, strict=True)):
                substitutions = alignment_counts(truth, prediction)['substitutions']
                emitted = symbols[j] != 67
                min_margin = float(margins[j][emitted].min()) if emitted.any() else 0.
                rows.append(dict(id=records[cursor]['id'], correct=truth == prediction,
                    prediction=prediction, pair_error=bool(PAIR_SUBSTITUTIONS & substitutions.keys()),
                    low_margin=min_margin < 2., minimum_emission_margin=min_margin))
                cursor += 1
    if cursor != len(records):
        raise ValueError('Incomplete mining')
    return rows


def pair_report(metrics, plates):
    occurrences = Counter(''.join(plates))
    return [dict(pair=[a, b], occurrences={a:occurrences[a], b:occurrences[b]},
                 a_to_b=metrics['substitutions'].get(a+'>'+b, 0),
                 b_to_a=metrics['substitutions'].get(b+'>'+a, 0)) for a, b in PAIRS]


def validate(model, loaders, device):
    reports = {}
    for tag, loader in loaders.items():
        reports[tag] = metrics_on(model, loader, device)
        reports[tag]['confusion_pairs'] = pair_report(reports[tag], [r['plate'] for r in loader.dataset.records])
    return dict(main=reports['main']['plate_accuracy'], non_anhui=reports['province']['non_anhui_plate_accuracy'],
        supported_macro=reports['province']['macro_supported_accuracy'],
        robust_mean=float(np.mean([r['plate_accuracy'] for tag, r in reports.items() if tag.startswith('stress_')])),
        reports=reports)


def verify_data(data, main_data):
    manifest = json.loads((data/'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('holdout_parent_plate_overlap') != 0:
        raise ValueError('Dataset leakage guard failed')
    for root in (data, main_data):
        meta = json.loads((root/'manifest.json').read_text(encoding='utf-8'))
        for relative, sha in meta['cache_sha256'].items():
            if file_hash(root/relative) != sha:
                raise ValueError('Changed cache: '+str(root/relative))
        for split, value in meta['splits'].items():
            if file_hash(root/f'{split}.jsonl') != value['records_sha256']:
                raise ValueError('Changed records')
    train = {json.loads(s)['plate'] for s in (data/'train.jsonl').read_text(encoding='utf-8').splitlines()}
    for root in (data, main_data):
        for split in ('val', 'test'):
            held = {json.loads(s)['plate'] for s in (root/f'{split}.jsonl').read_text(encoding='utf-8').splitlines()}
            if train & held:
                raise ValueError('Training/holdout plate overlap')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data', type=Path, required=True)
    p.add_argument('--main-data', type=Path, required=True)
    p.add_argument('--parent-run', type=Path, required=True)
    p.add_argument('--retention-run', type=Path, help='Frozen deployed reference, independent of initialization')
    p.add_argument('--distill-run', type=Path, help='Teacher for correctly recognized augmented training samples only')
    p.add_argument('--kd-weight', type=float, default=0.)
    p.add_argument('--augmentation-strength', type=float, default=1.)
    p.add_argument('--qat-package', type=Path, help='Freeze existing INT8 scales and train with folded fake quantization')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--epochs', type=int, default=40)
    p.add_argument('--epoch-samples', type=int, default=32000)
    p.add_argument('--min-epochs', type=int, default=16)
    p.add_argument('--patience', type=int, default=10)
    p.add_argument('--batch-size', type=int, default=128)
    p.add_argument('--workers', type=int, default=2)
    p.add_argument('--lr', type=float, default=.00015)
    p.add_argument('--province-loss', type=float, default=.10)
    p.add_argument('--seed', type=int, default=2026102901)
    args = p.parse_args()
    if not 0. <= args.augmentation_strength <= 1. or args.kd_weight < 0.:
        raise ValueError('Invalid augmentation/distillation strength')
    if args.kd_weight and args.distill_run is None:
        raise ValueError('Distillation requires an explicit teacher')
    if args.output.exists():
        raise FileExistsError('Existing experiment preserved; choose a fresh output directory')
    if not torch.cuda.is_available():
        raise RuntimeError('CUDA required')
    args.output.mkdir(parents=True)
    cv2.setNumThreads(1); seed_all(args.seed)
    verify_data(args.data, args.main_data)
    parent_config = json.loads((args.parent_run/'config.json').read_text(encoding='utf-8'))
    model_options = parent_config['model_options']
    model = FPGA_LPRNet(**model_options).cuda()
    model.load_state_dict(torch.load(args.parent_run/'model_state.pth', map_location='cpu', weights_only=True), strict=True)
    if args.qat_package:
        from integer_reference import IntegerNetwork
        from teacher_qat import FixedScaleTeacher
        torch.backends.cudnn.allow_tf32 = False
        model = FixedScaleTeacher(model, IntegerNetwork.load(args.qat_package))
    reference = None
    reference_run = args.retention_run or args.distill_run
    if reference_run:
        reference_options = json.loads((reference_run/'config.json').read_text(encoding='utf-8'))['model_options']
        if reference_options != model_options:
            raise ValueError('Reference architecture must match')
        reference = FPGA_LPRNet(**model_options).cuda().eval()
        reference.load_state_dict(torch.load(reference_run/'model_state.pth', map_location='cpu', weights_only=True))
        for parameter in reference.parameters(): parameter.requires_grad_(False)
    if args.retention_run and args.distill_run and args.retention_run.resolve() != args.distill_run.resolve():
        raise ValueError('Use the same frozen model for retention and distillation')
    config = {k:str(v.resolve()) if isinstance(v, Path) else v for k, v in vars(args).items()}
    config.update(model_options=model_options, parameter_count=sum(x.numel() for x in model.parameters()),
        parent_sha256=file_hash(args.parent_run/'model_state.pth'), source_sha256=file_hash(Path(__file__)),
        data_manifest_sha256=file_hash(args.data/'manifest.json'), preprocessing_sha256=file_hash(Path(__file__).parents[1]/'teacher_preprocess.py'),
        ccpd2020_used=False, phone_capture_used=False, camera_diagnostics_training=False,
        selection_partition='validation only; fixed test and camera diagnostics excluded')
    if reference_run: config['reference_sha256'] = file_hash(reference_run/'model_state.pth')
    if args.qat_package:
        config.update(qat_scales_sha256=file_hash(args.qat_package/'model.json'),
            qat_source_sha256=file_hash(Path(__file__).with_name('teacher_qat.py')),
            validation_numeric='fixed-scale fake quantization; final exact INT8 validation remains mandatory')
    save_json(args.output/'config.json', config)
    options = dict(num_workers=args.workers, collate_fn=collate, pin_memory=True, worker_init_fn=worker_init,
                   persistent_workers=args.workers > 0)
    train = RobustPlates(args.data, 'train', args.seed, strength=args.augmentation_strength)
    clean_train = CachedPlates(args.data, '128x32', 'train')
    clean_loader = DataLoader(clean_train, batch_size=256, shuffle=False, **options)
    print('Mining training partition only', flush=True)
    mined = mine(model, clean_loader, train.records, 'cuda')
    save_json(args.output/'mining.json', dict(samples=len(mined), errors=sum(not r['correct'] for r in mined),
        pair_errors=sum(r['pair_error'] for r in mined), low_margin=sum(r['low_margin'] for r in mined), rows=mined))
    del clean_loader
    weights = hard_weights(train.records, mined)
    generator = torch.Generator().manual_seed(args.seed)
    sampler = WeightedRandomSampler(weights, args.epoch_samples, replacement=True, generator=generator)
    train_loader = DataLoader(train, batch_size=args.batch_size, sampler=sampler, **options)
    # Eight small validation loaders must not each retain two Windows-spawned Torch
    # processes. Only the training loader benefits from persistent workers.
    val_options = dict(num_workers=0, collate_fn=collate, pin_memory=True)
    loaders = {tag:DataLoader(CachedPlates(root, '128x32', 'val'), batch_size=256, **val_options)
               for tag, root in [('main', args.main_data), ('province', args.data)]}
    stress_ids = {}; rng = np.random.default_rng(args.seed)
    # Fixed stratified validation subsets shared by every epoch and the parent baseline.
    for source, root in [('main', args.main_data), ('province', args.data)]:
        base = loaders[source].dataset
        eligible = [i for i, r in enumerate(base.records) if source == 'main' or r['plate'][0] != '皖']
        indices = sorted(rng.choice(eligible, min(512, len(eligible)), replace=False).tolist())
        stress_ids[source] = [base.records[i]['id'] for i in indices]
        for mode in ('inverted', 'low_contrast', 'soft_strokes'):
            dataset = RobustPlates(root, 'val', args.seed+17, mode, indices)
            loaders['stress_'+source+'_'+mode] = DataLoader(dataset, batch_size=256, **val_options)
    save_json(args.output/'stress_validation_ids.json', stress_ids)
    baseline = validate(reference if args.retention_run else model, loaders, 'cuda')
    save_json(args.output/'baseline_validation.json', baseline)
    if args.retention_run:
        save_json(args.output/'initial_validation.json', validate(model, loaders, 'cuda'))
    print(json.dumps({'baseline':{k:v for k,v in baseline.items() if k!='reports'}}, ensure_ascii=False), flush=True)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scaler = torch.amp.GradScaler('cuda', init_scale=1024.)
    criterion = nn.CTCLoss(blank=67, zero_infinity=False)
    best_key = (-1., -1., -1.); best_epoch = stale = skips = 0; begin = time.monotonic()
    for epoch in range(args.epochs):
        ep_begin = time.monotonic(); model.train(); train.epoch.fill_(epoch)
        generator.manual_seed(args.seed+epoch)
        lr = args.lr*min(1., (epoch+1)/2)*(.1+.9*.5*(1+math.cos(math.pi*epoch/args.epochs)))
        for group in optimizer.param_groups: group['lr'] = lr
        total = ctc_total = aux_total = kd_total = 0.; count = consecutive_skips = 0
        for batch, (images, targets, lengths, plates) in enumerate(train_loader, 1):
            images = images.cuda(non_blocking=True); optimizer.zero_grad(set_to_none=True)
            with torch.autocast('cuda', dtype=torch.float16): logits = model(images)
            ctc = criterion(logits.float().permute(2, 0, 1).log_softmax(2), targets,
                            torch.full((len(plates),), logits.shape[2], dtype=torch.long), lengths)
            aux = province_aux_loss(logits, plates)
            kd = ctc.new_tensor(0.)
            if args.kd_weight:
                with torch.no_grad(), torch.autocast('cuda', dtype=torch.float16):
                    soft = reference(images)
                predictions = decode_indices(soft.argmax(1).cpu().numpy())
                mask = torch.tensor([a == b for a, b in zip(predictions, plates, strict=True)], device='cuda')
                kd = distillation_loss(logits, soft, 2., mask)
            loss = ctc+args.province_loss*aux+args.kd_weight*kd
            if not bool(torch.isfinite(loss)): raise FloatingPointError('Nonfinite loss')
            scaler.scale(loss).backward()
            if finish_amp_step(model, optimizer, scaler): consecutive_skips = 0
            else:
                skips += 1; consecutive_skips += 1
                if consecutive_skips > 6: raise FloatingPointError('AMP failed to recover')
            n = len(plates); count += n
            total += float(loss.detach())*n; ctc_total += float(ctc.detach())*n; aux_total += float(aux.detach())*n
            kd_total += float(kd.detach())*n
        metrics = validate(model, loaders, 'cuda'); key = candidate_key(metrics, baseline)
        improved = key > best_key
        if improved: best_key = key; best_epoch = epoch+1; stale = 0
        else: stale += 1
        row = dict(epoch=epoch+1, loss=total/count, ctc_loss=ctc_total/count, province_loss=aux_total/count, kd_loss=kd_total/count,
            validation=metrics, retained=retained(metrics, baseline), best_epoch=best_epoch,
            epoch_seconds=time.monotonic()-ep_begin, elapsed_seconds=time.monotonic()-begin, amp_skips=skips)
        with (args.output/'history.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(row, ensure_ascii=False)+'\n')
        deploy_state = model.model.state_dict() if args.qat_package else model.state_dict()
        atomic_checkpoint(args.output/'last.pt', dict(model=deploy_state, optimizer=optimizer.state_dict(),
            scaler=scaler.state_dict(), epoch=epoch+1, config=config))
        if improved:
            atomic_checkpoint(args.output/'model_state.pth', deploy_state)
            save_json(args.output/'best_validation.json', row)
        save_json(args.output/'progress.json', {k:v for k,v in row.items() if k!='validation'} | {'state':'training',
            'metrics':{k:v for k,v in metrics.items() if k!='reports'}})
        print(json.dumps({k:v for k,v in row.items() if k!='validation'} | {
            'metrics':{k:v for k,v in metrics.items() if k!='reports'}}, ensure_ascii=False), flush=True)
        if epoch+1 >= args.min_epochs and stale >= args.patience: break
    best = json.loads((args.output/'best_validation.json').read_text(encoding='utf-8'))
    metrics = best['validation']
    qualified = retained(metrics, baseline) and metrics['robust_mean'] >= baseline['robust_mean']+.10
    summary = dict(status='TRAINING_COMPLETE', best_epoch=best_epoch, epochs_run=epoch+1,
        validation_qualified=qualified, baseline={k:v for k,v in baseline.items() if k!='reports'},
        candidate={k:v for k,v in metrics.items() if k!='reports'},
        model_state_sha256=file_hash(args.output/'model_state.pth'), model_options=model_options,
        elapsed_seconds=time.monotonic()-begin,
        deployment='Not evaluated on fixed test or INT8; original FPGA program remains active')
    save_json(args.output/'summary.json', summary); save_json(args.output/'progress.json', dict(state='complete', **summary))
    print(json.dumps(summary, ensure_ascii=False), flush=True)


if __name__ == '__main__': main()
