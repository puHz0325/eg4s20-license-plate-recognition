"""Calibrate/export the actual 8-layer teacher and evaluate exact INT8 integer inference."""
import argparse
import json
from pathlib import Path
import time
import zlib

import numpy as np
import torch
from torch import nn

from model import FPGA_LPRNet
from integer_reference import quantize_model,IntegerNetwork,file_hash
from train_highres import save_json
from finetune_province import sampling_weights
from lpr_common import decode_ctc


def calibrate_cached(model,pixels,indices,device,robust=False,seed=2026102903):
    modules=list(model.backbone.children());maxima=[];handles=[]
    for index,module in enumerate(modules):
        if isinstance(module,nn.ReLU) or index==len(modules)-1:
            slot=len(maxima);maxima.append(0.)
            def observe(mod,args,output,slot=slot):maxima[slot]=max(maxima[slot],float(output.abs().max()))
            handles.append(module.register_forward_hook(observe))
    with torch.inference_mode():
        for start in range(0,len(indices),64):
            raw=np.asarray(pixels[indices[start:start+64]],dtype=np.uint8)
            batches=[raw]
            if robust:
                from robust_teacher import photometric
                for mode in ('inverted','low_contrast','soft_strokes'):
                    batches.append(np.stack([photometric(image,np.random.default_rng(seed+int(index)),mode)
                        for index,image in zip(indices[start:start+64],raw,strict=True)]))
            for images in batches:
                model(torch.from_numpy((images.astype(np.float32)-127.5)/128.)[:,None].to(device))
    for handle in handles:handle.remove()
    return maxima


