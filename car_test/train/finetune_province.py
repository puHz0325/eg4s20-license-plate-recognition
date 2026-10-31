"""Strengthen non-Anhui recognition with balanced sampling and a training-only province loss."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import time

import cv2
import torch
from torch import nn
from torch.utils.data import DataLoader, WeightedRandomSampler

from model import FPGA_LPRNet
from prepare_highres import file_hash
from train_highres import (CachedPlates, collate, worker_init, seed_all, save_json,
                           atomic_checkpoint, evaluate, finish_amp_step, CHAR_INDEX, SIMILAR)
from summarize_highres import paired_plate_bootstrap


def sampling_weights(records, anhui_share=.2, rectified_share=None):
    groups=defaultdict(list)
    for index,row in enumerate(records):groups[row['plate'][0]].append(index)
    others=[key for key in groups if key!='皖']
    normalizer=sum(math.sqrt(len(groups[key])) for key in others)
    shares={key:(1-anhui_share if '皖' in groups else 1.)*math.sqrt(len(groups[key]))/normalizer
            for key in others}
    if '皖' in groups:shares['皖']=anhui_share if others else 1.
    result=[0.]*len(records)
    for key,indices in groups.items():
        views=defaultdict(list)
        if rectified_share is None:views['all']=indices
        else:
            for index in indices:views[records[index].get('crop_mode','raw')].append(index)
        for mode,subset in views.items():
            if rectified_share is None:mass=1.
            elif len(views)==1:mass=1.
            else:mass=rectified_share if mode=='rectified' else 1.-rectified_share
            hard=[1.25 if SIMILAR&set(records[i]['plate'][1:]) else 1. for i in subset]
            denominator=sum(hard)
            for index,weight in zip(subset,hard,strict=True):result[index]=shares[key]*mass*weight/denominator
    return result


def province_aux_loss(logits, plates):
    # The province is the first character; only the leading temporal window contributes.
    window=max(4,logits.shape[2]//5)
    scores=torch.logsumexp(logits[:,:31,:window].float(),dim=2)
    targets=torch.tensor([CHAR_INDEX[p[0]] for p in plates],device=logits.device,dtype=torch.long)
    return nn.functional.cross_entropy(scores,targets)


def add_province_metrics(metrics):
    province=metrics['province_results']
    non_count=sum(x['samples'] for key,x in province.items() if key!='皖')
    non_correct=sum(x['correct'] for key,x in province.items() if key!='皖')
    supported=[x['accuracy'] for x in province.values() if x['samples']>=10]
    metrics.update(non_anhui_samples=non_count,non_anhui_correct=non_correct,
        non_anhui_plate_accuracy=non_correct/non_count if non_count else 0.,
        anhui_plate_accuracy=province.get('皖',{}).get('accuracy',0.),
        macro_supported_accuracy=sum(supported)/len(supported) if supported else 0.,
        macro_supported_provinces=len(supported))
    return metrics


def selection_key(metrics, anhui_floor):
    return (float(metrics['anhui_plate_accuracy']>=anhui_floor),metrics['non_anhui_plate_accuracy'],
            metrics['macro_supported_accuracy'],metrics['plate_accuracy'])


def set_training_mode(model, freeze_bn):
    model.train()
    if freeze_bn:
        for module in model.modules():
            if isinstance(module,nn.BatchNorm2d):module.eval()


def metrics_on(model,loader,device,records=None):
    metrics=add_province_metrics(evaluate(model,loader,device,include_predictions=records is not None))
    if records is not None:
        for prediction,record in zip(metrics['predictions'],records,strict=True):
            prediction.update(id=record['id'],source=record['source'])
    return metrics


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data',type=Path,required=True)
    parser.add_argument('--init',type=Path,required=True)
    parser.add_argument('--regression-data',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--epochs',type=int,default=40)
    parser.add_argument('--min-epochs',type=int,default=15)
    parser.add_argument('--patience',type=int,default=8)
    parser.add_argument('--lr',type=float,default=.0001)
    parser.add_argument('--batch-size',type=int,default=128)
    parser.add_argument('--workers',type=int,default=2)
    parser.add_argument('--anhui-share',type=float,default=.2)
    parser.add_argument('--province-loss',type=float,default=.15)
    parser.add_argument('--anhui-max-drop',type=float,default=.03)
    parser.add_argument('--seed',type=int,default=2026102603)
    parser.add_argument('--resume',action='store_true')
    parser.add_argument('--freeze-bn',action='store_true')
    parser.add_argument('--rectified-share',type=float,default=None)
    parser.add_argument('--epoch-samples',type=int,default=0)
    args=parser.parse_args();cv2.setNumThreads(1);seed_all(args.seed)
    if not torch.cuda.is_available():raise RuntimeError('CUDA required for this run')
    manifest=json.loads((args.data/'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('format')!='lpr-province-dataset-v3' or manifest['seed']!=args.seed:
        raise ValueError('Wrong dataset version/seed')
    if manifest['holdout_parent_plate_overlap']!=0:raise ValueError('Parent leakage')
    for relative,sha in manifest['cache_sha256'].items():
        if file_hash(args.data/relative)!=sha:raise ValueError('Cache changed')
    for split,value in manifest['splits'].items():
        if file_hash(args.data/f'{split}.jsonl')!=value['records_sha256']:raise ValueError('Records changed')
    args.output.mkdir(parents=True,exist_ok=True)
    config={key:value for key,value in vars(args).items() if key!='resume'}
    config={key:str(value.resolve()) if isinstance(value,Path) else value for key,value in config.items()}
    config.update(input_height=32,input_wh=[128,32],parent_sha256=file_hash(args.init),
        data_manifest_sha256=file_hash(args.data/'manifest.json'),
        architecture='same FPGA_LPRNet; auxiliary loss adds no inference parameters',ccpd2020_used=False)
    path=args.output/'config.json'
    if path.exists():
        if not args.resume or json.loads(path.read_text(encoding='utf-8'))!=config:raise ValueError('Existing run preserved')
        if (args.output/'summary.json').exists():print('ALREADY_COMPLETE');return
    else:save_json(path,config)
    device='cuda'
    train=CachedPlates(args.data,'128x32','train',True,args.seed)
    val=CachedPlates(args.data,'128x32','val')
    options=dict(batch_size=args.batch_size,num_workers=args.workers,collate_fn=collate,
        pin_memory=True,worker_init_fn=worker_init,persistent_workers=args.workers>0,
        generator=torch.Generator().manual_seed(args.seed))
    generator=torch.Generator().manual_seed(args.seed)
    sampler=WeightedRandomSampler(sampling_weights(train.records,args.anhui_share,args.rectified_share),
                                   args.epoch_samples or len(train),
                                   replacement=True,generator=generator)
    train_loader=DataLoader(train,sampler=sampler,**options)
    val_loader=DataLoader(val,shuffle=False,**options)
    model=FPGA_LPRNet(68,input_height=32).to(device)
    model.load_state_dict(torch.load(args.init,map_location='cpu',weights_only=True),strict=True)
    if (args.output/'parent_validation.json').exists():
        parent_val=json.loads((args.output/'parent_validation.json').read_text(encoding='utf-8'))
    else:
        parent_val=metrics_on(model,val_loader,device)
        save_json(args.output/'parent_validation.json',parent_val)
    floor=max(0.,parent_val['anhui_plate_accuracy']-args.anhui_max_drop)
    best_key=selection_key(parent_val,floor);best_epoch=0;stale=0;start_epoch=0;elapsed_before=0.;skips=0
    optimizer=torch.optim.AdamW(model.parameters(),lr=args.lr,weight_decay=1e-4)
    scaler=torch.amp.GradScaler('cuda',init_scale=1024.)
    criterion=nn.CTCLoss(blank=67,zero_infinity=False)
    if args.resume and (args.output/'last.pt').exists():
        state=torch.load(args.output/'last.pt',map_location='cpu',weights_only=False)
        model.load_state_dict(state['model']);optimizer.load_state_dict(state['optimizer']);scaler.load_state_dict(state['scaler'])
        start_epoch=state['epoch'];best_epoch=state['best_epoch'];best_key=tuple(state['best_key'])
        stale=state['stale'];elapsed_before=state['elapsed_seconds'];skips=state['amp_skipped_steps']
    elif not (args.output/'best.pt').exists():
        atomic_checkpoint(args.output/'best.pt',dict(model=model.state_dict(),epoch=0,config=config))
        atomic_checkpoint(args.output/'model_state.pth',model.state_dict())
        save_json(args.output/'best_validation.json',dict(epoch=0,**parent_val))
    print(json.dumps({'parent_validation':{key:parent_val[key] for key in
        ['plate_accuracy','non_anhui_plate_accuracy','anhui_plate_accuracy','macro_supported_accuracy']},
        'anhui_floor':floor,'train':len(train),'val':len(val)},ensure_ascii=False),flush=True)
    begin=time.monotonic();consecutive_skips=0
    for epoch in range(start_epoch,args.epochs):
        set_training_mode(model,args.freeze_bn);generator.manual_seed(args.seed+epoch);train.epoch.fill_(epoch)
        ep_begin=time.monotonic();total=0.;ctc_total=0.;aux_total=0.;count=0
        lr=args.lr*min(1.,(epoch+1)/3)*(.1+.9*.5*(1+math.cos(math.pi*epoch/args.epochs)))
        for group in optimizer.param_groups:group['lr']=lr
        for batch,(images,targets,lengths,plates) in enumerate(train_loader,1):
            optimizer.zero_grad(set_to_none=True);images=images.to(device,non_blocking=True)
            with torch.autocast('cuda',dtype=torch.float16):logits=model(images)
            ctc=criterion(logits.float().permute(2,0,1).log_softmax(2),targets,
                          torch.full((len(plates),),logits.shape[2],dtype=torch.long),lengths)
            aux=province_aux_loss(logits,plates)
            loss=ctc+args.province_loss*min(1.,(epoch+1)/3)*aux
            if not bool(torch.isfinite(loss)):raise FloatingPointError('Nonfinite training loss')
            scaler.scale(loss).backward();updated=finish_amp_step(model,optimizer,scaler)
            if updated:consecutive_skips=0
            else:
                skips+=1;consecutive_skips+=1
                print(json.dumps({'amp_skip':skips,'epoch':epoch+1,'batch':batch,'scale':scaler.get_scale()}),flush=True)
                if consecutive_skips>6:raise FloatingPointError('Persistent AMP failure')
            n=len(plates);count+=n;total+=float(loss.detach())*n;ctc_total+=float(ctc.detach())*n;aux_total+=float(aux.detach())*n
            if batch==1 or batch%100==0:print(json.dumps({'epoch':epoch+1,'batch':batch,'loss':total/count}),flush=True)
        metrics=metrics_on(model,val_loader,device);key=selection_key(metrics,floor)
        if key>best_key:best_key=key;best_epoch=epoch+1;stale=0;improved=True
        else:stale+=1;improved=False
        elapsed=elapsed_before+time.monotonic()-begin
        row=dict(epoch=epoch+1,train_loss=total/count,ctc_loss=ctc_total/count,province_loss=aux_total/count,
            lr=lr,validation=metrics,best_epoch=best_epoch,epoch_seconds=time.monotonic()-ep_begin,
            elapsed_seconds=elapsed,amp_skipped_steps=skips,anhui_floor=floor)
        with (args.output/'history.jsonl').open('a',encoding='utf-8') as stream:stream.write(json.dumps(row,ensure_ascii=False)+'\n')
        state=dict(model=model.state_dict(),optimizer=optimizer.state_dict(),scaler=scaler.state_dict(),
            epoch=epoch+1,best_epoch=best_epoch,best_key=best_key,stale=stale,elapsed_seconds=elapsed,
            amp_skipped_steps=skips,config=config)
        atomic_checkpoint(args.output/'last.pt',state)
        if improved:
            atomic_checkpoint(args.output/'best.pt',state);atomic_checkpoint(args.output/'model_state.pth',model.state_dict())
            save_json(args.output/'best_validation.json',dict(epoch=epoch+1,**metrics))
        save_json(args.output/'progress.json',dict(state='training',**row))
        print(json.dumps({'epoch':epoch+1,'non_anhui_accuracy':metrics['non_anhui_plate_accuracy'],
            'anhui_accuracy':metrics['anhui_plate_accuracy'],'overall_accuracy':metrics['plate_accuracy'],
            'best_epoch':best_epoch},ensure_ascii=False),flush=True)
        if epoch+1>=args.min_epochs and stale>=args.patience:break
    best=torch.load(args.output/'best.pt',map_location='cpu',weights_only=False);model.load_state_dict(best['model'])
    parent_model=FPGA_LPRNet(68,input_height=32).to(device)
    parent_model.load_state_dict(torch.load(args.init,map_location='cpu',weights_only=True))
    test=CachedPlates(args.data,'128x32','test');test_loader=DataLoader(test,shuffle=False,**options)
    parent_test=metrics_on(parent_model,test_loader,device,test.records)
    new_test=metrics_on(model,test_loader,device,test.records)
    save_json(args.output/'parent_test.json',parent_test);save_json(args.output/'test.json',new_test)
    paired=paired_plate_bootstrap(parent_test['predictions'],new_test['predictions'])
    paired.update(direction='province-focused minus parent128',only_new_correct=paired.pop('only_188_correct'),
                  only_parent_correct=paired.pop('only_128_correct'))
    save_json(args.output/'paired_comparison.json',paired)
    regression=CachedPlates(args.regression_data,'128x32','test')
    regression_loader=DataLoader(regression,shuffle=False,**options)
    regression_metrics=metrics_on(model,regression_loader,device,regression.records)
    save_json(args.output/'old_test_regression.json',dict(scope='Previously inspected holdout, regression only',metrics=regression_metrics))
    summary=dict(status='TRAINING_COMPLETE',best_epoch=best_epoch,epochs_run=epoch+1,
        elapsed_seconds=elapsed_before+time.monotonic()-begin,anhui_floor=floor,
        model_state_sha256=file_hash(args.output/'model_state.pth'),parent_model_sha256=file_hash(args.init),
        inference_parameter_count=sum(p.numel() for p in model.parameters()),ccpd2020_used=False,
        validation=json.loads((args.output/'best_validation.json').read_text(encoding='utf-8')),
        parent_test={k:v for k,v in parent_test.items() if k!='predictions'},
        test={k:v for k,v in new_test.items() if k!='predictions'},
        old_test_regression={k:v for k,v in regression_metrics.items() if k!='predictions'},
        caveat='New holdout is parent-unseen and province-focused, so its overall accuracy is not comparable to the earlier Anhui-heavy test. Rare provinces remain uncertain; no integer/hardware validation.')
    save_json(args.output/'summary.json',summary);save_json(args.output/'progress.json',{'state':'complete','best_epoch':best_epoch})
    print(json.dumps({'best_epoch':best_epoch,'parent_non_anhui_test':parent_test['non_anhui_plate_accuracy'],
                     'new_non_anhui_test':new_test['non_anhui_plate_accuracy'],'new_overall_test':new_test['plate_accuracy']}),flush=True)
    print('PROVINCE_FINETUNE_PASS',flush=True)


if __name__=='__main__':main()
