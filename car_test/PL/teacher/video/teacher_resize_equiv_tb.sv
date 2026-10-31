`timescale 1ns/1ps
module teacher_resize_equiv_tb;
 reg capture_clk=0,core_clk=0;always #6.666667 capture_clk=~capture_clk;always #20 core_clk=~core_clk;
 reg capture_reset_n=0,core_reset_n=0,token_valid=0,snapshot_take=0,snapshot_release=0,read_enable=0;
 reg [35:0] token=0;reg [11:0] read_addr=0;
 wire snapshot_valid;wire [31:0] snapshot_frame,published,skipped,rejected;wire [7:0] read_data;
 reg [7:0] frame[0:307199],expected[0:4095];
 teacher_roi_snapshot dut(.*);
 task send(input [35:0] value,input bit pause);
  if(pause) begin @(negedge capture_clk);token_valid=0;repeat(2) @(negedge capture_clk);end
  @(negedge capture_clk);token=value;token_valid=1;
 endtask
 task capture(input integer tag,input integer count,input bit good);
  send({2'b01,2'b0,32'(tag)},0);
  for(integer i=0;i<count;i+=4)
   send({4'b0,frame[i+3],frame[i+2],frame[i+1],frame[i]},i%68==0);
  send({2'b10,1'b0,good,32'b0},0);
  @(negedge capture_clk);token_valid=0;
 endtask
 initial begin
  $readmemh("car_test/PL/teacher/data/preprocess_frame.hex",frame);
  $readmemh("car_test/PL/teacher/data/preprocess_expected.hex",expected);
  repeat(4) @(negedge core_clk);capture_reset_n=1;core_reset_n=1;
  capture(1,177*640+520,1); // Good EOF flag alone cannot publish a partial frame.
  repeat(6) @(negedge core_clk);
  if(snapshot_valid || rejected!=1) $fatal(1,"partial frame published");
  capture(2,307200,1);
  wait(snapshot_valid);@(negedge core_clk);
  if(snapshot_frame!=2) $fatal(1,"bad oracle frame tag");
  snapshot_take=1;@(negedge core_clk);snapshot_take=0;
  for(integer i=0;i<4096;i++) begin
   read_enable=1;read_addr=i;@(negedge core_clk);
   if(read_data!==expected[i]) $fatal(1,"OpenCV mismatch index=%0d got=%h expected=%h",i,read_data,expected[i]);
  end
  read_enable=0;snapshot_release=1;@(negedge core_clk);snapshot_release=0;
  capture_reset_n=0;core_reset_n=0;repeat(4) @(negedge core_clk);capture_reset_n=1;core_reset_n=1;
  capture(3,307200,1);wait(snapshot_valid);
  if(snapshot_frame!=3) $fatal(1,"line cache reset recovery");
  $display("PASS teacher_resize_equiv: 4096 random OpenCV pixels, odd rounding/extremes, token pauses, partial EOF rejection and reset recovery");$finish;
 end
 initial begin #30000000;$fatal(1,"resize oracle timeout");end
endmodule
