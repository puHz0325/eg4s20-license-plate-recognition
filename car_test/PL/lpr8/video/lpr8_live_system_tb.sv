`timescale 1ns/1ps
`include "expected.vh"
`include "lpr8_model_identity.vh"
module teacher_live_system_tb;
 reg cam_clk=0,mem_clk=0,core_clk=0;
 always #20.833333 cam_clk=~cam_clk;
 always #6.666667 mem_clk=~mem_clk;
 always #20 core_clk=~core_clk;
 reg cam_reset_n=0,mem_reset_n=0,core_reset_n=0,configured=0,camera_fault=0;
 reg [3:0] fault_code=0;reg [1:0] retries=0;
 reg cam_vsync=1,cam_href=0;reg [7:0] cam_data=0;
 reg uart_rx_valid=0,uart_tx_ready=0;reg [7:0] uart_rx_data=0;
 wire uart_tx_valid,hs,vs,de,initialized,model_ready,camera_mode,cnn_busy,system_error;
 wire [7:0] uart_tx_data;wire [23:0] rgb;
 wire ras_n,cas_n,we_n,cke,cs_n;wire [10:0] addr;wire [1:0] ba;wire [3:0] dm;wire [31:0] dq;
 wire [31:0] camera_good,camera_bad,published,rejected,underflows,inference_count;
 teacher_video_system #(.INIT_CYCLES(20)) dut(.*);
 video_sdram_model #(.WORDS(524288),.MAX_REFRESH_CYCLES(585)) memory(!mem_clk,mem_reset_n,cke,cs_n,ras_n,cas_n,we_n,addr,ba,dm,dq);
 reg [7:0] model[0:156255],pixels[0:4095],response[0:127],chars[0:31];
 reg [31:0] expected_layer[0:7];
 integer received=0,checked_pixels=0,displayed_frames=0,roi_reads=0;
 integer green_border_checks=0;
 reg [11:0] displayed_x,displayed_y;reg displayed_ready;
 reg [31:0] rng=32'h9a472d13,roi_crc;
 reg stalled=0;reg [7:0] held;
 function [31:0] crc_byte(input [31:0] prior,input [7:0] data);
  reg [31:0] t;begin t=prior^data;for(integer j=0;j<8;j++) t=t[0]?(t>>1)^32'hedb88320:t>>1;crc_byte=t;end
 endfunction
 function [7:0] scene(input integer x,input integer y);
  if(x>=128 && x<512 && y>=176 && y<304) scene=pixels[((y-176)/4)*128+(x-128)/3];
  else scene=(x*3+y*7)&255;
 endfunction
 always @(negedge core_clk) begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};uart_tx_ready=rng[1:0]!=0;end
 always @(posedge core_clk) if(core_reset_n) begin
  displayed_x<=dut.x;displayed_y<=dut.y;
  displayed_ready<=dut.frontend.display.synced && !dut.frontend.display.broken && dut.frontend.display.word_valid;
  if(stalled && (!uart_tx_valid || uart_tx_data!==held)) $fatal(1,"system UART response changed under stall");
  stalled=uart_tx_valid&&!uart_tx_ready;held=uart_tx_data;
  if(uart_tx_valid&&uart_tx_ready) begin
   if(received>=128) $fatal(1,"system response overflow");
   response[received]=uart_tx_data;received++;
  end
  if(dut.frontend.frame_start && dut.frontend.display.synced && !dut.frontend.display.broken) displayed_frames++;
 end
 always @(negedge core_clk) if(core_reset_n && de && displayed_ready && displayed_y==176 && displayed_x>=128 && displayed_x<512) begin
  if(rgb!==24'h00ff00) $fatal(1,"OSD obscured aligned ROI top border");
  green_border_checks++;
 end
 // Check the preview before the OSD overlay. RGB data is combinational at x/y.
 always @(negedge core_clk) if(core_reset_n && dut.frontend.de && dut.frontend.display.synced && !dut.frontend.display.broken) begin
  if(!dut.frontend.display.border) begin
   if(dut.base_rgb!=={3{scene(dut.x,dut.y)}}) $fatal(1,"preview mismatch x=%0d y=%0d got=%h",dut.x,dut.y,dut.base_rgb);
   checked_pixels++;
  end else if(dut.base_rgb!==24'h00ff00) $fatal(1,"ROI border color");
 end
 always @(posedge mem_clk) if(mem_reset_n && dut.f_req_valid && dut.f_req_ready && dut.f_req_write && dut.frontend.store.display_owned)
  if(dut.f_req_addr/(640*480/4)==dut.frontend.store.display_bank) $fatal(1,"overwrote display-owned buffer");
 task byte_send(input [7:0] data);
  @(negedge core_clk);uart_rx_valid=1;uart_rx_data=data;
  @(negedge core_clk);uart_rx_valid=0;repeat(47) @(negedge core_clk);
 endtask
 task ack(input [7:0] command);
  reg [31:0] crc;
  wait(received==128);@(negedge core_clk);
  if({response[0],response[1],response[2],response[3]}!==32'h54434831 || response[4]!==command) $fatal(1,"bad system ACK command %h expected %h",response[4],command);
  crc='1;for(integer i=0;i<124;i++) crc=crc_byte(crc,response[i]);
  if({response[127],response[126],response[125],response[124]}!==~crc || response[5][3]) $fatal(1,"bad system ACK CRC/status %h",response[5]);
  received=0;repeat(4) @(negedge core_clk);
 endtask
 task upload(input integer offset,input integer count);
  reg [31:0] crc;integer address;
  address='h100000+offset;
  byte_send("W");byte_send(address);byte_send(address>>8);byte_send(address>>16);byte_send(count>>4);byte_send(count>>12);
  crc='1;for(integer i=0;i<count;i++) begin byte_send(model[offset+i]);crc=crc_byte(crc,model[offset+i]);end
  crc=~crc;for(integer i=0;i<4;i++) byte_send(crc>>(i*8));ack("W");
 endtask
 task camera_frame;
  @(negedge cam_clk);cam_vsync=0;repeat(5) @(negedge cam_clk);
  for(integer y=0;y<480;y++) begin
   for(integer x=0;x<640;x++) begin
    @(negedge cam_clk);cam_href=1;cam_data=scene(x,y);
    @(negedge cam_clk);cam_data=8'haa;
    @(negedge cam_clk);cam_data=8'h55;
   end
   @(negedge cam_clk);cam_href=0;repeat(7) @(negedge cam_clk);
  end
  repeat(8) @(negedge cam_clk);cam_vsync=1;repeat(17) @(negedge cam_clk);
 endtask
 initial begin
  for(integer i='h40000;i<'h80000;i++) memory.memory[i]=32'ha5c79e13;
  $readmemh("car_test/PL/lpr8/data/model.hex",model);
  $readmemh("car_test/PL/lpr8/data/input_0.hex",pixels);
  $readmemh("car_test/PL/lpr8/data/chars_0.hex",chars);
  expected_layer[0]=`BOARD_CRC_0_0;expected_layer[1]=`BOARD_CRC_0_1;
  expected_layer[2]=`BOARD_CRC_0_2;expected_layer[3]=`BOARD_CRC_0_3;
  expected_layer[4]=`BOARD_CRC_0_4;expected_layer[5]=`BOARD_CRC_0_5;
  expected_layer[6]=`BOARD_CRC_0_6;expected_layer[7]=`BOARD_CRC_0_7;
  roi_crc='1;for(integer i=0;i<4096;i++) roi_crc=crc_byte(roi_crc,pixels[i]);roi_crc=~roi_crc;
  repeat(4) @(negedge core_clk);cam_reset_n=1;mem_reset_n=1;core_reset_n=1;configured=1;wait(initialized);
  byte_send("P");ack("P");
  for(integer offset=0;offset<156256;offset+=4096) upload(offset,156256-offset>4096 ? 4096:156256-offset);
  byte_send("V");ack("V");
  if(!model_ready || {response[11],response[10],response[9],response[8]}!==`TEACHER_MODEL_CRC32) $fatal(1,"integrated physical model CRC");
  $display("CHECK teacher_live_system: model UART upload and physical SDRAM CRC passed");
  byte_send("A");ack("A");if(!camera_mode) $fatal(1,"camera enable");
  fork
   begin repeat(3) camera_frame();end
   begin
    ack("I");
    if((response[5]&8'h3f)!==8'h23 || response[6]!=7 || system_error) $fatal(1,"camera inference status %h",response[5]);
    if({response[15],response[14],response[13],response[12]}!==roi_crc) $fatal(1,"camera ROI CRC differs from frozen image");
    for(integer i=0;i<7;i++) if(response[24+i]!==chars[i]) $fatal(1,"camera CTC mismatch %0d",i);
    for(integer i=0;i<8;i++)
     if({response[59+i*4],response[58+i*4],response[57+i*4],response[56+i*4]}!==expected_layer[i]) $fatal(1,"camera layer CRC %0d",i);
   end
  join
  if(camera_good!=3 || camera_bad!=0 || published!=3 || rejected!=0 || checked_pixels<640*480 || displayed_frames<2 || underflows!=0 || green_border_checks==0)
   $fatal(1,"video coverage good=%0d bad=%0d published=%0d rejected=%0d pixels=%0d frames=%0d underflows=%0d",camera_good,camera_bad,published,rejected,checked_pixels,displayed_frames,underflows);
  for(integer i=0;i<4096;i++)
   if(((memory.memory[('h140000+i)/4]>>((i%4)*8))&255)!==32'(pixels[i])) $fatal(1,"SDRAM snapshot mismatch %0d",i);
  $display("PASS teacher_live_system: 3 full VGA RGB888 frames, grayscale preview and ROI border, exact camera ROI in SDRAM, real teacher 8 layer CRCs and 7 CTC characters, zero underflow");$finish;
 end
 initial begin #3000000000;$fatal(1,"live system timeout service=%0d bridge=%0d frames=%0d",dut.service.state,dut.bridge.state,published);end
endmodule
