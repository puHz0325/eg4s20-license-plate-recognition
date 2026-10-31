// Diagnostic-specific controller with runtime read-wait calibration.
// 2M x 32 SDR SDRAM, geometry: bank[20:19], row[18:8], column[7:0].
// Commands are sampled on the opposite clock edge (phase-shifted memory clock).
// One aligned 4-word burst per request; ready/valid acceptance, done exactly once.
module teacher_sdram_controller #(parameter INIT_CYCLES=15000, REFRESH_CYCLES=150,SAMPLE_RISING=1)(
    input wire clk,input wire reset_n,input wire [2:0] read_delay,
    input wire request_valid,output wire request_ready,input wire request_write,
    input wire [20:0] request_addr,input wire [127:0] request_data,
    output reg done,output reg [127:0] read_data,output reg initialized,
    output reg ras_n,cas_n,we_n,output reg [10:0] addr,output reg [1:0] ba,
    output wire [3:0] dm,inout wire [31:0] dq,output wire cke,cs_n
);
    localparam INIT=0,IPRE=1,IWAIT=2,IREF1=3,IREF2=4,IMODE=5,IDLE=6,
        ACT=7,ACTWAIT=8,WCMD=9,WDATA=10,WREC=11,RCMD=12,RWAIT=13,
        RDATA=14,PRE=15,PWAIT=16,REF=17,REFWAIT=18;
    reg [4:0] state,next_wait;
    reg [15:0] delay_count,refresh_count;
    reg [20:0] saved_addr;
    reg [127:0] saved_data;
    reg saved_write;
    reg [1:0] word_index;
    reg [31:0] write_dq;
    reg dq_enable;
    // Legacy video keeps falling-edge capture. The diagnostic clock uses rising-
    // edge capture, half a clock after SDRAM launch. Its old value is consumed by
    // the result register on the next rising edge, preserving the CAS3 schedule.
    reg [31:0] sampled_dq;
    generate if(SAMPLE_RISING) begin: rising_capture
        always @(posedge clk) sampled_dq<=dq;
    end else begin: falling_capture
        always @(negedge clk) sampled_dq<=dq;
    end endgenerate
    assign dq=dq_enable ? write_dq:32'bz;
    assign dm=4'b0;
    assign cke=reset_n;
    assign cs_n=1'b0;
    assign request_ready=state==IDLE && refresh_count<REFRESH_CYCLES;
    always @(*) begin
        ras_n=1; cas_n=1; we_n=1; addr=0; ba=saved_addr[20:19];
        case(state)
            IPRE,PRE: begin ras_n=0; we_n=0; addr[10]=1; end
            IREF1,IREF2,REF: begin ras_n=0; cas_n=0; end
            IMODE: begin ras_n=0; cas_n=0; we_n=0; ba=0; addr=11'h032; end
            ACT: begin ras_n=0; addr=saved_addr[18:8]; end
            WCMD: begin cas_n=0; we_n=0; addr={3'b000,saved_addr[7:0]}; end
            RCMD: begin cas_n=0; addr={3'b000,saved_addr[7:0]}; end
            default: begin end
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=INIT; next_wait<=0; delay_count<=INIT_CYCLES-1; refresh_count<=0;
            saved_addr<=0; saved_data<=0; saved_write<=0; word_index<=0;
            write_dq<=0; dq_enable<=0;
            done<=0; initialized<=0; read_data<=0;
        end else begin
            done<=0;
            if(initialized && refresh_count<65535) refresh_count<=refresh_count+1'b1;
            case(state)
                INIT: if(delay_count==0) state<=IPRE; else delay_count<=delay_count-1'b1;
                IPRE: begin state<=IWAIT; delay_count<=2; next_wait<=IREF1; end
                IWAIT: if(delay_count==0) state<=next_wait; else delay_count<=delay_count-1'b1;
                IREF1: begin state<=IWAIT; delay_count<=7; next_wait<=IREF2; end
                IREF2: begin state<=IWAIT; delay_count<=7; next_wait<=IMODE; end
                IMODE: begin state<=IWAIT; delay_count<=2; next_wait<=IDLE; initialized<=1; refresh_count<=0; end
                IDLE: begin
                    if(refresh_count>=REFRESH_CYCLES) state<=REF;
                    else if(request_valid) begin
                        saved_addr<={request_addr[20:2],2'b00}; saved_data<=request_data;
                        write_dq<=request_data[31:0];
                        saved_write<=request_write; word_index<=0; state<=ACT;
                    end
                end
                ACT: begin state<=ACTWAIT; delay_count<=1; end
                ACTWAIT: if(delay_count==0) begin state<=saved_write ? WCMD:RCMD; dq_enable<=saved_write; end
                         else delay_count<=delay_count-1'b1;
                WCMD: begin
                    word_index<=1; state<=WDATA; write_dq<=saved_data[63:32]; saved_data<=saved_data>>32;
                end
                WDATA: if(word_index==3) begin state<=WREC; delay_count<=2; dq_enable<=0; end
                       else begin
                           word_index<=word_index+1'b1;
                           write_dq<=saved_data[63:32]; saved_data<=saved_data>>32;
                       end
                WREC: if(delay_count==0) state<=PRE; else delay_count<=delay_count-1'b1;
                RCMD: begin state<=RWAIT; delay_count<=read_delay; end
                RWAIT: if(delay_count==0) begin read_data[31:0]<=sampled_dq; word_index<=1; state<=RDATA; end
                       else delay_count<=delay_count-1'b1;
                RDATA: begin
                    read_data[word_index*32+:32]<=sampled_dq;
                    if(word_index==3) state<=PRE; else word_index<=word_index+1'b1;
                end
                PRE: begin state<=PWAIT; delay_count<=1; end
                PWAIT: if(delay_count==0) begin done<=1; state<=IDLE; end else delay_count<=delay_count-1'b1;
                REF: begin refresh_count<=0; state<=REFWAIT; delay_count<=7; end
                REFWAIT: if(delay_count==0) state<=IDLE; else delay_count<=delay_count-1'b1;
                default: begin state<=INIT; delay_count<=INIT_CYCLES-1; initialized<=0; end
            endcase
        end
    end
endmodule
