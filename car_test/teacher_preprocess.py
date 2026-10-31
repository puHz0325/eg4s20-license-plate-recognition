"""Shared R8 crop/resize contract for teacher training, replay and FPGA vectors."""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np

ROOT=Path(__file__).resolve().parent
CONTRACT_PATH=ROOT/'PL/teacher/video/preprocess.json'
CONTRACT=json.loads(CONTRACT_PATH.read_text(encoding='utf-8'))
SOURCE_WH=tuple(CONTRACT['source_wh'])
ROI_X,ROI_Y,ROI_WIDTH,ROI_HEIGHT=CONTRACT['roi_xywh']
INPUT_WH=tuple(CONTRACT['input_wh'])


def red8(image):
    a=np.asarray(image)
    if a.dtype!=np.uint8:raise ValueError('R8 pixels must be uint8')
    if a.ndim==2:return np.ascontiguousarray(a)
    if a.ndim==3 and a.shape[2] in (3,4):return np.ascontiguousarray(a[:,:,2])
    raise ValueError('Expected grayscale or OpenCV BGR/BGRA pixels')


def resize_plate_red(image,size=INPUT_WH):
    """Resize a complete cropped plate; no inferred detection or implicit padding."""
    a=red8(image);w,h=size
    if not a.size or w<=0 or h<=0:raise ValueError('Empty plate or target')
    return np.ascontiguousarray(cv2.resize(a,(w,h),interpolation=cv2.INTER_LINEAR))


def camera_input(frame):
    a=red8(frame)
    if a.shape!=SOURCE_WH[::-1]:raise ValueError('Expected a full 640x480 camera frame')
    return resize_plate_red(a[ROI_Y:ROI_Y+ROI_HEIGHT,ROI_X:ROI_X+ROI_WIDTH])


def header_text():
    if CONTRACT['format']!='teacher-r8-linear-v1' or INPUT_WH!=(128,32):raise ValueError('Unsupported contract')
    if (ROI_WIDTH,ROI_HEIGHT)!=(384,128):raise ValueError('RTL supports the specified 3x4 ratio')
    if not (0<=ROI_X<=SOURCE_WH[0]-ROI_WIDTH and 0<=ROI_Y<=SOURCE_WH[1]-ROI_HEIGHT):raise ValueError('ROI out of bounds')
    values=dict(X=ROI_X,Y=ROI_Y,WIDTH=ROI_WIDTH,HEIGHT=ROI_HEIGHT)
    return '// Generated from teacher/video/preprocess.json; do not hand-edit.\n'+\
        '`ifndef TEACHER_PREPROCESS_VH\n`define TEACHER_PREPROCESS_VH\n'+''.join(
        f'`define TEACHER_ROI_{key} {value}\n' for key,value in values.items())+'`endif\n'


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--write-header',action='store_true');args=p.parse_args()
    target=ROOT/'PL/teacher/data/teacher_preprocess.vh'
    expected=header_text()
    if args.write_header:target.write_text(expected,encoding='ascii')
    if not target.exists() or target.read_text()!=expected:raise ValueError('Preprocessing header differs from shared contract')
    print('PASS teacher R8/linear preprocessing contract and generated RTL geometry')


if __name__=='__main__':main()
