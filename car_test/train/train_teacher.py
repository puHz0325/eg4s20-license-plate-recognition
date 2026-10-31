"""Offline stronger teacher, then gated student/control training; deployment remains separate."""
import argparse
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
from train_highres import (CachedPlates,collate,worker_init,seed_all,save_json,atomic_checkpoint,
                           finish_amp_step,decode_indices)
from finetune_province import sampling_weights,metrics_on


def distillation_loss(student,teacher,temperature=2.,sample_mask=None):
    teacher=teacher.detach().float();student=student.float()
    logq=(teacher/temperature).log_softmax(1);q=logq.exp()
    logs=(student/temperature).log_softmax(1)
    divergence=(q*(logq-logs)).sum(1)
    weights=.2+.8*(1.-teacher.softmax(1)[:,67])
    if sample_mask is not None:weights=weights*sample_mask[:,None].to(weights)
    return (divergence*weights).sum()/weights.sum().clamp_min(1.)*temperature**2


def teacher_qualifies(metrics,baseline):
    return (metrics['main']>=baseline['main']-.01 and metrics['non_anhui']>=baseline['non_anhui']+.03
            and metrics['supported_macro']>=baseline['supported_macro'])


def build_model(mode):
    options=dict(class_num=68,input_height=32)
    if mode=='teacher':options.update(channels=[16,32,48,64,64,128],extra_prepool=True,context_kernel=7)
    return FPGA_LPRNet(**options),options


