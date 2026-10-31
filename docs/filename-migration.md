# lpr8 文件更名说明

本次将交付包中50个含teacher的文件名改为lpr8，同时把主要源码目录改为 `car_test/PL/lpr8/`。lpr8表示八层车牌识别网络。原本地实验工程保留作为回退，当前GitHub主分支使用新入口。

| 原入口 | 当前入口 |
| --- | --- |
| `train_teacher.py` | `train_lpr8.py` |
| `robust_teacher.py` | `robust_lpr8.py` |
| `teacher_qat.py` | `lpr8_qat.py` |
| `quantize_teacher.py` | `quantize_lpr8.py` |
| `evaluate_robust_teacher.py` | `evaluate_robust_lpr8.py` |
| `teacher_preprocess.py` | `lpr8_preprocess.py` |
| `teacher_inference.v` | `lpr8_inference.v` |
| `teacher_config.vh` | `lpr8_config.vh` |
| `teacher_video.al` | `lpr8_video.al` |
| `teacher_video_p1.bit` | `lpr8_video_p1.bit` |

Python导入、头文件include、向量清单、工程创建脚本和文档引用已同步处理。完整逐路径映射及机械替换记录保存在 `verification/filename_migration.json`。仓库当前文件完整性以根目录和minimal目录的 `SHA256SUMS.json` 为准。

RTL内部模块、信号、宏和二进制协议格式沿用原标识，使预编译bit与主机保持兼容；TD顶层仍选择 `teacher_video_top`。这些内部名字是历史标识，不表示部署时存在大小模型配对。

训练方式与文件名分别描述。最终直接部署八层网络；恢复微调和QAT训练记录仍包含同结构参考模型的知识蒸馏损失，系数为0.35和0.15。不能因更名而把这段训练历史删除，模型参数和评测结果也没有因此改变。

原始构建/仿真证据保留旧路径。校验工具按映射找到新文件，再逆向恢复文件名和路径引用核对原SHA；不会伪造一份改名后完成全部仿真的历史报告。本轮编译和工程检查见 `verification/filename_migration_checks.json`。
