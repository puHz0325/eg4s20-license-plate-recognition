from torch.utils.data import Dataset
import numpy as np
import os
import random
import torch
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lpr_common import CHARS, normalize_gray, prepare_gray, read_image

CHARS_DICT = {char: i for i, char in enumerate(CHARS)}

def cv_imread(file_path):
    """支持中文路径的 OpenCV 读取函数"""
    try:
        return read_image(file_path)
    except (OSError, ValueError):
        return None

class LPRDataLoader(Dataset):
    def __init__(self, img_paths, imgSize, is_train=True, use_binarization=False):
        """
        初始化车牌数据集加载器
        :param img_paths: 图片路径列表
        :param imgSize: 模型输入尺寸，例如 [94, 24] (宽 x 高)
        :param is_train: 是否为训练模式 (控制验证集关闭随机抖动)
        :param use_binarization: 保留旧调用参数；当前灰度方案不支持 True
        """
        self.img_paths = img_paths
        self.img_size = imgSize
        self.is_train = is_train
        if use_binarization:
            raise ValueError('当前模型使用灰度输入，不支持二值化训练')

    def __len__(self):
        return len(self.img_paths)

    def __getitem__(self, index):
        filename = self.img_paths[index]
        Image = cv_imread(filename)
        
        # 如果图片读取失败(损坏等)，随机换读另一张
        if Image is None:
            return self.__getitem__(random.randint(0, len(self)-1))

        img_proc = normalize_gray(prepare_gray(Image, self.img_size))
        
        # 4. 增加 Channel 维度 -> [1, Height, Width]
        Image_tensor = np.expand_dims(img_proc, axis=0)

        # 5. 解析标签 (从文件名中提取纯车牌号)
        basename = os.path.basename(filename)
        imgname, _ = os.path.splitext(basename)
        
        # 兼容性处理：无论你是否用过 balance_dataset 脚本
        # 遇到 "皖A12345_abcdef" 自动截取 "皖A12345"
        lp_number = imgname.split('_')[0] 
        
        label = []
        for c in lp_number:
            if c in CHARS_DICT:
                label.append(CHARS_DICT[c])
        
        # 防御性容错：如果车牌名解析出来为空，重新取样
        if len(label) == 0:
            return self.__getitem__(random.randint(0, len(self)-1))
        
        return Image_tensor, label, len(label)

def collate_fn(batch):
    """
    DataLoader 的自定义拼装函数，用于处理 CTC 的变长序列
    """
    imgs = []
    labels = []
    lengths = []
    for _, sample in enumerate(batch):
        img, label, length = sample
        imgs.append(torch.from_numpy(img))
        labels.extend(label)
        lengths.append(length)
        
    labels = np.asarray(labels).flatten().astype(np.int32)
    return torch.stack(imgs, 0), torch.from_numpy(labels), lengths
