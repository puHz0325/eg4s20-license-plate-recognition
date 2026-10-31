`timescale 1ns/1ps
`include "teacher_model_identity.vh"
module teacher_live_bridge_tb;
 reg clk=0;always #20 clk=~clk;
 reg reset_n=0,pc_rx_valid=0,pc_tx_ready=0,service_rx_ready=0,service_tx_valid=0;
 reg [7:0] pc_rx_data=0,service_tx_data=0,snapshot_data=0;
 reg service_idle=1,model_ready=1,camera_mode=1,snapshot_valid=1;
 reg [31:0] snapshot_frame=17;
 wire pc_tx_valid,service_rx_valid,service_tx_ready,snapshot_take,snapshot_release,snapshot_read,result_event,result_error,fault;
 wire [7:0] pc_tx_data,service_rx_data;wire [11:0] snapshot_addr;
 wire [31:0] result_frame,result_count;wire [4:0] result_length;wire [160:0] result_chars;
 teacher_camera_bridge dut(.*);
 reg [31:0] rng=32'h51273496;reg corrupt=0,wrong_model=0;
 integer released=0,results=0,forwarded=0,inferences=0;
 reg [7:0] packet[0:127];reg [31:0] roi_crc;
 function [31:0] crc_byte(input [31:0] prior,input [7:0] b);
  reg [31:0] t;begin t=prior^b;for(integer k=0;k<8;k++) t=t[0]?(t>>1)^32'hedb88320:t>>1;crc_byte=t;end
 endfunction
 function [7:0] pixel(input integer a);pixel=(a*19+(a>>7)*7)^'ha3;endfunction
 always @(negedge clk) begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  service_rx_ready=!service_tx_valid && rng[1:0]!=0;pc_tx_ready=rng[3:2]==0;
 end
 always @(posedge clk) if(reset_n) begin
  if(snapshot_read) snapshot_data<=pixel(snapshot_addr);
  if(snapshot_take) snapshot_valid<=0;
  if(snapshot_release) released++;
  if(pc_tx_valid && pc_tx_ready) begin
   if(dut.state==6 || dut.state==8) $fatal(1,"internal ACK leaked to PC");
   forwarded++;
  end
  if(result_event) begin
   results++;
   if(results==1 && (result_error || result_frame!=17 || result_length!=7 || result_chars[48:0]!=={7'd43,7'd40,7'd42,7'd39,7'd38,7'd41,7'd0})) $fatal(1,"camera result parse");
  end
 end
 task receive(output reg [7:0] value);
  do @(posedge clk);while(!(service_rx_valid && service_rx_ready));
  value=service_rx_data;@(negedge clk);
 endtask
 task ack(input [7:0] command);
  reg [31:0] crc;reg [48:0] plate;
  for(integer k=0;k<128;k++) packet[k]=0;
  packet[0]="T";packet[1]="C";packet[2]="H";packet[3]="1";packet[4]=command;
  packet[5]=command=="I" ? 'h23:3;packet[6]=command=="I" ? 7:0;
  for(integer k=0;k<4;k++) begin packet[8+k]=`TEACHER_MODEL_CRC32>>(k*8);packet[12+k]=roi_crc>>(k*8);end
  if(wrong_model && command=="V") packet[8]=packet[8]^1;
  plate={7'd43,7'd40,7'd42,7'd39,7'd38,7'd41,7'd0};
  for(integer k=0;k<7;k++) packet[24+k]=(plate>>(k*7))&127;
  crc='1;for(integer k=0;k<124;k++) crc=crc_byte(crc,packet[k]);crc=~crc;
  if(corrupt && command=="V") crc=crc^1;
  for(integer k=0;k<4;k++) packet[124+k]=crc>>(k*8);
  for(integer k=0;k<128;k++) begin
   @(negedge clk);service_tx_valid=1;service_tx_data=packet[k];
   do @(posedge clk);while(!service_tx_ready);
  end
  @(negedge clk);service_tx_valid=0;
 endtask
 initial begin : server
  reg [7:0] b;reg [31:0] crc,got;
  wait(reset_n);
  forever begin
   receive(b);service_idle=0;
   case(b)
    "W":begin
     for(integer k=1;k<6;k++) begin receive(b);if(b!==(k==3 ? 8'h14:k==5 ? 8'h01:8'h00)) $fatal(1,"W header %0d",k);end
     crc='1;
     for(integer k=0;k<4096;k++) begin receive(b);if(b!==pixel(k)) $fatal(1,"ROI payload %0d got %h",k,b);crc=crc_byte(crc,b);end
     got=0;for(integer k=0;k<4;k++) begin receive(b);got[k*8+:8]=b;end
     roi_crc=~crc;if(got!==roi_crc || released!=inferences) $fatal(1,"ROI CRC or early release");ack("W");
    end
    "V":ack("V");
    "I":begin inferences++;ack("I");end
    "B":begin camera_mode=0;ack("B");end
    "A":begin camera_mode=1;ack("A");end
    default:$fatal(1,"unexpected bridge command %h",b);
   endcase
   service_idle=1;
  end
 end
 task pc_byte(input [7:0] b);
  @(negedge clk);pc_rx_data=b;pc_rx_valid=1;@(negedge clk);pc_rx_valid=0;
 endtask
 initial begin
  repeat(4) @(negedge clk);reset_n=1;
  wait(dut.state==10);pc_byte("B");
  wait(results==1 && !camera_mode);wait(dut.state==0);repeat(3) @(negedge clk);
  if(forwarded!=256 || released!=1 || result_count!=1 || fault) $fatal(1,"first transaction accounting");
  wrong_model=$test$plusargs("WRONG_MODEL");corrupt=!wrong_model;
  snapshot_frame=18;snapshot_valid=1;pc_byte("A");
  wait(fault);repeat(10) @(negedge clk);
  if(inferences!=1 || released!=2 || results!=2 || !result_error) $fatal(1,"bad verify ACK did not stop inference");
  repeat(100) @(negedge clk);if(inferences!=1) $fatal(1,"fault did not stop auto mode");
  if(wrong_model) $display("PASS teacher_live_bridge: valid-packet wrong-model CRC blocked inference");
  else $display("PASS teacher_live_bridge: exact ROI/CRC, RAM latency, randomized stalls, W/V ACK suppression, I parsing, queued stop and corrupt-CRC gate");
  $finish;
 end
 initial begin #10000000;$fatal(1,"camera bridge timeout state=%0d",dut.state);end
endmodule
