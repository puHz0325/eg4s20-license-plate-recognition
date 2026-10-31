import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader
import numpy as np
import os
import argparse
import random

from model import FPGA_LPRNet
from dataset import LPRDataLoader, collate_fn, CHARS

def get_parser():
    parser = argparse.ArgumentParser(description='FPGA Tiny LPRNet Training')
    parser.add_argument('--img_size', default=[94, 24], help='输入图像尺寸 [宽, 高]')
    parser.add_argument('--train_dir', default="./train_data1", help='图片文件夹路径')
    
    # --- 修改点：降 BatchSize 为 16，增加模型学习时的“试错空间” ---
    parser.add_argument('--batch_size', default=16, type=int, help='建议 16')
    parser.add_argument('--max_epoch', default=100, type=int, help='总Epoch')
    parser.add_argument('--lr', default=0.0001, type=float, help='初始学习率')
    parser.add_argument('--save_folder', default='./weights/', help='模型保存路径')
    parser.add_argument('--val_split', default=0.1, type=float, help='验证集比例')
    parser.add_argument('--patience', default=20, type=int, help='早停耐心值')
    return parser.parse_args()

def sparse_tuple_for_ctc(T_length, lengths):
    input_lengths = []
    target_lengths = []
    for ch in lengths:
        input_lengths.append(T_length)
        target_lengths.append(ch)
    return tuple(input_lengths), tuple(target_lengths)

def evaluate(model, dataloader, device, T_length):
    model.eval()
    correct = 0
    total = 0
    BLANK_IDX = len(CHARS) - 1
    
    demo_targets = []
    demo_preds = []
    
    with torch.no_grad():
        for images, labels, lengths in dataloader:
            images = images.to(device)
            logits = model(images)
            logits = logits.cpu().numpy()
            
            start = 0
            current_targets = []
            for length in lengths:
                target_plate = labels[start : start+length]
                current_targets.append(target_plate.tolist())
                start += length
            
            preds = np.argmax(logits, axis=1)
            
            for i in range(len(preds)):
                pred_seq = preds[i]
                decoded_seq = []
                last_char = -1
                for char_idx in pred_seq:
                    if char_idx != last_char and char_idx != BLANK_IDX:
                        decoded_seq.append(char_idx)
                    last_char = char_idx
                
                if decoded_seq == current_targets[i]:
                    correct += 1
                total += 1
                
                if len(demo_targets) < 5:
                    demo_targets.append(current_targets[i])
                    demo_preds.append(decoded_seq)

    if len(demo_targets) > 0:
        idx = random.randint(0, len(demo_targets) - 1)
        real_str = "".join([CHARS[c] for c in demo_targets[idx]])
        pred_str = "".join([CHARS[c] for c in demo_preds[idx]])
        print(f"   [随机演示] 真实: {real_str} | 预测: {pred_str}")

    return correct / total

def train():
    args = get_parser()
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"使用设备: {device} | BatchSize: {args.batch_size}")

    if not os.path.exists(args.train_dir):
        print(f"错误: 找不到目录 {args.train_dir}")
        return

    # --- 修改点：手动划分图片路径，分离训练集与测试集 ---
    all_imgs = [os.path.join(args.train_dir, f) for f in os.listdir(args.train_dir) if f.lower().endswith(('.jpg', '.png', '.jpeg', '.bmp'))]
    random.shuffle(all_imgs)
    
    total_size = len(all_imgs)
    val_size = int(total_size * args.val_split)
    train_size = total_size - val_size
    
    train_paths = all_imgs[val_size:]
    val_paths = all_imgs[:val_size]
    
    print(f"总图片: {total_size} | 训练集: {train_size} | 测试集: {val_size}")

    # 训练与验证均使用共享的 R 通道灰度预处理和相同归一化。
    train_dataset = LPRDataLoader(train_paths, args.img_size, is_train=True)
    val_dataset = LPRDataLoader(val_paths, args.img_size, is_train=False)

    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True, 
                              num_workers=2, collate_fn=collate_fn)
    val_loader = DataLoader(val_dataset, batch_size=args.batch_size, shuffle=True, 
                            num_workers=2, collate_fn=collate_fn)

    model = FPGA_LPRNet(class_num=len(CHARS))
    model.to(device)
    
    if not os.path.exists(args.save_folder):
        os.makedirs(args.save_folder)
        
    model_path = os.path.join(args.save_folder, 'fpga_best_model.pth')
    
    # --- 核心新增：断点续训 (加载已有模型) ---
    best_acc = 0.0
    if os.path.exists(model_path):
        print("\n=========================================")
        print(f"✅ 发现已有模型: {model_path}")
        print(">>> 正在加载权重，在此基础上继续训练...")
        print("=========================================\n")
        model.load_state_dict(torch.load(model_path, map_location=device))
        # best_acc 保留为 0，让系统跑完第一个 epoch 后自动更新为当前测试集上的实际 Acc
    else:
        print("\n⚠️ 未找到历史模型，将从头开始初始化训练...\n")

    ctc_loss = nn.CTCLoss(blank=len(CHARS)-1, reduction='mean') 
    optimizer = optim.Adam(model.parameters(), lr=args.lr)
    
    # --- 修改点：改用 Cosine 退火学习率，使微调下降更平滑 ---
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.max_epoch)

    T_length = 23 
    patience_counter = 0

    for epoch in range(args.max_epoch):
        model.train()
        epoch_loss = 0
        
        for i, (images, labels, lengths) in enumerate(train_loader):
            images = images.to(device)
            labels = labels.to(device)

            logits = model(images)
            log_probs = logits.permute(2, 0, 1).log_softmax(2).requires_grad_()
            input_lengths, target_lengths = sparse_tuple_for_ctc(T_length, lengths)
            
            optimizer.zero_grad()
            loss = ctc_loss(log_probs, labels, input_lengths=input_lengths, target_lengths=target_lengths)
            
            if loss.item() == float('inf'): continue
            loss.backward()
            optimizer.step()
            epoch_loss += loss.item()

        scheduler.step()
        current_lr = scheduler.get_last_lr()[0]

        avg_loss = epoch_loss / len(train_loader)
        print(f"Epoch [{epoch+1}/{args.max_epoch}] Loss: {avg_loss:.4f} (LR: {current_lr:.6f})", end="")
        
        if len(val_dataset) > 0:
            acc = evaluate(model, val_loader, device, T_length)
            print(f" | Test Acc: {acc*100:.2f}%")
            
            if acc > best_acc:
                best_acc = acc
                patience_counter = 0
                torch.save(model.state_dict(), model_path)
                print(f"   >>> 发现新高! 模型已保存 (Best Acc: {best_acc*100:.2f}%)")
            else:
                patience_counter += 1
                print(f"   ... 准确率未提升 (耐心值: {patience_counter}/{args.patience})")
                
                if patience_counter >= args.patience:
                    print("\n==============================")
                    print(f"早停触发! 训练结束。")
                    print(f"本次最佳准确率: {best_acc*100:.2f}%")
                    print(f"最佳模型已保存在: {model_path}")
                    print("==============================")
                    break
        else:
            print("")

if __name__ == "__main__":
    train()
