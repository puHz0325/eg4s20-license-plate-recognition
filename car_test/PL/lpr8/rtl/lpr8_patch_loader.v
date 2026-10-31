// Gather a CHW-ordered convolution window from HWC SDRAM bytes.
// Iterate ky,kx,ci for coalescing; write k=ci*Kh*Kw+ky*Kw+kx.
module teacher_patch_loader (
    input wire clk,input wire reset_n,input wire start,output wire ready,
    input wire [22:0] input_base,input wire [7:0] input_h,input_w,input_ch,
    input wire [3:0] kernel_h,kernel_w,pad_h,pad_w,
    input wire [7:0] center_y,center_x,input wire first_layer,
    output wire byte_req_valid,input wire byte_req_ready,output wire [22:0] byte_addr,
    input wire byte_valid,output wire byte_ready,input wire [7:0] byte_data,
    output wire write_enable,output wire [10:0] write_addr,
    output wire signed [8:0] write_data,output reg done
);
    localparam IDLE=0,REQUEST=1,RESPONSE=2;
    reg [1:0] state;
    reg [22:0] base_q;
    reg [7:0] h_q,w_q,c_q,cy_q,cx_q,ci;
    reg [3:0] kh_q,kw_q,ph_q,pw_q,ky,kx;
    reg normalize;
    wire signed [9:0] iy=$signed({2'b0,cy_q})+$signed({6'b0,ky})-$signed({6'b0,ph_q});
    wire signed [9:0] ix=$signed({2'b0,cx_q})+$signed({6'b0,kx})-$signed({6'b0,pw_q});
    wire padding=iy<0 || ix<0 || iy>=$signed({2'b0,h_q}) || ix>=$signed({2'b0,w_q});
    assign ready=state==IDLE;
    assign byte_req_valid=state==REQUEST && !padding;
    assign byte_addr=base_q+(iy*w_q+ix)*c_q+ci;
    assign byte_ready=state==RESPONSE;
    assign write_enable=(state==REQUEST && padding) || (state==RESPONSE && byte_valid);
    assign write_addr=ci*kh_q*kw_q+ky*kw_q+kx;
    assign write_data=padding ? 9'sd0 : normalize ? ({byte_data,1'b0}-9'd255):{1'b0,byte_data};
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; base_q<=0; h_q<=0; w_q<=0; c_q<=0; cy_q<=0; cx_q<=0;
            kh_q<=0; kw_q<=0; ph_q<=0; pw_q<=0; ky<=0; kx<=0; ci<=0; normalize<=0; done<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    base_q<=input_base; h_q<=input_h; w_q<=input_w; c_q<=input_ch;
                    kh_q<=kernel_h; kw_q<=kernel_w; ph_q<=pad_h; pw_q<=pad_w;
                    cy_q<=center_y; cx_q<=center_x; normalize<=first_layer;
                    ky<=0; kx<=0; ci<=0; state<=REQUEST;
                end
                REQUEST: if(!padding && byte_req_ready) state<=RESPONSE;
                default: begin end
            endcase
            if(write_enable) begin
                state<=REQUEST;
                if(ci==c_q-1'b1) begin
                    ci<=0;
                    if(kx==kw_q-1'b1) begin
                        kx<=0;
                        if(ky==kh_q-1'b1) begin state<=IDLE; done<=1; end
                        else ky<=ky+1'b1;
                    end else kx<=kx+1'b1;
                end else ci<=ci+1'b1;
            end
        end
    end
endmodule
