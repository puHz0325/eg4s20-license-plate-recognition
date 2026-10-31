module tmds_encoder(input wire clk,input wire reset_n,input wire [7:0] data,
    input wire de,input wire c0,c1,output reg [9:0] symbol);
    wire [3:0] ones={3'b0,data[0]}+{3'b0,data[1]}+{3'b0,data[2]}+{3'b0,data[3]}+
                    {3'b0,data[4]}+{3'b0,data[5]}+{3'b0,data[6]}+{3'b0,data[7]};
    wire xnor_mode=ones>4 || (ones==4 && !data[0]);
    wire [8:0] q;
    assign q[0]=data[0];
    assign q[8]=!xnor_mode;
    genvar n;
    generate for(n=1;n<8;n=n+1) begin: encode_chain
        // Prefix parity avoids a vector self-reference in TD's HDL frontend.
        assign q[n]=(^data[n:0]) ^ (xnor_mode && (n%2==1));
    end endgenerate
    wire [3:0] qones={3'b0,q[0]}+{3'b0,q[1]}+{3'b0,q[2]}+{3'b0,q[3]}+
                     {3'b0,q[4]}+{3'b0,q[5]}+{3'b0,q[6]}+{3'b0,q[7]};
    reg signed [5:0] disparity;
    wire signed [5:0] balance=$signed({1'b0,qones,1'b0})-6'sd8;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin disparity<=0; symbol<=10'b1101010100; end
        else if(!de) begin
            disparity<=0;
            case({c1,c0})
                0:symbol<=10'b1101010100;
                1:symbol<=10'b0010101011;
                2:symbol<=10'b0101010100;
                3:symbol<=10'b1010101011;
            endcase
        end else if(disparity==0 || balance==0) begin
            symbol<={~q[8],q[8],q[8] ? q[7:0]:~q[7:0]};
            disparity<=disparity+(q[8] ? balance:-balance);
        end else if((disparity>0 && balance>0)||(disparity<0 && balance<0)) begin
            symbol<={1'b1,q[8],~q[7:0]};
            disparity<=disparity-balance+(q[8] ? 6'sd2:6'sd0);
        end else begin
            symbol<={1'b0,q[8],q[7:0]};
            disparity<=disparity+balance-(q[8] ? 6'sd0:6'sd2);
        end
    end
endmodule
