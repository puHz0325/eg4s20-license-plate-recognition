// Internal ready/valid byte master for camera W->V->I, sharing the proven service.
// PC commands have priority at transaction boundaries. Internal W/V ACKs stay local.
`include "teacher_model_identity.vh"
module teacher_camera_bridge(
 input wire clk,reset_n,input wire pc_rx_valid,input wire [7:0] pc_rx_data,
 output wire pc_tx_valid,input wire pc_tx_ready,output wire [7:0] pc_tx_data,
 output wire service_rx_valid,input wire service_rx_ready,output reg [7:0] service_rx_data,
 input wire service_tx_valid,output wire service_tx_ready,input wire [7:0] service_tx_data,
 input wire service_idle,model_ready,camera_mode,
 input wire snapshot_valid,input wire [31:0] snapshot_frame,
 output wire snapshot_take,output reg snapshot_release,output wire snapshot_read,
 output wire [11:0] snapshot_addr,input wire [7:0] snapshot_data,
 output reg result_event,output reg [31:0] result_frame,
 output wire [4:0] result_length,output reg [160:0] result_chars,output reg result_error,
 output reg fault,output reg [31:0] result_count
);
 localparam IDLE=0,PC=1,HEADER=2,FETCH=3,PIXEL=4,CRC_BYTES=5,WAIT_W=6,VERIFY=7,WAIT_V=8,START_I=9,WAIT_I=10;
 reg [3:0] state;
 reg [7:0] fifo[0:15];reg [3:0] wp,rp;reg [4:0] count;
 wire pc_pop=(state==IDLE || state==PC) && count!=0 && service_rx_ready;
 wire pc_push=pc_rx_valid && (count<16 || pc_pop);
 reg [2:0] header_index;reg [1:0] crc_index;
 reg [11:0] pixel_index;
 reg [31:0] source_frame,roi_crc,roi_final,rx_crc,packet_crc,ack_upload_crc,ack_model_crc;
 reg [6:0] packet_index;
 reg [7:0] ack_command,ack_flags;
 reg [5:0] raw_length;
 reg invalid_char;
 wire auto_take=state==IDLE && count==0 && !pc_rx_valid && service_idle && model_ready && camera_mode && !fault && snapshot_valid;
 assign snapshot_take=auto_take;
 assign snapshot_read=state==FETCH;
 assign snapshot_addr=pixel_index;
 assign result_length=raw_length>23 ? 5'd23:raw_length[4:0];
 assign service_rx_valid=((state==IDLE || state==PC) && count!=0) || state==HEADER || state==PIXEL || state==CRC_BYTES || state==VERIFY || state==START_I;
 assign pc_tx_valid=service_tx_valid && (state==PC || state==WAIT_I);
 assign pc_tx_data=service_tx_data;
 assign service_tx_ready=state==PC || state==WAIT_I ? pc_tx_ready:state==WAIT_W || state==WAIT_V;
 wire tx_take=service_tx_valid && service_tx_ready;
 wire upload_state=state==HEADER || state==FETCH || state==PIXEL || state==CRC_BYTES;
 wire crc_ok={service_tx_data,rx_crc[23:0]}==~packet_crc;
 function [31:0] crc_byte;
  input [31:0] prior;input [7:0] value;reg [31:0] temp;integer j;
  begin temp=prior^value;for(j=0;j<8;j=j+1) temp=temp[0] ? (temp>>1)^32'hedb88320:temp>>1;crc_byte=temp;end
 endfunction
 always @(*) begin
  service_rx_data=0;
  case(state)
   IDLE,PC:service_rx_data=fifo[rp];
   HEADER:case(header_index)
    0:service_rx_data="W";1,2,4:service_rx_data=0;3:service_rx_data=8'h14;5:service_rx_data=1;
    default:service_rx_data=0;
   endcase
   PIXEL:service_rx_data=snapshot_data;
   CRC_BYTES:service_rx_data=roi_final>>(crc_index*8);
   VERIFY:service_rx_data="V";
   START_I:service_rx_data="I";
   default:service_rx_data=0;
  endcase
 end
 always @(posedge clk) if(pc_push) fifo[wp]<=pc_rx_data;
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   state<=IDLE;wp<=0;rp<=0;count<=0;header_index<=0;crc_index<=0;pixel_index<=0;
   source_frame<=0;roi_crc<=32'hffffffff;roi_final<=0;rx_crc<=0;packet_crc<=32'hffffffff;
   ack_upload_crc<=0;ack_model_crc<=0;packet_index<=0;ack_command<=0;ack_flags<=0;raw_length<=0;invalid_char<=0;
   snapshot_release<=0;result_event<=0;result_frame<=0;result_chars<=0;result_error<=0;fault<=0;result_count<=0;
  end else begin
   snapshot_release<=0;result_event<=0;
   if(pc_rx_valid && !pc_push) fault<=1;
   if(pc_push) wp<=wp+1'b1;
   if(pc_pop) rp<=rp+1'b1;
   case({pc_push,pc_pop}) 2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
   if(tx_take) begin
    if(packet_index<124) packet_crc<=crc_byte(packet_crc,service_tx_data);
    else rx_crc[(packet_index-124)*8+:8]<=service_tx_data;
    if(packet_index==4) ack_command<=service_tx_data;
    if(packet_index==5) ack_flags<=service_tx_data;
    if(packet_index==6) raw_length<=service_tx_data[5:0];
    if(packet_index>=8 && packet_index<12) ack_model_crc[(packet_index-8)*8+:8]<=service_tx_data;
    if(packet_index>=12 && packet_index<16) ack_upload_crc[(packet_index-12)*8+:8]<=service_tx_data;
    if(state==WAIT_I && packet_index>=24 && packet_index<56 && packet_index-24<raw_length) begin
     if(packet_index<47) result_chars[(packet_index-24)*7+:7]<=service_tx_data[6:0];
     if(service_tx_data>=67 || packet_index>=47) invalid_char<=1;
    end
    if(packet_index==127) begin packet_index<=0;packet_crc<=32'hffffffff;end
    else packet_index<=packet_index+1'b1;
   end
   case(state)
    IDLE: if(pc_pop) begin
     state<=PC;packet_index<=0;packet_crc<=32'hffffffff;
     if(fifo[rp]=="A") fault<=0;
    end else if(auto_take) begin
     source_frame<=snapshot_frame;roi_crc<=32'hffffffff;pixel_index<=0;header_index<=0;state<=HEADER;
     packet_index<=0;packet_crc<=32'hffffffff;result_chars<=0;invalid_char<=0;
    end
    PC: if(tx_take && packet_index==127) state<=IDLE;
    HEADER: if(service_rx_ready) begin
     if(header_index==5) state<=FETCH;else header_index<=header_index+1'b1;
    end
    FETCH: state<=PIXEL;
    PIXEL: if(service_rx_ready) begin
     roi_crc<=crc_byte(roi_crc,snapshot_data);
     if(pixel_index==4095) begin roi_final<=~crc_byte(roi_crc,snapshot_data);crc_index<=0;state<=CRC_BYTES;end
     else begin pixel_index<=pixel_index+1'b1;state<=FETCH;end
    end
    CRC_BYTES: if(service_rx_ready) begin
     if(crc_index==3) state<=WAIT_W;else crc_index<=crc_index+1'b1;
    end
    WAIT_W: if(tx_take && packet_index==127) begin
     snapshot_release<=1;
     if(ack_command!="W" || (ack_flags&8'h1c)!=0 || ack_upload_crc!=roi_final || !crc_ok) begin
      fault<=1;state<=IDLE;result_event<=1;result_error<=1;result_frame<=source_frame;raw_length<=0;
     end else state<=VERIFY;
    end
    VERIFY: if(service_rx_ready) state<=WAIT_V;
    WAIT_V: if(tx_take && packet_index==127) begin
     if(ack_command!="V" || (ack_flags&8'h1f)!=3 || ack_model_crc!=`TEACHER_MODEL_CRC32 || !crc_ok) begin
      fault<=1;state<=IDLE;result_event<=1;result_error<=1;result_frame<=source_frame;raw_length<=0;
     end else state<=START_I;
    end
    START_I: if(service_rx_ready) begin state<=WAIT_I;invalid_char<=0;end
    WAIT_I: if(tx_take && packet_index==127) begin
     result_event<=1;result_frame<=source_frame;result_count<=result_count+1'b1;
     result_error<=ack_command!="I" || (ack_flags&8'h3f)!=8'h23 || !crc_ok || invalid_char || raw_length>23;
     state<=IDLE;
    end
    default: state<=IDLE;
   endcase
   if(upload_state && service_tx_valid) state<=WAIT_W;
  end
 end
endmodule
