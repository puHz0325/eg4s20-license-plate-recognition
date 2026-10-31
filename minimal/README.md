# 最小上板系统

本目录可单独复制使用。硬件为DMZ EG4S20BG256核心板＋综合底板、OV5640 V5.0 DVP模块、HDMI显示器。仅提供原车牌识别功能。

## 使用顺序

1. 按下表接好相机，连接底板HDMI。分别接好JTAG下载USB和核心板CH340串口USB。
2. TD Download选择JTAG，下载 `fpga/teacher_video_p1.bit`，等待成功提示。
3. 在本目录执行：

```powershell
python -m pip install -r requirements.txt
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

多个CH340时使用 `-PortName COM11` 指定实际端口。脚本上传并校验模型、开启自动相机推理、等待3次结果；成功后关闭串口程序，FPGA仍继续运行。日志保存在 `logs/`。

每次断电或重新下载bit后都需重新加载模型。摄像头预览可以早于模型就绪；只有预览不代表推理已开启。电脑只负责串口传输及打印结果，不做车牌识别。不需要PyTorch/OpenCV。

## OV5640接核心板P1

相机背面丝印朝自己、排针在上方：上排1/3/5…19，下排2/4/6…20。核心板P1为2×30公针，按板上1/2标记确定计数方向。以下为连接器针号。

| 相机针号/丝印 | 核心板P1 |
| --- | --- |
| 1 / 3V3 | 59 |
| 2 / GND | 58 |
| 3 / SCK | 39 |
| 4 / SDA | 40 |
| 5 / VS | 37 |
| 6 / HS | 38 |
| 7 / PCLK | 25 |
| 8 / XCK | 26 |
| 9 / D7 | 36 |
| 10 / D6 | 35 |
| 11 / D5 | 34 |
| 12 / D4 | 33 |
| 13 / D3 | 32 |
| 14 / D2 | 31 |
| 15 / D1 | 30 |
| 16 / D0 | 29 |
| 17 / RST | 27 |
| 18 / PWDN | 28 |
| 19 / FREX、20 / STRO | 不接 |

使用3.3V供电并断电接线。P1-1/2为VBUS，不能作为相机电源；**P1-57为F4信号，不是GND**。使用P1-58接地。本组GPIO还连到底板LCD扩展，运行时不接占用同组信号的并口屏。

## 工程文件

- `fpga/teacher_video.al`：相对路径TD工程；顶层 `teacher_video_top`，器件 `EG4S20BG256`。
- `fpga/video.v`：完整合并RTL，按随附TD工程的Verilog入口使用。ModelSim仿真使用完整源码包中的分文件脚本，按原规则分别编译Verilog和SystemVerilog。`video.adc/video.sdc`为原版引脚/时序约束。
- `fpga/assets/`：相机初始化表、4块字库ROM，保持文件相对位置。
- `fpga/create_project.tcl`：需要时在本机创建新的 `teacher_video_local.al`，不会覆盖已有本机工程。
- `model/model_init.bin`、`model_identity.json`：156256字节冻结模型，CRC32 `D5CA7402`。
- `host/start_camera.py --status`：只读状态；`--check-files`：不连接板卡的模型校验。

绿色框为384×128，目标完整七位车牌应位于其中；FPGA输入为128×32，显示为640×480灰度。四次一致合法结果才确认。bit SHA256为`0dcc73e3fa692c37b07edd84f24ebd36e31a0a3f0a66558b2e7cddcefa229538`。

本bit已有短时实板验证，仍有原PHY-7002 SDRAM位置告警；没有宣称长期稳定性或所有实拍场景的识别准确率。
