"""Train/evaluate paired high-resolution LPR models on a frozen CCPD manifest."""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import random
import sys
import time

import cv2
import numpy as np
import torch
from torch import nn
from torch.utils.data import Dataset, DataLoader, WeightedRandomSampler

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lpr_common import CHARS, BLANK_IDX
from model import FPGA_LPRNet
from prepare_highres import file_hash

CHAR_INDEX = {char: index for index, char in enumerate(CHARS)}
SIMILAR = set('ACG0Q')


def save_json(path, data):
    temporary = Path(path).with_suffix('.json.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    temporary.replace(path)


def augment_pixels(pixels, rng):
    """Small camera/ROI variations; evaluation never calls this function."""
    h, w = pixels.shape
    matrix = cv2.getRotationMatrix2D((w/2, h/2), rng.uniform(-3, 3), rng.uniform(.94, 1.04))
    matrix[:, 2] += [rng.uniform(-.025, .025)*w, rng.uniform(-.04, .04)*h]
    out = cv2.warpAffine(pixels, matrix, (w, h), flags=cv2.INTER_LINEAR,
                         borderMode=cv2.BORDER_REPLICATE)
    if rng.random() < .3:
        out = cv2.GaussianBlur(out, (3, 3), rng.uniform(.2, .8))
    values = out.astype(np.float32)*rng.uniform(.8, 1.2)+rng.uniform(-12, 12)
    if rng.random() < .25:
        values += rng.normal(0, rng.uniform(1, 3), values.shape)
    return np.clip(np.rint(values), 0, 255).astype(np.uint8)


def alignment_counts(expected, predicted):
    """Levenshtein alignment, so insertions do not shift all substitution counts."""
    n, m = len(expected), len(predicted)
    cost = [[0]*(m+1) for _ in range(n+1)]
    for i in range(n+1): cost[i][0] = i
    for j in range(m+1): cost[0][j] = j
    for i in range(1, n+1):
        for j in range(1, m+1):
            cost[i][j] = min(cost[i-1][j-1]+(expected[i-1] != predicted[j-1]),
                             cost[i-1][j]+1, cost[i][j-1]+1)
    substitutions = Counter(); insertions = deletions = 0; i, j = n, m
    while i or j:
        if i and j and cost[i][j] == cost[i-1][j-1]+(expected[i-1] != predicted[j-1]):
            if expected[i-1] != predicted[j-1]:
                substitutions[f'{expected[i-1]}>{predicted[j-1]}'] += 1
            i -= 1; j -= 1
        elif i and cost[i][j] == cost[i-1][j]+1:
            deletions += 1; i -= 1
        else:
            insertions += 1; j -= 1
    return dict(edits=cost[n][m], substitutions=dict(substitutions),
                insertions=insertions, deletions=deletions)


class CachedPlates(Dataset):
    def __init__(self, data_root, size, split, augment=False, seed=20261026):
        self.records = [json.loads(line) for line in (data_root/f'{split}.jsonl').read_text(encoding='utf-8').splitlines()]
        self.pixels = np.load(data_root/size/f'{split}.npy', mmap_mode='r')
        self.augment = augment
        self.seed = seed
        self.epoch = torch.zeros((), dtype=torch.int64).share_memory_()
        if not self.records or len(self.records) > self.pixels.shape[0]:
            raise ValueError('Cache and record count disagree')
        self.labels = [tuple(CHAR_INDEX[c] for c in row['plate']) for row in self.records]

    def __len__(self):
        return len(self.records)

    def __getitem__(self, index):
        record = self.records[index]
        image = self.pixels[record['cache_index']]
        if self.augment:
            rng = np.random.default_rng(self.seed+int(self.epoch)*1000003+index)
            image = augment_pixels(image, rng)
        image = (image.astype(np.float32)-127.5)/128.
        return torch.from_numpy(image[None]), self.labels[index], record['plate']


def collate(batch):
    images, labels, plates = zip(*batch)
    return (torch.stack(images), torch.tensor([x for label in labels for x in label], dtype=torch.long),
            torch.tensor([len(label) for label in labels], dtype=torch.long), list(plates))


def worker_init(worker_id):
    cv2.setNumThreads(1)
    seed = torch.initial_seed() % 2**32
    random.seed(seed)


def decode_indices(indices):
    texts = []
    for sequence in indices:
        previous = BLANK_IDX; text = []
        for value in sequence:
            value = int(value)
            if value != BLANK_IDX and value != previous:
                text.append(CHARS[value])
            previous = value
        texts.append(''.join(text))
    return texts


def evaluate(model, loader, device, include_predictions=False):
    model.eval(); total = correct = edits = characters = insertions = deletions = 0
    confusion = Counter(); province = defaultdict(lambda: [0, 0]); predictions = []
    with torch.inference_mode():
        for images, _, _, expected in loader:
            output = model(images.to(device, non_blocking=True))
            decoded = decode_indices(output.argmax(1).cpu().numpy())
            for truth, text in zip(expected, decoded, strict=True):
                exact = truth == text
                total += 1; correct += exact; characters += len(truth)
                province[truth[0]][0] += exact; province[truth[0]][1] += 1
                stat = alignment_counts(truth, text)
                edits += stat['edits']; confusion.update(stat['substitutions'])
                insertions += stat['insertions']; deletions += stat['deletions']
                if include_predictions:
                    predictions.append(dict(expected=truth, prediction=text, exact_match=exact))
    result = dict(samples=total, exact_matches=correct, plate_accuracy=correct/total,
        character_error_rate=edits/characters, edit_errors=edits,
        insertions=insertions, deletions=deletions,
        substitutions=dict(confusion.most_common()),
        similar_char_substitutions={key:value for key,value in confusion.items()
                                   if key.split('>')[0] in SIMILAR and key.split('>')[1] in SIMILAR},
        province_results={key:dict(correct=value[0],samples=value[1],accuracy=value[0]/value[1])
                          for key,value in sorted(province.items())},
        macro_province_accuracy=sum(v[0]/v[1] for v in province.values())/len(province))
    if include_predictions:
        result['predictions'] = predictions
    return result


def atomic_checkpoint(path, data):
    temporary = path.with_suffix(path.suffix+'.tmp')
    torch.save(data, temporary)
    temporary.replace(path)


def seed_all(seed):
    random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.set_num_threads(4)


def finish_amp_step(model, optimizer, scaler):
    """AMP overflow lowers the scale and skips this update; FP32 faults still fail."""
    scaler.unscale_(optimizer)
    norm = nn.utils.clip_grad_norm_(model.parameters(), 5.)
    finite = bool(torch.isfinite(norm))
    if not finite:
        nonfinite_gradient = any(parameter.grad is not None and
                                not bool(torch.isfinite(parameter.grad).all())
                                for parameter in model.parameters())
        if not scaler.is_enabled() or not nonfinite_gradient:
            raise FloatingPointError('Nonfinite unscaled gradient norm outside recoverable AMP overflow')
    # GradScaler recorded found_inf before clipping and suppresses optimizer.step on overflow.
    scaler.step(optimizer)
    scaler.update()
    return finite


def run_variant(args, size, manifest_hash):
    width, height = map(int, size.split('x'))
    if [width, height] not in ([128, 32], [188, 48]):
        raise ValueError('Only validated high-resolution candidates are accepted')
    seed_all(args.seed)
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    if device.type != 'cuda' and not args.allow_cpu:
        raise RuntimeError('CUDA unavailable; refusing an unexpectedly slow CPU training run')
    output = args.output/size
    output.mkdir(parents=True, exist_ok=True)
    config = dict(size_wh=[width,height], input_height=height, ctc_steps=width//4,
        chars=CHARS, grayscale='R8', normalization='(pixel-127.5)/128',
        seed=args.seed, epochs=args.epochs, batch_size=args.batch_size, lr=args.lr,
        patience=args.patience, min_epochs=args.min_epochs,
        initialization='fresh_random_no_legacy_checkpoint',data_manifest_sha256=manifest_hash,
        torch_version=str(torch.__version__), device=str(device), gpu=torch.cuda.get_device_name(0) if device.type=='cuda' else None)
    config_path = output/'config.json'
    if config_path.exists():
        if not args.resume or json.loads(config_path.read_text(encoding='utf-8')) != config:
            raise ValueError(f'Existing experiment preserved; use --resume with identical config or a new output: {output}')
        if (output/'summary.json').exists():
            print(f'{size}: already complete, retaining results', flush=True)
            return json.loads((output/'summary.json').read_text(encoding='utf-8'))
    else:
        save_json(config_path, config)
    train = CachedPlates(args.data, size, 'train', True, args.seed)
    val = CachedPlates(args.data, size, 'val')
    province_counts = Counter(x['plate'][0] for x in train.records)
    maximum = max(province_counts.values())
    weights = [min(4., (maximum/province_counts[x['plate'][0]])**.25)
               *(1.25 if SIMILAR & set(x['plate'][1:]) else 1.) for x in train.records]
    sampler_generator = torch.Generator().manual_seed(args.seed)
    sampler = WeightedRandomSampler(weights, len(train), replacement=True, generator=sampler_generator)
    loader_args = dict(batch_size=args.batch_size, num_workers=args.workers,
        collate_fn=collate, pin_memory=device.type=='cuda', worker_init_fn=worker_init,
        persistent_workers=args.workers > 0,
        generator=torch.Generator().manual_seed(args.seed))
    train_loader = DataLoader(train, sampler=sampler, **loader_args)
    val_loader = DataLoader(val, shuffle=False, **loader_args)
    model = FPGA_LPRNet(len(CHARS), input_height=height).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scaler = torch.amp.GradScaler('cuda', init_scale=1024., enabled=device.type=='cuda')
    criterion = nn.CTCLoss(blank=BLANK_IDX, reduction='mean', zero_infinity=False)
    start_epoch = 0; best_key = (-1., -float('inf')); best_epoch = 0; stale = 0
    elapsed_before = 0.; global_step = 0; amp_skipped_steps = 0; consecutive_skipped = 0
    if args.resume and (output/'last.pt').exists():
        checkpoint = torch.load(output/'last.pt', map_location='cpu', weights_only=False)
        model.load_state_dict(checkpoint['model']); optimizer.load_state_dict(checkpoint['optimizer'])
        scaler.load_state_dict(checkpoint['scaler']); start_epoch = checkpoint['epoch']
        best_key = tuple(checkpoint['best_key']); best_epoch = checkpoint['best_epoch']; stale = checkpoint['stale']
        elapsed_before = checkpoint['elapsed_seconds']; global_step = checkpoint['global_step']
        amp_skipped_steps = checkpoint.get('amp_skipped_steps', 0)
    begin = time.monotonic()
    print(json.dumps({'starting':size,'device':str(device),'train':len(train),'val':len(val),
                      'parameters':sum(p.numel() for p in model.parameters()),'resume_epoch':start_epoch},ensure_ascii=False),flush=True)
    for epoch in range(start_epoch, args.epochs):
        model.train(); epoch_begin = time.monotonic(); loss_total = 0.; examples = 0
        sampler_generator.manual_seed(args.seed+epoch)
        # Shared epoch makes per-image augmentation stable across worker scheduling and resume.
        train.epoch.fill_(epoch)
        lr = args.lr*min(1., (epoch+1)/3)*(.05+.95*.5*(1+math.cos(math.pi*epoch/args.epochs)))
        for group in optimizer.param_groups: group['lr'] = lr
        for batch_index, (images, targets, lengths, _) in enumerate(train_loader, 1):
            images = images.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.autocast(device_type=device.type, dtype=torch.float16, enabled=device.type=='cuda'):
                logits = model(images)
            log_probs = logits.float().permute(2,0,1).log_softmax(2)
            input_lengths = torch.full((images.shape[0],), logits.shape[2], dtype=torch.long)
            loss = criterion(log_probs, targets, input_lengths, lengths)
            if not torch.isfinite(loss):
                raise FloatingPointError(f'Nonfinite CTC loss at {size} epoch {epoch+1} batch {batch_index}')
            scaler.scale(loss).backward()
            updated = finish_amp_step(model, optimizer, scaler)
            if updated:
                consecutive_skipped = 0
            else:
                amp_skipped_steps += 1; consecutive_skipped += 1
                print(json.dumps(dict(amp_overflow=True,variant=size,epoch=epoch+1,
                    batch=batch_index,new_scale=scaler.get_scale(),skipped_updates=amp_skipped_steps)),flush=True)
                if consecutive_skipped > 6:
                    raise FloatingPointError('AMP failed to recover after repeated scale reductions')
            count = images.shape[0]; examples += count; loss_total += float(loss.detach())*count
            global_step += 1
            if batch_index == 1 or batch_index % 100 == 0:
                progress = dict(variant=size,epoch=epoch+1,batch=batch_index,batches=len(train_loader),
                    loss=loss_total/examples,images_per_second=examples/(time.monotonic()-epoch_begin),
                    amp_skipped_steps=amp_skipped_steps,amp_scale=scaler.get_scale())
                save_json(output/'progress.json', progress)
                print(json.dumps(progress),flush=True)
        metrics = evaluate(model, val_loader, device)
        key = (metrics['plate_accuracy'], -metrics['character_error_rate'])
        improved = key > best_key
        if improved:
            best_key = key; best_epoch = epoch+1; stale = 0
        else:
            stale += 1
        elapsed = elapsed_before+time.monotonic()-begin
        row = dict(epoch=epoch+1,train_loss=loss_total/examples,lr=lr,
                   epoch_seconds=time.monotonic()-epoch_begin,elapsed_seconds=elapsed,
                   validation=metrics,best_epoch=best_epoch,amp_skipped_steps=amp_skipped_steps,
                   amp_scale=scaler.get_scale())
        with (output/'history.jsonl').open('a',encoding='utf-8') as stream:
            stream.write(json.dumps(row,ensure_ascii=False)+'\n')
        checkpoint = dict(model=model.state_dict(),optimizer=optimizer.state_dict(),scaler=scaler.state_dict(),
            epoch=epoch+1,best_key=best_key,best_epoch=best_epoch,stale=stale,
            elapsed_seconds=elapsed,global_step=global_step,config=config)
        checkpoint['amp_skipped_steps'] = amp_skipped_steps
        atomic_checkpoint(output/'last.pt', checkpoint)
        if improved:
            atomic_checkpoint(output/'best.pt', checkpoint)
            atomic_checkpoint(output/'model_state.pth', model.state_dict())
            save_json(output/'best_validation.json', dict(epoch=epoch+1,**metrics))
        save_json(output/'progress.json',dict(state='training',variant=size,**row))
        print(json.dumps({'variant':size,'epoch':epoch+1,'loss':row['train_loss'],
            'val_accuracy':metrics['plate_accuracy'],'val_cer':metrics['character_error_rate'],
            'best_epoch':best_epoch,'epoch_seconds':row['epoch_seconds']},ensure_ascii=False),flush=True)
        if epoch+1 >= args.min_epochs and stale >= args.patience:
            print(f'{size}: EARLY_STOP epoch {epoch+1}',flush=True)
            break
    checkpoint = torch.load(output/'best.pt',map_location='cpu',weights_only=False)
    model.load_state_dict(checkpoint['model'])
    # The test partition is first opened only after validation has chosen the checkpoint.
    test = CachedPlates(args.data,size,'test')
    test_loader = DataLoader(test,shuffle=False,**loader_args)
    test_metrics = evaluate(model,test_loader,device,include_predictions=True)
    for prediction, record in zip(test_metrics['predictions'], test.records, strict=True):
        prediction.update(id=record['id'],source=record['source'])
    save_json(output/'test.json',test_metrics)
    summary = dict(status='COMPLETE',variant=size,best_epoch=best_epoch,
        epochs_run=epoch+1,elapsed_seconds=elapsed_before+time.monotonic()-begin,
        amp_skipped_steps=amp_skipped_steps,
        best_validation=json.loads((output/'best_validation.json').read_text(encoding='utf-8')),
        test={key:value for key,value in test_metrics.items() if key != 'predictions'},
        model_state_sha256=file_hash(output/'model_state.pth'),
        data_manifest_sha256=manifest_hash,
        precision='Floating-point checkpoint trained with CUDA AMP; not yet integer-calibrated or deployed',
        scope='Custom grouped CCPD2019 holdout; accuracy does not establish real-camera performance')
    save_json(output/'summary.json',summary)
    save_json(output/'progress.json',dict(state='complete',variant=size,best_epoch=best_epoch))
    print(json.dumps({'completed':size,'best_epoch':best_epoch,'test_accuracy':test_metrics['plate_accuracy']},ensure_ascii=False),flush=True)
    del model, optimizer, train_loader, val_loader, test_loader, train, val, test
    torch.cuda.empty_cache()
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--sizes',nargs='+',default=['128x32','188x48'])
    parser.add_argument('--epochs',type=int,default=60)
    parser.add_argument('--min-epochs',type=int,default=20)
    parser.add_argument('--patience',type=int,default=10)
    parser.add_argument('--batch-size',type=int,default=128)
    parser.add_argument('--lr',type=float,default=.001)
    parser.add_argument('--seed',type=int,default=20261026)
    parser.add_argument('--workers',type=int,default=2)
    parser.add_argument('--resume',action='store_true')
    parser.add_argument('--allow-cpu',action='store_true')
    args = parser.parse_args()
    cv2.setNumThreads(1)
    manifest = json.loads((args.data/'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('format') != 'lpr-highres-dataset-v2':
        raise ValueError('Only the audited full-vertex crop dataset v2 is accepted')
    if manifest['chars'] != CHARS or manifest['seed'] != args.seed:
        raise ValueError('Dataset alphabet/seed mismatch')
    manifest_hash = file_hash(args.data/'manifest.json')
    for relative, expected in manifest['cache_sha256'].items():
        if file_hash(args.data/relative) != expected:
            raise ValueError(f'Prepared pixels changed: {relative}')
    for split, data in manifest['splits'].items():
        if file_hash(args.data/f'{split}.jsonl') != data['records_sha256']:
            raise ValueError(f'Split records changed: {split}')
    summaries = [run_variant(args,size,manifest_hash) for size in args.sizes]
    # Resolution selection uses validation, not the held-out test scores.
    winner = max(summaries,key=lambda x:(x['best_validation']['plate_accuracy'],
                                        -x['best_validation']['character_error_rate']))
    save_json(args.output/'comparison.json',dict(status='COMPLETE',
        selection_basis='validation exact accuracy, then CER; test not used for checkpoint/size selection',
        selected_variant=winner['variant'],variants=summaries,
        caveat='Resolution remains a deployment candidate until integer calibration, FPGA timing/resources, and independent real-camera validation'))
    print('HIGHRES_TRAINING_PASS',flush=True)


if __name__ == '__main__':
    main()
