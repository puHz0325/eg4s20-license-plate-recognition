`timescale 1ns/1ps
module lpr_health_tb;
 reg clk=0,rn=0,cfg=0,fault=0,mem=0,frame=0,event_in=0,error=0,confirmed=0;
 always #5 clk=~clk;
 reg [4:0] length=0;
 reg [160:0] chars=0;
 wire [3:0] state;
 wire shown,fa,ra,valid;
 wire [4:0] last_length;
 wire [48:0] last_chars;
 lpr_health #(.CLK_HZ(1000),.TIMEOUT_MS(20)) dut(clk,rn,cfg,fault,mem,frame,event_in,length,chars,error,confirmed,
  state,shown,fa,ra,last_length,last_chars,valid);
 reg [48:0] plate;
 task check(input integer expected);
  begin #1;if(state!==expected) $fatal(1,"Health state got %0d expected %0d",state,expected);end
 endtask
 task image;
  begin @(negedge clk);frame=1;@(negedge clk);frame=0;end
 endtask
 task result(input integer n,input bit bad);
  begin @(negedge clk);event_in=1;length=n;chars=plate;error=bad;@(negedge clk);event_in=0;end
 endtask
 initial begin
  plate={7'd39,7'd46,7'd39,7'd54,7'd39,7'd53,7'd0};
  repeat(3) @(negedge clk);rn=1;check(0);
  fault=1;check(1);fault=0;cfg=1;check(2);mem=1;check(3);
  image();check(4);result(2,0);check(5);
  if(last_length!=2 || last_chars!=plate || valid) $fatal(1,"Raw invalid candidate was hidden or accepted");
  result(7,0);check(6);if(!valid) $fatal(1,"Valid format not reported");
  confirmed=1;check(7);if(!shown) $fatal(1,"Confirmed plate not shown");
  result(7,1);check(9);if(shown) $fatal(1,"Engine error showed confirmed plate");
  confirmed=0;result(7,0);
  repeat(12) @(negedge clk);image();repeat(9) @(negedge clk);
  check(8);if(last_length!=0 || ra) $fatal(1,"Expired candidate remained active");
  repeat(22) @(negedge clk);check(3);
  image();result(7,0);confirmed=1;check(7);
  fault=1;check(1);@(negedge clk);
  if(shown || last_length!=0 || fa || ra) $fatal(1,"Camera fault retained recognition state");
  fault=0;cfg=0;check(0);cfg=1;check(3);
  $display("PASS health priority: init, camera fault, memory wait, no frame, no result, invalid, pending, confirmed, stale and engine fault");
  $display("PASS raw length/text visibility, heartbeat expiry, stale candidate clearing and camera-fault invalidation");
  $finish;
 end
 initial begin #100000;$fatal(1,"Health timeout");end
endmodule
