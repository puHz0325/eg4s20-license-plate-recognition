// Consume a framed 32-bit pixel stream. Discard an underflowed frame, never shift pixels.
module video_display #(parameter ROI_X=132,ROI_Y=192,ROI_WIDTH=376,ROI_HEIGHT=96)(input wire clk,input wire reset_n,input wire frame_start,
    input wire de,input wire [11:0] x,y,
    input wire [35:0] stream_data,input wire stream_valid,output wire stream_ready,
    output reg frame_request,output wire [23:0] rgb,output reg [31:0] underflows);
    reg synced,word_valid,broken;
    reg [31:0] word_data;
    reg [1:0] byte_index;
    wire last=de && word_valid && byte_index==3;
    assign stream_ready=!frame_start && (!synced || broken || !word_valid || last);
    wire [7:0] gray=word_data>>(byte_index*8);
    wire border=(x==ROI_X || x==ROI_X+ROI_WIDTH-1) && y>=ROI_Y && y<ROI_Y+ROI_HEIGHT ||
                (y==ROI_Y || y==ROI_Y+ROI_HEIGHT-1) && x>=ROI_X && x<ROI_X+ROI_WIDTH;
    assign rgb=!synced ? {x[7:0],y[7:0],8'h40}:
               broken || !word_valid ? 24'hff00ff:
               border ? 24'h00ff00:{gray,gray,gray};
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            frame_request<=0; synced<=0; word_valid<=0; broken<=0;
            word_data<=0; byte_index<=0; underflows<=0;
        end else if(frame_start) begin
            frame_request<=~frame_request; synced<=0; word_valid<=0; broken<=0; byte_index<=0;
        end else begin
            if(de && synced && !broken) begin
                if(!word_valid) begin broken<=1; underflows<=underflows+1'b1; end
                else if(byte_index==3) begin byte_index<=0; word_valid<=0; end
                else byte_index<=byte_index+1'b1;
            end
            if(stream_valid && stream_ready) begin
                if(stream_data[35:34]==1) begin
                    if(stream_data[0]==frame_request && stream_data[32]) begin
                        synced<=1; broken<=0; byte_index<=0; word_valid<=0;
                    end
                end else if(synced && !broken && stream_data[35:34]==0) begin
                    word_data<=stream_data[31:0]; word_valid<=1; byte_index<=0;
                end
            end
        end
    end
endmodule
