`timescale 1ns/1ps
module teacher_roi_tb;
 reg capture_clk=0,core_clk=0;always #6.666667 capture_clk=~capture_clk;always #20 core_clk=~core_clk;
 reg capture_reset_n=0,core_reset_n=0,token_valid=0,snapshot_take=0,snapshot_release=0,read_enable=0;
 reg [35:0] token=0;reg [11:0] read_addr=0;
 wire snapshot_valid;wire [31:0] snapshot_frame,published,skipped,rejected;wire [7:0] read_data;
 teacher_roi_snapshot dut(.*);
 function [7:0] pixel(input integer y,input integer x,input integer frame);
  pixel=(y*13+x*7+frame*31)&255;
 endfunction
 task send(input [35:0] value);
  begin @(negedge capture_clk);token=value;token_valid=1;end
 endtask
 task frame(input integer f,input bit good);
  reg [31:0] bytes4;
  begin
   send({2'b01,2'b0,32'(f)});
   for(integer y=0;y<480;y++) for(integer x=0;x<640;x+=4) begin
    for(integer b=0;b<4;b++) bytes4[b*8+:8]=pixel(y,x+b,f);
    send({4'b0,bytes4});
   end
   send({2'b10,1'b0,good,32'b0});@(negedge capture_clk);token_valid=0;
  end
 endtask
 task consume(input integer f);
  integer expected;
  begin
   wait(snapshot_valid);@(negedge core_clk);
   if(snapshot_frame!==32'(f)) $fatal(1,"ROI tag got=%0d wanted=%0d",snapshot_frame,f);
   snapshot_take=1;@(negedge core_clk);snapshot_take=0;
   for(integer i=0;i<4096;i++) begin
    read_enable=1;read_addr=i;@(negedge core_clk);
    expected=(int'(pixel(177+4*(i/128),129+3*(i%128),f))+int'(pixel(178+4*(i/128),129+3*(i%128),f))+1)/2;
    if(read_data!==8'(expected)) $fatal(1,"ROI element %0d got=%h expected=%h",i,read_data,8'(expected));
   end
   read_enable=0;snapshot_release=1;@(negedge core_clk);snapshot_release=0;
  end
 endtask
 always @(posedge capture_clk) if(capture_reset_n && (dut.even_write || dut.odd_write))
  if(dut.write_bank ? !dut.free1:!dut.free0) $fatal(1,"ROI overwrote occupied bank");
 initial begin
  repeat(4) @(negedge core_clk);capture_reset_n=1;core_reset_n=1;
  frame(1,1);
  fork consume(1);frame(2,1);join
  consume(2);repeat(5) @(negedge capture_clk);
  frame(3,1);frame(4,1);frame(5,1);
  if(skipped==0) $fatal(1,"full-buffer skipping not tested");
  consume(4);repeat(5) @(negedge capture_clk);
  frame(6,0);repeat(6) @(negedge core_clk);
  if(snapshot_valid || rejected!=1) $fatal(1,"bad EOF published");
  $display("PASS teacher_roi: exact 4096 bilinear pixels, two-row rounding, 2 lanes, ownership, newest frame, full and bad EOF");$finish;
 end
 initial begin #30000000;$fatal(1,"ROI timeout");end
endmodule
