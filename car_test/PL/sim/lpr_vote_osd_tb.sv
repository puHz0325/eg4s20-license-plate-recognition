`timescale 1ns/1ps
// Accepted raw result -> vote -> coherent mailbox -> visible pixels.
module lpr_vote_osd_tb;
    reg sc=0,pc=0,rn=0,event_in=0,fs=0;
    always #5 sc=~sc;
    always #7 pc=~pc;
    reg [31:0] frame=0;
    reg [160:0] chars=0;
    wire confirmed;
    wire [48:0] plate;
    wire hs,vs,de;
    wire [23:0] rgb;
    lpr_vote #(.CLK_HZ(100000),.TIMEOUT_MS(20)) voter(sc,rn,event_in,frame,5'd7,chars,1'b0,confirmed,plate, , );
    lpr_osd display(sc,rn,confirmed,plate,pc,rn,fs,12'd34,12'd28,1'b1,1'b1,1'b1,24'h808080,hs,vs,de,rgb,
        confirmed ? 4'd7:4'd6,49'b0,5'b0,3'b0,1'b0,4'b0,2'b0);
    reg [48:0] a,b;
    task send(input integer id,input reg [48:0] value);
        begin @(negedge sc);event_in=1;frame=id;chars=value;@(negedge sc);event_in=0;end
    endtask
    task boundary;
        begin repeat(12) @(negedge pc);fs=1;@(negedge pc);fs=0;end
    endtask
    initial begin
        a={7'd39,7'd46,7'd39,7'd54,7'd39,7'd53,7'd0};
        b=a;b[48:42]=31;
        repeat(5) @(negedge sc);rn=1;
        send(0,a);send(1,b);send(2,a);send(3,a);
        boundary();if(display.visible!=0) $fatal(1,"OSD confirmed too early");
        send(4,a);boundary();
        if(display.visible!={1'b1,a} || !confirmed) $fatal(1,"Confirmed result never reached OSD");
        send(5,b);send(6,b);boundary();
        if(display.visible!={1'b1,a}) $fatal(1,"Two outliers changed screen");
        repeat(2100) @(negedge sc);boundary();
        if(display.visible!=0 || confirmed) $fatal(1,"Stale plate did not clear on screen");
        $display("PASS raw-result to vote to frame-boundary OSD integration, outlier hold and expiry");
        $finish;
    end
    initial begin #100000; $fatal(1,"Vote/OSD integration timeout"); end
endmodule
