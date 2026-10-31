// One ten-bit TMDS symbol, LSB first, five DDR cycles. Related clocks are required.
module tmds_serializer(input wire serial_clk,input wire reset_n,
    input wire [9:0] symbol,output wire serial_out);
    reg [2:0] pair_index;
    reg [9:0] shift;
    reg [1:0] pair_bits;
    // Prepare both bits half a serial clock before the ODDR capture edge.
    // This also separates pixel-clock symbol updates from the I/O hold window.
    always @(negedge serial_clk or negedge reset_n) begin
        if(!reset_n) begin pair_index<=0; shift<=0; pair_bits<=0; end
        else begin
            pair_bits<=pair_index==0 ? symbol[1:0]:shift[1:0];
            if(pair_index==4) pair_index<=0; else pair_index<=pair_index+1'b1;
            if(pair_index==0) shift<={2'b0,symbol[9:2]}; else shift<={2'b0,shift[9:2]};
        end
    end
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) ddr(
        .q(serial_out),.clk(serial_clk),.d0(pair_bits[0]),.d1(pair_bits[1]),.rst(!reset_n));
endmodule
