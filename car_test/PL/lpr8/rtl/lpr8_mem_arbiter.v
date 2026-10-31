// Registered grant, held through response. A pending store gets next idle slot.
module teacher_mem_arbiter (
    input wire clk,input wire reset_n,
    input wire r_req_valid,output wire r_req_ready,input wire [22:0] r_req_addr,
    output wire r_rsp_valid,input wire r_rsp_ready,output wire [127:0] r_rsp_data,
    input wire w_req_valid,output wire w_req_ready,input wire [22:0] w_req_addr,
    input wire [127:0] w_req_data,input wire [15:0] w_req_strobe,
    output wire w_rsp_valid,input wire w_rsp_ready,
    output wire mem_req_valid,input wire mem_req_ready,output wire mem_req_write,
    output wire [22:0] mem_req_addr,output wire [127:0] mem_req_wdata,
    output wire [15:0] mem_req_wstrb,
    input wire mem_rsp_valid,output wire mem_rsp_ready,input wire [127:0] mem_rsp_rdata
);
    localparam IDLE=0,READ_REQ=1,READ_RSP=2,WRITE_REQ=3,WRITE_RSP=4;
    reg [2:0] state;
    assign mem_req_valid=state==READ_REQ ? r_req_valid : state==WRITE_REQ ? w_req_valid : 1'b0;
    assign mem_req_write=state==WRITE_REQ;
    assign mem_req_addr=state==WRITE_REQ ? w_req_addr:r_req_addr;
    assign mem_req_wdata=state==WRITE_REQ ? w_req_data:128'b0;
    assign mem_req_wstrb=state==WRITE_REQ ? w_req_strobe:16'b0;
    assign r_req_ready=state==READ_REQ && mem_req_ready;
    assign w_req_ready=state==WRITE_REQ && mem_req_ready;
    assign r_rsp_valid=state==READ_RSP && mem_rsp_valid;
    assign w_rsp_valid=state==WRITE_RSP && mem_rsp_valid;
    assign r_rsp_data=mem_rsp_rdata;
    assign mem_rsp_ready=state==READ_RSP ? r_rsp_ready:state==WRITE_RSP ? w_rsp_ready:1'b0;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) state<=IDLE;
        else case(state)
            IDLE: if(w_req_valid) state<=WRITE_REQ; else if(r_req_valid) state<=READ_REQ;
            READ_REQ: if(mem_req_valid && mem_req_ready) state<=READ_RSP;
            WRITE_REQ: if(mem_req_valid && mem_req_ready) state<=WRITE_RSP;
            READ_RSP,WRITE_RSP: if(mem_rsp_valid && mem_rsp_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
