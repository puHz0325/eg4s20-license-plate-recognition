module video_timing #(
    parameter H_ACTIVE=640,H_FRONT=16,H_SYNC=96,H_BACK=48,
    parameter V_ACTIVE=480,V_FRONT=10,V_SYNC=2,V_BACK=33
)(input wire clk,input wire reset_n,output wire hs,vs,de,frame_start,
    output wire [11:0] x,y);
    localparam HT=H_ACTIVE+H_FRONT+H_SYNC+H_BACK, VT=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
    reg [11:0] h,v;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin h<=0; v<=0; end
        else if(h==HT-1) begin h<=0; if(v==VT-1) v<=0; else v<=v+1'b1; end
        else h<=h+1'b1;
    end
    assign hs=!(h<H_SYNC);
    assign vs=!(v<V_SYNC);
    assign de=h>=H_SYNC+H_BACK && h<H_SYNC+H_BACK+H_ACTIVE &&
              v>=V_SYNC+V_BACK && v<V_SYNC+V_BACK+V_ACTIVE;
    assign x=h-(H_SYNC+H_BACK);
    assign y=v-(V_SYNC+V_BACK);
    assign frame_start=h==0 && v==0;
endmodule
