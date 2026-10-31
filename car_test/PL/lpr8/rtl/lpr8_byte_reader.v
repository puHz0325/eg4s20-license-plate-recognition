// One-entry 16-byte read cache. Exactly one byte request/response outstanding.
module teacher_byte_reader (
    input wire clk,input wire reset_n,input wire invalidate,
    input wire byte_req_valid,output wire byte_req_ready,input wire [22:0] byte_addr,
    output wire byte_valid,input wire byte_ready,output reg [7:0] byte_data,
    output wire req_valid,input wire req_ready,output wire [22:0] req_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [127:0] rsp_data
);
    localparam IDLE=0,REQUEST=1,RESPONSE=2,DELIVER=3;
    reg [1:0] state;
    reg cache_valid;
    reg [18:0] cache_tag;
    reg [127:0] cache_data;
    reg [22:0] saved_addr;
    assign byte_req_ready=state==IDLE && !invalidate;
    assign byte_valid=state==DELIVER;
    assign req_valid=state==REQUEST;
    assign req_addr={saved_addr[22:4],4'b0};
    assign rsp_ready=state==RESPONSE;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; cache_valid<=0; cache_tag<=0; cache_data<=0;
            saved_addr<=0; byte_data<=0;
        end else begin
            if(invalidate) cache_valid<=0;
            case(state)
                IDLE: if(byte_req_valid && byte_req_ready) begin
                    saved_addr<=byte_addr;
                    if(cache_valid && cache_tag==byte_addr[22:4]) begin
                        byte_data<=cache_data[byte_addr[3:0]*8+:8]; state<=DELIVER;
                    end else state<=REQUEST;
                end
                REQUEST: if(req_ready) state<=RESPONSE;
                RESPONSE: if(rsp_valid) begin
                    cache_tag<=saved_addr[22:4]; cache_data<=rsp_data;
                    cache_valid<=!invalidate;
                    byte_data<=rsp_data[saved_addr[3:0]*8+:8]; state<=DELIVER;
                end
                DELIVER: if(byte_ready) state<=IDLE;
                default: begin state<=IDLE; cache_valid<=0; end
            endcase
        end
    end
endmodule
