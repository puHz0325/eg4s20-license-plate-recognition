"""Fixed power-of-two QAT for the existing folded Conv/BN SDRAM datapath."""
import copy

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

from integer_reference import IntegerNetwork, fold_layers, quantize_array


def fake_quant(values, frac, minimum, maximum, runtime=False):
    scale = 2.**frac
    scaled = values*scale
    rounded = torch.sign(scaled)*torch.floor(scaled.abs()+.5) if runtime else torch.round(scaled)
    # STE through rounding; clipping keeps its actual zero gradient outside range.
    return (scaled+(rounded-scaled).detach()).clamp(minimum, maximum)/scale


class FixedScaleTeacher(nn.Module):
    def __init__(self, model, template):
        super().__init__()
        self.model = model
        self.specs = [{k:layer[k] for k in ['input_frac','weight_frac','output_frac','relu','pool']}
                      for layer in template.layers]
        if len(self.specs) != len(fold_layers(model)): raise ValueError('QAT architecture mismatch')

    def forward(self, images):
        # AMP convolution would simulate FP16 error instead of the RTL quantizer.
        with torch.autocast(device_type=images.device.type, enabled=False):
            x = images.to(dtype=next(self.model.parameters()).dtype)
            modules = list(self.model.backbone.children()); layer = 0; index = 0
            while index < len(modules):
                conv = modules[index]
                if not isinstance(conv, nn.Conv2d): raise ValueError('Expected convolution')
                spec = self.specs[layer]; index += 1
                weight = conv.weight
                bias = conv.bias if conv.bias is not None else weight.new_zeros(conv.out_channels)
                if index < len(modules) and isinstance(modules[index], nn.BatchNorm2d):
                    bn = modules[index]; index += 1
                    factor = bn.weight/torch.sqrt(bn.running_var+bn.eps)
                    weight = weight*factor[:,None,None,None]
                    bias = (bias-bn.running_mean)*factor+bn.bias
                weight = fake_quant(weight, spec['weight_frac'], -128, 127)
                bias = fake_quant(bias, spec['input_frac']+spec['weight_frac'], -(1<<31), (1<<31)-1)
                x = F.conv2d(x, weight, bias, padding=conv.padding)
                if spec['relu']:
                    if not isinstance(modules[index], nn.ReLU): raise ValueError('Missing ReLU')
                    index += 1; x = F.relu(x)
                    x = fake_quant(x, spec['output_frac'], 0, 255, runtime=True)
                else: x = fake_quant(x, spec['output_frac'], -32768, 32767, runtime=True)
                if spec['pool']:
                    if not isinstance(modules[index], nn.MaxPool2d): raise ValueError('Missing pool')
                    x = modules[index](x); index += 1
                layer += 1
            return x.squeeze(2)


def export_fixed(model, template):
    layers = []
    for floating, old in zip(fold_layers(model), template.layers, strict=True):
        scale = old['input_frac']+old['weight_frac']
        bias = quantize_array(floating['bias'], scale, -(1<<31), (1<<31)-1)
        # Clipping a bias would hide an invalid accumulator contract.
        raw_bias = np.rint(floating['bias']*2.**scale)
        if np.any(raw_bias != bias): raise OverflowError('QAT bias exceeds INT32')
        layers.append(dict(floating, weight=quantize_array(floating['weight'],old['weight_frac'],-128,127).astype(np.int8),
            bias=bias.astype(np.int32), **{k:copy.deepcopy(old[k]) for k in
                ['input_frac','weight_frac','output_frac','output_bits','calibrated_max']}))
    return IntegerNetwork(layers)
