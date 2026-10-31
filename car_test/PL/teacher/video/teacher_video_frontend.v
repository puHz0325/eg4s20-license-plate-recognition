// Existing full-resolution video transport, exposing its single memory master.
`include "teacher_preprocess.vh"
module teacher_video_frontend #(parameter WIDTH=640,HEIGHT=480)(
 input wire cam_clk,mem_clk,pixel_clk,cam_reset_n,mem_reset_n,pixel_reset_n,
 input wire camera_enable,cam_vsync,cam_href,input wire [7:0] cam_data,
 input wire initialized,output wire hs,vs,de,output wire [23:0] rgb,
 output wire [11:0] x,y,output wire frame_start,
 output wire req_valid,input wire req_ready,output wire req_write,
 output wire [20:0] req_addr,output wire [127:0] req_data,
 input wire done,input wire [127:0] read_data,
 output wire [35:0] capture_token,output wire capture_valid,
 output wire [31:0] camera_good,camera_bad,published,rejected,underflows
);
 (* ASYNC_REG="TRUE" *) reg en1,en2;
 always @(posedge cam_clk or negedge cam_reset_n)
  if(!cam_reset_n) begin en1<=0;en2<=0;end else begin en1<=camera_enable;en2<=en1;end
 wire [35:0] cap_data,cap_q,disp_data,disp_q;
 wire cap_valid,cap_ready,cap_qvalid,cap_qready,disp_valid,disp_ready,disp_qvalid,disp_qready;
 wire display_request;
 dvp_capture #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) capture(cam_clk,cam_reset_n,en2,cam_vsync,cam_href,cam_data,
  cap_data,cap_valid,cap_ready,camera_good,camera_bad);
 video_async_fifo #(.WIDTH(36),.AW(9)) capture_fifo(cam_clk,cam_reset_n,cap_data,cap_valid,cap_ready,
  mem_clk,mem_reset_n,cap_q,cap_qvalid,cap_qready);
 assign capture_token=cap_q;assign capture_valid=cap_qvalid && cap_qready;
 video_timing #(.H_ACTIVE(WIDTH),.V_ACTIVE(HEIGHT)) timing(pixel_clk,pixel_reset_n,hs,vs,de,frame_start,x,y);
 video_display #(.ROI_X(`TEACHER_ROI_X),.ROI_Y(`TEACHER_ROI_Y),.ROI_WIDTH(`TEACHER_ROI_WIDTH),.ROI_HEIGHT(`TEACHER_ROI_HEIGHT)) display(
  pixel_clk,pixel_reset_n,frame_start,de,x,y,disp_q,disp_qvalid,disp_qready,display_request,rgb,underflows);
 video_async_fifo #(.WIDTH(36),.AW(10)) display_fifo(mem_clk,mem_reset_n,disp_data,disp_valid,disp_ready,
  pixel_clk,pixel_reset_n,disp_q,disp_qvalid,disp_qready);
 video_frame_store #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) store(mem_clk,mem_reset_n,initialized,
  cap_q,cap_qvalid,cap_qready,display_request,disp_data,disp_valid,disp_ready,
  req_valid,req_ready,req_write,req_addr,req_data,done,read_data,published,rejected);
endmodule
