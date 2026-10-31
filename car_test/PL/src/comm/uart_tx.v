module uart_tx #(parameter CLKS_PER_BIT=434) (
    input wire clk, input wire rst_n, input wire [7:0] data_in, input wire data_valid,
    output reg txd, output reg busy
);
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg [31:0] count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin txd<=1; busy<=0; shift<=10'h3ff; bit_index<=0; count<=0; end
        else if(!busy) begin
            txd<=1;
            if(data_valid) begin
                shift<={1'b1,data_in,1'b0}; bit_index<=0; count<=0; txd<=0; busy<=1;
            end
        end else if(count==CLKS_PER_BIT-1) begin
            count<=0;
            if(bit_index==9) begin busy<=0; txd<=1; end
            else begin bit_index<=bit_index+1'b1; shift<={1'b1,shift[9:1]}; txd<=shift[1]; end
        end else count<=count+1'b1;
    end
endmodule
