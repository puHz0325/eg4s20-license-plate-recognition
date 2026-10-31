`include "teacher_preprocess.vh"
// 384x128 ->128x32, exactly INTER_LINEAR: x center, two y samples averaged.
module teacher_roi_snapshot #(parameter WIDTH=640,HEIGHT=480,ROI_X=`TEACHER_ROI_X,ROI_Y=`TEACHER_ROI_Y)(
 input wire capture_clk,capture_reset_n,input wire [35:0] token,input wire token_valid,
 input wire core_clk,core_reset_n,
 output wire snapshot_valid,output wire [31:0] snapshot_frame,
 input wire snapshot_take,snapshot_release,read_enable,input wire [11:0] read_addr,
 output wire [7:0] read_data,output reg [31:0] published,skipped,rejected
);
 localparam WORDS=WIDTH*HEIGHT/4;
 reg [1:0] published_toggle,released;
 (* ASYNC_REG="TRUE" *) reg [1:0] rel1,rel2,pub1,pub2;
 reg [31:0] tag0,tag1,frame_id;
 reg filling,bank,active,malformed,owned,read_bank,read_parity;
 reg [9:0] column,row,target_y;
 reg [10:0] target_x;
 reg [7:0] out_x;
 reg [5:0] out_y;
 reg [19:0] words;
 reg [12:0] written;
 wire free0=published_toggle[0]==rel2[0],free1=published_toggle[1]==rel2[1];
 wire [1:0] available=pub2^released;
 wire candidate=available==3 ? ($signed(tag1-tag0)>0):available[1];
 assign snapshot_valid=!owned && |available;
 assign snapshot_frame=(owned ? read_bank:candidate) ? tag1:tag0;
 reg even_write,odd_write,write_bank;
 reg [10:0] even_addr,odd_addr;
 reg [7:0] even_raw_pipe,odd_raw_pipe;
 reg line_wr_even,line_wr_odd,line_rd_even,line_rd_odd,sample_bank;
 reg [10:0] sample_even_addr,sample_odd_addr;
 reg [7:0] sample_even_data,sample_odd_data;
 reg pick_even,pick_odd;
 reg [10:0] pick_even_addr,pick_odd_addr,next_target_x;
 reg [7:0] pick_even_data,pick_odd_data,next_out_x;
 wire column_match=column=={1'b0,target_x[10:2]} && out_x<128;
 wire second_pixel=target_x[1:0]==0 && out_x<127;
 wire first_row=row==target_y;
 wire second_row=row==target_y+10'd1;
 wire select_pixels=token_valid && token[35:34]==0 && active && filling &&
                    (first_row || second_row) && out_y<32 && column_match;
 wire [10:0] first_addr={out_y[4:0],out_x[6:1]};
 wire [7:0] first_data=token>>(target_x[1:0]*8);
 always @(*) begin
  pick_even=0;pick_odd=0;pick_even_addr=first_addr;pick_odd_addr=first_addr;pick_even_data=0;pick_odd_data=0;
  next_target_x=target_x;next_out_x=out_x;
  // With stride 3 and four pixels/token, a second hit exists only at offset 0.
  // Calculate both lanes directly; avoid four cascaded add/compare/select steps.
  if(column_match) begin
   next_target_x=target_x+(second_pixel ? 11'd6:11'd3);
   next_out_x=out_x+(second_pixel ? 8'd2:8'd1);
  end
  if(select_pixels) begin
   if(out_x[0]) begin
    pick_odd=1;pick_odd_data=first_data;
    if(second_pixel) begin pick_even=1;pick_even_addr=first_addr+1'b1;pick_even_data=token[31:24];end
   end else begin
    pick_even=1;pick_even_data=first_data;
    if(second_pixel) begin pick_odd=1;pick_odd_data=token[31:24];end
   end
  end
 end
 wire [7:0] line_even,line_odd;
 teacher_roi_line line_e(capture_clk,line_wr_even,sample_even_addr[5:0],sample_even_data,
  line_rd_even,sample_even_addr[5:0],line_even);
 teacher_roi_line line_o(capture_clk,line_wr_odd,sample_odd_addr[5:0],sample_odd_data,
  line_rd_odd,sample_odd_addr[5:0],line_odd);
 wire [8:0] even_sum={1'b0,line_even}+{1'b0,even_raw_pipe}+9'd1;
 wire [8:0] odd_sum={1'b0,line_odd}+{1'b0,odd_raw_pipe}+9'd1;
 wire [7:0] even_data=even_sum[8:1],odd_data=odd_sum[8:1];
 // Select token at N, synchronous line read at N+1, matching average commits N+2.
 always @(posedge capture_clk or negedge capture_reset_n) begin
  if(!capture_reset_n) begin
   even_write<=0;odd_write<=0;write_bank<=0;even_addr<=0;odd_addr<=0;even_raw_pipe<=0;odd_raw_pipe<=0;
   line_wr_even<=0;line_wr_odd<=0;line_rd_even<=0;line_rd_odd<=0;sample_bank<=0;
   sample_even_addr<=0;sample_odd_addr<=0;sample_even_data<=0;sample_odd_data<=0;
  end else begin
   line_wr_even<=pick_even && first_row;line_wr_odd<=pick_odd && first_row;
   line_rd_even<=pick_even && second_row;line_rd_odd<=pick_odd && second_row;
   sample_bank<=bank;sample_even_addr<=pick_even_addr;sample_odd_addr<=pick_odd_addr;
   sample_even_data<=pick_even_data;sample_odd_data<=pick_odd_data;
   even_write<=line_rd_even;odd_write<=line_rd_odd;
   write_bank<=sample_bank;even_addr<=sample_even_addr;odd_addr<=sample_odd_addr;
   even_raw_pipe<=sample_even_data;odd_raw_pipe<=sample_odd_data;
   if(token_valid && token[35:34]!=0) begin
    even_write<=0;odd_write<=0;line_wr_even<=0;line_wr_odd<=0;line_rd_even<=0;line_rd_odd<=0;
   end
  end
 end
 wire [7:0] e0,o0,e1,o1;
 wire [1:0] write_count=even_write && odd_write ? 2'd2:even_write || odd_write ? 2'd1:2'd0;
 teacher_roi_plane plane_e0(capture_clk,even_write && !write_bank,even_addr,even_data,core_clk,read_enable && owned && !read_bank && !read_addr[0],read_addr[11:1],e0);
 teacher_roi_plane plane_o0(capture_clk,odd_write && !write_bank,odd_addr,odd_data,core_clk,read_enable && owned && !read_bank && read_addr[0],read_addr[11:1],o0);
 teacher_roi_plane plane_e1(capture_clk,even_write && write_bank,even_addr,even_data,core_clk,read_enable && owned && read_bank && !read_addr[0],read_addr[11:1],e1);
 teacher_roi_plane plane_o1(capture_clk,odd_write && write_bank,odd_addr,odd_data,core_clk,read_enable && owned && read_bank && read_addr[0],read_addr[11:1],o1);
 assign read_data=read_bank ? (read_parity ? o1:e1):(read_parity ? o0:e0);
 always @(posedge core_clk) if(read_enable) read_parity<=read_addr[0];
 always @(posedge capture_clk or negedge capture_reset_n) begin
  if(!capture_reset_n) begin
   published_toggle<=0;rel1<=0;rel2<=0;tag0<=0;tag1<=0;frame_id<=0;
   filling<=0;bank<=0;active<=0;malformed<=0;column<=0;row<=0;
   target_x<=ROI_X+1;target_y<=ROI_Y+1;out_x<=0;out_y<=0;words<=0;written<=0;
   published<=0;skipped<=0;rejected<=0;
  end else begin
   rel1<=released;rel2<=rel1;
   if(even_write || odd_write) written<=written+write_count;
   if(token_valid) case(token[35:34])
    1: begin
     active<=1;filling<=free0 || free1;bank<=!free0;malformed<=0;frame_id<=token[31:0];
     column<=0;row<=0;target_x<=ROI_X+1;target_y<=ROI_Y+1;out_x<=0;out_y<=0;words<=0;written<=0;
     if(!free0 && !free1) skipped<=skipped+1'b1;
    end
    0: if(active) begin
     words<=words+1'b1;if(words>=WORDS) malformed<=1;
     if(column==WIDTH/4-1) begin
      column<=0;row<=row+1'b1;target_x<=ROI_X+1;out_x<=0;
      if(second_row && out_y<32) begin target_y<=target_y+4;out_y<=out_y+1'b1;end
     end else begin column<=column+1'b1;target_x<=next_target_x;out_x<=next_out_x;end
    end
    2: if(active) begin
     active<=0;filling<=0;
     if(filling) begin
      if(token[32] && !malformed && words==WORDS && written==4096) begin
       published_toggle[bank]<=!published_toggle[bank];
       if(bank) tag1<=frame_id;else tag0<=frame_id;published<=published+1'b1;
      end else rejected<=rejected+1'b1;
     end
    end
    default: malformed<=1;
   endcase
  end
 end
 always @(posedge core_clk or negedge core_reset_n) begin
  if(!core_reset_n) begin pub1<=0;pub2<=0;released<=0;owned<=0;read_bank<=0;end
  else begin
   pub1<=published_toggle;pub2<=pub1;
   if(snapshot_take && snapshot_valid) begin
    owned<=1;read_bank<=candidate;
    if(available==3) released[!candidate]<=pub2[!candidate];
   end
   if(snapshot_release && owned) begin released[read_bank]<=pub2[read_bank];owned<=0;end
  end
 end
endmodule

// Two independent 64x8 planes total 128B; no full-row RAM reset.
module teacher_roi_line(input wire clk,wr_enable,input wire [5:0] wr_addr,input wire [7:0] wr_data,
 input wire rd_enable,input wire [5:0] rd_addr,output reg [7:0] rd_data);
 reg [7:0] memory[0:63];
 always @(posedge clk) begin
  if(wr_enable) memory[wr_addr]<=wr_data;
  if(rd_enable) rd_data<=memory[rd_addr];
 end
endmodule

module teacher_roi_plane(
 input wire wr_clk,wr_enable,input wire [10:0] wr_addr,input wire [7:0] wr_data,
 input wire rd_clk,rd_enable,input wire [10:0] rd_addr,output reg [7:0] rd_data
);
 (* ram_style="block" *) reg [7:0] memory[0:2047];
 always @(posedge wr_clk) if(wr_enable) memory[wr_addr]<=wr_data;
 always @(posedge rd_clk) if(rd_enable) rd_data<=memory[rd_addr];
endmodule
