import os

export_dir = './fpga_hex_weights'
weights_outfile = 'all_weights.txt'
biases_outfile = 'all_biases.txt'

# 按照 1 到 7 层的顺序严格拼接
with open(weights_outfile, 'w') as fw, open(biases_outfile, 'w') as fb:
    for i in range(1, 8):
        # 拼接权重
        w_path = os.path.join(export_dir, f'layer{i}_weights.txt')
        if os.path.exists(w_path):
            with open(w_path, 'r') as f:
                fw.write(f.read())
        
        # 拼接偏置
        b_path = os.path.join(export_dir, f'layer{i}_bias.txt')
        if os.path.exists(b_path):
            with open(b_path, 'r') as f:
                fb.write(f.read())

print("✅ 合并完成！请将 all_weights.txt 和 all_biases.txt 放入 Quartus 工程根目录。")