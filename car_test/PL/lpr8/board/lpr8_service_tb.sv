`timescale 1ns/1ps
`include "expected.vh"
`include "lpr8_model_identity.vh"
module teacher_service_tb;
    reg clk=0;always #20 clk=~clk;
    integer skew=0;
    reg shifted_clk=0;
    initial begin
        void'($value$plusargs("SKEW_NS=%d",skew));
        #(40+skew);
        forever begin shifted_clk=1;#20;shifted_clk=0;#20;end
    end
    reg reset_n=0,rx_valid=0,tx_ready=0;
    reg [7:0] rx_data=0;
    wire tx_valid,initialized,model_ready,busy,error;
    wire rx_ready,command_idle,camera_mode;
    wire [127:0] video_status=0;
    wire [2:0] read_delay;
    wire [7:0] tx_data;
    wire mem_req_valid,mem_req_ready,mem_req_write,mem_rsp_valid,mem_rsp_ready;
    wire [22:0] mem_req_addr;
    wire [127:0] mem_req_wdata,mem_rsp_rdata;
    wire [15:0] mem_req_wstrb;
    teacher_board_service service(.*);
    wire ras_n,cas_n,we_n,cke,cs_n;wire [10:0] addr;wire [1:0] ba;wire [3:0] dm;wire [31:0] dq;
    teacher_sdram_adapter #(.INIT_CYCLES(20),.REFRESH_CYCLES(150)) adapter(.clk(clk),.reset_n(reset_n),.read_delay(read_delay),
        .req_valid(mem_req_valid),.req_ready(mem_req_ready),.req_write(mem_req_write),.req_addr(mem_req_addr),
        .req_wdata(mem_req_wdata),.req_wstrb(mem_req_wstrb),.rsp_valid(mem_rsp_valid),.rsp_ready(mem_rsp_ready),
        .rsp_data(mem_rsp_rdata),.initialized(initialized),.ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),
        .addr(addr),.ba(ba),.dm(dm),.dq(dq),.cke(cke),.cs_n(cs_n));
    video_sdram_model #(.WORDS(524288),.MAX_REFRESH_CYCLES(195)) memory(shifted_clk,reset_n,cke,cs_n,ras_n,cas_n,we_n,addr,ba,dm,dq);
    reg [7:0] model[0:156255],pixels[0:4095],response[0:127],chars[0:31];
    reg [31:0] expected_layer[0:7];
    integer received=0;
    integer capture;
    reg [31:0] rng=32'h3cd15972;
    reg stalled=0;reg [7:0] held;
    reg [31:0] upload_crc;
    function [31:0] crc_byte(input [31:0] prior,input [7:0] data);
        reg [31:0] t;begin t=prior^data;for(integer j=0;j<8;j++) t=t[0]?(t>>1)^32'hedb88320:t>>1;crc_byte=t;end
    endfunction
    always @(negedge clk) begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};tx_ready=rng[1:0]==0;end
    always @(posedge clk) begin
        if(!reset_n) stalled=0;
        else begin
            if(stalled && (!tx_valid || tx_data!==held)) $fatal(1,"UART response changed while stalled");
            stalled=tx_valid&&!tx_ready;held=tx_data;
            if(tx_valid&&tx_ready) begin
                if(received>=128) $fatal(1,"response overflow");
                response[received]=tx_data;received++;
            end
        end
    end
    task byte_send(input [7:0] data);
        begin @(negedge clk);rx_valid=1;rx_data=data;@(negedge clk);rx_valid=0;repeat(47) @(negedge clk);end
    endtask
    task ack(input [7:0] command,input bit expect_error);
        reg [31:0] crc,got;
        begin
            wait(received==128);@(negedge clk);
            for(integer i=0;i<128;i++) if($isunknown(response[i])) $fatal(1,"unknown response byte %0d",i);
            if({response[0],response[1],response[2],response[3]}!==32'h54434831 || response[4]!==command) $fatal(1,"bad response header");
            crc=32'hffffffff;for(integer i=0;i<124;i++) crc=crc_byte(crc,response[i]);
            got={response[127],response[126],response[125],response[124]};
            if(got!==~crc || response[5][3]!==expect_error) $fatal(1,"bad response crc/status %h %h",got,response[5]);
            received=0;repeat(4) @(negedge clk);
        end
    endtask
    task upload(input integer address,input integer offset,input integer count,input bit roi,input bit bad_crc);
        reg [31:0] crc;
        reg [7:0] value;
        begin
            byte_send("W");byte_send(address);byte_send(address>>8);byte_send(address>>16);
            byte_send(count>>4);byte_send(count>>12);crc=32'hffffffff;
            for(integer i=0;i<count;i++) begin value=roi ? pixels[offset+i]:model[offset+i];byte_send(value);crc=crc_byte(crc,value);end
            crc=~crc;upload_crc=crc;
            for(integer i=0;i<4;i++) byte_send((bad_crc ? crc^32'h1:crc)>>(i*8));
            ack("W",bad_crc);
            if({response[15],response[14],response[13],response[12]}!==upload_crc) $fatal(1,"upload CRC mismatch");
        end
    endtask
    initial begin
        // Real power-up storage has arbitrary binary contents; poison unused bytes
        // so RMW can preserve them, rather than representing them as X on DQ.
        for(integer i='h40000;i<'h80000;i++) memory.memory[i]=32'ha5c79e13;
        $readmemh("car_test/PL/lpr8/data/model.hex",model);
        $readmemh("car_test/PL/lpr8/data/input_0.hex",pixels);
        $readmemh("car_test/PL/lpr8/data/chars_0.hex",chars);
        expected_layer[0]=`BOARD_CRC_0_0;expected_layer[1]=`BOARD_CRC_0_1;
        expected_layer[2]=`BOARD_CRC_0_2;expected_layer[3]=`BOARD_CRC_0_3;
        expected_layer[4]=`BOARD_CRC_0_4;expected_layer[5]=`BOARD_CRC_0_5;
        expected_layer[6]=`BOARD_CRC_0_6;expected_layer[7]=`BOARD_CRC_0_7;
        repeat(4) @(negedge clk);reset_n=1;wait(initialized);
        byte_send("P");ack("P",0);
        byte_send("I");ack("I",1);
        for(integer offset=0;offset<156256;offset+=4096) begin
            upload('h100000+offset,offset,(156256-offset>4096 ? 4096:156256-offset),0,0);
        end
        byte_send("V");ack("V",0);
        if(!model_ready || {response[11],response[10],response[9],response[8]}!==`TEACHER_MODEL_CRC32) $fatal(1,"SDRAM model validation failed");
        $display("CHECK teacher_service model uploaded and physical CRC verified");
        byte_send("R");byte_send(0);byte_send(0);byte_send('h10);ack("R",0);
        for(integer i=0;i<16;i++) if(response[56+i]!==model[i]) $fatal(1,"raw model readback mismatch");
        byte_send("T");byte_send(3);ack("T",0);
        if(model_ready || response[24]!=3) $fatal(1,"timing update did not revoke model-ready");
        byte_send("V");ack("V",0);
        // A corrupted physical parameter block must invalidate the model gate.
        model[0]^=1;upload('h100000,0,16,0,0);byte_send("V");ack("V",1);
        if(model_ready) $fatal(1,"bad SDRAM model accepted");
        byte_send("I");ack("I",1);
        model[0]^=1;upload('h100000,0,16,0,0);byte_send("V");ack("V",0);
        upload('h140000,0,4096,1,1); // Check upload-line CRC rejection too.
        upload('h140000,0,4096,1,0);
        byte_send("I");ack("I",0);
        if(response[5]!==8'h63 || response[6]!=7 || error) $fatal(1,"inference status %h length=%0d",response[5],response[6]);
        for(integer i=0;i<7;i++) if(response[24+i]!==chars[i]) $fatal(1,"board service character mismatch");
        for(integer i=0;i<8;i++) begin
            if({response[59+i*4],response[58+i*4],response[57+i*4],response[56+i*4]}!==expected_layer[i])
                $fatal(1,"physical layer CRC mismatch layer=%0d",i);
        end
        capture=$fopen("tmp/modelsim_teacher_board/response.bin","wb");
        if(!capture) $fatal(1,"cannot save service response");
        for(integer i=0;i<128;i++) $fwrite(capture,"%c",response[i]);
        $fclose(capture);
        $display("PASS teacher_service: upload CRC, physical model CRC rejection, 8 physical layer CRCs and CTC");$finish;
    end
    initial begin #2400000000;$fatal(1,"board service timeout state=%0d",service.state);end
endmodule
