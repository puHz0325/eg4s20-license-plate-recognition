// Single outstanding command; preserve bytes via read-modify-write for masks.
module teacher_sdram_adapter # (parameter INIT_CYCLES=15000,REFRESH_CYCLES=150,SAMPLE_RISING=1)(
    input wire clk,input wire reset_n,input wire [2:0] read_delay,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [22:0] req_addr,input wire [127:0] req_wdata,input wire [15:0] req_wstrb,
    output wire rsp_valid,input wire rsp_ready,output reg [127:0] rsp_data,
    output wire initialized,output wire ras_n,cas_n,we_n,
    output wire [10:0] addr,output wire [1:0] ba,output wire [3:0] dm,
    inout wire [31:0] dq,output wire cke,cs_n
);
    localparam IDLE=0,READ_REQ=1,READ_WAIT=2,WRITE_REQ=3,WRITE_WAIT=4,RESPONSE=5;
    reg [2:0] state;
    reg [20:0] saved_addr;
    reg [127:0] saved_data,merged;
    reg [15:0] saved_strobe;
    reg saved_write;
    reg [2:0] saved_delay;
    wire ctrl_ready,ctrl_done;
    wire [127:0] ctrl_data;
    integer b;
    assign req_ready=state==IDLE && initialized;
    assign rsp_valid=state==RESPONSE;
    teacher_sdram_controller #(.INIT_CYCLES(INIT_CYCLES),.REFRESH_CYCLES(REFRESH_CYCLES),.SAMPLE_RISING(SAMPLE_RISING)) controller(
        .clk(clk),.reset_n(reset_n),.read_delay(saved_delay),.request_valid(state==READ_REQ || state==WRITE_REQ),
        .request_ready(ctrl_ready),.request_write(state==WRITE_REQ),.request_addr(saved_addr),
        .request_data(merged),.done(ctrl_done),.read_data(ctrl_data),.initialized(initialized),
        .ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.addr(addr),.ba(ba),.dm(dm),.dq(dq),.cke(cke),.cs_n(cs_n));
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin state<=IDLE; saved_addr<=0; saved_data<=0; merged<=0; saved_strobe<=0; saved_write<=0; rsp_data<=0;saved_delay<=3;end
        else case(state)
            IDLE: if(req_valid && req_ready) begin
                saved_addr<=req_addr[22:2]; saved_data<=req_wdata; saved_strobe<=req_wstrb;
                saved_write<=req_write;
                saved_delay<=read_delay;
                if(req_write && req_wstrb==16'hffff) begin merged<=req_wdata; state<=WRITE_REQ; end
                else state<=READ_REQ;
            end
            READ_REQ: if(ctrl_ready) state<=READ_WAIT;
            READ_WAIT: if(ctrl_done) begin
                rsp_data<=ctrl_data;
                if(saved_write) begin
                    for(b=0;b<16;b=b+1) merged[b*8+:8]<=saved_strobe[b] ? saved_data[b*8+:8]:ctrl_data[b*8+:8];
                    state<=WRITE_REQ;
                end else state<=RESPONSE;
            end
            WRITE_REQ: if(ctrl_ready) state<=WRITE_WAIT;
            WRITE_WAIT: if(ctrl_done) state<=RESPONSE;
            RESPONSE: if(rsp_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
