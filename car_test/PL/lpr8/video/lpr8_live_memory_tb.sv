`timescale 1ns/1ps
module teacher_live_memory_tb;
 reg clk=0;always #6.666667 clk=~clk;
 reg reset_n=0,frame_valid=0,frame_write=0,cnn_valid=0,cnn_rsp_ready=0;
 reg [20:0] frame_addr=0;reg [127:0] frame_data=0;reg [170:0] cnn_command=0;
 wire frame_ready,frame_done,cnn_ready,cnn_rsp_valid,initialized,ras_n,cas_n,we_n,cke,cs_n;
 wire [127:0] frame_read_data,cnn_rsp_data;wire [2:0] active_read_delay;
 wire [10:0] addr;wire [1:0] ba;wire [3:0] dm;wire [31:0] dq;
 teacher_video_memory #(.INIT_CYCLES(20),.REFRESH_CYCLES(450)) dut(.*);
 video_sdram_model #(.WORDS(524288),.MAX_REFRESH_CYCLES(585)) memory(!clk,reset_n,cke,cs_n,ras_n,cas_n,we_n,addr,ba,dm,dq);
 function [127:0] pattern(input integer n);
  pattern={32'(n*17+5),32'(n^'h51827),32'(n*19+3),32'(~n)};
 endfunction
 function [127:0] mixed(input integer n);
  reg [127:0] first,last;
  begin first=pattern(n+500);last=pattern(n+900);mixed={first[127:64],last[63:0]};end
 endfunction
 task frame_op(input bit wr,input integer a,input bit [127:0] d,input bit [127:0] expected);
  @(negedge clk);frame_valid=1;frame_write=wr;frame_addr=a/4;frame_data=d;
  do @(posedge clk);while(!frame_ready);
  @(negedge clk);frame_valid=0;frame_addr='1;frame_data='1;
  wait(frame_done);@(negedge clk);
  if(!wr && frame_read_data!==expected) $fatal(1,"frame memory address=%h got=%h expected=%h",a,frame_read_data,expected);
 endtask
 task cnn_op(input bit wr,input integer a,input bit [127:0] d,input bit [15:0] mask,input bit [127:0] expected);
  @(negedge clk);cnn_valid=1;cnn_command={3'd3,wr,23'(a),d,mask};
  do @(posedge clk);while(!cnn_ready);
  @(negedge clk);cnn_valid=0;cnn_command='1;
  wait(cnn_rsp_valid);repeat(11) @(negedge clk);
  if(!cnn_rsp_valid || (!wr && cnn_rsp_data!==expected)) $fatal(1,"CNN memory address=%h got=%h expected=%h",a,cnn_rsp_data,expected);
  cnn_rsp_ready=1;@(negedge clk);cnn_rsp_ready=0;
 endtask
 integer frame_transactions=0,cnn_transactions=0,consecutive=0;reg last_owner;
 always @(posedge clk) if(reset_n && dut.req_valid && dut.req_ready) begin
  if(dut.state==1) frame_transactions++;
  else cnn_transactions++;
  if(frame_valid && cnn_valid && consecutive>4) $fatal(1,"memory client starved");
  if(last_owner==(dut.state==3)) consecutive++;else consecutive=0;
  last_owner=dut.state==3;
 end
 initial begin
  repeat(4) @(negedge clk);reset_n=1;wait(initialized);
  fork
   begin
    for(integer i=0;i<192;i++) begin
     frame_op(1,i*16,pattern(i),0);
     frame_op(0,i*16,0,pattern(i));
    end
   end
   begin
    for(integer i=0;i<192;i++) begin
     cnn_op(1,'h100000+i*16,pattern(i+500),16'hffff,0);
     cnn_op(1,'h100000+i*16,pattern(i+900),16'h00ff,0);
     cnn_op(0,'h100000+i*16,0,0,mixed(i));
    end
   end
  join
  if(frame_transactions!=384 || cnn_transactions!=576 || memory.refreshes<20 || active_read_delay!=3) $fatal(1,"memory coverage");
  $display("PASS teacher_live_memory: concurrent video/CNN, 960 transactions, RMW masks, stable capture, fair arbitration, refresh and response stalls");$finish;
 end
 initial begin #5000000;$fatal(1,"live memory timeout");end
endmodule
