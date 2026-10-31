`timescale 1ns/1ps
module teacher_adapter_tb;
    reg clk=0;always #10 clk=~clk;
    reg reset_n=0,req_valid=0,req_write=0,rsp_ready=0;
    reg [2:0] read_delay=3;
    reg [22:0] req_addr=0;
    reg [127:0] req_wdata=0;
    reg [15:0] req_wstrb=0;
    wire req_ready,rsp_valid,initialized,ras_n,cas_n,we_n,cke,cs_n;
    wire [127:0] rsp_data;
    wire [10:0] addr;wire [1:0] ba;wire [3:0] dm;wire [31:0] dq;
    teacher_sdram_adapter #(.INIT_CYCLES(20),.REFRESH_CYCLES(90)) dut(.*);
    video_sdram_model #(.WORDS(524288),.MAX_REFRESH_CYCLES(390)) memory(!clk,reset_n,cke,cs_n,ras_n,cas_n,we_n,addr,ba,dm,dq);
    reg [127:0] golden=128'h112233445566778899aabbccddeeff00;
    task transact(input bit write_en,input integer address,input bit [127:0] data,input bit [15:0] mask);
        begin
            @(negedge clk);req_valid=1;req_write=write_en;req_addr=address;req_wdata=data;req_wstrb=mask;
            do @(posedge clk);while(!req_ready);
            @(negedge clk);req_valid=0;
            wait(rsp_valid);repeat(7) @(negedge clk);
            if(!rsp_valid) $fatal(1,"response lost under backpressure");
            if(!write_en && rsp_data!==golden) $fatal(1,"SDRAM masked data mismatch %h vs %h",rsp_data,golden);
            rsp_ready=1;@(negedge clk);rsp_ready=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);reset_n=1;wait(initialized);
        for(integer row=0;row<8;row++) begin
            transact(1,'h100000+row*1024,golden,16'hffff);
            for(integer b=0;b<16;b++) begin
                req_wdata={8{16'hb135}};
                transact(1,'h100000+row*1024,req_wdata,16'h1<<b);
                golden[b*8+:8]=req_wdata[b*8+:8];
                transact(0,'h100000+row*1024,0,0);
            end
        end
        if(memory.refreshes<10) $fatal(1,"refresh coverage missing");
        $display("PASS teacher_adapter: physical BL4/CAS3, RMW masks, rows, ACK backpressure and refresh");$finish;
    end
    initial begin #5000000;$fatal(1,"adapter timeout");end
endmodule
