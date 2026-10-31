module teacher_board_top(
    input wire clk_50m,input wire rst_n,input wire uart_rxd,
    output wire uart_txd,output wire [3:0] status_led
);
    wire clk,shift_clk,unused,locked,reset_n;
    video_pll_core #(.C0DIV(12),.C1DIV(24),.C2DIV(24),.C2PHASE(35),.C3DIV(25))
        clocks(clk_50m,!rst_n,locked,clk,shift_clk,unused);
    video_reset reset_sync(clk,rst_n && locked,reset_n);
    wire rx_valid,tx_valid,tx_busy,initialized,model_ready,busy,error;
    wire [7:0] rx_data,tx_data;
    wire [2:0] read_delay;
    uart_rx #(.CLKS_PER_BIT(217)) receiver(clk,reset_n,uart_rxd,rx_data,rx_valid);
    uart_tx #(.CLKS_PER_BIT(217)) transmitter(clk,reset_n,tx_data,tx_valid && !tx_busy,uart_txd,tx_busy);
    wire req_valid,req_ready,req_write,rsp_valid,rsp_ready;
    wire [22:0] req_addr;
    wire [127:0] req_wdata,rsp_data;
    wire [15:0] req_wstrb;
    teacher_board_service service(.clk(clk),.reset_n(reset_n),.initialized(initialized),
        .rx_valid(rx_valid),.rx_data(rx_data),.tx_valid(tx_valid),.tx_ready(!tx_busy),.tx_data(tx_data),
        .model_ready(model_ready),.busy(busy),.error(error),.read_delay(read_delay),.video_status(128'b0),
        .mem_req_valid(req_valid),.mem_req_ready(req_ready),.mem_req_write(req_write),.mem_req_addr(req_addr),
        .mem_req_wdata(req_wdata),.mem_req_wstrb(req_wstrb),.mem_rsp_valid(rsp_valid),.mem_rsp_ready(rsp_ready),.mem_rsp_rdata(rsp_data));
    wire ras_n,cas_n,we_n,cke,cs_n;
    wire [10:0] addr;
    wire [1:0] ba;
    wire [3:0] dm;
    wire [31:0] dq;
    teacher_sdram_adapter adapter(.clk(clk),.reset_n(reset_n),.read_delay(read_delay),.req_valid(req_valid),.req_ready(req_ready),
        .req_write(req_write),.req_addr(req_addr),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.initialized(initialized),
        .ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.addr(addr),.ba(ba),.dm(dm),.dq(dq),.cke(cke),.cs_n(cs_n));
    EG_PHY_SDRAM_2M_32 memory(.clk(shift_clk),.ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),
        .addr(addr),.ba(ba),.dq(dq),.cs_n(cs_n),.cke(cke),.dm0(dm[0]),.dm1(dm[1]),.dm2(dm[2]),.dm3(dm[3]));
    assign status_led={error,busy,model_ready,initialized};
endmodule
