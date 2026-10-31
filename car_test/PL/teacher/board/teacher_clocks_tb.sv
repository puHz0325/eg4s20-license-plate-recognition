`timescale 1ns/1ps
module teacher_clocks_tb;
    reg clk=0,reset=1;always #10 clk=~clk;
    wire locked,core_clk,shift_clk,unused;
    video_pll_core #(.C0DIV(12),.C1DIV(24),.C2DIV(24),.C2PHASE(35),.C3DIV(25))
        dut(clk,reset,locked,core_clk,shift_clk,unused);
    realtime t0,t1;
    initial begin
        #200;reset=0;wait(locked);#10000;
        @(posedge core_clk);t0=$realtime;@(posedge core_clk);t1=$realtime;
        if(t1-t0<39.98 || t1-t0>40.02) $fatal(1,"not 25MHz: %f",t1-t0);
        @(posedge core_clk);t0=$realtime;@(posedge shift_clk);t1=$realtime;
        if(t1-t0<19.98 || t1-t0>20.02) $fatal(1,"not 180deg: %f",t1-t0);
        $display("PASS teacher_clocks: native PLL 25MHz CNN/SDRAM and 180deg SDRAM shift");$finish;
    end
    initial begin #500000;$fatal(1,"PLL timeout");end
endmodule
