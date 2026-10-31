`timescale 1ns/1ps
module lpr_osd_tb;
 reg sc=0,pc=0,rn=0,fs=0;
 always #5 sc=~sc;always #7 pc=~pc;
 reg [127:0] offered=0;
 reg [11:0] x=0,y=0;
 reg hs=1,vs=1,de=0;
 wire ho,vo,dout;wire [23:0] rgb;
 lpr_osd dut(sc,rn,offered[49],offered[48:0],pc,rn,fs,x,y,hs,vs,de,24'h456789,ho,vo,dout,rgb,
  offered[110:107],offered[98:50],offered[103:99],offered[106:104],offered[117],offered[114:111],offered[116:115]);
 reg [127:0] cases[0:5];
 reg [23:0] expected[0:307199];
 integer file_id;
 task boundary;
  begin repeat(12) @(negedge pc);fs=1;@(negedge pc);fs=0;end
 endtask
 task scan(input integer number);
  begin
   $readmemh($sformatf("tmp/osd_validation/expected%0d.hex",number),expected);
   file_id=$fopen($sformatf("tmp/osd_validation/frame%0d.ppm",number),"w");
   $fdisplay(file_id,"P3\n640 480\n255");
   for(integer cy=0;cy<480;cy=cy+1) for(integer cx=0;cx<640;cx=cx+1) begin
    @(negedge pc);x=cx;y=cy;de=1;hs=cx[0];vs=cy[0];
    @(posedge pc);#1;
    if(rgb!==expected[cy*640+cx] || ho!==hs || vo!==vs || dout!==de)
     $fatal(1,"OSD oracle mismatch case=%0d x=%0d y=%0d got=%h expected=%h",number,cx,cy,rgb,expected[cy*640+cx]);
    $fdisplay(file_id,"%0d %0d %0d",rgb[23:16],rgb[15:8],rgb[7:0]);
   end
   $fclose(file_id);
   @(negedge pc);de=0;@(posedge pc);#1;
   if(dout!==0 || rgb!==24'h456789) $fatal(1,"OSD blanking latency");
  end
 endtask
 initial begin
  $readmemh("tmp/osd_validation/cases.hex",cases);
  repeat(5) @(negedge sc);rn=1;
  for(integer number=0;number<6;number=number+1) begin
   @(negedge sc);offered=cases[number];
   repeat(20) @(negedge pc);
   if(number!=0 && dut.visible_payload!==cases[number-1]) $fatal(1,"OSD changed mid-frame");
   boundary();if(dut.visible_payload!==offered) $fatal(1,"OSD mixed metadata and text");
   scan(number);
  end
  $display("PASS six full VGA OSD frames against independent Pillow oracle: raw short/illegal characters, length23, votes, confirmation and camera fault");
  @(negedge sc);offered=cases[2];repeat(12) @(negedge pc);
  @(negedge sc);offered=cases[3];fs=1;@(negedge pc);fs=0;
  if(dut.visible_payload!==cases[2]) $fatal(1,"Pending mailbox overwritten");
  boundary();if(dut.visible_payload!==cases[3]) $fatal(1,"Latest mailbox state lost");
  @(negedge sc);rn=0;repeat(4) @(negedge pc);
  if(dut.visible_payload!=0 || dout!=0) $fatal(1,"OSD reset");
  $display("PASS 128-bit atomic frame commit, rapid replacement, video sync alignment and reset");$finish;
 end
 initial begin #40000000;$fatal(1,"OSD watchdog");end
endmodule
