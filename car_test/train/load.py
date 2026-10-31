import os
import random
import shutil
from collections import defaultdict
from tqdm import tqdm

def main():
    # ================= 配置区 =================
    source_dir = "./train_data_flat"   # 你刚才裁剪后保存的源文件夹
    target_dir = "./train_data1"    # 最终用于训练的均衡数据集文件夹
    
    # 每个省份最多抽取的车牌数量。
    # 假设全国约 31 个省市，如果设为 1000，总数据集大约在 20000~30000 张。
    # 对于你的 FPGA Tiny 模型，2万~3万张是非常完美的训练体量！
    max_per_province = 500        
    # ==========================================

    if not os.path.exists(target_dir):
        os.makedirs(target_dir)

    print(f"正在扫描 {source_dir} 目录下的车牌...")
    
    # province_dict 的结构: { '皖': {'皖A12345': '路径1', '皖B54321': '路径2'}, '京': {...} }
    # 利用字典的 Key 天然去重特性，确保同一个车牌号只会保留一张图片
    province_dict = defaultdict(dict)

    img_files = [f for f in os.listdir(source_dir) if f.endswith('.jpg')]
    
    for filename in tqdm(img_files, desc="去重与分类"):
        # 提取真实车牌号 (抛弃 _ 和后面的随机小写字母)
        # 比如 "皖A12345_abcdef.jpg" -> "皖A12345"
        lp_number = filename.split('_')[0] 
        
        # 提取省份汉字 (第一位)
        province = lp_number[0]
        
        # 存入字典（如果车牌号已存在，会自动覆盖，实现完美去重）
        original_path = os.path.join(source_dir, filename)
        province_dict[province][lp_number] = original_path

    print("\n各省份去重后的可用车牌数量分布：")
    total_selected = 0
    
    # 开始均衡采样并复制文件
    for province, plates in province_dict.items():
        # plates 字典里存的都是去重后的车牌
        unique_plate_list = list(plates.items()) # 转为列表 [('皖A12345', '路径'), ...]
        
        # 随机打乱
        random.shuffle(unique_plate_list)
        
        # 截取该省份的数量（如果不超过上限，就全要；超过了，就只取上限数量）
        selected_plates = unique_plate_list[:max_per_province]
        count = len(selected_plates)
        total_selected += count
        
        print(f"[{province}]: 原有 {len(plates)} 张 -> 抽取 {count} 张")
        
        # 复制到新文件夹，并重命名为纯净的车牌号
        for lp_number, src_path in selected_plates:
            # 最终文件名为 "皖A12345.jpg"
            new_filename = f"{lp_number}.jpg"
            dst_path = os.path.join(target_dir, new_filename)
            
            shutil.copy(src_path, dst_path)

    print("-" * 40)
    print(f"✅ 数据均衡完毕！最终选出 {total_selected} 张无重复、无后缀的精品车牌，已存入 {target_dir}。")
    print("你可以直接用它们开始训练了！")

if __name__ == "__main__":
    main()