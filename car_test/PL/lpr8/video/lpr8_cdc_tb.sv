`timescale 1ns/1ps
module teacher_cdc_tb;
 reg s_clk=0,m_clk=0;always #20 s_clk=~s_clk;always #8.333 m_clk=~m_clk;
 reg s_reset_n=0,m_reset_n=0,s_valid=0,s_rsp_ready=0,m_ready=0,m_rsp_valid=0;
 reg [170:0] s_command=0;reg [127:0] m_rsp_data=0;
 wire s_ready,s_rsp_valid,m_valid,m_rsp_ready;wire [127:0] s_rsp_data;wire [170:0] m_command;
 teacher_mem_cdc dut(.*);
 reg [170:0] expected[0:400];
 integer accepted=0,delay_count=0;reg pending=0;
 reg [31:0] rng=32'hbaca6152;
 reg stalled=0;reg [170:0] held;
 function [127:0] reply(input [170:0] command);
  reply=command[143:16]^{4{command[166:135]}};
 endfunction
 always @(negedge m_clk) begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};m_ready=rng[1:0]!=0;s_rsp_ready=rng[3:2]==0;
 end
 always @(posedge m_clk) begin
  if(!m_reset_n) begin pending<=0;accepted<=0;m_rsp_valid<=0;delay_count<=0;stalled<=0;end
  else begin
   if(stalled && (!m_valid || m_command!==held)) $fatal(1,"CDC command changed while stalled");
   stalled<=m_valid&&!m_ready;held<=m_command;
   if(m_valid && m_ready) begin
    if(pending || m_rsp_valid || m_command!==expected[accepted]) $fatal(1,"CDC request sequence %0d",accepted);
    accepted<=accepted+1;pending<=1;delay_count<=rng[8:4];m_rsp_data<=reply(m_command);
   end
   if(pending) begin if(delay_count==0) begin pending<=0;m_rsp_valid<=1;end else delay_count<=delay_count-1;end
   if(m_rsp_valid && m_rsp_ready) m_rsp_valid<=0;
  end
 end
 initial begin
  for(integer i=0;i<400;i++) expected[i]={3'd3,i[0],23'('h100000+i*16),32'(i),32'(~i),32'(i*17),32'(i*31),16'(i^16'ha55a)};
  repeat(4) @(negedge s_clk);s_reset_n=1;m_reset_n=1;
  for(integer i=0;i<400;i++) begin
   @(negedge s_clk);s_valid=1;s_command=expected[i];
   do @(posedge s_clk);while(!s_ready);
   @(negedge s_clk);s_valid=0;
   do @(posedge s_clk);while(!(s_rsp_valid && s_rsp_ready));
   if(s_rsp_data!==reply(expected[i])) $fatal(1,"CDC response %0d",i);
  end
  @(negedge s_clk);
  if(accepted!=400) $fatal(1,"CDC count");
  expected[400]={171{1'b1}};
  s_valid=1;s_command=expected[400];
  do @(posedge s_clk);while(!s_ready);
  @(negedge s_clk);s_valid=0;
  wait(pending);@(negedge s_clk);s_reset_n=0;m_reset_n=0;
  repeat(5) @(negedge s_clk);s_reset_n=1;m_reset_n=1;
  repeat(5) @(negedge s_clk);
  if(s_rsp_valid || m_valid) $fatal(1,"CDC leaked a pre-reset transaction");
  s_valid=1;s_command=expected[0];
  do @(posedge s_clk);while(!s_ready);
  @(negedge s_clk);s_valid=0;
  do @(posedge s_clk);while(!(s_rsp_valid && s_rsp_ready));
  if(s_rsp_data!==reply(expected[0])) $fatal(1,"CDC reset recovery");
  $display("PASS teacher_cdc: 401 tagged replies, independent clocks, gaps, backpressure, in-flight reset cancellation and recovery");$finish;
 end
 initial begin #2000000;$fatal(1,"CDC timeout");end
endmodule
