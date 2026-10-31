module uart_rx #(parameter CLKS_PER_BIT=434) (
    input wire clk, input wire rst_n, input wire rxd,
    output reg [7:0] data_out, output reg data_valid
);
    localparam IDLE=0, START=1, DATA=2, STOP=3;
    reg [1:0] state;
    reg [31:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;
    (* ASYNC_REG="TRUE" *) reg rx_meta,rx_sync;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin rx_meta<=1; rx_sync<=1; end
        else begin rx_meta<=rxd; rx_sync<=rx_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=IDLE; count<=0; bit_index<=0; shift<=0; data_out<=0; data_valid<=0; end
        else begin
            data_valid<=0;
            case(state)
                IDLE: if(!rx_sync) begin count<=0; state<=START; end
                START: begin
                    if(count==(CLKS_PER_BIT/2)-1) begin
                        count<=0;
                        if(!rx_sync) begin state<=DATA; bit_index<=0; end
                        else state<=IDLE;
                    end else count<=count+1'b1;
                end
                DATA: begin
                    if(count==CLKS_PER_BIT-1) begin
                        count<=0; shift[bit_index]<=rx_sync;
                        if(bit_index==7) state<=STOP;
                        else bit_index<=bit_index+1'b1;
                    end else count<=count+1'b1;
                end
                STOP: begin
                    if(count==CLKS_PER_BIT-1) begin
                        count<=0; state<=IDLE;
                        if(rx_sync) begin data_out<=shift; data_valid<=1; end
                    end else count<=count+1'b1;
                end
            endcase
        end
    end
endmodule
