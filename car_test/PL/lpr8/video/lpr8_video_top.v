module teacher_video_top(
 input wire clk_50m,rst_n,uart_rxd,cam_pclk,cam_vsync,cam_href,input wire [7:0] cam_data,
 output wire uart_txd,cam_xclk,cam_rst_n,cam_pwdn,inout wire cam_scl,cam_sda,
 output wire hdmi_clk_p,hdmi_d0_p,hdmi_d1_p,hdmi_d2_p,output wire [3:0] status_led
);
 wire mem_clk,mem_shift,core_clk,serial_clk,locked;
 teacher_video_clocks clocks(clk_50m,rst_n,mem_clk,mem_shift,cam_xclk,core_clk,serial_clk,locked);
 wire sys_reset_n,cam_reset_n,mem_reset_n,core_reset_n;
 video_reset rs(clk_50m,rst_n && locked,sys_reset_n);
 video_reset rc(cam_pclk,rst_n && locked,cam_reset_n);
 video_reset rm(mem_clk,rst_n && locked,mem_reset_n);
 video_reset rp(core_clk,rst_n && locked,core_reset_n);
 wire configured,camera_fault;
 wire [3:0] fault_code;
 wire [8:0] config_index;
 wire [1:0] retries;
 ov5640_config camera_config(clk_50m,sys_reset_n,cam_scl,cam_sda,
  cam_rst_n,cam_pwdn,configured,camera_fault,fault_code,config_index,retries);
 wire rx_valid,tx_valid,tx_busy;
 wire [7:0] rx_data,tx_data;
 uart_rx #(.CLKS_PER_BIT(217)) receiver(core_clk,core_reset_n,uart_rxd,rx_data,rx_valid);
 uart_tx #(.CLKS_PER_BIT(217)) transmitter(core_clk,core_reset_n,tx_data,tx_valid && !tx_busy,uart_txd,tx_busy);
 wire hs,vs,de;wire [23:0] rgb;
 wire ras_n,cas_n,we_n,cke,cs_n;wire [10:0] addr;wire [1:0] ba;wire [3:0] dm;wire [31:0] dq;
 wire initialized,model_ready,camera_mode,cnn_busy,system_error;
 wire [31:0] camera_good,camera_bad,published,rejected,underflows,inference_count;
 teacher_video_system system(cam_pclk,mem_clk,core_clk,cam_reset_n,mem_reset_n,core_reset_n,
  configured,camera_fault,fault_code,retries,cam_vsync,cam_href,cam_data,
  rx_valid,rx_data,tx_valid,!tx_busy,tx_data,hs,vs,de,rgb,
  ras_n,cas_n,we_n,addr,ba,dm,dq,cke,cs_n,initialized,model_ready,camera_mode,cnn_busy,system_error,
  camera_good,camera_bad,published,rejected,underflows,inference_count);
 EG_PHY_SDRAM_2M_32 memory(.clk(mem_shift),.ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),
  .addr(addr),.ba(ba),.dq(dq),.cs_n(cs_n),.cke(cke),.dm0(dm[0]),.dm1(dm[1]),.dm2(dm[2]),.dm3(dm[3]));
 wire [9:0] blue,green,red;
 tmds_encoder eb(core_clk,core_reset_n,rgb[7:0],de,hs,vs,blue);
 tmds_encoder eg(core_clk,core_reset_n,rgb[15:8],de,1'b0,1'b0,green);
 tmds_encoder er(core_clk,core_reset_n,rgb[23:16],de,1'b0,1'b0,red);
 tmds_serializer sb(serial_clk,core_reset_n,blue,hdmi_d0_p);
 tmds_serializer sg(serial_clk,core_reset_n,green,hdmi_d1_p);
 tmds_serializer sr(serial_clk,core_reset_n,red,hdmi_d2_p);
 tmds_serializer sc(serial_clk,core_reset_n,10'b0000011111,hdmi_clk_p);
 assign status_led={camera_fault || system_error,underflows!=0,published!=0,model_ready && initialized};
endmodule
