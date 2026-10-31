import os
import cv2
import numpy as np
import random
import string
import math
from tqdm import tqdm

# 根据 CCPD 官方设定提供的字典
PROVINCES = ["皖", "沪", "津", "渝", "冀", "晋", "蒙", "辽", "吉", "黑", 
             "苏", "浙", "京", "闽", "赣", "鲁", "豫", "鄂", "湘", "粤", 
             "桂", "琼", "川", "贵", "云", "藏", "陕", "甘", "青", "宁", 
             "新", "警", "学", "O"]

ADS = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 
       'L', 'M', 'N', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 
       'W', 'X', 'Y', 'Z', '0', '1', '2', '3', '4', '5', 
       '6', '7', '8', '9', 'O']

def cv_imread(file_path):
    return cv2.imdecode(np.fromfile(file_path, dtype=np.uint8), -1)

def cv_imwrite(file_path, img):
    cv2.imencode('.jpg', img)[1].tofile(file_path)

def generate_random_suffix(length=6):
    return ''.join(random.choices(string.ascii_lowercase, k=length))

def calculate_tilt_angles(br, bl, tl, tr):
    """
    利用四个顶点坐标计算真实的水平和垂直倾斜角 (单位：度)
    """
    # 1. 计算水平倾斜角 (利用上下边缘)
    # 上边缘角度
    dx_top = tr[0] - tl[0]
    dy_top = tr[1] - tl[1]
    angle_top = math.degrees(math.atan2(dy_top, dx_top))
    
    # 下边缘角度
    dx_bot = br[0] - bl[0]
    dy_bot = br[1] - bl[1]
    angle_bot = math.degrees(math.atan2(dy_bot, dx_bot))
    
    # 取绝对值的平均作为真实水平倾斜角
    horizontal_tilt = (abs(angle_top) + abs(angle_bot)) / 2.0
    
    # 2. 计算垂直倾斜角/形变 (利用左右边缘)
    # 完美的垂直边缘应该是 90 度或 -90 度
    dx_left = bl[0] - tl[0]
    dy_left = bl[1] - tl[1]
    angle_left = math.degrees(math.atan2(dy_left, dx_left))
    vert_tilt_left = abs(abs(angle_left) - 90.0)

    dx_right = br[0] - tr[0]
    dy_right = br[1] - tr[1]
    angle_right = math.degrees(math.atan2(dy_right, dx_right))
    vert_tilt_right = abs(abs(angle_right) - 90.0)
    
    vertical_tilt = (vert_tilt_left + vert_tilt_right) / 2.0
    
    return horizontal_tilt, vertical_tilt

def main():
    # ================= 配置区 =================
    source_dir = "D:/用户/Downloads/CCPD2019/ccpd_base"       # 你的 CCPD 原图文件夹
    save_dir = "./train_data_flat"   # 过滤出的“端正”车牌的保存路径
    target_size = (94, 24)           # FPGA 模型输入尺寸
    
    # 【核心参数】倾斜容忍度设定 (建议 10~15 度)
    MAX_HORIZ_ANGLE = 12.0  # 水平倾斜超过 12 度不要
    MAX_VERT_ANGLE = 15.0   # 垂直倾斜(侧视严重)超过 15 度不要
    # ==========================================

    if not os.path.exists(save_dir):
        os.makedirs(save_dir)

    img_files = [f for f in os.listdir(source_dir) if f.endswith('.jpg')]
    print(f"找到 {len(img_files)} 张原图，开启严格审查模式...")

    success_count = 0
    filtered_count = 0

    for filename in tqdm(img_files):
        try:
            name_without_ext = filename.replace(".jpg", "")
            parts = name_without_ext.split("-")
            if len(parts) < 7: continue

            # 解析边界框 (用于裁剪)
            bbox = parts[2].split("_")
            xmin, ymin = map(int, bbox[0].split("&"))
            xmax, ymax = map(int, bbox[1].split("&"))

            # 解析四个顶点 (用于计算角度)
            # 顺序：右下_左下_左上_右上
            corners = parts[3].split("_")
            br = list(map(int, corners[0].split("&")))
            bl = list(map(int, corners[1].split("&")))
            tl = list(map(int, corners[2].split("&")))
            tr = list(map(int, corners[3].split("&")))

            # ----------------------------------------------------
            # 【核心过滤逻辑】计算倾斜角度并拦截
            h_tilt, v_tilt = calculate_tilt_angles(br, bl, tl, tr)
            
            if h_tilt > MAX_HORIZ_ANGLE or v_tilt > MAX_VERT_ANGLE:
                filtered_count += 1
                continue # 太歪了，直接扔掉！
            # ----------------------------------------------------

            # 解析车牌号码
            lp_indices = parts[4].split("_")
            province = PROVINCES[int(lp_indices[0])]
            alphanumerics = "".join([ADS[int(idx)] for idx in lp_indices[1:]])
            lp_str = province + alphanumerics

            # 读取并裁剪图像
            img_path = os.path.join(source_dir, filename)
            img = cv_imread(img_path)
            if img is None: continue
            
            h, w = img.shape[:2]
            xmin, ymin = max(0, xmin), max(0, ymin)
            xmax, ymax = min(w, xmax), min(h, ymax)
            if xmax <= xmin or ymax <= ymin: continue

            crop_img = img[ymin:ymax, xmin:xmax]
            resize_img = cv2.resize(crop_img, target_size)

            # 保存
            safe_suffix = generate_random_suffix()
            save_name = f"{lp_str}_{safe_suffix}.jpg"
            save_path = os.path.join(save_dir, save_name)
            
            cv_imwrite(save_path, resize_img)
            success_count += 1

        except Exception as e:
            continue

    print("\n" + "="*40)
    print(f"✅ 过滤与裁剪完成！")
    print(f"👉 成功保留端正车牌: {success_count} 张")
    print(f"🗑️ 剔除太歪的车牌:   {filtered_count} 张")
    print("="*40)
    print("现在，你可以把这些干净的数据拿去做均衡(balance_dataset.py)，然后开始训练了！")

if __name__ == "__main__":
    main()