`timescale 1ns/1ps
module teacher_ctc_tb;
    reg clk=0; always #10 clk=~clk;
    reg reset_n=0,start=0,symbol_valid=0,symbol_last=0,char_ready=0;
    reg [6:0] symbol=67;
    wire symbol_ready,char_valid,done;
    wire [6:0] char_data;
    wire [5:0] length;
    teacher_ctc dut(.*);
    integer received=0,expected_count=0;
    integer expected[32];
    integer cycles=0;
    reg [31:0] ready_lfsr=32'h1b96ac35;
    reg stalled=0;
    reg [6:0] held;
    always @(negedge clk) if(reset_n) begin
        ready_lfsr={ready_lfsr[30:0],ready_lfsr[31]^ready_lfsr[21]^ready_lfsr[1]^ready_lfsr[0]};
        char_ready=ready_lfsr[1:0]==0;
    end
    always @(posedge clk) if(reset_n) begin
        cycles++;
        if(cycles>4000) $fatal(1,"CTC timeout received=%0d expected=%0d running=%0b pending=%0b valid=%0b ready=%0b sym=%0d symvalid=%0b",received,expected_count,dut.running,dut.end_pending,char_valid,char_ready,symbol,symbol_valid);
        if(stalled && (!char_valid || char_data!==held)) $fatal(1,"CTC stalled payload changed");
        stalled=char_valid && !char_ready; held=char_data;
        if(char_valid && char_ready) begin
            if(received>=expected_count || char_data!==expected[received]) $fatal(1,"CTC mismatch index=%0d",received);
            received++;
        end
        if(done && received!=expected_count) $fatal(1,"done before last character consumed");
    end
    task send(input integer s,input bit last);
        begin
            @(negedge clk); symbol=s; symbol_valid=1; symbol_last=last;
            do @(posedge clk); while(!symbol_ready);
            @(negedge clk); symbol_valid=0; symbol_last=0;
        end
    endtask
    task begin_case;
        begin @(negedge clk); start=1; received=0; @(negedge clk); start=0; end
    endtask
    task end_case;
        begin wait(done); @(negedge clk); if(length!=expected_count) $fatal(1,"CTC length mismatch"); $display("CHECK CTC count=%0d",length); @(negedge clk); end
    endtask
    initial begin
        repeat(3) @(negedge clk); reset_n=1;
        expected_count=5; expected[0]=10; expected[1]=10; expected[2]=40; expected[3]=41; expected[4]=41;
        begin_case();
        send(67,0); send(10,0); send(10,0); send(67,0); send(10,0); send(40,0);
        send(40,0); send(41,0); send(67,0); send(41,1); end_case();
        expected_count=0; begin_case(); send(67,0); send(67,1); end_case();
        expected_count=32; for(integer i=0;i<32;i++) expected[i]=i%2;
        begin_case(); for(integer i=0;i<32;i++) send(i%2,i==31); end_case();
        // Abort a held character, then restart without ghost symbols.
        expected_count=1; expected[0]=17; begin_case();
        @(negedge clk); symbol=17; symbol_valid=1; symbol_last=0;
        wait(symbol_ready); @(negedge clk); symbol_valid=0; reset_n=0;
        repeat(2) @(negedge clk); stalled=0; reset_n=1;
        expected_count=1; expected[0]=18; begin_case(); send(18,1); end_case();
        $display("PASS teacher_ctc: blanks, repeats, 32 outputs, backpressure and reset"); $finish;
    end
endmodule
