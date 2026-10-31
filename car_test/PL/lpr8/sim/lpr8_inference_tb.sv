`timescale 1ns/1ps
`include "lpr8_test_meta.vh"
module teacher_inference_tb;
    reg clk=0; always #10 clk=~clk;
    reg reset_n=0,model_ready=0,start=0,char_ready=0;
    wire start_ready,busy,done,error,char_valid,layer_done;
    wire [6:0] char_data;
    wire [5:0] result_length;
    wire [2:0] completed_layer;
    wire [31:0] cycles,prefetch_wait_cycles;
    wire mem_req_valid,mem_req_ready,mem_req_write,mem_rsp_valid,mem_rsp_ready;
    wire [22:0] mem_req_addr;
    wire [127:0] mem_req_wdata,mem_rsp_rdata;
    wire [15:0] mem_req_wstrb;
    teacher_inference dut(.*);
    wire [31:0] reads,writes;
    teacher_memory_model memory (
        .clk(clk),.reset_n(reset_n),.req_valid(mem_req_valid),.req_ready(mem_req_ready),
        .req_write(mem_req_write),.req_addr(mem_req_addr),.req_wdata(mem_req_wdata),.req_wstrb(mem_req_wstrb),
        .rsp_valid(mem_rsp_valid),.rsp_ready(mem_rsp_ready),.rsp_rdata(mem_rsp_rdata),.reads(reads),.writes(writes)
    );
    reg [7:0] model_bytes[0:`TEACHER_MODEL_BYTES-1],input_bytes[0:4095],expected_chars[0:31];
    reg [15:0] expected_layer[0:65535];
    integer case_index,expected_count,received=0,seen_layers=0,checked_elements=0;
    reg monitoring=0;
    reg req_stalled=0,char_stalled=0;
    reg [167:0] held_req;
    reg [6:0] held_char;
    reg [31:0] ready_lfsr=32'hbad6b731;
    integer bank_full_both=0,prefetch_during_mac=0,masked_stores=0,crossing_stores=0;
    integer last_store_addr=-1;
    function automatic integer elements(input integer layer);
        case(layer)
            0: elements=65536; 1: elements=16384; 2: elements=8192; 3: elements=12288;
            4: elements=8192; 5: elements=2048; 6: elements=4096; 7: elements=2176;
        endcase
    endfunction
    task check_layer(input integer layer);
        integer base_addr,n,actual;
        begin
            if(layer!=seen_layers) $fatal(1,"unexpected layer %0d, wanted %0d",layer,seen_layers);
            base_addr=layer%2==0 ? 'h150000:'h190000;
            n=elements(layer);
            $readmemh($sformatf("car_test/PL/lpr8/data/layer_%0d_%0d.hex",case_index,layer),expected_layer,0,n-1);
            for(integer i=0;i<n;i++) begin
                if(layer==7) actual={memory.bytes[base_addr+2*i+1],memory.bytes[base_addr+2*i]};
                else actual={8'b0,memory.bytes[base_addr+i]};
                if(actual!=={16'b0,expected_layer[i]})
                    $fatal(1,"layer=%0d element=%0d actual=%h expected=%h state=%0d",layer,i,actual,expected_layer[i],dut.state);
            end
            checked_elements+=n; seen_layers++;
            $display("CHECK layer=%0d elements=%0d cycles=%0d reads=%0d writes=%0d",layer,n,cycles,reads,writes);
        end
    endtask
    always @(negedge clk) begin
        ready_lfsr={ready_lfsr[30:0],ready_lfsr[31]^ready_lfsr[21]^ready_lfsr[1]^ready_lfsr[0]};
        char_ready=ready_lfsr[2:0]==0;
    end
    always @(posedge clk) begin
        if(!reset_n) begin req_stalled=0; char_stalled=0; end
        else begin
            if(req_stalled && (!mem_req_valid || {mem_req_write,mem_req_addr,mem_req_wstrb,mem_req_wdata}!==held_req))
                $fatal(1,"burst source changed under backpressure");
            req_stalled=mem_req_valid && !mem_req_ready;
            held_req={mem_req_write,mem_req_addr,mem_req_wstrb,mem_req_wdata};
            if(char_stalled && (!char_valid || char_data!==held_char)) $fatal(1,"character changed under backpressure");
            char_stalled=char_valid && !char_ready; held_char=char_data;
            if(mem_req_valid && mem_req_ready) begin
                if(mem_req_addr<'h100000) $fatal(1,"CNN touched reserved video memory");
                if(mem_req_write && mem_req_addr<'h150000) $fatal(1,"CNN wrote input or parameters");
                if(mem_req_write && mem_req_wstrb!=16'hffff) masked_stores++;
                if(mem_req_write && last_store_addr>=0 && mem_req_addr==last_store_addr+16) crossing_stores++;
                if(mem_req_write) last_store_addr=mem_req_addr;
            end
            if(dut.patch_start && dut.patch_full[dut.load_bank]) $fatal(1,"prefetch overwrote occupied bank");
            if(dut.patch_write && dut.patch_full[dut.load_bank]) $fatal(1,"DMA wrote occupied bank");
            if(dut.state==9 && !dut.patch_full[dut.compute_bank]) $fatal(1,"MAC read unowned buffer");
            if(dut.patch_full==2'b11) bank_full_both++;
            if(dut.patch_write && dut.state>=9 && dut.state<=11) prefetch_during_mac++;
            if(error===1'b1 || $isunknown(error)) $fatal(1,"MAC error at layer=%0d state=%0d",dut.layer_index,dut.state);
            if(monitoring) begin
                if(layer_done) check_layer(completed_layer);
                if(char_valid && char_ready) begin
                    if(received>=expected_count || char_data!==expected_chars[received])
                        $fatal(1,"CTC mismatch symbol=%0d got=%0d expected=%0d",received,char_data,expected_chars[received]);
                    received++;
                end
                if(cycles>60000000) $fatal(1,"inference timeout state=%0d layer=%0d",dut.state,dut.layer_index);
            end
        end
    end
    task launch;
        begin
            wait(start_ready); @(negedge clk); start=1; @(negedge clk); start=0;
        end
    endtask
    initial begin
        if(!$value$plusargs("CASE=%d",case_index)) case_index=0;
        case(case_index)
            0: expected_count=`TEACHER_CHAR_COUNT_0;
            1: expected_count=`TEACHER_CHAR_COUNT_1;
            2: expected_count=`TEACHER_CHAR_COUNT_2;
            default: $fatal(1,"invalid case");
        endcase
        for(integer i='h140000;i<'h1a0000;i++) memory.bytes[i]=8'ha5;
        $readmemh("car_test/PL/lpr8/data/model.hex",model_bytes);
        for(integer i=0;i<`TEACHER_MODEL_BYTES;i++) memory.bytes['h100000+i]=model_bytes[i];
        $readmemh($sformatf("car_test/PL/lpr8/data/input_%0d.hex",case_index),input_bytes);
        for(integer i=0;i<4096;i++) memory.bytes['h140000+i]=input_bytes[i];
        $readmemh($sformatf("car_test/PL/lpr8/data/chars_%0d.hex",case_index),expected_chars);
        repeat(3) @(negedge clk); reset_n=1;
        start=1; repeat(8) @(negedge clk);
        if(busy || start_ready) $fatal(1,"started before model_ready");
        start=0; model_ready=1;
        if(case_index==0) begin
            launch();
            repeat(1200) @(negedge clk);
            wait(dut.state==10 && memory.pending); @(negedge clk); reset_n=0;
            repeat(3) @(negedge clk); reset_n=1;
            if(busy || char_valid) $fatal(1,"mid-flight reset failed");
        end
        monitoring=1; launch();
        repeat(100) @(negedge clk);
        start=1; repeat(20) @(negedge clk); start=0;
        wait(done); @(negedge clk);
        if(seen_layers!=8 || received!=expected_count || result_length!=expected_count || busy)
            $fatal(1,"incomplete inference layers=%0d chars=%0d expected=%0d",seen_layers,received,expected_count);
        if(prefetch_during_mac==0 || masked_stores==0 || crossing_stores==0) $fatal(1,"missing DMA coverage");
        $display("PASS teacher_inference case=%0d layers=%0d elements=%0d chars=%0d cycles=%0d prefetch_wait=%0d overlap=%0d both_full=%0d reads=%0d writes=%0d", 
            case_index,seen_layers,checked_elements,received,cycles,prefetch_wait_cycles,prefetch_during_mac,bank_full_both,reads,writes);
        if(case_index==2) begin
            // Different ROI and output length, without reset or parameter reload.
            monitoring=0;
            repeat(3) @(negedge clk);
            case_index=0; expected_count=`TEACHER_CHAR_COUNT_0;
            $readmemh("car_test/PL/lpr8/data/input_0.hex",input_bytes);
            $readmemh("car_test/PL/lpr8/data/chars_0.hex",expected_chars);
            for(integer i=0;i<4096;i++) memory.bytes['h140000+i]=input_bytes[i];
            received=0; seen_layers=0; checked_elements=0; monitoring=1;
            launch(); wait(done); @(negedge clk);
            if(seen_layers!=8 || received!=expected_count || result_length!=expected_count || busy)
                $fatal(1,"restart without reset failed");
            $display("PASS teacher_restart case=%0d layers=%0d elements=%0d chars=%0d cycles=%0d prefetch_wait=%0d", 
                case_index,seen_layers,checked_elements,received,cycles,prefetch_wait_cycles);
        end
        $finish;
    end
endmodule
