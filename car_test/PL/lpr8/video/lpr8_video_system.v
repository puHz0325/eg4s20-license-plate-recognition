`include "lpr8_preprocess.vh"
module teacher_video_system #(parameter WIDTH=640,HEIGHT=480,INIT_CYCLES=20000)(
 input wire cam_clk,mem_clk,core_clk,cam_reset_n,mem_reset_n,core_reset_n,
 input wire configured,camera_fault,input wire [3:0] fault_code,input wire [1:0] retries,
 input wire cam_vsync,cam_href,input wire [7:0] cam_data,
 input wire uart_rx_valid,input wire [7:0] uart_rx_data,
 output wire uart_tx_valid,input wire uart_tx_ready,output wire [7:0] uart_tx_data,
 output wire hs,vs,de,output wire [23:0] rgb,
 output wire ras_n,cas_n,we_n,output wire [10:0] addr,output wire [1:0] ba,output wire [3:0] dm,
 inout wire [31:0] dq,output wire cke,cs_n,
 output wire initialized,model_ready,camera_mode,cnn_busy,system_error,
 output wire [31:0] camera_good,camera_bad,published,rejected,underflows,
 output wire [31:0] inference_count
);
 wire f_req_valid,f_req_ready,f_req_write,f_done;
 wire [20:0] f_req_addr;
 wire [127:0] f_req_data,f_read_data;
 wire base_hs,base_vs,base_de,frame_start;
 wire [23:0] base_rgb;
 wire [11:0] x,y;
 wire [35:0] capture_token;
 wire capture_valid;
 teacher_video_frontend #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) frontend(
  cam_clk,mem_clk,core_clk,cam_reset_n,mem_reset_n,core_reset_n,configured,cam_vsync,cam_href,cam_data,
  initialized,base_hs,base_vs,base_de,base_rgb,x,y,frame_start,
  f_req_valid,f_req_ready,f_req_write,f_req_addr,f_req_data,f_done,f_read_data,
  capture_token,capture_valid,camera_good,camera_bad,published,rejected,underflows);
 wire snapshot_valid,snapshot_take,snapshot_release,snapshot_read;
 wire [31:0] snapshot_frame;
 wire [11:0] snapshot_addr;
 wire [7:0] snapshot_data;
 teacher_roi_snapshot #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) snapshots(
  mem_clk,mem_reset_n,capture_token,capture_valid,core_clk,core_reset_n,
  snapshot_valid,snapshot_frame,snapshot_take,snapshot_release,snapshot_read,snapshot_addr,snapshot_data, , , );
 wire service_rx_valid,service_rx_ready,service_tx_valid,service_tx_ready,service_idle;
 wire [7:0] service_rx_data,service_tx_data;
 wire bridge_fault,service_error,result_event,result_error;
 wire [31:0] result_frame;
 wire [4:0] result_length;
 wire [160:0] result_chars;
 teacher_camera_bridge bridge(core_clk,core_reset_n,uart_rx_valid,uart_rx_data,
  uart_tx_valid,uart_tx_ready,uart_tx_data,
  service_rx_valid,service_rx_ready,service_rx_data,service_tx_valid,service_tx_ready,service_tx_data,
  service_idle,model_ready,camera_mode,snapshot_valid,snapshot_frame,snapshot_take,snapshot_release,
  snapshot_read,snapshot_addr,snapshot_data,result_event,result_frame,result_length,result_chars,result_error,bridge_fault,inference_count);
 (* ASYNC_REG="TRUE" *) reg init1,init2,pub1,pub2,cfg1,cfg2,flt1,flt2;
 reg pub_seen,model_available;
 reg [31:0] frame_count;
 reg [3:0] fault_code_held;
 reg [1:0] retries_held;
 always @(posedge core_clk or negedge core_reset_n) begin
  if(!core_reset_n) begin init1<=0;init2<=0;pub1<=0;pub2<=0;pub_seen<=0;cfg1<=0;cfg2<=0;flt1<=0;flt2<=0;model_available<=0;frame_count<=0;fault_code_held<=0;retries_held<=0;end
  else begin
   init1<=initialized;init2<=init1;pub1<=published[0];pub2<=pub1;pub_seen<=pub2;
   cfg1<=configured;cfg2<=cfg1;flt1<=camera_fault;flt2<=flt1;
   if(pub2^pub_seen) frame_count<=frame_count+1'b1;
   // Camera fault metadata is held in its source domain before the synchronized qualifier is consumed.
   if(flt2) begin fault_code_held<=fault_code;retries_held<=retries;end
   if(bridge_fault || (!camera_mode && !model_ready)) model_available<=0;
   else if(model_ready) model_available<=1;
  end
 end
 wire c_req_valid,c_req_ready,c_req_write,c_rsp_valid,c_rsp_ready;
 wire [22:0] c_req_addr;
 wire [127:0] c_req_data,c_rsp_data;
 wire [15:0] c_req_strobe;
 wire [2:0] read_delay;
 wire [31:0] video_flags={18'b0,retries_held,fault_code_held,service_error,bridge_fault,cnn_busy,camera_mode,model_ready,init2,flt2,cfg2};
 teacher_board_service #(.VIDEO_STATUS(1)) service(.clk(core_clk),.reset_n(core_reset_n),.initialized(init2),
  .rx_valid(service_rx_valid),.rx_data(service_rx_data),.rx_ready(service_rx_ready),.command_idle(service_idle),
  .tx_valid(service_tx_valid),.tx_ready(service_tx_ready),.tx_data(service_tx_data),
  .model_ready(model_ready),.busy(cnn_busy),.error(service_error),.read_delay(read_delay),.camera_mode(camera_mode),
  .video_status({inference_count,underflows,frame_count,video_flags}),
  .mem_req_valid(c_req_valid),.mem_req_ready(c_req_ready),.mem_req_write(c_req_write),.mem_req_addr(c_req_addr),
  .mem_req_wdata(c_req_data),.mem_req_wstrb(c_req_strobe),.mem_rsp_valid(c_rsp_valid),.mem_rsp_ready(c_rsp_ready),.mem_rsp_rdata(c_rsp_data));
 wire m_req_valid,m_req_ready,m_rsp_valid,m_rsp_ready;
 wire [170:0] m_command;
 wire [127:0] m_rsp_data;
 teacher_mem_cdc memory_bridge(core_clk,core_reset_n,mem_clk,mem_reset_n,
  c_req_valid,c_req_ready,{read_delay,c_req_write,c_req_addr,c_req_data,c_req_strobe},
  c_rsp_valid,c_rsp_ready,c_rsp_data,m_req_valid,m_req_ready,m_command,m_rsp_valid,m_rsp_ready,m_rsp_data);
 teacher_video_memory #(.INIT_CYCLES(INIT_CYCLES)) storage(mem_clk,mem_reset_n,
  f_req_valid,f_req_ready,f_req_write,f_req_addr,f_req_data,f_done,f_read_data,
  m_req_valid,m_req_ready,m_command,m_rsp_valid,m_rsp_ready,m_rsp_data,
  initialized, ,ras_n,cas_n,we_n,addr,ba,dm,dq,cke,cs_n);
 wire confirmed,display_confirmed,frame_alive,result_alive,last_format,candidate_valid;
 wire [48:0] confirmed_chars,last_chars;
 wire [4:0] last_length;
 wire [2:0] votes;
 wire [3:0] health_status;
 wire vote_reset=core_reset_n && cfg2 && !flt2 && init2 && frame_alive && model_available;
 lpr_vote #(.CLK_HZ(25000000),.TIMEOUT_MS(5000)) voter(core_clk,vote_reset,
  result_event,result_frame,result_length,result_chars,result_error,confirmed,confirmed_chars,votes,candidate_valid);
 lpr_health #(.CLK_HZ(25000000),.TIMEOUT_MS(5000)) health(core_clk,core_reset_n,cfg2,flt2,
  init2 && model_available,pub2^pub_seen,result_event,result_length,result_chars,result_error,
  confirmed,health_status,display_confirmed,frame_alive,result_alive,last_length,last_chars,last_format);
 lpr_osd #(.PANEL_BOTTOM(`TEACHER_ROI_Y)) osd(core_clk,core_reset_n,display_confirmed,confirmed_chars,
  core_clk,core_reset_n,frame_start,x,y,base_hs,base_vs,base_de,base_rgb,
  hs,vs,de,rgb,health_status,last_chars,last_length,result_alive ? votes:3'b0,
  last_format && result_alive,fault_code_held,retries_held);
 assign system_error=bridge_fault || service_error;
endmodule
