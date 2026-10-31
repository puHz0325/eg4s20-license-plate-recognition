"""Shared grayscale, pixel layout and character contract (no Torch dependency)."""
from pathlib import Path

import cv2
import numpy as np

IMAGE_SIZE = (94, 24)  # width, height
CHARS = list('京沪津渝冀晋蒙辽吉黑苏浙皖闽赣鲁豫鄂湘粤桂琼川贵云藏陕甘青宁新') + list(
    '0123456789ABCDEFGHJKLMNPQRSTUVWXYZIO-'
)
BLANK_IDX = len(CHARS) - 1


def read_image(path):
    """Decode without OpenCV's Windows Unicode-path limitation."""
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(f'无法读取图像: {path}')
    encoded = np.fromfile(path, dtype=np.uint8)
    image = cv2.imdecode(encoded, cv2.IMREAD_UNCHANGED) if encoded.size else None
    if image is None:
        raise ValueError(f'图像无法解码: {path}')
    return image


def prepare_gray(image, target_size=IMAGE_SIZE):
    """BGR/BGRA R channel or grayscale, UINT8, OpenCV linear resize."""
    if image.dtype != np.uint8:
        raise ValueError('输入图像必须为 UINT8，不能隐式截断高位深像素')
    if image.ndim == 3 and image.shape[2] in (3, 4):
        gray = image[:, :, 2]
    elif image.ndim == 2:
        gray = image
    else:
        raise ValueError('输入必须为单通道灰度、BGR 或 BGRA 图像')
    width, height = target_size
    if width <= 0 or height <= 0 or not gray.size:
        raise ValueError('图像和目标尺寸必须非空且为正')
    if gray.shape != (height, width):
        gray = cv2.resize(gray, (width, height), interpolation=cv2.INTER_LINEAR)
    return np.ascontiguousarray(gray)


def normalize_gray(pixels):
    if pixels.dtype != np.uint8 or pixels.ndim != 2:
        raise ValueError('归一化输入必须为二维 UINT8 灰度图')
    return (pixels.astype(np.float32) - 127.5) / 128.0


def gray_payload(pixels):
    if pixels.dtype != np.uint8 or pixels.shape != (IMAGE_SIZE[1], IMAGE_SIZE[0]):
        raise ValueError('灰度载荷必须为 24×94 的 UINT8 图像')
    return pixels.tobytes(order='C')


def decode_ctc(logits):
    """Return one string per batch, with lowest-index argmax ties."""
    scores = np.asarray(logits)
    if scores.ndim == 4 and scores.shape[2] == 1:
        scores = scores[:, :, 0, :]
    if scores.ndim != 3 or scores.shape[1] != len(CHARS):
        raise ValueError('CTC 输入必须为 N×68×T 或 N×68×1×T')
    texts = []
    for sequence in scores.argmax(axis=1):
        previous = BLANK_IDX
        text = []
        for idx in sequence:
            if idx != BLANK_IDX and idx != previous:
                text.append(CHARS[idx])
            previous = idx
        texts.append(''.join(text))
    return texts
