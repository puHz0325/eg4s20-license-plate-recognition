`timescale 1ns/1ps
// Transaction-level SDRAM stand-in, not the physical SDRAM command model.
module teacher_memory_model #(parameter MEM_BYTES=2097152) (
    input wire clk,input wire reset_n,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [22:0] req_addr,input wire [127:0] req_wdata,input wire [15:0] req_wstrb,
    output reg rsp_valid,input wire rsp_ready,output reg [127:0] rsp_rdata,
    output reg [31:0] reads,writes
);
    reg [7:0] bytes[0:MEM_BYTES-1];
    reg pending,saved_write;
    reg [22:0] saved_addr;
    reg [127:0] saved_data;
    reg [15:0] saved_strobe;
    reg [31:0] lfsr;
    integer delay_count,clock_count;
    integer extra_latency=0;
    initial void'($value$plusargs("EXTRA_LATENCY=%d",extra_latency));
    // Short periodic blackout plus random gaps exercises refill under contention.
    wire blackout=clock_count%4096<29;
    assign req_ready=!pending && !rsp_valid && lfsr[1:0]!=0 && !blackout;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            pending<=0; saved_write<=0; saved_addr<=0; saved_data<=0; saved_strobe<=0;
            rsp_valid<=0; rsp_rdata<=0; lfsr<=32'h9c61ab73;
            delay_count<=0; clock_count<=0; reads<=0; writes<=0;
        end else begin
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            clock_count<=clock_count+1;
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            if(req_valid && req_ready) begin
                if(req_addr[3:0]!=0 || req_addr+16>MEM_BYTES) $fatal(1,"invalid burst address %h",req_addr);
                if(req_write && req_wstrb==0) $fatal(1,"empty write");
                saved_addr<=req_addr; saved_data<=req_wdata; saved_strobe<=req_wstrb;
                saved_write<=req_write; pending<=1; delay_count<=2+lfsr[7:4]+extra_latency;
            end
            if(pending && !blackout) begin
                if(delay_count!=0) delay_count<=delay_count-1;
                else begin
                    pending<=0; rsp_valid<=1;
                    if(saved_write) begin
                        for(integer b=0;b<16;b++) if(saved_strobe[b]) bytes[saved_addr+b]<=saved_data[b*8+:8];
                        writes<=writes+1;
                        rsp_rdata<=0;
                    end else begin
                        for(integer b=0;b<16;b++) rsp_rdata[b*8+:8]<=bytes[saved_addr+b];
                        reads<=reads+1;
                    end
                end
            end
        end
    end
endmodule
