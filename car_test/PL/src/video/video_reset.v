module video_reset(input wire clk, input wire async_reset_n, output wire reset_n);
    (* ASYNC_REG="TRUE" *) reg [2:0] sync;
    always @(posedge clk or negedge async_reset_n)
        if(!async_reset_n) sync<=0;
        else sync<={sync[1:0],1'b1};
    assign reset_n=sync[2];
endmodule
