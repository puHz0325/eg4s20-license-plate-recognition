`include "osd_glyphs.vh"
// Coherent frame-boundary snapshot of confirmed plate, raw result and health.
module lpr_osd #(parameter PANEL_BOTTOM=184)(
 input wire sys_clk,sys_reset_n,input wire confirmed_valid,input wire [48:0] confirmed_chars,
 input wire pixel_clk,pixel_reset_n,frame_start,input wire [11:0] x,y,
 input wire hs,vs,de,input wire [23:0] base_rgb,
 output reg hs_out,vs_out,de_out,output wire [23:0] rgb_out,
 input wire [3:0] status,input wire [48:0] raw_chars,input wire [4:0] raw_length,
 input wire [2:0] votes,input wire raw_valid,input wire [3:0] fault_code,input wire [1:0] retries
);
 reg [127:0] mailbox,visible_payload;
 wire [49:0] visible=visible_payload[49:0];
 reg request,ack;
 (* ASYNC_REG="TRUE" *) reg ack1,ack2,req1,req2;
 wire [127:0] wanted={10'b0,raw_valid,retries,fault_code,status,votes,raw_length,raw_chars,
  confirmed_valid,confirmed_valid ? confirmed_chars:49'b0};
 always @(posedge sys_clk or negedge sys_reset_n) begin
  if(!sys_reset_n) begin mailbox<=0;request<=0;ack1<=0;ack2<=0;end
  else begin
   ack1<=ack;ack2<=ack1;
   if(request==ack2 && wanted!=mailbox) begin mailbox<=wanted;request<=~request;end
  end
 end
 always @(posedge pixel_clk or negedge pixel_reset_n) begin
  if(!pixel_reset_n) begin req1<=0;req2<=0;ack<=0;visible_payload<=0;end
  else begin
   req1<=request;req2<=req1;
   if(frame_start && req2!=ack) begin visible_payload<=mailbox;ack<=req2;end
  end
 end
 function [6:0] at;
  input [48:0] text;input [2:0] position;
  begin
   case(position)
    0:at=text[6:0];1:at=text[13:7];2:at=text[20:14];3:at=text[27:21];
    4:at=text[34:28];5:at=text[41:35];6:at=text[48:42];default:at=`OSD_GLYPH_SPACE;
   endcase
  end
 endfunction
 reg [48:0] message;
 always @(*) begin
  case(visible_payload[110:107])
   0:message=`OSD_STATE_0;1:message=`OSD_STATE_1;2:message=`OSD_STATE_2;
   3:message=`OSD_STATE_3;4:message=`OSD_STATE_4;5:message=`OSD_STATE_5;
   6:message=`OSD_STATE_6;7:message=`OSD_STATE_7;8:message=`OSD_STATE_8;default:message=`OSD_STATE_9;
  endcase
 end
 wire panel=de && x>=16 && x<624 && y>=16 && y<PANEL_BOTTOM;
 reg [6:0] glyph;
 reg [10:0] font_addr;
 reg [3:0] column,row;
 reg [2:0] cell_index;
 reg draw;
 reg [23:0] ink;
 reg [13:0] label;
 wire [4:0] length=visible_payload[103:99];
 wire [3:0] tens=length>=20 ? 2:length>=10 ? 1:0;
 wire [4:0] ones=length>=20 ? length-20:length>=10 ? length-10:length;
 always @(*) begin
  glyph=`OSD_GLYPH_SPACE;column=(x-32)>>1;row=0;cell_index=0;
  draw=0;ink=24'hffffff;label=0;
  if(y>=24 && y<56 && x>=32 && x<320) begin
   row=(y-24)>>1;draw=1;
   if(x<96) begin label=`OSD_LABEL_CONFIRM;glyph=x<64 ? label[6:0]:label[13:7];end
   else begin
    cell_index=(x-96)>>5;glyph=visible[49] ? at(visible[48:0],cell_index):`OSD_GLYPH_DASH;
    ink=visible[49] ? 24'h60ff90:24'ha0a0a0;
   end
  end else if(y>=64 && y<96 && x>=32 && x<256) begin
   row=(y-64)>>1;cell_index=(x-32)>>5;draw=1;glyph=at(message,cell_index);
   ink=visible_payload[110:107]==7 ? 24'h60ff90:
    visible_payload[110:107]==1 || visible_payload[110:107]==9 ? 24'hff7070:24'hffd060;
  end else if(y>=104 && y<136 && x>=32 && x<320) begin
   row=(y-104)>>1;draw=1;
   if(x<96) begin label=`OSD_LABEL_RAW;glyph=x<64 ? label[6:0]:label[13:7];end
   else begin
    cell_index=(x-96)>>5;glyph=cell_index<length ? at(visible_payload[98:50],cell_index):`OSD_GLYPH_SPACE;
    if(glyph==65) glyph=`OSD_GLYPH_I;else if(glyph==66) glyph=`OSD_GLYPH_O;
    ink=visible_payload[117] ? 24'hffd060:24'hffb080;
   end
  end else if(y>=104 && y<136 && x>=352 && x<480) begin
   row=(y-104)>>1;draw=1;
   if(x<416) begin label=`OSD_LABEL_LENGTH;glyph=x<384 ? label[6:0]:label[13:7];end
   else glyph=31+(x<448 ? tens:ones);
  end else if(y>=144 && y<176) begin
   row=(y-144)>>1;
   if(x>=32 && x<192) begin
    draw=1;
    if(x<96) begin label=`OSD_LABEL_VOTES;glyph=x<64 ? label[6:0]:label[13:7];end
    else if(x<128) glyph=31+visible_payload[106:104];
    else if(x<160) glyph=`OSD_GLYPH_SLASH;else glyph=35;
   end else if(x>=352 && x<448) begin
    draw=1;
    if(x<416) begin label=`OSD_LABEL_FAULT;glyph=x<384 ? label[6:0]:label[13:7];end
    else glyph=31+visible_payload[114:111];
   end else if(x>=480 && x<576) begin
    draw=1;
    if(x<544) begin label=`OSD_LABEL_RETRIES;glyph=x<512 ? label[6:0]:label[13:7];end
    else glyph=31+visible_payload[116:115];
   end
  end
  font_addr={glyph,row};
 end
 wire [15:0] glyph_row;
 lpr_font_rom font(pixel_clk,font_addr,glyph_row);
 reg [23:0] background_q,ink_q;
 reg [3:0] column_q;
 reg draw_q;
 always @(posedge pixel_clk or negedge pixel_reset_n) begin
  if(!pixel_reset_n) begin
   hs_out<=1;vs_out<=1;de_out<=0;background_q<=0;ink_q<=0;column_q<=0;draw_q<=0;
  end else begin
   hs_out<=hs;vs_out<=vs;de_out<=de;background_q<=panel ? 24'h102030:base_rgb;
   ink_q<=ink;column_q<=column;draw_q<=de && draw;
  end
 end
 assign rgb_out=draw_q && glyph_row[15-column_q] ? ink_q:background_q;
endmodule

module lpr_font_rom(input wire clk,input wire [10:0] address,output wire [15:0] data);
 wire [15:0] d0,d1,d2,d3;
 reg [1:0] tile;
 always @(posedge clk) tile<=address[10:9];
 lpr_font_tile #(.FILE("car_test/PL/data/osd_font0.hex")) t0(clk,address[8:0],d0);
 lpr_font_tile #(.FILE("car_test/PL/data/osd_font1.hex")) t1(clk,address[8:0],d1);
 lpr_font_tile #(.FILE("car_test/PL/data/osd_font2.hex")) t2(clk,address[8:0],d2);
 lpr_font_tile #(.FILE("car_test/PL/data/osd_font3.hex")) t3(clk,address[8:0],d3);
 assign data=tile==0 ? d0:tile==1 ? d1:tile==2 ? d2:d3;
endmodule
module lpr_font_tile #(parameter FILE="")(
 input wire clk,input wire [8:0] address,output reg [15:0] data
);
 (* ram_style="block" *) reg [15:0] rows[0:511];
 initial $readmemh(FILE,rows);
 always @(posedge clk) data<=rows[address];
endmodule
