# 构建、仿真与模型源代码

## 工具

已验证环境为Windows、Anlogic TD 5.6.5 SP3、ModelSim SE-64 2020.4、Python 3.12。TD安装包、器件数据库、仿真原语库和许可证由本机安装提供，本仓库不复制EDA安装文件。

默认路径沿用已验证机器，可通过环境变量覆盖：

```powershell
$env:ANLOGIC_TD_HOME='E:\Anlogic\TD_5.6.5_SP3_151.449'
$env:ANLOGIC_TD_BIN="$env:ANLOGIC_TD_HOME\bin\td_commands_prompt.exe"
$env:MODELSIM_BIN='E:\modelsim\win64'
```

所有命令从仓库根目录执行。直接上板仅需 `minimal/requirements.txt`；完整模型参考/仿真向量辅助工具使用：

```powershell
python -m pip install -r requirements-full.txt
```

完整依赖中Torch为2.10.0；已验证机器使用2.10.0+cu130。仅串口启动不需要Torch/CUDA。

## 检查和短测试

```powershell
python tools/verify_release.py
python -S minimal/host/start_camera.py --check-files
python -m unittest discover -s tests -v
python tools/prepare_sim.py
```

准备脚本从冻结的合成OSD像素参考恢复 `tmp/osd_validation`，不要求本机有原字库字体。ROM已经包含，不必重新生成字体。若主动更改字体/相机表/ROI/模型，应重新产生参考向量并完整验证。

## ModelSim

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File car_test/PL/lpr8/sim/run_tests.ps1 -ModelSimBin $env:MODELSIM_BIN
python -B car_test/PL/lpr8/video/run_tests.py
```

第一项检查算术、CTC、DMA及3种输入共4次完整CNN推理，逐层比对475648个元素；第二项包含13项视频/CDC/仲裁/结果桥/投票/OSD/完整相机输入到真实CNN的检查。完整仿真耗时较长，查看 `tmp/modelsim_teacher*` 日志，不把仅编译成功当作完整仿真通过。

`verification/`保存原版本已完成的证据，SHA用于追溯。新的仿真报告在运行后重新写入活动目录。当前文件名改为lpr8前缀，原50项构建输入恢复旧路径/引用后与原记录字节一致；导出的构建脚本还支持工具路径配置。历史证据不冒充改名后重新执行的完整仿真。

## 从完整源文件重新综合

```powershell
python car_test/PL/lpr8/video/build_video.py --stage map --output car_test/PL/lpr8/td/local_build --seed 2
python car_test/PL/lpr8/video/build_video.py --stage pnr --output car_test/PL/lpr8/td/local_build --seed 2
python car_test/PL/lpr8/video/build_video.py --stage bit --output car_test/PL/lpr8/td/local_build --seed 2
```

输出目录必须全新；修改源文件后换目录。bit阶段要求当前完整视频仿真报告为PASS、输入哈希未变，并要求路由setup/hold为零违例。资源可用性必须看实际打包/布局，不只看综合LUT。

最小TD工程可直接打开 `minimal/fpga/lpr8_video.al`。若TD需要本机绝对工程路径，可在该目录执行：

```powershell
& $env:ANLOGIC_TD_BIN create_project.tcl
```

该命令创建新的 `lpr8_video_local.al` 并设置顶层，拒绝覆盖已有本机工程。最小工程ROM使用 `assets/` 相对路径；请保持目录关系。直接使用预编译bit不需要重建工程。

## 模型与训练

当前冻结QAT八层模型检查点为 `car_test/train/accuracy_stage3/qat_run_04/model_state.pth`；整数包为 `robust_int8_04`。模型结构、训练、参考模型约束、QAT、量化和整数参考源代码位于 `car_test/train/`。

保留的config/calibration元数据中的旧本机路径是训练溯源信息，不是最小启动程序的依赖。重训需要另行准备CCPD2019数据、训练/验证/测试划分及原父模型；数据集、旧父模型和训练缓存未打包，不能直接把历史config当作可独立恢复训练全过程的脚本。

预处理固定为完整车牌R8→128×32线性缩放。数据读取默认函数有旧94×24参数，八层模型训练必须使用配置里的128×32，不得将旧低分辨率输入放大当作原始高分辨率数据。
