// RGB888 (R,G,B) on an 8-bit DVP bus. Rising PCLK samples data.
// Tokens: [35:34] 01=SOF, 00=four R8 pixels, 10=EOF; EOF[32]=frame good.
module dvp_capture #(parameter WIDTH=640, HEIGHT=480, RED_COMPONENT=0)(
    input wire pclk, input wire reset_n, input wire enable,
    input wire vsync, input wire href, input wire [7:0] data,
    output reg [35:0] stream_data, output reg stream_valid, input wire stream_ready,
    output reg [31:0] good_frames, output reg [31:0] bad_frames
);
    reg vs_d,hr_d,active,bad;
    reg [1:0] component,packed_count;
    reg [7:0] red;
    reg [31:0] packed_pixels,frame_id;
    reg [11:0] line_bytes;
    reg [10:0] lines;
    reg [19:0] pixels;
    wire slot=!stream_valid || stream_ready;
    wire [7:0] selected=RED_COMPONENT==2 ? data:red;
    wire frame_good=!bad && pixels==WIDTH*HEIGHT && lines==HEIGHT && packed_count==0;
    always @(posedge pclk or negedge reset_n) begin
        if(!reset_n) begin
            vs_d<=1; hr_d<=0; active<=0; bad<=0; component<=0; packed_count<=0;
            red<=0; packed_pixels<=0; frame_id<=0; line_bytes<=0; lines<=0; pixels<=0;
            stream_data<=0; stream_valid<=0; good_frames<=0; bad_frames<=0;
        end else begin
            vs_d<=vsync; hr_d<=href;
            if(stream_valid && stream_ready) stream_valid<=0;
            if(!enable) begin active<=0; stream_valid<=0; vs_d<=1; hr_d<=0; end
            else if(vs_d && !vsync) begin
                active<=1; bad<=!slot; pixels<=0; lines<=0; component<=0;
                packed_count<=0; line_bytes<=0; frame_id<=frame_id+1'b1;
                if(slot) begin stream_data<={2'b01,2'b00,frame_id}; stream_valid<=1; end
            end else if(!vs_d && vsync && active) begin
                active<=0;
                if(frame_good && slot) good_frames<=good_frames+1'b1;
                else bad_frames<=bad_frames+1'b1;
                if(slot) begin stream_data<={2'b10,1'b0,frame_good,32'b0}; stream_valid<=1; end
            end else if(active && !vsync) begin
                if(href) begin
                    line_bytes<=line_bytes+1'b1;
                    if(component==RED_COMPONENT) red<=data;
                    if(line_bytes>=WIDTH*3 || lines>=HEIGHT) bad<=1;
                    if(component==2) begin
                        component<=0; pixels<=pixels+1'b1;
                        packed_pixels<={selected,packed_pixels[31:8]};
                        packed_count<=packed_count+1'b1;
                        if(packed_count==3) begin
                            if(slot) begin
                                stream_data<={4'b0000,selected,packed_pixels[31:8]}; stream_valid<=1;
                            end else bad<=1;
                        end
                    end else component<=component+1'b1;
                end else begin
                    component<=0; line_bytes<=0;
                    if(hr_d) begin
                        lines<=lines+1'b1;
                        if(line_bytes!=WIDTH*3) bad<=1;
                    end
                end
            end
        end
    end
endmodule
