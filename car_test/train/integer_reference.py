"""Integer LPR reference: exact integer MAC, power-of-two scales and RTL vectors.

Float operations are used only for calibration, parameter quantization and the
comparison baseline. IntegerNetwork.forward performs no floating point math.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import sys

import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from lpr_common import CHARS, decode_ctc, gray_payload, normalize_gray, prepare_gray, read_image
from model import FPGA_LPRNet


def select_fraction_bits(maximum, limit):
    if not math.isfinite(maximum) or maximum < 0:
        raise ValueError('Calibration range must be finite and nonnegative')
    return math.floor(math.log2(limit / maximum)) if maximum else 0


def quantize_array(values, frac, minimum, maximum):
    values = np.asarray(values, dtype=np.float64)
    if not np.isfinite(values).all():
        raise ValueError('Cannot quantize nonfinite parameters')
    return np.clip(np.rint(values * 2.**frac), minimum, maximum).astype(np.int64)


def round_shift(values, shift):
    """Runtime rounding: nearest, ties away from zero; negative shift is left."""
    values = np.asarray(values, dtype=np.int64)
    if shift <= 0:
        return values << -shift
    magnitude = (np.abs(values) + (1 << (shift-1))) >> shift
    return np.where(values < 0, -magnitude, magnitude)


def conv2d_int(features, weight, bias, padding=0):
    """NCHW/OIHW stride-one correlation; int64 host MAC checks int32 RTL range."""
    features = np.asarray(features)
    weight = np.asarray(weight)
    bias = np.asarray(bias)
    if not all(np.issubdtype(x.dtype, np.integer) for x in (features,weight,bias)):
        raise ValueError('Integer convolution cannot accept floating point values')
    if features.ndim != 4 or weight.ndim != 4 or features.shape[1] != weight.shape[1]:
        raise ValueError('Invalid convolution shape or input channel count')
    if bias.shape != (weight.shape[0],):
        raise ValueError('Invalid bias shape')
    ph,pw=padding if isinstance(padding,(tuple,list)) else (padding,padding)
    if ph<0 or pw<0:raise ValueError('Padding must be nonnegative')
    x = np.pad(features.astype(np.int64), ((0,0),(0,0),(ph,ph),(pw,pw)))
    kh,kw = weight.shape[2:]
    windows = np.lib.stride_tricks.sliding_window_view(x,(kh,kw),axis=(2,3))
    result = np.einsum('nchwkl,ockl->nohw', windows, weight.astype(np.int64), optimize=True)
    result += bias.astype(np.int64)[None,:,None,None]
    if result.min() < -(1 << 31) or result.max() > (1 << 31)-1:
        raise OverflowError('Convolution exceeds signed INT32 accumulator range')
    return result.astype(np.int32)


def maxpool_int(features, kernel):
    kh,kw = kernel
    n,c,h,w = features.shape
    oh,ow = h//kh,w//kw
    if not oh or not ow:
        raise ValueError('Pooling kernel exceeds feature dimensions')
    windows = features[:,:,:oh*kh,:ow*kw].reshape(n,c,oh,kh,ow,kw)
    return windows.max(axis=(3,5))


def fold_layers(model):
    """Read the real Sequential definition, including the 2x1 fourth pool."""
    modules = list(model.backbone.children())
    layers = []
    for index,module in enumerate(modules):
        if isinstance(module, nn.Conv2d):
            w = module.weight.detach().cpu().double().numpy().copy()
            b = (module.bias.detach().cpu().double().numpy().copy() if module.bias is not None
                 else np.zeros(module.out_channels,dtype=np.float64))
            if index+1 < len(modules) and isinstance(modules[index+1],nn.BatchNorm2d):
                bn = modules[index+1]
                factor = bn.weight.detach().cpu().double().numpy() / np.sqrt(
                    bn.running_var.detach().cpu().double().numpy()+bn.eps)
                w *= factor[:,None,None,None]
                b = (b-bn.running_mean.detach().cpu().double().numpy())*factor + bn.bias.detach().cpu().double().numpy()
            padding=module.padding[0] if module.padding[0]==module.padding[1] else list(module.padding)
            layers.append(dict(weight=w,bias=b,padding=padding,relu=False,pool=None))
        elif isinstance(module,nn.ReLU):
            layers[-1]['relu'] = True
        elif isinstance(module,nn.MaxPool2d):
            kernel = module.kernel_size
            layers[-1]['pool'] = tuple(kernel) if isinstance(kernel,tuple) else (kernel,kernel)
        elif not isinstance(module,nn.BatchNorm2d):
            raise ValueError(f'Unsupported backbone module: {type(module).__name__}')
    return layers


class IntegerNetwork:
    def __init__(self,layers):
        self.layers = layers

    def forward(self,images,trace=False):
        images = np.asarray(images)
        if images.dtype != np.uint8 or images.ndim != 3:
            raise ValueError('Input must be UINT8 N x H x W pixels')
        feature = (images.astype(np.int16)*2-255)[:,None,:,:]
        traces = {'input_u8':images[:,None,:,:].copy(),'input_q':feature.copy()} if trace else {}
        current_frac = 8
        for index,layer in enumerate(self.layers,1):
            if layer['input_frac'] != current_frac:
                raise ValueError(f'Layer {index} input scale disagrees with previous output')
            accum = conv2d_int(feature,layer['weight'],layer['bias'],layer.get('padding',0))
            shift = current_frac+layer['weight_frac']-layer['output_frac']
            if layer['relu']:
                accum_for_output = np.maximum(accum,0)
                output = np.clip(round_shift(accum_for_output,shift),0,255).astype(np.uint8)
            else:
                output = np.clip(round_shift(accum,shift),-32768,32767).astype(np.int16)
            if trace:
                traces[f'layer{index}_accum'] = accum
                traces[f'layer{index}_quantized'] = output
            feature = maxpool_int(output,layer['pool']) if layer['pool'] else output
            if trace:
                traces[f'layer{index}_output'] = feature
            current_frac = layer['output_frac']
        return feature,traces

    def save(self,directory,metadata):
        directory = Path(directory)
        directory.mkdir(parents=True,exist_ok=True)
        arrays = {}
        specs = []
        for index,layer in enumerate(self.layers,1):
            arrays[f'layer{index}_weight'] = layer['weight']
            arrays[f'layer{index}_bias'] = layer['bias']
            specs.append({k:v for k,v in layer.items() if k not in ('weight','bias')})
            write_hex(directory/f'layer{index}_weight.hex',layer['weight'],8)
            write_hex(directory/f'layer{index}_bias.hex',layer['bias'],32)
        np.savez_compressed(directory/'parameters.npz',**arrays)
        parameters_hash = file_hash(directory/'parameters.npz')
        write_json(directory/'model.json',dict(format='lpr-int-pow2-v1',chars=CHARS,input_frac=8,
            runtime_rounding='nearest, ties away from zero',offline_rounding='nearest, ties to even',
            parameter_sha256=parameters_hash,layers=specs,metadata=metadata))

    @classmethod
    def load(cls,directory):
        directory = Path(directory)
        spec = json.loads((directory/'model.json').read_text(encoding='utf-8'))
        if spec['format'] != 'lpr-int-pow2-v1' or spec['chars'] != CHARS:
            raise ValueError('Unsupported integer package format or character map')
        if file_hash(directory/'parameters.npz') != spec['parameter_sha256']:
            raise ValueError('Integer parameter archive checksum mismatch')
        layers = []
        with np.load(directory/'parameters.npz',allow_pickle=False) as arrays:
            for index,entry in enumerate(spec['layers'],1):
                layers.append(dict(entry,weight=arrays[f'layer{index}_weight'].copy(),
                                   bias=arrays[f'layer{index}_bias'].copy()))
        return cls(layers)


def file_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path,value):
    Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


def write_hex(path,values,bits):
    digits = (bits+3)//4
    mask = (1 << bits)-1
    text = ''.join(f'{int(value)&mask:0{digits}X}\n' for value in values.flat)
    Path(path).write_text(text,encoding='ascii')


def load_float(weights):
    model = FPGA_LPRNet(len(CHARS))
    model.load_state_dict(torch.load(weights,map_location='cpu',weights_only=True))
    return model.eval()


def load_pixels(paths):
    return np.stack([prepare_gray(read_image(path)) for path in paths])


def float_input(pixels):
    return torch.from_numpy(np.stack([normalize_gray(image) for image in pixels]))[:,None,:,:]


def calibrate(model,paths):
    maxima = np.zeros(len(fold_layers(model)),dtype=np.float64)
    with torch.inference_mode():
        for start in range(0,len(paths),16):
            x = float_input(load_pixels(paths[start:start+16]))
            layer_index = 0
            modules = list(model.backbone.children())
            for index,module in enumerate(modules):
                x = module(x)
                if isinstance(module,nn.ReLU) or index == len(modules)-1:
                    maxima[layer_index] = max(maxima[layer_index],float(x.abs().max()))
                    layer_index += 1
    return maxima


def quantize_model(model,maxima):
    layers = []
    input_frac = 8
    for index,layer in enumerate(fold_layers(model)):
        weight_frac = select_fraction_bits(float(np.abs(layer['weight']).max()),127)
        output_bits = 8 if layer['relu'] else 16
        output_frac = select_fraction_bits(float(maxima[index]),255 if layer['relu'] else 32767)
        bias_scaled = np.rint(layer['bias']*2.**(input_frac+weight_frac))
        if np.any(bias_scaled < -(1<<31)) or np.any(bias_scaled > (1<<31)-1):
            raise OverflowError(f'Layer {index+1} bias exceeds INT32')
        layers.append(dict(layer,
            weight=quantize_array(layer['weight'],weight_frac,-128,127).astype(np.int8),
            bias=bias_scaled.astype(np.int32),weight_frac=weight_frac,input_frac=input_frac,
            output_frac=output_frac,output_bits=output_bits,calibrated_max=float(maxima[index])))
        input_frac = output_frac
    return IntegerNetwork(layers)


def evaluate(network,model,paths):
    float_correct = int_correct = agreements = 0
    examples = []
    totals = [dict(zero_after_relu=0,clipped=0,elements=0) for _ in network.layers]
    with torch.inference_mode():
        for start in range(0,len(paths),16):
            group = paths[start:start+16]
            pixels = load_pixels(group)
            floating = decode_ctc(model(float_input(pixels)).numpy())
            output,traces = network.forward(pixels,trace=True)
            integer = decode_ctc(output)
            for path,ftext,itext in zip(group,floating,integer):
                expected = path.stem.split('_')[0]
                float_correct += ftext == expected
                int_correct += itext == expected
                agreements += ftext == itext
                examples.append(dict(file=str(path),expected=expected,float_prediction=ftext,integer_prediction=itext))
            for index,layer in enumerate(network.layers,1):
                accum = traces[f'layer{index}_accum']
                rounded = round_shift(np.maximum(accum,0) if layer['relu'] else accum,
                    layer['input_frac']+layer['weight_frac']-layer['output_frac'])
                lo,hi = (0,255) if layer['relu'] else (-32768,32767)
                totals[index-1]['clipped'] += int(((rounded < lo)|(rounded > hi)).sum())
                totals[index-1]['elements'] += rounded.size
                if layer['relu']:
                    totals[index-1]['zero_after_relu'] += int((rounded <= 0).sum())
            print(f'Evaluated {min(start+16,len(paths))}/{len(paths)}',flush=True)
    count = len(paths)
    return dict(samples=count,float_exact_matches=int(float_correct),integer_exact_matches=int(int_correct),
        float_accuracy=float_correct/count,integer_accuracy=int_correct/count,
        agreement=agreements/count,accuracy_drop_percentage_points=100*(float_correct-int_correct)/count,
        caveat='Compatibility sample from existing training-data directory. Original training split unknown; not independent validation.',
        activation_statistics=totals,examples=examples)


def build(args):
    paths = sorted(p.resolve() for p in args.data_dir.iterdir() if p.suffix.lower() in ('.jpg','.jpeg','.png','.bmp'))
    if args.calibration_count <= 0 or args.evaluation_count <= 0:
        raise ValueError('Calibration/evaluation counts must be positive')
    if len(paths) < args.calibration_count+args.evaluation_count:
        raise ValueError('Not enough different files for disjoint calibration and evaluation samples')
    random.Random(args.seed).shuffle(paths)
    calibration = paths[:args.calibration_count]
    evaluation = paths[args.calibration_count:args.calibration_count+args.evaluation_count]
    model = load_float(args.weights)
    maxima = calibrate(model,calibration)
    network = quantize_model(model,maxima)
    manifest = dict(seed=args.seed,source_directory=str(args.data_dir.resolve()),
        training_membership='unknown',calibration=[dict(path=str(p),sha256=file_hash(p)) for p in calibration],
        evaluation=[dict(path=str(p),sha256=file_hash(p)) for p in evaluation])
    network.save(args.output,dict(weights=str(args.weights.resolve()),weights_sha256=file_hash(args.weights),
        calibration_count=len(calibration),evaluation_count=len(evaluation),numpy_version=np.__version__,torch_version=torch.__version__))
    write_json(args.output/'samples.json',manifest)
    # Validate the reloaded artifact, rather than only its in-memory precursor.
    network = IntegerNetwork.load(args.output)
    report = evaluate(network,model,evaluation)
    write_json(args.output/'evaluation.json',report)
    print(json.dumps({k:v for k,v in report.items() if k not in ('examples','activation_statistics')},ensure_ascii=False,indent=2))


def export_trace(args):
    network = IntegerNetwork.load(args.package)
    pixels = load_pixels([args.image])
    output,traces = network.forward(pixels,trace=True)
    args.output.mkdir(parents=True,exist_ok=True)
    np.savez_compressed(args.output/'trace.npz',**traces)
    (args.output/'input.bin').write_bytes(gray_payload(pixels[0]))
    descriptions = {}
    for name,array in traces.items():
        bits = 9 if name == 'input_q' else array.dtype.itemsize*8
        write_hex(args.output/f'{name}.hex',array,bits)
        descriptions[name] = dict(shape=list(array.shape),dtype=str(array.dtype),hex_bits=bits,
            minimum=int(array.min()),maximum=int(array.max()),sha256=file_hash(args.output/f'{name}.hex'))
    write_json(args.output/'trace.json',dict(image=str(args.image.resolve()),image_sha256=file_hash(args.image),
        package=str(args.package.resolve()),package_parameters_sha256=file_hash(args.package/'parameters.npz'),
        layout='NCHW, C row-major within each sample; two\'s-complement hex',
        prediction=decode_ctc(output)[0],arrays=descriptions))
    print(f"Integer prediction: {decode_ctc(output)[0]}; vectors: {args.output.resolve()}")


def evaluate_package(args):
    metadata = json.loads((args.package/'model.json').read_text(encoding='utf-8'))['metadata']
    if file_hash(args.weights) != metadata['weights_sha256']:
        raise ValueError('Float checkpoint differs from package calibration checkpoint')
    manifest = json.loads((args.package/'samples.json').read_text(encoding='utf-8'))
    paths = []
    for entry in manifest['evaluation']:
        path = Path(entry['path'])
        if file_hash(path) != entry['sha256']:
            raise ValueError(f'Sample changed: {path}')
        paths.append(path)
    report = evaluate(IntegerNetwork.load(args.package),load_float(args.weights),paths)
    write_json(args.output,report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command',required=True)
    checkpoint = Path(__file__).resolve().parent/'weights/fpga_best_model.pth'
    builder = commands.add_parser('build',help='Calibrate/export a package and compare disjoint compatibility samples')
    builder.add_argument('--weights',type=Path,default=checkpoint)
    builder.add_argument('--data-dir',type=Path,required=True)
    builder.add_argument('--calibration-count',type=int,default=128)
    builder.add_argument('--evaluation-count',type=int,default=256)
    builder.add_argument('--seed',type=int,default=20261017)
    builder.add_argument('--output',type=Path,required=True)
    builder.set_defaults(handler=build)
    infer = commands.add_parser('infer',help='Export input, accumulators and every layer output as RTL vectors')
    infer.add_argument('--package',type=Path,required=True)
    infer.add_argument('--image',type=Path,required=True)
    infer.add_argument('--output',type=Path,required=True)
    infer.set_defaults(handler=export_trace)
    evaluator = commands.add_parser('evaluate',help='Repeat comparison on the saved manifest without recalibration')
    evaluator.add_argument('--package',type=Path,required=True)
    evaluator.add_argument('--weights',type=Path,default=checkpoint)
    evaluator.add_argument('--output',type=Path,required=True)
    evaluator.set_defaults(handler=evaluate_package)
    args = parser.parse_args()
    torch.set_num_threads(4)
    args.handler(args)


if __name__ == '__main__':
    main()
