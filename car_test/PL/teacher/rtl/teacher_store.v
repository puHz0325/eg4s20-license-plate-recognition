// Write 1..16 consecutive bytes; split at burst boundary, wait for every ACK.
module teacher_store (
    input wire clk,input wire reset_n,
    input wire start,output wire ready,input wire [22:0] address,
    input wire [127:0] data,input wire [4:0] count,output reg done,
    output wire req_valid,input wire req_ready,output wire [22:0] req_addr,
    output wire [127:0] req_data,output wire [15:0] req_strobe,
    input wire rsp_valid,output wire rsp_ready
);
    localparam IDLE=0,REQUEST=1,RESPONSE=2;
    reg [1:0] state;
    reg [22:0] saved_addr;
    reg [255:0] expanded_data;
    reg [31:0] expanded_mask;
    assign ready=state==IDLE;
    assign req_valid=state==REQUEST;
    assign req_addr=saved_addr;
    assign req_data=expanded_data[127:0];
    assign req_strobe=expanded_mask[15:0];
    assign rsp_ready=state==RESPONSE;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; saved_addr<=0; expanded_data<=0; expanded_mask<=0; done<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    saved_addr<={address[22:4],4'b0};
                    expanded_data<={128'b0,data}<<(address[3:0]*8);
                    expanded_mask<=((32'h1<<count)-1'b1)<<address[3:0];
                    state<=REQUEST;
                end
                REQUEST: if(req_ready) state<=RESPONSE;
                RESPONSE: if(rsp_valid) begin
                    if(|expanded_mask[31:16]) begin
                        saved_addr<=saved_addr+23'd16;
                        expanded_data<=expanded_data>>128; expanded_mask<=expanded_mask>>16;
                        state<=REQUEST;
                    end else begin state<=IDLE; done<=1; end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
