`timescale 1ns/1ps
module teacher_dma_tb;
    reg clk=0; always #10 clk=~clk;
    reg reset_n=0,invalidate=0;
    reg byte_req_valid=0,byte_ready=0;
    reg [22:0] byte_addr=0;
    wire byte_req_ready,byte_valid;
    wire [7:0] byte_data;
    wire r_req_valid,r_req_ready,r_rsp_valid,r_rsp_ready;
    wire [22:0] r_req_addr;
    wire [127:0] r_rsp_data;
    teacher_byte_reader reader(.*,.req_valid(r_req_valid),.req_ready(r_req_ready),.req_addr(r_req_addr),
        .rsp_valid(r_rsp_valid),.rsp_ready(r_rsp_ready),.rsp_data(r_rsp_data));
    reg store_start=0;
    reg [22:0] store_addr=0;
    reg [127:0] store_data=0;
    reg [4:0] store_count=0;
    wire store_ready,store_done;
    wire w_req_valid,w_req_ready,w_rsp_valid,w_rsp_ready;
    wire [22:0] w_req_addr;
    wire [127:0] w_req_data;
    wire [15:0] w_req_strobe;
    teacher_store store(.clk(clk),.reset_n(reset_n),.start(store_start),.ready(store_ready),
        .address(store_addr),.data(store_data),.count(store_count),.done(store_done),
        .req_valid(w_req_valid),.req_ready(w_req_ready),.req_addr(w_req_addr),
        .req_data(w_req_data),.req_strobe(w_req_strobe),.rsp_valid(w_rsp_valid),.rsp_ready(w_rsp_ready));
    wire mem_req_valid,mem_req_ready,mem_req_write,mem_rsp_valid,mem_rsp_ready;
    wire [22:0] mem_req_addr;
    wire [127:0] mem_req_wdata,mem_rsp_rdata;
    wire [15:0] mem_req_wstrb;
    teacher_mem_arbiter arbiter(.*);
    wire [31:0] reads,writes;
    teacher_memory_model #(.MEM_BYTES(1024)) memory(.clk(clk),.reset_n(reset_n),
        .req_valid(mem_req_valid),.req_ready(mem_req_ready),.req_write(mem_req_write),
        .req_addr(mem_req_addr),.req_wdata(mem_req_wdata),.req_wstrb(mem_req_wstrb),
        .rsp_valid(mem_rsp_valid),.rsp_ready(mem_rsp_ready),.rsp_rdata(mem_rsp_rdata),.reads(reads),.writes(writes));
    reg [7:0] shadow[0:1023];
    reg [31:0] ready_lfsr=32'h3219b5ac;
    reg stalled=0;
    reg [167:0] held_request;
    integer cycles=0;
    always @(negedge clk) begin
        ready_lfsr={ready_lfsr[30:0],ready_lfsr[31]^ready_lfsr[21]^ready_lfsr[1]^ready_lfsr[0]};
        byte_ready=ready_lfsr[2:0]==0;
    end
    always @(posedge clk) begin
        cycles++;
        if(cycles>100000) $fatal(1,"DMA timeout");
        if(!reset_n) stalled=0;
        else begin
            if(stalled && (!mem_req_valid || {mem_req_write,mem_req_addr,mem_req_wstrb,mem_req_wdata}!==held_request))
                $fatal(1,"arbiter changed stalled request");
            stalled=mem_req_valid && !mem_req_ready;
            held_request={mem_req_write,mem_req_addr,mem_req_wstrb,mem_req_wdata};
        end
    end
    task read_byte(input integer address);
        begin
            @(negedge clk); byte_req_valid=1; byte_addr=address;
            do @(posedge clk); while(!byte_req_ready);
            @(negedge clk); byte_req_valid=0;
            do @(posedge clk); while(!(byte_valid && byte_ready));
            if(byte_data!==shadow[address]) $fatal(1,"cached byte mismatch addr=%0d",address);
            @(negedge clk);
        end
    endtask
    task write_bytes(input integer address,input integer count,input integer salt);
        begin
            wait(store_ready); @(negedge clk);
            store_addr=address; store_count=count;
            for(integer i=0;i<16;i++) store_data[i*8+:8]=salt+i*17;
            store_start=1; @(negedge clk); store_start=0;
            wait(store_done); @(negedge clk);
            for(integer i=0;i<count;i++) shadow[address+i]=salt+i*17;
        end
    endtask
    initial begin
        for(integer i=0;i<1024;i++) begin shadow[i]=(i*13+7)%256; memory.bytes[i]=shadow[i]; end
        repeat(3) @(negedge clk); reset_n=1;
        for(integer i=0;i<16;i++) read_byte(i);
        if(reads!=1) $fatal(1,"16 bytes should use one cached burst, used %0d",reads);
        fork
            begin for(integer i=16;i<208;i++) read_byte(i); end
            begin
                for(integer off=0;off<16;off++) begin
                    write_bytes(256+off,16,off*11);
                    for(integer i=256;i<304;i++) if(memory.bytes[i]!==shadow[i]) $fatal(1,"masked write damaged byte %0d",i);
                end
                for(integer count=1;count<=16;count++) write_bytes(512+7,count,count*3);
            end
        join
        @(negedge clk); invalidate=1; @(negedge clk); invalidate=0;
        for(integer i=256;i<304;i++) read_byte(i);
        for(integer i=512;i<544;i++) read_byte(i);
        // Cancel an actual outstanding read and restart with no stale byte/ACK.
        @(negedge clk); byte_req_valid=1; byte_addr=900;
        wait(mem_req_valid && mem_req_ready); @(negedge clk); reset_n=0; byte_req_valid=0;
        repeat(3) @(negedge clk); reset_n=1;
        read_byte(901);
        if(store_done) $fatal(1,"stale write ACK after reset");
        $display("PASS teacher_dma: cache, all burst offsets/counts, concurrent arbitration, stalls and reset");
        $finish;
    end
endmodule
