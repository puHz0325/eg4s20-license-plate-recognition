`timescale 1ns/1ps
module lpr_vote_tb;
    reg clk=0,rn=0,event_in=0,error=0;
    always #5 clk=~clk;
    reg [31:0] frame=0;
    reg [4:0] length=7;
    reg [160:0] chars=0;
    wire cv;
    wire [48:0] cc;
    lpr_vote #(.CLK_HZ(1000),.TIMEOUT_MS(100)) dut(clk,rn,event_in,frame,length,chars,error,cv,cc, , );
    reg [48:0] a,b,bad;
    integer tag;
    task send(input reg [31:0] id,input reg [48:0] value,input integer len,input bit fault);
        begin
            @(negedge clk);event_in=1;frame=id;chars={112'b0,value};length=len;error=fault;
            @(negedge clk);event_in=0;
        end
    endtask
    task reset;
        begin @(negedge clk);rn=0; repeat(2) @(negedge clk);rn=1; end
    endtask
    initial begin
        // 京N8P8F8 and 京N8P8F0, low seven bits are the province.
        a={7'd39,7'd46,7'd39,7'd54,7'd39,7'd53,7'd0};
        b={7'd31,7'd46,7'd39,7'd54,7'd39,7'd53,7'd0};
        bad=a;bad[13:7]=7'd65;
        reset();
        send(10,a,7,0);send(11,a,7,0);send(12,a,7,0);
        if(cv) $fatal(1,"Confirmed before fourth vote");
        send(12,a,7,0);send(11,a,7,0);
        if(cv || dut.head!=3) $fatal(1,"Repeated/old frame voted");
        send(13,a,7,0);
        if(!cv || cc!==a) $fatal(1,"Fourth vote failed");
        send(14,b,7,0);send(15,b,7,0);send(16,b,7,0);
        if(!cv || cc!==a) $fatal(1,"Outliers changed confirmation early");
        send(17,b,7,0);
        if(!cv || cc!==b) $fatal(1,"New winner failed");
        $display("PASS 4-of-6 complete-plate voting, duplicate/old tags, isolated errors and winner replacement");
        reset();
        send(0,a,7,0);send(1,a,7,0);send(2,a,7,0);
        send(3,bad,7,0);send(4,a,8,0);send(5,a,7,1);send(6,a,7,0);
        if(cv) $fatal(1,"Invalid frames did not evict old votes");
        send(7,a,7,0);send(8,a,7,0);send(9,a,7,0);
        if(!cv || cc!==a) $fatal(1,"Post-error recovery");
        repeat(105) @(negedge clk);
        if(cv || cc!=0 || dut.valid!=0) $fatal(1,"Expired plate/votes remain visible");
        send(10,a,7,0);
        if(cv) $fatal(1,"Expired history reused");
        $display("PASS strict plate format, bad length/engine rejection, invalid slot eviction and two-second-equivalent expiry");
        reset();
        send(32'hfffffffe,a,7,0);send(32'hffffffff,a,7,0);send(0,a,7,0);send(1,a,7,0);
        if(!cv || cc!==a) $fatal(1,"Frame tag wrap");
        // Different, valid plates must not keep an obsolete confirmed plate alive.
        for(tag=2;tag<62;tag=tag+1) begin
            bad=a;bad[6:0]=10;bad[20:14]=31+(tag%10);send(tag,bad,7,0);
        end
        if(cv) $fatal(1,"Unrelated valid plates refreshed stale winner");
        reset();
        if(cv || cc!=0 || dut.valid!=0) $fatal(1,"Reset did not clear winner");
        $display("PASS frame tag rollover, stale winner expiry under unrelated traffic and reset");
        $finish;
    end
    initial begin #100000; $fatal(1,"Vote timeout"); end
endmodule