def validate(model,main_loader,province_loader,device):
    main=metrics_on(model,main_loader,device);province=metrics_on(model,province_loader,device)
    return dict(main=main['plate_accuracy'],non_anhui=province['non_anhui_plate_accuracy'],
        supported_macro=province['macro_supported_accuracy'],main_metrics=main,province_metrics=province)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data',type=Path,required=True)
    parser.add_argument('--main-data',type=Path,required=True)
    parser.add_argument('--parent',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--mode',choices=['teacher','student_control','student_kd'],default='teacher')
    parser.add_argument('--teacher',type=Path)
    parser.add_argument('--epochs',type=int,default=60)
    parser.add_argument('--min-epochs',type=int,default=20)
    parser.add_argument('--patience',type=int,default=10)
    parser.add_argument('--batch-size',type=int,default=128)
    parser.add_argument('--epoch-samples',type=int,default=32000)
    parser.add_argument('--workers',type=int,default=2)
    parser.add_argument('--lr',type=float,default=.001)
    parser.add_argument('--seed',type=int,default=2026102604)
    parser.add_argument('--resume',action='store_true')
    args=parser.parse_args();cv2.setNumThreads(1);seed_all(args.seed)
    if not torch.cuda.is_available():raise RuntimeError('CUDA required')
    data_manifest=json.loads((args.data/'manifest.json').read_text(encoding='utf-8'))
    for relative,sha in data_manifest['cache_sha256'].items():
        if file_hash(args.data/relative)!=sha:raise ValueError('Training cache changed')
    for split,data in data_manifest['splits'].items():
        if file_hash(args.data/f'{split}.jsonl')!=data['records_sha256']:raise ValueError('Training records changed')
    args.output.mkdir(parents=True,exist_ok=True)
    model,model_options=build_model(args.mode)
    config={k:str(v.resolve()) if isinstance(v,Path) else v for k,v in vars(args).items() if k!='resume'}
    config.update(parent_sha256=file_hash(args.parent),data_manifest_sha256=file_hash(args.data/'manifest.json'),
                  model_options=model_options,ccpd2020_used=False,phone_capture_used=False)
    config_path=args.output/'config.json'
    if config_path.exists():
        if not args.resume or json.loads(config_path.read_text(encoding='utf-8'))!=config:raise ValueError('Existing experiment preserved')
        if (args.output/'summary.json').exists():print('ALREADY_COMPLETE');return
    else:save_json(config_path,config)
    teacher=None
    if args.mode=='student_kd':
        if args.teacher is None:raise ValueError('Teacher run required')
        teacher_summary=json.loads((args.teacher/'summary.json').read_text(encoding='utf-8'))
        if not teacher_summary['teacher_qualifies']:raise ValueError('Teacher failed validation gate; do not distill')
        teacher_config=json.loads((args.teacher/'config.json').read_text(encoding='utf-8'))
        teacher=FPGA_LPRNet(**teacher_config['model_options']).cuda().eval()
        teacher.load_state_dict(torch.load(args.teacher/'model_state.pth',map_location='cpu',weights_only=True))
        for p in teacher.parameters():p.requires_grad_(False)
    device='cuda';model=model.to(device)
    if args.mode!='teacher':model.load_state_dict(torch.load(args.parent,map_location='cpu',weights_only=True))
    train=CachedPlates(args.data,'128x32','train',True,args.seed)
    main_val=CachedPlates(args.main_data,'128x32','val')
    province_val=CachedPlates(args.data,'128x32','val')
    options=dict(num_workers=args.workers,collate_fn=collate,pin_memory=True,worker_init_fn=worker_init,
                 persistent_workers=args.workers>0,generator=torch.Generator().manual_seed(args.seed))
    generator=torch.Generator().manual_seed(args.seed)
    sampler=WeightedRandomSampler(sampling_weights(train.records,.4,.2),args.epoch_samples,
                                   replacement=True,generator=generator)
    train_loader=DataLoader(train,batch_size=args.batch_size,sampler=sampler,**options)
    main_loader=DataLoader(main_val,batch_size=256,shuffle=False,**options)
    province_loader=DataLoader(province_val,batch_size=256,shuffle=False,**options)
    baseline_path=args.output/'baseline_validation.json'
    if baseline_path.exists():baseline=json.loads(baseline_path.read_text(encoding='utf-8'))
    else:
        reference=FPGA_LPRNet(68,input_height=32).cuda().eval()
        reference.load_state_dict(torch.load(args.parent,map_location='cpu',weights_only=True))
        baseline=validate(reference,main_loader,province_loader,device);save_json(baseline_path,baseline)
        del reference;torch.cuda.empty_cache()
    optimizer=torch.optim.AdamW(model.parameters(),lr=args.lr,weight_decay=1e-4)
    scaler=torch.amp.GradScaler('cuda',init_scale=1024.)
    criterion=nn.CTCLoss(blank=67,zero_infinity=False)
    best_key=(-1.,-1.,-1.);best_epoch=0;stale=0;start=0;elapsed_before=0.;skips=0
    if args.resume and (args.output/'last.pt').exists():
        state=torch.load(args.output/'last.pt',map_location='cpu',weights_only=False)
        model.load_state_dict(state['model']);optimizer.load_state_dict(state['optimizer']);scaler.load_state_dict(state['scaler'])
        start=state['epoch'];best_key=tuple(state['best_key']);best_epoch=state['best_epoch']
        stale=state['stale'];elapsed_before=state['elapsed_seconds'];skips=state['amp_skipped_steps']
    print(json.dumps({'mode':args.mode,'parameters':sum(p.numel() for p in model.parameters()),
        'baseline':{k:baseline[k] for k in ['main','non_anhui','supported_macro']},'start_epoch':start}),flush=True)
    begin=time.monotonic();consecutive_skips=0
    for epoch in range(start,args.epochs):
        model.train();train.epoch.fill_(epoch);generator.manual_seed(args.seed+epoch)
        ep_begin=time.monotonic();total=ctc_total=kd_total=0.;count=0;teacher_correct=0
        lr=args.lr*min(1.,(epoch+1)/3)*(.05+.95*.5*(1+math.cos(math.pi*epoch/args.epochs)))
        for group in optimizer.param_groups:group['lr']=lr
        for batch,(images,targets,lengths,plates) in enumerate(train_loader,1):
            images=images.to(device,non_blocking=True);optimizer.zero_grad(set_to_none=True)
            with torch.autocast('cuda',dtype=torch.float16):logits=model(images)
            ctc=criterion(logits.float().permute(2,0,1).log_softmax(2),targets,
                          torch.full((len(plates),),logits.shape[2],dtype=torch.long),lengths)
            kd=ctc.new_tensor(0.)
            if teacher is not None:
                with torch.no_grad(),torch.autocast('cuda',dtype=torch.float16):soft=teacher(images)
                predictions=decode_indices(soft.argmax(1).cpu().numpy())
                mask=torch.tensor([a==b for a,b in zip(predictions,plates,strict=True)],device=device)
                teacher_correct+=int(mask.sum())
                kd=distillation_loss(logits,soft,2.,mask)
            loss=ctc+.5*kd
            if not bool(torch.isfinite(loss)):raise FloatingPointError('Nonfinite CTC/KD loss')
            scaler.scale(loss).backward();updated=finish_amp_step(model,optimizer,scaler)
            if updated:consecutive_skips=0
            else:
                skips+=1;consecutive_skips+=1
                print(json.dumps({'amp_skip':skips,'scale':scaler.get_scale(),'epoch':epoch+1,'batch':batch}),flush=True)
                if consecutive_skips>6:raise FloatingPointError('AMP did not recover')
            n=len(plates);count+=n;total+=float(loss.detach())*n;ctc_total+=float(ctc.detach())*n;kd_total+=float(kd.detach())*n
            if batch==1 or batch%100==0:print(json.dumps({'epoch':epoch+1,'batch':batch,'loss':total/count}),flush=True)
        validation=validate(model,main_loader,province_loader,device)
        combined=.5*(validation['main']+validation['non_anhui'])
        key=(float(validation['main']>=baseline['main']-.01),combined,validation['supported_macro'])
        improved=key>best_key
        if improved:best_key=key;best_epoch=epoch+1;stale=0
        else:stale+=1
        elapsed=elapsed_before+time.monotonic()-begin
        row=dict(epoch=epoch+1,loss=total/count,ctc_loss=ctc_total/count,kd_loss=kd_total/count,
            validation=validation,combined=combined,best_epoch=best_epoch,epoch_seconds=time.monotonic()-ep_begin,
            elapsed_seconds=elapsed,amp_skipped_steps=skips,teacher_correct_training_examples=teacher_correct)
        with (args.output/'history.jsonl').open('a',encoding='utf-8') as stream:stream.write(json.dumps(row,ensure_ascii=False)+'\n')
        state=dict(model=model.state_dict(),optimizer=optimizer.state_dict(),scaler=scaler.state_dict(),epoch=epoch+1,
            best_key=best_key,best_epoch=best_epoch,stale=stale,elapsed_seconds=elapsed,amp_skipped_steps=skips,config=config)
        atomic_checkpoint(args.output/'last.pt',state)
        if improved:
            atomic_checkpoint(args.output/'best.pt',state);atomic_checkpoint(args.output/'model_state.pth',model.state_dict())
            save_json(args.output/'best_validation.json',dict(epoch=epoch+1,**validation))
        save_json(args.output/'progress.json',dict(state='training',**row))
        print(json.dumps({'epoch':epoch+1,'main':validation['main'],'non_anhui':validation['non_anhui'],
            'supported_macro':validation['supported_macro'],'best_epoch':best_epoch,'seconds':row['epoch_seconds']}),flush=True)
        if epoch+1>=args.min_epochs and stale>=args.patience:break
    best=json.loads((args.output/'best_validation.json').read_text(encoding='utf-8'))
    qualified=teacher_qualifies(best,baseline)
    save_json(args.output/'summary.json',dict(status='TRAINING_COMPLETE',mode=args.mode,best_epoch=best_epoch,
        epochs_run=epoch+1,elapsed_seconds=elapsed_before+time.monotonic()-begin,
        baseline=baseline,validation=best,teacher_qualifies=qualified,
        model_state_sha256=file_hash(args.output/'model_state.pth'),model_options=model_options,
        parameter_count=sum(p.numel() for p in model.parameters()),ccpd2020_used=False,phone_capture_used=False,
        caveat='Validation-gated offline experiment. Fixed evaluation is separate; no quantization or FPGA deployment.'))
    save_json(args.output/'progress.json',dict(state='complete',best_epoch=best_epoch,teacher_qualifies=qualified))
    print(json.dumps({'completed':args.mode,'qualified':qualified,'best_epoch':best_epoch,
                     'main':best['main'],'non_anhui':best['non_anhui']}),flush=True)


if __name__=='__main__':main()