def export_rtl_package(network,output):
    weight_parts=[];bias_parts=[];layers=[];height,width=32,128;weight_base=bias_index=0
    for index,layer in enumerate(network.layers):
        oc,ic,kh,kw=layer['weight'].shape
        ph,pw=layer['padding'] if isinstance(layer['padding'],(tuple,list)) else (layer['padding'],)*2
        ch=height+2*ph-kh+1;cw=width+2*pw-kw+1
        pool_h,pool_w=layer['pool'] or (1,1)
        oh,ow=ch//pool_h,cw//pool_w
        weight_parts.append(layer['weight'].astype(np.int8).tobytes(order='C'))
        bias_parts.append(layer['bias'].astype('<i4').tobytes(order='C'))
        layers.append(dict(index=index,input_hwc=[height,width,ic],conv_hwc=[ch,cw,oc],output_hwc=[oh,ow,oc],
            kernel_hw=[kh,kw],padding_hw=[ph,pw],pool_hw=[pool_h,pool_w],weight_offset_bytes=weight_base,
            weight_bytes=layer['weight'].size,bias_index=bias_index,bias_count=oc,
            shift=layer['input_frac']+layer['weight_frac']-layer['output_frac'],
            relu=layer['relu'],output_bits=layer['output_bits']))
        height,width=oh,ow;weight_base+=layer['weight'].size;bias_index+=oc
    weights=b''.join(weight_parts);biases=b''.join(bias_parts);binary=weights+biases
    (output/'weights.bin').write_bytes(weights);(output/'biases.bin').write_bytes(biases)
    (output/'model_init.bin').write_bytes(binary)
    for layer in layers:
        layer['weight_address_bytes']=0x100000+layer['weight_offset_bytes']
        layer['bias_address_bytes']=0x100000+len(weights)+4*layer['bias_index']
        assert layer['weight_address_bytes']%16==0 and layer['bias_address_bytes']%16==0
    assert len(binary)<=256*1024 and (height,width)==(1,32)
    save_json(output/'rtl_model.json',dict(format='teacher-sdram-int8-v1',input_wh=[128,32],classes=68,
        ctc_steps=32,layers=layers,address_unit='bytes; SDRAM controller requests use address>>2 and BL4 alignment',
        parameter_base_bytes=0x100000,weight_layout='OIHW int8',bias_layout='little-endian int32',
        weights_bytes=len(weights),bias_bytes=len(biases),model_bytes=len(binary),
        crc32=f'{zlib.crc32(binary)&0xffffffff:08X}',model_sha256=file_hash(output/'model_init.bin'),
        caveat='Parameter export only; RTL simulation, timing and hardware are verified separately.'))
    text=['// Generated 8-layer teacher descriptor. Addresses are absolute BYTES, not SDRAM words.',
          '// Requires cfg_* registers of appropriate widths in a new controller.', 'case (layer_idx)']
    for layer in layers:
        ih,iw,ic=layer['input_hwc'];oh,ow,oc=layer['output_hwc'];kh,kw=layer['kernel_hw']
        ph,pw=layer['padding_hw'];pool_h,pool_w=layer['pool_hw'];shift=layer['shift']
        fields=dict(in_h=ih,in_w=iw,in_ch=ic,out_ch=oc,out_h=oh,out_w=ow,kernel_h=kh,kernel_w=kw,
            pad_h=ph,pad_w=pw,pool_h=pool_h,pool_w=pool_w,
            weight_base_bytes=layer['weight_address_bytes'],bias_base_bytes=layer['bias_address_bytes'],
            shift=shift,relu=int(layer['relu']),final=int(layer['index']==7))
        text.append(f"  3'd{layer['index']}: begin")
        text.extend(f'    cfg_{key} = {value};' for key,value in fields.items());text.append('  end')
    text.extend(['  default: begin end','endcase',''])
    (output/'teacher_layers.vh').write_text('\n'.join(text),encoding='ascii')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True)
    parser.add_argument('--training-data',type=Path,required=True)
    parser.add_argument('--main-data',type=Path,required=True)
    parser.add_argument('--province-data',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--calibration-count',type=int,default=1024)
    parser.add_argument('--evaluation-count',type=int,default=256)
    parser.add_argument('--seed',type=int,default=2026102605)
    parser.add_argument('--robust-calibration',action='store_true',help='Include train-only polarity and low-contrast variants')
    parser.add_argument('--fixed-scales',type=Path,help='QAT template; preserve its weight and activation fractions exactly')
    args=parser.parse_args();torch.set_num_threads(4)
    if (args.run/'summary.json').exists():
        summary=json.loads((args.run/'summary.json').read_text(encoding='utf-8'))
        if summary.get('validation_qualified') is False:raise ValueError('Robust teacher failed validation retention gate')
    if args.output.exists():raise FileExistsError('Existing quantization preserved')
    args.output.mkdir(parents=True)
    config=json.loads((args.run/'config.json').read_text(encoding='utf-8'))
    device='cuda' if torch.cuda.is_available() else 'cpu'
    model=FPGA_LPRNet(**config['model_options']).to(device).eval()
    model.load_state_dict(torch.load(args.run/'model_state.pth',map_location='cpu',weights_only=True))
    train_rows=[json.loads(x) for x in (args.training_data/'train.jsonl').read_text(encoding='utf-8').splitlines()]
    train_pixels=np.load(args.training_data/'128x32/train.npy',mmap_mode='r')
    weights=np.asarray(sampling_weights(train_rows,.4,.2));weights/=weights.sum()
    rng=np.random.default_rng(args.seed)
    chosen=rng.choice(len(train_rows),size=min(args.calibration_count,len(train_rows)),replace=False,p=weights)
    indices=np.array([train_rows[i]['cache_index'] for i in chosen])
    maxima=calibrate_cached(model,train_pixels,indices,device,args.robust_calibration,args.seed)
    if args.fixed_scales:
        from teacher_qat import export_fixed
        if config.get('qat_scales_sha256')!=file_hash(args.fixed_scales/'model.json'):
            raise ValueError('QAT scale identity mismatch')
        network=export_fixed(model,IntegerNetwork.load(args.fixed_scales))
    else:network=quantize_model(model,maxima)
    network.save(args.output,dict(model_options=config['model_options'],weights_sha256=file_hash(args.run/'model_state.pth'),
        input_wh=[128,32],calibration_count=len(chosen)*(4 if args.robust_calibration else 1),
        robust_calibration=args.robust_calibration,fixed_qat_scales=str(args.fixed_scales) if args.fixed_scales else None,
        calibration_partition='training only',seed=args.seed))
    export_rtl_package(network,args.output)
    network=IntegerNetwork.load(args.output)
    save_json(args.output/'calibration.json',dict(maxima=maxima,robust_variants=args.robust_calibration,
        source_manifest_sha256=file_hash(args.training_data/'manifest.json'),
        samples=[dict(id=train_rows[i]['id'],plate=train_rows[i]['plate'],cache_index=train_rows[i]['cache_index']) for i in chosen]))
    reports={};begin=time.monotonic()
    for tag,root in [('main_validation',args.main_data),('province_validation',args.province_data)]:
        rows=[json.loads(x) for x in (root/'val.jsonl').read_text(encoding='utf-8').splitlines()]
        if tag=='province_validation':rows=[row for row in rows if row['plate'][0]!='皖']
        rows=[rows[i] for i in sorted(rng.choice(len(rows),size=min(args.evaluation_count,len(rows)),replace=False))]
        pixels=np.load(root/'128x32/val.npy',mmap_mode='r');examples=[];float_correct=integer_correct=agreement=0
        for start in range(0,len(rows),4):
            group=rows[start:start+4];images=np.stack([pixels[r['cache_index']] for r in group])
            with torch.inference_mode():
                x=torch.from_numpy((images.astype(np.float32)-127.5)/128.)[:,None].to(device)
                floating=decode_ctc(model(x).cpu().numpy())
            result,_=network.forward(images);integer=decode_ctc(result)
            for row,fp,qp in zip(group,floating,integer,strict=True):
                float_correct+=fp==row['plate'];integer_correct+=qp==row['plate'];agreement+=fp==qp
                examples.append(dict(id=row['id'],expected=row['plate'],float_prediction=fp,integer_prediction=qp))
            if start%32==0:print(json.dumps({'group':tag,'done':min(start+4,len(rows)),'total':len(rows),
                'float_correct':float_correct,'integer_correct':integer_correct}),flush=True)
        n=len(rows);reports[tag]=dict(samples=n,float_exact=float_correct,integer_exact=integer_correct,
            float_accuracy=float_correct/n,integer_accuracy=integer_correct/n,agreement=agreement/n,
            accuracy_drop_percentage_points=100*(float_correct-integer_correct)/n,examples=examples)
        save_json(args.output/(tag+'.json'),reports[tag])
    save_json(args.output/'evaluation.json',dict(status='COMPLETE',reports=reports,
        validation_gate_passed=all(r['accuracy_drop_percentage_points']<=1. for r in reports.values()),
        elapsed_seconds=time.monotonic()-begin,scope='Frozen validation sample, not full-regression or FPGA proof'))
    print(json.dumps({tag:{k:v for k,v in row.items() if k!='examples'} for tag,row in reports.items()},indent=2))


if __name__=='__main__':main()
