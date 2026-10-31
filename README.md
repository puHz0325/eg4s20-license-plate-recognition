# EG4S20 车牌识别系统

安路 EG4S20BG256（大拇指核心板＋综合底板）、OV5640 V5.0 DVP 摄像头和 HDMI 显示器的固定位置单车牌识别。FPGA 完成摄像头配置、采集、R8预处理、SDRAM访问、八层整数CNN、CTC、4/6投票及文字叠加。电脑负责上电后加载权重，不参与图像识别。

本交付恢复为已验证的原识别系统，包含实时灰度预览、绿色识别框、原始候选与确认结果。停车记录、计时、数码管时钟及相关开发分支不在交付范围。

## 最快上板

1. 按 [接线说明](docs/hardware-p1.md) 连接相机、底板HDMI、JTAG下载USB和核心板串口USB。
2. 使用 Anlogic TD Download 窗口，以 JTAG 模式下载 **`minimal/fpga/teacher_video_p1.bit`**；等待下载成功提示。本包不写Flash。
3. 在仓库根目录安装最小依赖并启动：

```powershell
python -m pip install -r minimal/requirements.txt
powershell -NoProfile -ExecutionPolicy Bypass -File .\minimal\start.ps1
```

脚本自动选择唯一CH340/CH341，上传156256字节模型，校验SDRAM全模型CRC，开启相机自动推理并等待3次真实结果。串口有多个设备时追加 `-PortName COM11`，以实际端口为准。每次断电或重配置FPGA都需要重新加载权重；只有预览但没有候选时先检查这一步。

将完整七位车牌放在绿色框内，四周适当留边。未满足格式及4/6一致性时，界面保持识别中，原始候选与字数仍可更新。关闭电脑串口程序后FPGA继续自动推理。

## 交付结构

| 路径 | 用途 |
| --- | --- |
| `minimal/` | 可独立复制的最小上板包：bit、TD最小工程、ROM、模型、串口启动程序 |
| `car_test/PL/teacher/rtl/` | 八层CNN、预取缓冲、MAC、定点量化、CTC等RTL |
| `car_test/PL/teacher/video/` | 相机、ROI、视频/推理仲裁、CDC、集成顶层及视频测试 |
| `car_test/PL/teacher/board/` | 串口服务、SDRAM控制器、验证程序及诊断测试 |
| `car_test/PL/src/` | 共享采集、HDMI、FIFO、显示、投票和字库模块 |
| `car_test/train/` | 模型、训练、QAT、整数参考和量化导出源代码 |
| `verification/`、`release.json` | 冻结源码指纹、原版仿真/资源证据及模型身份 |
| `testdata/`、`tests/`、`tools/` | 冻结OSD参考、最小运行程序测试、打包与仿真准备工具 |
| `docs/` | 接线、架构、协议、构建及验证说明 |

训练原始图、CCPD完整数据集、训练临时缓存、相机实拍照片、EDA安装包及失败停车工程不包含在仓库中。提供当前浮点检查点、整数参数和必要冻结回归向量。

## 版本身份与资源

- bit SHA256：`0dcc73e3fa692c37b07edd84f24ebd36e31a0a3f0a66558b2e7cddcefa229538`
- 模型CRC32：`D5CA7402`；模型SHA256：`10e190ea58a2d8706338923bea83ada74eab1e3144e3ab9c4e5918d5b69cb1c4`
- 相机640×480；ROI为 `(128,176,384,128)`；输入128×32；灰度使用RGB888的R通道，按冻结R8线性插值合同缩放。
- 核心/像素25MHz，内存75MHz，TMDS125MHz，相机XCLK24MHz；8MiB合封SDRAM。
- 原版路由结果：15400 LUT、6868 FF、19 DSP、40个9K RAM、0个32K RAM、2 PLL；setup/hold违例0。
- 保留原PHY-7002 SDRAM位置告警，历史验证不等于小时级或跨温度稳定性签核。

查看 [验证范围](docs/validation.md)、[架构与存储](docs/architecture.md)、[构建和测试](docs/build-and-test.md)、[串口协议](docs/uart-protocol.md)。

## 完整性检查

```powershell
python tools/verify_release.py
python -S minimal/host/start_camera.py --check-files
python -m unittest discover -s tests -v
```

`.gitattributes`保留冻结文件的原始字节和行尾，便于校验与原bit一致的源码/ROM。最小工程的合并RTL只把5个ROM文件路径改为相对路径；预编译bit本身未改动。
