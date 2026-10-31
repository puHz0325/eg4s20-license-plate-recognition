`timescale 1ns/1ps
module teacher_vote_slow_tb;
 reg clk=0;always #5 clk=~clk;
 reg reset_n=0,result_event=0,error=0;reg [31:0] frame_id=0;
 reg [4:0] length=7;reg [160:0] chars=0;
 wire confirmed_valid,candidate_valid;wire [48:0] confirmed_chars;wire [2:0] candidate_votes;
 lpr_vote #(.CLK_HZ(1000),.TIMEOUT_MS(5000)) dut(.*);
 wire [3:0] status;wire display_confirmed,frame_alive,result_alive,last_format_valid;
 wire [4:0] last_length;wire [48:0] last_chars;
 lpr_health #(.CLK_HZ(1000),.TIMEOUT_MS(5000)) health(clk,reset_n,1'b1,1'b0,1'b1,1'b1,
  result_event,length,chars,error,confirmed_valid,status,display_confirmed,frame_alive,result_alive,last_length,last_chars,last_format_valid);
 task result(input integer tag);
  @(negedge clk);frame_id=tag;result_event=1;
  @(negedge clk);result_event=0;
 endtask
 initial begin
  chars[48:0]={7'd43,7'd40,7'd42,7'd39,7'd38,7'd41,7'd0};
  repeat(3) @(negedge clk);reset_n=1;
  for(integer i=1;i<=4;i++) begin
   repeat(750) @(negedge clk);result(i);
   if(candidate_votes!=i || confirmed_valid!=(i==4)) $fatal(1,"slow result voting at %0d",i);
  end
  if(!display_confirmed || status!=7) $fatal(1,"confirmed health missing");
  repeat(3000) @(negedge clk);
  if(!confirmed_valid || !result_alive) $fatal(1,"age counter wrapped before five seconds");
  result(4);if(candidate_votes!=4) $fatal(1,"duplicate frame voted twice");
  repeat(5002) @(negedge clk);
  if(confirmed_valid || result_alive || last_length!=0 || status!=8) $fatal(1,"stale result not removed");
  $display("PASS teacher_vote_slow: four distinct results over 3 seconds, five-second expiry and no age wrap or replay vote");$finish;
 end
endmodule
