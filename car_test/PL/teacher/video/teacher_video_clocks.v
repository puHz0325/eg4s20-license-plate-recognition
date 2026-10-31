module teacher_video_clocks(input wire clk_50m,reset_n,
 output wire mem_clk,mem_shift,cam_xclk,core_clk,serial_clk,output wire locked);
 wire lm,lv,unused;
 video_pll_core #(.C0DIV(12),.C1DIV(8),.C2DIV(8),.C2PHASE(11),.C3DIV(25))
  memory_pll(clk_50m,!reset_n,lm,mem_clk,mem_shift,cam_xclk);
 video_pll_core #(.C0DIV(20),.C1DIV(40),.C2DIV(8),.C2PHASE(7),.C3DIV(40))
  display_pll(clk_50m,!reset_n,lv,core_clk,serial_clk,unused);
 assign locked=lm && lv;
endmodule
