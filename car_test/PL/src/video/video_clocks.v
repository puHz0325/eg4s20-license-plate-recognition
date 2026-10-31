// Two native EG4 PLLs: SDRAM 75 MHz / shifted 75 MHz / camera 24 MHz;
// display 25 MHz and 125 MHz. VGA totals 800x525 -> 59.524 Hz.
module video_pll_core #(parameter C0DIV=12,C1DIV=8,C2DIV=8,C2PHASE=11,C3DIV=25)(
    input wire clk,input wire reset,output wire locked,output wire c1,c2,c3
);
    wire feedback_raw,feedback;
    wire [4:0] clocks;
    assign feedback_raw=clocks[0];
    assign c1=clocks[1]; assign c2=clocks[2]; assign c3=clocks[3];
    EG_LOGIC_BUFG fb(.i(feedback_raw),.o(feedback));
    EG_PHY_PLL #(.DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000"),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),.STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),.DERIVE_PLL_CLOCKS("DISABLE"),
        .GEN_BASIC_CLOCK("DISABLE"),.GMC_GAIN(2),.ICP_CURRENT(9),.KVCO(2),
        .LPF_CAPACITOR(1),.LPF_RESISTOR(8),.REFCLK_DIV(1),.FBCLK_DIV(1),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(C0DIV),.CLKC0_CPHASE(C0DIV-1),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(C1DIV),.CLKC1_CPHASE(C1DIV-1),.CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(C2DIV),.CLKC2_CPHASE(C2PHASE),.CLKC2_FPHASE(0),
        .CLKC3_ENABLE("ENABLE"),.CLKC3_DIV(C3DIV),.CLKC3_CPHASE(C3DIV-1),.CLKC3_FPHASE(0)
    ) pll(.refclk(clk),.reset(reset),.stdby(1'b0),.extlock(locked),.load_reg(1'b0),
        .psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'b0),.dclk(1'b0),
        .dcs(1'b0),.dwe(1'b0),.di(8'b0),.daddr(6'b0),.fbclk(feedback),.clkc(clocks));
endmodule

module video_clocks(input wire clk_50m,input wire reset_n,
    output wire mem_clk,mem_clk_shift,cam_xclk,pixel_clk,serial_clk,output wire locked);
    wire lm,lv,unused;
    video_pll_core memory_pll(clk_50m,!reset_n,lm,mem_clk,mem_clk_shift,cam_xclk);
    video_pll_core #(.C0DIV(20),.C1DIV(40),.C2DIV(8),.C2PHASE(7),.C3DIV(40))
        display_pll(clk_50m,!reset_n,lv,pixel_clk,serial_clk,unused);
    assign locked=lm && lv;
endmodule
