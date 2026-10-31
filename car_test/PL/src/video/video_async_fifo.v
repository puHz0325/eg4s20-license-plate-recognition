// Dual-clock RAM with a registered, elastic read output. AW must be >= 2.
// The read pointer advances on prefetch; the output register owns that word thereafter.
module video_async_fifo #(parameter WIDTH=36, parameter AW=9)(
    input wire wr_clk, input wire wr_reset_n,
    input wire [WIDTH-1:0] wr_data, input wire wr_valid, output wire wr_ready,
    input wire rd_clk, input wire rd_reset_n,
    output reg [WIDTH-1:0] rd_data, output reg rd_valid, input wire rd_ready
);
    reg [WIDTH-1:0] mem[0:(1<<AW)-1];
    reg [AW:0] wbin,wgray,rbin,rgray;
    (* ASYNC_REG="TRUE" *) reg [AW:0] rg1,rg2,wg1,wg2;
    wire [AW:0] wn=wbin+1'b1, rn=rbin+1'b1;
    assign wr_ready=wgray!={~rg2[AW:AW-1],rg2[AW-2:0]};
    wire empty=rgray==wg2;
    always @(posedge wr_clk or negedge wr_reset_n) begin
        if(!wr_reset_n) begin wbin<=0; wgray<=0; rg1<=0; rg2<=0; end
        else begin
            rg1<=rgray; rg2<=rg1;
            if(wr_valid && wr_ready) begin wbin<=wn; wgray<=(wn>>1)^wn; end
        end
    end
    always @(posedge wr_clk) if(wr_valid && wr_ready) mem[wbin[AW-1:0]]<=wr_data;
    always @(posedge rd_clk or negedge rd_reset_n) begin
        if(!rd_reset_n) begin rbin<=0; rgray<=0; wg1<=0; wg2<=0; rd_valid<=0; end
        else begin
            wg1<=wgray; wg2<=wg1;
            if(!rd_valid || rd_ready) begin
                rd_valid<=!empty;
                if(!empty) begin rbin<=rn; rgray<=(rn>>1)^rn; end
            end
        end
    end
    always @(posedge rd_clk)
        if((!rd_valid || rd_ready) && !empty) rd_data<=mem[rbin[AW-1:0]];
endmodule
