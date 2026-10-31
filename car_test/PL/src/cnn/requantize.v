module requantize (
    input wire signed [31:0] accum, input wire [3:0] shift, input wire relu,
    output reg signed [15:0] value
);
    reg [14:0] rounding_bias;
    reg signed [32:0] biased,rounded;
    always @(*) begin
        // Arithmetic shift rounds toward -infinity. For shift>0, adding
        // half minus the sign bit gives nearest, ties away from zero.
        // The 33-bit sum also handles INT32_MIN/MAX without overflow.
        if(shift==0) rounding_bias=0;
        else rounding_bias=(15'd1<<(shift-1'b1))-{14'd0,accum[31]};
        biased=$signed({accum[31],accum})+$signed({18'd0,rounding_bias});
        rounded=biased>>>shift;
        if(relu) begin
            if(rounded[32]) value=16'sd0;
            else if(|rounded[31:8]) value=16'sd255;
            else value={8'd0,rounded[7:0]};
        end else begin
            if(rounded[32] && !(&rounded[31:15])) value=16'sh8000;
            else if(!rounded[32] && |rounded[31:15]) value=16'sd32767;
            else value=rounded[15:0];
        end
    end
endmodule
