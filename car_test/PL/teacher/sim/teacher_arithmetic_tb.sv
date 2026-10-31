`timescale 1ns/1ps
module teacher_arithmetic_tb;
    reg clk=0; always #10 clk=~clk;
    reg reset_n=0,load_bias=0,multiply_enable=0,add_enable=0;
    reg signed [8:0] feature=0;
    reg [63:0] weights=0;
    reg [255:0] biases=0;
    wire [255:0] sums;
    wire overflow;
    teacher_mac8 dut(.*);
    reg signed [31:0] accum;
    reg [3:0] shift;
    reg relu;
    wire signed [15:0] value;
    requantize quant(.*);
    longint signed expected[8],a,rounded,product;
    integer seed=20261026;
    task check_quant(input integer v,input integer s,input bit r);
        begin
            accum=v; shift=s; relu=r; #1;
            a=v;
            if(s>0) rounded=a<0 ? -(((-a)+(64'sd1<<(s-1)))>>>s):((a+(64'sd1<<(s-1)))>>>s);
            else rounded=a;
            if(r) begin if(rounded<0) rounded=0; if(rounded>255) rounded=255; end
            else begin if(rounded< -32768) rounded=-32768; if(rounded>32767) rounded=32767; end
            if($signed(value)!==rounded) $fatal(1,"requant v=%0d shift=%0d relu=%0b got=%0d expected=%0d",v,s,r,value,rounded);
        end
    endtask
    initial begin
        void'($urandom(seed));
        repeat(3) @(negedge clk); reset_n=1;
        for(integer i=0;i<8;i++) begin biases[i*32+:32]=i*713-2123; expected[i]=i*713-2123; end
        load_bias=1; @(negedge clk); load_bias=0;
        for(integer k=0;k<896;k++) begin
            feature=k==0 ? -255:k==1 ? 255:($urandom()%511)-255;
            for(integer i=0;i<8;i++) begin
                weights[i*8+:8]=k==0 ? 8'h80:k==1 ? 8'h7f:$urandom();
                product=$signed(feature)*$signed(weights[i*8+:8]); expected[i]+=product;
            end
            multiply_enable=1; @(negedge clk); multiply_enable=0;
            add_enable=1; @(negedge clk); add_enable=0;
            @(negedge clk);
            for(integer i=0;i<8;i++) if($signed(sums[i*32+:32])!==expected[i]) $fatal(1,"MAC lane=%0d K=%0d",i,k);
        end
        if(overflow) $fatal(1,"unexpected overflow");
        for(integer s=0;s<16;s++) begin
            check_quant(32'h80000000,s,0); check_quant(32'h7fffffff,s,0);
            check_quant(-1,s,0); check_quant(0,s,0); check_quant(1,s,1);
            check_quant(32768,s,0); check_quant(-32769,s,0);
            if(s>0) begin check_quant(1<<(s-1),s,0); check_quant(-(1<<(s-1)),s,0); end
            for(integer n=0;n<100;n++) begin
                check_quant($urandom(),s,0); check_quant($urandom(),s,1);
            end
        end
        @(negedge clk); biases={8{32'h7fffffff}}; load_bias=1;
        @(negedge clk); load_bias=0; feature=255; weights={8{8'h7f}}; multiply_enable=1;
        @(negedge clk); multiply_enable=0; add_enable=1;
        @(negedge clk); add_enable=0;
        if(!overflow) $fatal(1,"INT32 overflow was not flagged");
        reset_n=0; @(negedge clk); reset_n=1;
        if(overflow) $fatal(1,"overflow reset failed");
        $display("PASS teacher_arithmetic: 8x896 MACs, INT32 overflow, rounding and saturation");
        $finish;
    end
endmodule
