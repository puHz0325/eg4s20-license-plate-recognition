// UART byte protocol, model CRC, inference, and physical-memory layer CRCs.
`include "lpr8_model_identity.vh"
module teacher_board_service #(parameter CLOCK_HZ=25000000,VIDEO_STATUS=0)(
    input wire clk,input wire reset_n,input wire initialized,
    input wire rx_valid,input wire [7:0] rx_data,output wire rx_ready,output wire command_idle,
    output wire tx_valid,input wire tx_ready,output reg [7:0] tx_data,
    output reg model_ready,output wire busy,output wire error,output reg [2:0] read_delay,output reg camera_mode,
    input wire [127:0] video_status,
    output wire mem_req_valid,input wire mem_req_ready,output wire mem_req_write,
    output wire [22:0] mem_req_addr,output wire [127:0] mem_req_wdata,output wire [15:0] mem_req_wstrb,
    input wire mem_rsp_valid,output wire mem_rsp_ready,input wire [127:0] mem_rsp_rdata
);
    localparam IDLE=0,ADDRESS=1,LENGTH=2,UPLOAD=3,WRITE_REQ=4,WRITE_WAIT=5,UPLOAD_CRC=6,
        SCAN_REQ=7,SCAN_WAIT=8,SCAN_BYTES=9,INFER_START=10,INFER_WAIT=11,TRANSMIT=12,
        TIMING=13,RAW_REQ=14,RAW_WAIT=15;
    reg [3:0] state;
    reg [7:0] command;
    reg [1:0] field_index;
    reg [3:0] byte_index;
    reg [22:0] upload_addr,scan_addr;
    reg [15:0] upload_blocks;
    reg [13:0] scan_blocks;
    reg [127:0] block_data;
    reg [31:0] crc,expected_crc,model_crc,upload_crc,packet_crc;
    reg [6:0] tx_index;
    reg protocol_error,scan_overrun,finished,scan_model;
    reg [2:0] scan_layer;
    reg [255:0] layer_crc,layer_cycles,characters;
    reg [5:0] character_count;
    wire core_start_ready,core_done,core_error,core_char_valid,core_layer_done;
    wire [6:0] core_char;
    wire [5:0] core_length;
    wire [2:0] core_layer;
    wire [31:0] core_cycles,core_wait;
    wire c_valid,c_ready,c_write,c_rsp_valid,c_rsp_ready;
    wire [22:0] c_addr;
    wire [127:0] c_wdata;
    wire [15:0] c_strobe;
    teacher_inference core(.clk(clk),.reset_n(reset_n),.model_ready(model_ready),
        .start(state==INFER_START),.start_ready(core_start_ready),.busy(busy),.done(core_done),.error(core_error),
        .char_valid(core_char_valid),.char_ready(1'b1),.char_data(core_char),.result_length(core_length),
        .layer_done(core_layer_done),.completed_layer(core_layer),.cycles(core_cycles),.prefetch_wait_cycles(core_wait),
        .mem_req_valid(c_valid),.mem_req_ready(c_ready),.mem_req_write(c_write),.mem_req_addr(c_addr),
        .mem_req_wdata(c_wdata),.mem_req_wstrb(c_strobe),.mem_rsp_valid(c_rsp_valid),.mem_rsp_ready(c_rsp_ready),.mem_rsp_rdata(mem_rsp_rdata));
    assign error=core_error || protocol_error || scan_overrun;
    assign command_idle=state==IDLE;
    assign rx_ready=state==IDLE || state==ADDRESS || state==LENGTH || state==UPLOAD || state==UPLOAD_CRC || state==TIMING;
    function [31:0] crc_byte;
        input [31:0] prior; input [7:0] data;
        reg [31:0] temp; integer j;
        begin
            temp=prior^{24'b0,data};
            for(j=0;j<8;j=j+1) temp=temp[0] ? (temp>>1)^32'hedb88320:temp>>1;
            crc_byte=temp;
        end
    endfunction
    function [13:0] layer_blocks;
        input [2:0] layer;
        begin case(layer)
            0:layer_blocks=4096;1:layer_blocks=1024;2:layer_blocks=512;3:layer_blocks=768;
            4:layer_blocks=512;5:layer_blocks=128;6:layer_blocks=256;7:layer_blocks=272;
        endcase end
    endfunction
    wire h_valid=state==WRITE_REQ || state==SCAN_REQ || state==RAW_REQ;
    wire h_ready,h_rsp_valid;
    wire h_rsp_ready=state==WRITE_WAIT || state==SCAN_WAIT || state==RAW_WAIT;
    // Hold selection until ACK; both request payloads remain stable under stalls.
    localparam A_IDLE=0,H_REQ=1,H_RSP=2,C_REQ=3,C_RSP=4;
    reg [2:0] owner;
    assign mem_req_valid=owner==H_REQ ? h_valid:owner==C_REQ ? c_valid:1'b0;
    assign mem_req_write=owner==H_REQ ? state==WRITE_REQ:owner==C_REQ ? c_write:1'b0;
    assign mem_req_addr=owner==H_REQ ? (state==WRITE_REQ || state==RAW_REQ ? upload_addr:scan_addr):c_addr;
    assign mem_req_wdata=owner==H_REQ ? (state==WRITE_REQ ? block_data:128'b0):owner==C_REQ ? c_wdata:128'b0;
    assign mem_req_wstrb=owner==H_REQ ? (state==WRITE_REQ ? 16'hffff:16'b0):owner==C_REQ ? c_strobe:16'b0;
    assign h_ready=owner==H_REQ && mem_req_ready;
    assign c_ready=owner==C_REQ && mem_req_ready;
    assign h_rsp_valid=owner==H_RSP && mem_rsp_valid;
    assign c_rsp_valid=owner==C_RSP && mem_rsp_valid;
    assign mem_rsp_ready=owner==H_RSP ? h_rsp_ready:owner==C_RSP ? c_rsp_ready:1'b0;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) owner<=A_IDLE;
        else case(owner)
            A_IDLE: if(h_valid) owner<=H_REQ; else if(c_valid) owner<=C_REQ;
            H_REQ: if(mem_req_valid && mem_req_ready) owner<=H_RSP;
            C_REQ: if(mem_req_valid && mem_req_ready) owner<=C_RSP;
            H_RSP,C_RSP: if(mem_rsp_valid && mem_rsp_ready) owner<=A_IDLE;
            default: owner<=A_IDLE;
        endcase
    end
    localparam [1:0] CLOCK_CODE=CLOCK_HZ==25000000 ? 2'd1:2'd0;
    wire [7:0] flags={CLOCK_CODE,finished,scan_overrun,protocol_error,core_error,model_ready,initialized};
    assign tx_valid=state==TRANSMIT;
    always @(*) begin
        tx_data=0;
        case(tx_index)
            0:tx_data="T";1:tx_data="C";2:tx_data="H";3:tx_data="1";
            4:tx_data=command;5:tx_data=flags;6:tx_data={2'b0,character_count};7:tx_data=1;
            120:tx_data=8'h28;121:tx_data=8'h10;122:tx_data=8'h26;123:tx_data=8'h20;
            default: begin
                if(tx_index<12) tx_data=model_crc[(tx_index-8)*8+:8];
                else if(tx_index<16) tx_data=upload_crc[(tx_index-12)*8+:8];
                else if(tx_index<20) tx_data=core_cycles[(tx_index-16)*8+:8];
                else if(tx_index<24) tx_data=core_wait[(tx_index-20)*8+:8];
                else if(tx_index<56) tx_data=command=="T" && tx_index==24 ? {5'b0,read_delay}:
                    (command=="A" || command=="B") && tx_index==24 ? {7'b0,camera_mode}:characters[(tx_index-24)*8+:8];
                else if(tx_index<88) tx_data=layer_crc[(tx_index-56)*8+:8];
                else if(tx_index<120) tx_data=layer_cycles[(tx_index-88)*8+:8];
                else tx_data=(~packet_crc)>>((tx_index-124)*8);
            end
        endcase
    end
    task begin_response;
        begin state<=TRANSMIT;tx_index<=0;packet_crc<=32'hffffffff;end
    endtask
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; command<=0; field_index<=0; byte_index<=0; upload_addr<=0; scan_addr<=0;
            upload_blocks<=0;scan_blocks<=0;block_data<=0;crc<=32'hffffffff;expected_crc<=0;
            model_crc<=0;upload_crc<=0;packet_crc<=32'hffffffff;tx_index<=0;model_ready<=0;
            protocol_error<=0;scan_overrun<=0;finished<=0;scan_model<=0;scan_layer<=0;
            layer_crc<=0;layer_cycles<=0;characters<=0;character_count<=0;
            read_delay<=3;
            camera_mode<=0;
        end else begin
            if(core_done) finished<=1;
            if(core_char_valid) begin
                if(character_count<32) characters[character_count*8+:8]<={1'b0,core_char};
                character_count<=character_count+1'b1;
            end
            if(core_layer_done && state!=INFER_WAIT) scan_overrun<=1;
            case(state)
                IDLE: if(rx_valid) begin
                    command<=rx_data;protocol_error<=0;
                    case(rx_data)
                        "P": begin_response();
                        "A": begin camera_mode<=1;begin_response();end
                        "B": begin camera_mode<=0;begin_response();end
                        "S": begin
                            if(VIDEO_STATUS) layer_crc[127:0]<=video_status;else protocol_error<=1;
                            begin_response();
                        end
                        "W","R": begin state<=ADDRESS;field_index<=0;upload_addr<=0;end
                        "T": state<=TIMING;
                        "V": if(initialized) begin
                            model_ready<=0;scan_model<=1;scan_addr<=23'h100000;scan_blocks<=9766;
                            crc<=32'hffffffff;state<=SCAN_REQ;
                        end else begin protocol_error<=1;begin_response();end
                        "I": if(initialized && model_ready && core_start_ready) begin
                            finished<=0;scan_overrun<=0;characters<=0;character_count<=0;layer_crc<=0;layer_cycles<=0;state<=INFER_START;
                        end else begin protocol_error<=1;begin_response();end
                        default: begin protocol_error<=1;begin_response();end
                    endcase
                end
                ADDRESS: if(rx_valid) begin
                    if(field_index==2) upload_addr[22:16]<=rx_data[6:0];
                    else upload_addr[field_index*8+:8]<=rx_data;
                    if(field_index==2) begin state<=command=="R" ? RAW_REQ:LENGTH;field_index<=0;end else field_index<=field_index+1'b1;
                end
                TIMING: if(rx_valid) begin
                    if(rx_data<2 || rx_data>4) protocol_error<=1;
                    else begin read_delay<=rx_data[2:0];model_ready<=0;end
                    begin_response();
                end
                RAW_REQ: if(h_ready) state<=RAW_WAIT;
                RAW_WAIT: if(h_rsp_valid) begin layer_crc[127:0]<=mem_rsp_rdata;begin_response();end
                LENGTH: if(rx_valid) begin
                    upload_blocks[field_index*8+:8]<=rx_data;
                    if(field_index==1) begin
                        if(upload_addr[3:0]!=0 || upload_addr<23'h100000 ||
                           upload_addr+({rx_data,upload_blocks[7:0]}<<4)>23'h150000 ||
                           {rx_data,upload_blocks[7:0]}==0 || {rx_data,upload_blocks[7:0]}>1024) begin
                            protocol_error<=1;begin_response();
                        end else begin
                            if(upload_addr<23'h140000) model_ready<=0;
                            byte_index<=0;crc<=32'hffffffff;state<=UPLOAD;
                        end
                    end else field_index<=1;
                end
                UPLOAD: if(rx_valid) begin
                    block_data[byte_index*8+:8]<=rx_data;crc<=crc_byte(crc,rx_data);
                    if(byte_index==15) begin byte_index<=0;state<=WRITE_REQ;end else byte_index<=byte_index+1'b1;
                end
                WRITE_REQ: if(h_ready) state<=WRITE_WAIT;
                WRITE_WAIT: if(h_rsp_valid) begin
                    upload_addr<=upload_addr+16;
                    if(upload_blocks==1) begin state<=UPLOAD_CRC;field_index<=0;expected_crc<=0;upload_crc<=~crc;end
                    else begin upload_blocks<=upload_blocks-1'b1;state<=UPLOAD;end
                end
                UPLOAD_CRC: if(rx_valid) begin
                    expected_crc[field_index*8+:8]<=rx_data;
                    if(field_index==3) begin
                        if({rx_data,expected_crc[23:0]}!=upload_crc) protocol_error<=1;
                        begin_response();
                    end else field_index<=field_index+1'b1;
                end
                INFER_START: if(core_start_ready) state<=INFER_WAIT;
                INFER_WAIT: begin
                    if(core_layer_done) begin
                        scan_model<=0;scan_layer<=core_layer;
                        scan_addr<=core_layer[0] ? 23'h190000:23'h150000;
                        scan_blocks<=layer_blocks(core_layer);crc<=32'hffffffff;
                        layer_cycles[core_layer*32+:32]<=core_cycles;state<=SCAN_REQ;
                    end else if(finished) begin_response();
                end
                SCAN_REQ: if(h_ready) state<=SCAN_WAIT;
                SCAN_WAIT: if(h_rsp_valid) begin block_data<=mem_rsp_rdata;byte_index<=0;state<=SCAN_BYTES;end
                SCAN_BYTES: begin
                    crc<=crc_byte(crc,block_data[byte_index*8+:8]);
                    if(byte_index==15) begin
                        if(scan_blocks==1) begin
                            if(scan_model) begin
                                model_crc<=~crc_byte(crc,block_data[127:120]);
                                model_ready<=~crc_byte(crc,block_data[127:120])==`TEACHER_MODEL_CRC32;
                                if(~crc_byte(crc,block_data[127:120])!=`TEACHER_MODEL_CRC32) protocol_error<=1;
                                begin_response();
                            end else begin
                                layer_crc[scan_layer*32+:32]<=~crc_byte(crc,block_data[127:120]);state<=INFER_WAIT;
                            end
                        end else begin scan_blocks<=scan_blocks-1'b1;scan_addr<=scan_addr+16;state<=SCAN_REQ;end
                    end else byte_index<=byte_index+1'b1;
                end
                TRANSMIT: if(tx_ready) begin
                    if(tx_index<124) packet_crc<=crc_byte(packet_crc,tx_data);
                    if(tx_index==127) state<=IDLE;else tx_index<=tx_index+1'b1;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
