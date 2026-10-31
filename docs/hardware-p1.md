# 硬件连接：OV5640 V5.0、P1与HDMI

适用DMZ EG4S20BG256核心板和综合底板，摄像头为OV5640 V5.0 DVP公针模块，使用母对母线。相机背面丝印朝自己、排针在上方：上排1/3/5…19，下排2/4/6…20。核心板P1是数码管与底板空白区域之间的2×30公排针，以丝印1/2标记确定起点，逐对计数。

P1-59提供3.3V，P1-58为GND。**P1-57是F4信号，不是GND；P1-1/2为VBUS，不能作为本相机电源。**断电接线，接相机前核对3.3V和共地。摄像头针号、P1连接器针号和FPGA封装球号是不同编号体系。

| 摄像头针号 | 摄像头丝印 | 核心板 P1 针号 | FPGA 管脚 | RTL 信号 |
|---|---|---|---|---|
| 1 | 3V3 | 59 | OUT_3.3V | 电源 |
| 2 | GND | 58 | GND | 共地 |
| 3 | SCK | 39 | M2 | cam_scl |
| 4 | SDA | 40 | M3 | cam_sda |
| 5 | VS | 37 | M5 | cam_vsync |
| 6 | HS | 38 | D1 | cam_href |
| 7 | PCLK | 25 | L1 | cam_pclk |
| 8 | XCK | 26 | L5 | cam_xclk |
| 9 | D7 | 36 | E1 | cam_data[7] |
| 10 | D6 | 35 | E2 | cam_data[6] |
| 11 | D5 | 34 | F1 | cam_data[5] |
| 12 | D4 | 33 | F2 | cam_data[4] |
| 13 | D3 | 32 | H2 | cam_data[3] |
| 14 | D2 | 31 | G1 | cam_data[2] |
| 15 | D1 | 30 | J1 | cam_data[1] |
| 16 | D0 | 29 | H1 | cam_data[0] |
| 17 | RST | 27 | K1 | cam_rst_n |
| 18 | PWDN | 28 | K2 | cam_pwdn |
| 19 | FREX | 不接 | — | 不使用 |
| 20 | STRO | 不接 | — | 不使用 |

SCK/SDA是SCCB配置总线，XCK为FPGA输出24MHz，PCLK为相机输出采样时钟，不可互换。PWDN高有效、RST低有效，由RTL控制。19/20脚不接。

HDMI使用底板原插座；FPGA CLK/D0/D1/D2正端球号依次为P1/N1/P4/J3，负端由配对差分资源驱动。这里的FPGA球号P1不是核心板连接器的P1-1。

板载50MHz输入为R7，复位为E3。CH340串口FPGA RX=F12、TX=D12；分别连接下载USB和串口USB，二者用途不同。摄像头GPIO还连接LCD扩展，运行时不连接占用同组GPIO的并口屏。

当前发布使用 `minimal/fpga/video.adc` 与 `video.sdc`，顶层 `teacher_video_top`。直接下载 `minimal/fpga/lpr8_video_p1.bit`；无需运行旧预览工程或切换P2参数。预览为640×480灰度，绿色ROI为(128,176,384,128)，CNN输入128×32。

连接表沿用原板原理图与实物确认结果，已与本发布ADC逐项核对。不同模块/板卡版本应按其原理图核对供电与排针方向。
