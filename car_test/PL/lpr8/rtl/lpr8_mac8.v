// READ is external, then multiply_enable, then add_enable: one K per 3 clocks.
module teacher_mac8 (
    input wire clk, input wire reset_n,
    input wire load_bias, input wire [255:0] biases,
    input wire multiply_enable, input wire add_enable,
    input wire signed [8:0] feature, input wire [63:0] weights,
    output wire [255:0] sums, output wire overflow
);
    wire [7:0] overflow_lanes;
    genvar lane;
    generate for(lane=0; lane<8; lane=lane+1) begin: lanes
        reg signed [16:0] product;
        reg signed [31:0] accum;
        reg overflow_q;
        wire signed [7:0] weight=$signed(weights[lane*8+:8]);
        wire signed [32:0] next_sum=
            $signed({accum[31],accum})+$signed({{16{product[16]}},product});
        assign sums[lane*32+:32]=accum;
        assign overflow_lanes[lane]=overflow_q;
        always @(posedge clk or negedge reset_n) begin
            if(!reset_n) begin product<=0; accum<=0; overflow_q<=0; end
            else begin
                if(load_bias) accum<=$signed(biases[lane*32+:32]);
                else if(add_enable) begin
                    accum<=next_sum[31:0];
                    if(next_sum[32]!=next_sum[31]) overflow_q<=1;
                end
                if(multiply_enable) product<=feature*weight;
            end
        end
    end endgenerate
    assign overflow=|overflow_lanes;
endmodule
