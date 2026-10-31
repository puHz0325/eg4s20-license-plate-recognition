"""Accelerate the INT8 reference with bounded, exact integer-valued FP64 GEMM.

Every multiplicand is an integer. We check the sum of absolute products plus
bias is below 2**53, so FP64 multiply/add is exact irrespective of GEMM order.
No FFT, FP32/TF32 convolution, or approximate inference is used.
"""
import numpy as np
import torch
from torch.nn import functional as F


class ExactIntegerGPU:
    def __init__(self, network, device='cuda'):
        self.network = network
        self.device = device
        self.layers = []
        current_frac = 8
        for index,layer in enumerate(network.layers):
            if layer['input_frac'] != current_frac: raise ValueError('Fraction chain mismatch')
            if index<len(network.layers)-1 and not layer['relu']:
                raise ValueError('Only UINT8 hidden activations are supported')
            if not all(np.issubdtype(layer[k].dtype,np.integer) for k in ['weight','bias']):
                raise ValueError('Exact GEMM requires integer parameters')
            weight = layer['weight'].astype(np.int64)
            bias = layer['bias'].astype(np.int64)
            if weight.min()<-128 or weight.max()>127 or bias.min()<-(1<<31) or bias.max()>(1<<31)-1:
                raise ValueError('Expected INT8 weights and INT32 biases')
            limit = 255  # signed9 input or UINT8 hidden activations
            bound = limit*np.abs(weight).reshape(len(bias),-1).sum(1)+np.abs(bias)
            if np.any(bound >= 2**53): raise OverflowError('FP64 exact integer range exceeded')
            self.layers.append((torch.as_tensor(weight,device=device,dtype=torch.float64),
                                torch.as_tensor(bias,device=device,dtype=torch.float64)))
            current_frac = layer['output_frac']

    @torch.inference_mode()
    def forward(self, images, trace=False):
        if images.dtype != np.uint8 or images.ndim != 3: raise ValueError('Expected UINT8 NHW')
        feature = torch.as_tensor(images.astype(np.int16)*2-255,device=self.device,dtype=torch.float64)[:,None]
        traces = {}
        for i,(layer,(weight,bias)) in enumerate(zip(self.network.layers,self.layers,strict=True),1):
            kh,kw = weight.shape[2:]; padding=layer.get('padding',0)
            ph,pw = padding if isinstance(padding,(list,tuple)) else (padding,padding)
            height,width = feature.shape[2]+2*ph-kh+1,feature.shape[3]+2*pw-kw+1
            patches = F.unfold(feature,(kh,kw),padding=(ph,pw))
            accum = torch.matmul(weight.reshape(weight.shape[0],-1),patches)
            accum = accum.reshape(len(images),weight.shape[0],height,width)+bias[None,:,None,None]
            if accum.min().item() < -(1<<31) or accum.max().item() > (1<<31)-1:
                raise OverflowError('Convolution exceeds signed INT32 accumulator range')
            values = accum.clamp_min(0) if layer['relu'] else accum
            shift = layer['input_frac']+layer['weight_frac']-layer['output_frac']
            values = (torch.sign(values)*torch.floor((values.abs()+2.**(shift-1))/2.**shift)
                      if shift>0 else values*2.**(-shift))
            output = values.clamp(0,255) if layer['relu'] else values.clamp(-32768,32767)
            feature = F.max_pool2d(output,layer['pool']) if layer['pool'] else output
            if trace:
                dtype = np.uint8 if layer['relu'] else np.int16
                traces[f'layer{i}_accum'] = accum.cpu().numpy().astype(np.int32)
                traces[f'layer{i}_quantized'] = output.cpu().numpy().astype(dtype)
                traces[f'layer{i}_output'] = feature.cpu().numpy().astype(dtype)
        return feature.cpu().numpy().astype(np.int16),traces

    def verify(self, images):
        expected,traces = self.network.forward(images,trace=True)
        actual,accelerated = self.forward(images,trace=True)
        np.testing.assert_array_equal(actual,expected)
        count = 0
        for key,value in accelerated.items():
            np.testing.assert_array_equal(value,traces[key],err_msg=key)
            count += value.size
        return count
