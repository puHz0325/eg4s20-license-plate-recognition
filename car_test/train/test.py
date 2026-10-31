import torch
import cv2
import argparse
import os
from pathlib import Path
import sys

# 导入优化的模型
from model import FPGA_LPRNet
from dataset import CHARS
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lpr_common import decode_ctc, normalize_gray, prepare_gray, read_image

def get_parser():
    parser = argparse.ArgumentParser(description='FPGA Tiny LPRNet Inference')
    parser.add_argument('--img_path', required=True, help='输入图片路径，或者包含图片的文件夹路径')
    parser.add_argument('--weights', default=str(Path(__file__).resolve().parent / 'weights/fpga_best_model.pth'), help='模型权重文件路径')
    parser.add_argument('--img_size', nargs=2, type=int, default=[94, 24], help='输入尺寸 宽 高')
    parser.add_argument('--show', action='store_true', help='是否显示图片')
    return parser.parse_args()

def preprocess_image(img_path, target_size):
    """
    预处理函数：与训练和上位机使用相同的灰度与归一化定义。
    """
    try:
        img = read_image(img_path)
    except (OSError, ValueError) as error:
        print(f"读取失败: {img_path}: {error}")
        return None

    if img is None: return None

    img_input = normalize_gray(prepare_gray(img, target_size))

    # 5. 转换为 Tensor 格式 [Batch, Channel, Height, Width] -> [1, 1, 24, 94]
    img_tensor = torch.from_numpy(img_input).unsqueeze(0).unsqueeze(0)
    
    return img_tensor, img

def decode_output(logits):
    """
    CTC 贪婪解码 (Greedy Decode)
    对应 FPGA 里的 ArgMax + 状态机去重逻辑
    """
    return decode_ctc(logits.cpu().detach().numpy())[0]

def main():
    args = get_parser()
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    # 1. 加载优化的 Tiny 模型
    print(f"正在加载模型: {args.weights} ...")
    model = FPGA_LPRNet(class_num=len(CHARS))
    
    if os.path.exists(args.weights):
        model.load_state_dict(torch.load(args.weights, map_location=device, weights_only=True))
        model.to(device)
        model.eval()
    else:
        print("错误: 找不到权重文件！请先运行 train.py")
        return

    # 2. 处理输入路径
    image_list = []
    if os.path.isdir(args.img_path):
        for f in os.listdir(args.img_path):
            if f.lower().endswith(('.jpg', '.png', '.bmp')):
                image_list.append(os.path.join(args.img_path, f))
    else:
        image_list.append(args.img_path)

    print(f"准备测试 {len(image_list)} 张图片...")
    print("-" * 30)

    # 3. 循环推理
    for img_file in image_list:
        result = preprocess_image(img_file, args.img_size)
        if result is None: continue
        
        img_tensor, orig_img = result
        img_tensor = img_tensor.to(device)

        with torch.no_grad():
            logits = model(img_tensor)
        
        pred_text = decode_output(logits)
        print(f"文件: {os.path.basename(img_file)}  \t-> 识别结果: {pred_text}")

        if args.show:
            cv2.imshow("Result", orig_img)
            print("按任意键继续...")
            cv2.waitKey(0)

    if args.show:
        cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
