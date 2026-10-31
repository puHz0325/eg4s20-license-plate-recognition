// Single SDRAM-domain owner for all three buffers. A completed write burst precedes EOF publication.
module video_frame_store #(parameter WIDTH=640,HEIGHT=480)(
    input wire clk,input wire reset_n,input wire initialized,
    input wire [35:0] capture_data,input wire capture_valid,output wire capture_ready,
    input wire display_request,
    output wire [35:0] display_data,output wire display_valid,input wire display_ready,
    output wire request_valid,input wire request_ready,output wire request_write,
    output wire [20:0] request_addr,output wire [127:0] request_data,
    input wire done,input wire [127:0] read_data,
    output reg [31:0] published_frames,output reg [31:0] rejected_frames
);
    localparam WORDS=WIDTH*HEIGHT/4, BLOCKS=WORDS/4;
    (* ASYNC_REG="TRUE" *) reg req1,req2;
    reg applied;
    reg capture_owned,display_owned,ready_owned,capture_bad;
    reg [1:0] capture_bank,display_bank,ready_bank;
    reg [18:0] capture_words,display_block;
    reg [1:0] collect_index;
    reg [127:0] write_block,output_block;
    reg write_pending,output_valid,header_pending;
    reg [1:0] output_index;
    reg bus_busy,bus_write,prefer_read;
    reg free_found;
    reg [1:0] free_bank;
    integer i;
    wire swap_pending=req2!=applied;
    wire want_read=display_owned && display_block<BLOCKS && !output_valid && !header_pending;
    wire choose_write=write_pending && (swap_pending || !want_read || !prefer_read);
    assign request_valid=initialized && !bus_busy && (write_pending || (!swap_pending && want_read));
    assign request_write=choose_write;
    assign request_addr=choose_write ? capture_bank*WORDS+capture_words-4:
                                             display_bank*WORDS+(display_block<<2);
    assign request_data=write_block;
    assign capture_ready=initialized && !write_pending && !bus_busy && !swap_pending;
    assign display_valid=header_pending || output_valid;
    wire [31:0] output_word=output_block>>(output_index*32);
    assign display_data=header_pending ? {2'b01,1'b0,display_owned,31'b0,applied}:{4'b0,output_word};
    always @(*) begin
        free_found=0; free_bank=0;
        for(i=2;i>=0;i=i-1)
            if((!display_owned || display_bank!=i) && (!ready_owned || ready_bank!=i)) begin
                free_found=1; free_bank=i;
            end
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            req1<=0; req2<=0; applied<=0;
            capture_owned<=0; display_owned<=0; ready_owned<=0; capture_bad<=0;
            capture_bank<=0; display_bank<=0; ready_bank<=0; capture_words<=0; display_block<=0;
            collect_index<=0; write_block<=0; output_block<=0; write_pending<=0;
            output_valid<=0; output_index<=0; header_pending<=0;
            bus_busy<=0; bus_write<=0; prefer_read<=0; published_frames<=0; rejected_frames<=0;
        end else begin
            req1<=display_request; req2<=req1;
            if(display_valid && display_ready) begin
                if(header_pending) header_pending<=0;
                else if(output_index==3) begin output_valid<=0; output_index<=0; end
                else output_index<=output_index+1'b1;
            end
            if(!bus_busy && swap_pending && !write_pending) begin
                applied<=req2; display_block<=0; output_valid<=0; output_index<=0; header_pending<=1;
                if(ready_owned) begin display_bank<=ready_bank; display_owned<=1; ready_owned<=0; end
            end
            // A pending capture write must finish before changing ownership.
            if(request_valid && request_ready) begin
                bus_busy<=1; bus_write<=choose_write; prefer_read<=choose_write;
                if(!choose_write) display_block<=display_block+1'b1;
            end
            if(done && bus_busy) begin
                bus_busy<=0;
                if(bus_write) write_pending<=0;
                else begin output_block<=read_data; output_index<=0; output_valid<=1; end
            end
            if(capture_valid && capture_ready) begin
                case(capture_data[35:34])
                    1: begin
                        capture_owned<=free_found; capture_bank<=free_bank;
                        capture_words<=0; collect_index<=0; capture_bad<=!free_found;
                    end
                    0: if(capture_owned && !capture_bad) begin
                        if(capture_words>=WORDS) capture_bad<=1;
                        else begin
                            write_block[collect_index*32+:32]<=capture_data[31:0];
                            capture_words<=capture_words+1'b1;
                            collect_index<=collect_index+1'b1;
                            if(collect_index==3) write_pending<=1;
                        end
                    end
                    2: begin
                        if(capture_owned && !capture_bad && capture_data[32] && capture_words==WORDS && collect_index==0) begin
                            ready_bank<=capture_bank; ready_owned<=1; published_frames<=published_frames+1'b1;
                        end else rejected_frames<=rejected_frames+1'b1;
                        capture_owned<=0;
                    end
                    default: begin capture_bad<=1; end
                endcase
            end
        end
    end
endmodule
