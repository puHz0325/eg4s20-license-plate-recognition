import torch
import torch.nn as nn
import numpy as np
import os

# 导入你带 BN 的深而窄模型
from model import FPGA_LPRNet

def fold_conv_bn(conv, bn):
    """
    核心算法：将 BatchNorm 折叠进 Conv2d
    返回：等效的卷积权重 (w_new) 和 偏置 (b_new)
    """
    w = conv.weight.data
    
    # 提取 BN 的参数
    gamma = bn.weight.data
    beta = bn.bias.data
    mean = bn.running_mean
    var = bn.running_var
    eps = bn.eps
    
    # 计算折叠缩放因子
    std = torch.sqrt(var + eps)
    multiplier = gamma / std
    
    # 1. 折叠权重: W_new = W_old * multiplier
    w_new = w * multiplier.view(-1, 1, 1, 1)
    
    # 2. 折叠偏置: B_new = (B_old - mean) * multiplier + beta
    # 如果原卷积没有偏置，设为全 0
    if conv.bias is not None:
        b_old = conv.bias.data
    else:
        b_old = torch.zeros_like(mean)
        
    b_new = (b_old - mean) * multiplier + beta
    
    return w_new, b_new

def quantize_to_int(tensor, scale_bits=7, is_bias=False):
    """
    定点量化：乘以 2^7 (128) 并取整
    """
    scale = 2 ** scale_bits
    tensor_scaled = tensor * scale
    tensor_rounded = torch.round(tensor_scaled)
    
    if not is_bias:
        # 权重：限制在 INT8 范围 (-128 ~ 127)
        tensor_clipped = torch.clamp(tensor_rounded, min=-128, max=127)
        return tensor_clipped.to(torch.int8).numpy()
    else:
        # 偏置：由于累加值可能较大，使用 INT16 范围 (-32768 ~ 32767)
        tensor_clipped = torch.clamp(tensor_rounded, min=-32768, max=32767)
        return tensor_clipped.to(torch.int16).numpy()

def write_hex_file(data, filename, bit_width=8):
    """
    写入 16 进制 txt 文件，供 Verilog $readmemh 使用
    """
    with open(filename, 'w') as f:
        for val in data.flatten():
            # 【核心修复】：先将 numpy 的数值转为 Python 原生 int
            val_int = int(val) 
            
            if bit_width == 8:
                hex_val = val_int & 0xFF
                f.write(f"{hex_val:02X}\n")
            elif bit_width == 16:
                hex_val = val_int & 0xFFFF
                f.write(f"{hex_val:04X}\n")

def main():
    class_num = 68
    model_path = './weights/fpga_best_model.pth'
    export_dir = './fpga_hex_weights'
    
    if not os.path.exists(export_dir):
        os.makedirs(export_dir)

    model = FPGA_LPRNet(class_num)
    
    print(f"正在加载模型: {model_path} ...")
    model.load_state_dict(torch.load(model_path, map_location='cpu'))
    
    # ⚠️ 极其重要：必须调为 eval 模式，这样才能固定 BN 的 mean 和 var
    model.eval() 
    
    layers = list(model.backbone.children())
    
    conv_idx = 1
    # 遍历网络，寻找需要融合的层
    for i in range(len(layers)):
        # 匹配规则：当前层是 Conv2d，且下一层是 BatchNorm2d
        if isinstance(layers[i], nn.Conv2d) and i+1 < len(layers) and isinstance(layers[i+1], nn.BatchNorm2d):
            print(f"正在处理第 {conv_idx} 层 (Conv + BN 折叠)...")
            
            w_folded, b_folded = fold_conv_bn(layers[i], layers[i+1])
            
            w_int8 = quantize_to_int(w_folded, scale_bits=7, is_bias=False)
            b_int16 = quantize_to_int(b_folded, scale_bits=7, is_bias=True)
            
            write_hex_file(w_int8, os.path.join(export_dir, f'layer{conv_idx}_weights.txt'), bit_width=8)
            write_hex_file(b_int16, os.path.join(export_dir, f'layer{conv_idx}_bias.txt'), bit_width=16)
            
            conv_idx += 1
            
        # 处理最后一层 (纯 Conv2d，无 BN)
        elif isinstance(layers[i], nn.Conv2d) and (i+1 == len(layers) or not isinstance(layers[i+1], nn.BatchNorm2d)):
            print(f"正在处理第 {conv_idx} 层 (输出层)...")
            w_int8 = quantize_to_int(layers[i].weight.data, scale_bits=7, is_bias=False)
            
            if layers[i].bias is not None:
                b_int16 = quantize_to_int(layers[i].bias.data, scale_bits=7, is_bias=True)
            else:
                b_int16 = np.zeros(w_int8.shape[0], dtype=np.int16)
                
            write_hex_file(w_int8, os.path.join(export_dir, f'layer{conv_idx}_weights.txt'), bit_width=8)
            write_hex_file(b_int16, os.path.join(export_dir, f'layer{conv_idx}_bias.txt'), bit_width=16)
            
    print("\n✅ 融合完毕！权重和等效偏置已完美转换为 FPGA 格式。")

if __name__ == "__main__":
    main()