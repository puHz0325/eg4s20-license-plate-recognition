`timescale 1ns/1ps
// Independent BL4/CAS3 command-level SDR SDRAM model, not a RAM bypass.
module video_sdram_model #(parameter WORDS=262144,MAX_REFRESH_CYCLES=900)(
    input wire clk,reset_n,cke,cs_n,ras_n,cas_n,we_n,
    input wire [10:0] addr,input wire [1:0] ba,input wire [3:0] dm,inout wire [31:0] dq
);
    reg [31:0] memory[0:WORDS-1];
    reg [10:0] row[0:3];
    reg [3:0] active=0;
    integer activated[0:3],precharged[0:3];
    integer cycles=0,refreshes=0,reads=0,writes=0;
    integer read_address=0,write_address=0,read_left=0,write_left=0,latency=0,last_refresh=0;
    reg drive=0,mode_set=0;
    reg [31:0] output_word;
    assign dq=drive ? output_word:32'bz;
    integer i,j,a;
    task store(input integer address);
        begin
            if(address>=WORDS) $fatal(1,"SDRAM address outside model: %h",address);
            if(^dq===1'bx) $fatal(1,"Unknown write data at SDRAM address %h",address);
            for(j=0;j<4;j=j+1) if(!dm[j]) memory[address][j*8+:8]=dq[j*8+:8];
        end
    endtask
    initial for(i=0;i<4;i=i+1) begin activated[i]=-100; precharged[i]=-100; end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(!reset_n) begin active=0; read_left=0; write_left=0; drive<=0; mode_set=0; refreshes=0; end
        else if(cke && !cs_n) begin
            if(mode_set && cycles-last_refresh>MAX_REFRESH_CYCLES) $fatal(1,"SDRAM refresh overdue");
            if(read_left>0) begin
                if(latency>0) latency=latency-1;
                if(latency==0) begin
                    if(read_address>=WORDS) $fatal(1,"Read address outside model");
                    output_word<=memory[read_address]; drive<=1;
                    read_address=read_address+1; read_left=read_left-1;
                end
            end else drive<=0;
            if(write_left>0) begin store(write_address); write_address=write_address+1; write_left=write_left-1; end
            case({ras_n,cas_n,we_n})
                3'b011: begin
                    if(!mode_set || active[ba] || cycles-precharged[ba]<2) $fatal(1,"Illegal SDRAM ACT");
                    active[ba]=1; row[ba]=addr; activated[ba]=cycles;
                end
                3'b100,3'b101: begin
                    if(!active[ba] || cycles-activated[ba]<2 || addr[1:0]!=0) $fatal(1,"Illegal SDRAM read/write");
                    a={ba,row[ba],addr[7:0]};
                    if(we_n) begin read_address=a; read_left=4; latency=3; reads=reads+1; end
                    else begin store(a); write_address=a+1; write_left=3; writes=writes+1; end
                end
                3'b010: begin
                    if(read_left || write_left) $fatal(1,"Precharge during burst");
                    if(addr[10]) for(i=0;i<4;i=i+1) begin active[i]=0; precharged[i]=cycles; end
                    else begin active[ba]=0; precharged[ba]=cycles; end
                end
                3'b001: begin
                    if(active!=0) $fatal(1,"Refresh with open bank");
                    refreshes=refreshes+1; last_refresh=cycles;
                end
                3'b000: begin
                    if(addr!=11'h032 || refreshes<2) $fatal(1,"Wrong SDRAM mode/init sequence");
                    mode_set=1; last_refresh=cycles;
                end
            endcase
        end
    end
endmodule
