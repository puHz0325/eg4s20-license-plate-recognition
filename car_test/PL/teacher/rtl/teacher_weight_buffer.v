// Dedicated simple dual-port block RAM per MAC lane. No reset of storage.
module teacher_weight_buffer (
    input wire clk,input wire write_enable,input wire [9:0] write_addr,input wire [7:0] write_data,
    input wire read_enable,input wire [9:0] read_addr,output reg [7:0] read_data
);
    (* ram_style="block" *) reg [7:0] memory[0:1023];
    always @(posedge clk) begin
        if(write_enable) memory[write_addr]<=write_data;
        if(read_enable) read_data<=memory[read_addr];
    end
endmodule
