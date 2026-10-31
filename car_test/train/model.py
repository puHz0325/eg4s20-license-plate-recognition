import torch.nn as nn
import torch

class FPGA_LPRNet(nn.Module):
    def __init__(self, class_num, input_height=24, channels=None, extra_prepool=False, context_kernel=1):
        super(FPGA_LPRNet, self).__init__()
        self.class_num = class_num
        if input_height < 8 or input_height % 8:
            raise ValueError('input height must be a positive multiple of eight')
        self.input_height = input_height
        final_pool_height = input_height // 8
        channels = tuple(channels or (8, 16, 24, 32, 32, 64))
        if len(channels) != 6 or any(not isinstance(c, int) or c <= 0 for c in channels):
            raise ValueError('Expected six positive channel counts')
        if context_kernel <= 0 or context_kernel % 2 != 1:
            raise ValueError('Context kernel must be a positive odd number')
        c1, c2, c3, c4, c5, c6 = channels
        
        layers = [
            # Layer 1: 1 -> 8 (省DSP，纯加法器实现)
            nn.Conv2d(1, c1, kernel_size=3, stride=1, padding=1, bias=False),
            nn.BatchNorm2d(c1),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=2, stride=2), # 24x94 -> 12x47
            
            # Layer 2: 8 -> 16
            nn.Conv2d(c1, c2, kernel_size=3, stride=1, padding=1, bias=False),
            nn.BatchNorm2d(c2),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=2, stride=2), # 12x47 -> 6x23
            
            # Layer 3: 16 -> 24 (★ 新增层，不降采样，增加感受野)
            nn.Conv2d(c2, c3, kernel_size=3, stride=1, padding=1, bias=False),
            nn.BatchNorm2d(c3),
            nn.ReLU(),
            
            # Layer 4: 24 -> 32
            nn.Conv2d(c3, c4, kernel_size=3, stride=1, padding=1, bias=False),
            nn.BatchNorm2d(c4),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=(2, 1), stride=(2, 1)), # 6x23 -> 3x23
            
            # Layer 5: 32 -> 32 (★ 新增层，不降采样水平宽度)
            nn.Conv2d(c4, c5, kernel_size=3, stride=1, padding=1, bias=False),
            nn.BatchNorm2d(c5),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=(final_pool_height, 1), stride=(final_pool_height, 1)),
            
            # Layer 6 (1x1卷积 整合特征): 32 -> 64
            nn.Conv2d(c5, c6, kernel_size=1, stride=1, bias=False),
            nn.BatchNorm2d(c6),
            nn.ReLU(),
            
            # Output Layer
            nn.Conv2d(c6, class_num, kernel_size=(1, context_kernel),
                      padding=(0, context_kernel // 2), stride=1, bias=True),
        ]
        if extra_prepool:
            layers[3:3] = [nn.Conv2d(c1, c1, 3, padding=1, bias=False), nn.BatchNorm2d(c1), nn.ReLU()]
        self.backbone = nn.Sequential(*layers)

    def forward(self, x):
        if x.ndim != 4 or x.shape[2] != self.input_height:
            raise ValueError(f'Expected NCHW input height {self.input_height}')
        x = self.backbone(x)
        x = x.squeeze(2) # [Batch, ClassNum, 1, T] -> [Batch, ClassNum, T]
        return x
