`timescale 1ns/1ps
module teacher_live_clocks_tb;
 reg clk_50m=0,reset_n=0;always #10 clk_50m=~clk_50m;
 wire mem_clk,mem_shift,cam_xclk,core_clk,serial_clk,locked;
 teacher_video_clocks dut(.*);
 realtime a,b;
 initial begin
  #200;reset_n=1;wait(locked);#10000;
  @(posedge mem_clk);a=$realtime;@(posedge mem_clk);b=$realtime;
  if(b-a<13.30 || b-a>13.36) $fatal(1,"memory period %f",b-a);
  @(posedge mem_clk);a=$realtime;@(posedge mem_shift);b=$realtime;
  if(b-a<6.64 || b-a>6.69) $fatal(1,"memory phase %f",b-a);
  @(posedge core_clk);a=$realtime;@(posedge core_clk);b=$realtime;if(b-a<39.98 || b-a>40.02) $fatal(1,"core clock");
  @(posedge serial_clk);a=$realtime;@(posedge serial_clk);b=$realtime;if(b-a<7.98 || b-a>8.02) $fatal(1,"TMDS clock");
  @(posedge cam_xclk);a=$realtime;@(posedge cam_xclk);b=$realtime;if(b-a<41.64 || b-a>41.69) $fatal(1,"camera clock");
  $display("PASS teacher_live_clocks: native PLL 75MHz/180deg SDRAM, 25/125MHz video and 24MHz camera");$finish;
 end
 initial begin #500000;$fatal(1,"live PLL timeout");end
endmodule
