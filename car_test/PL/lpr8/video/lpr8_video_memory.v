// Single owner of physical SDRAM. Video gets up to 3 bursts, then CNN gets one.
// A 1:1 split cannot sustain VGA capture plus 60Hz display during CNN traffic.
module teacher_video_memory #(parameter INIT_CYCLES=20000,REFRESH_CYCLES=450)(
 input wire clk,reset_n,
 input wire frame_valid,output wire frame_ready,input wire frame_write,
 input wire [20:0] frame_addr,input wire [127:0] frame_data,
 output reg frame_done,output reg [127:0] frame_read_data,
 input wire cnn_valid,output wire cnn_ready,input wire [170:0] cnn_command,
 output wire cnn_rsp_valid,input wire cnn_rsp_ready,output wire [127:0] cnn_rsp_data,
 output wire initialized,output wire [2:0] active_read_delay,
 output wire ras_n,cas_n,we_n,output wire [10:0] addr,output wire [1:0] ba,
 output wire [3:0] dm,inout wire [31:0] dq,output wire cke,cs_n
);
 localparam IDLE=0,FRAME_REQUEST=1,FRAME_RESPONSE=2,CNN_REQUEST=3,CNN_RESPONSE=4;
 reg [2:0] state,read_delay;
 reg frame_pending,frame_active,saved_write;
 reg [1:0] video_credit;
 reg [22:0] saved_addr;
 reg [127:0] saved_data;
 wire req_valid,req_ready,req_write,rsp_valid,rsp_ready;
 wire [22:0] req_addr;
 wire [127:0] req_data,rsp_data;
 wire [15:0] req_mask;
 wire [2:0] request_delay=state==CNN_REQUEST ? cnn_command[170:168]:read_delay;
 assign active_read_delay=read_delay;
 assign frame_ready=!frame_active && initialized;
 assign req_valid=state==FRAME_REQUEST ? frame_pending:state==CNN_REQUEST ? cnn_valid:1'b0;
 assign req_write=state==FRAME_REQUEST ? saved_write:state==CNN_REQUEST ? cnn_command[167]:1'b0;
 assign req_addr=state==FRAME_REQUEST ? saved_addr:cnn_command[166:144];
 assign req_data=state==FRAME_REQUEST ? (saved_write ? saved_data:128'b0):state==CNN_REQUEST ? cnn_command[143:16]:128'b0;
 assign req_mask=state==FRAME_REQUEST ? (saved_write ? 16'hffff:16'b0):state==CNN_REQUEST ? cnn_command[15:0]:16'b0;
 assign cnn_ready=state==CNN_REQUEST && req_ready;
 assign cnn_rsp_valid=state==CNN_RESPONSE && rsp_valid;
 assign cnn_rsp_data=rsp_data;
 assign rsp_ready=state==FRAME_RESPONSE || (state==CNN_RESPONSE && cnn_rsp_ready);
 // The 75MHz forwarded clock adds pad delay. Falling-edge input capture gives
 // SDRAM tAC plus input-pad delay a full cycle; rising-edge capture fails STA.
 teacher_sdram_adapter #(.INIT_CYCLES(INIT_CYCLES),.REFRESH_CYCLES(REFRESH_CYCLES),.SAMPLE_RISING(0)) adapter(
  .clk(clk),.reset_n(reset_n),.read_delay(request_delay),.req_valid(req_valid),.req_ready(req_ready),
  .req_write(req_write),.req_addr(req_addr),.req_wdata(req_data),.req_wstrb(req_mask),
  .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.initialized(initialized),
  .ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.addr(addr),.ba(ba),.dm(dm),.dq(dq),.cke(cke),.cs_n(cs_n));
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n) begin
   state<=IDLE;read_delay<=3;frame_pending<=0;frame_active<=0;video_credit<=0;
   saved_write<=0;saved_addr<=0;saved_data<=0;frame_done<=0;frame_read_data<=0;
  end else begin
   frame_done<=0;
   if(frame_valid && frame_ready) begin
    frame_active<=1;frame_pending<=1;saved_write<=frame_write;
    saved_addr<={frame_addr,2'b0};saved_data<=frame_data;
   end
   case(state)
    IDLE: if(cnn_valid && (!frame_pending || video_credit==3)) state<=CNN_REQUEST;
          else if(frame_pending) state<=FRAME_REQUEST;
    FRAME_REQUEST: if(req_valid && req_ready) begin
     state<=FRAME_RESPONSE;frame_pending<=0;
     if(video_credit!=3) video_credit<=video_credit+1'b1;
    end
    CNN_REQUEST: if(req_valid && req_ready) begin state<=CNN_RESPONSE;read_delay<=cnn_command[170:168];video_credit<=0;end
    FRAME_RESPONSE: if(rsp_valid && rsp_ready) begin
     frame_read_data<=rsp_data;frame_done<=1;frame_active<=0;state<=IDLE;
    end
    CNN_RESPONSE: if(rsp_valid && rsp_ready) state<=IDLE;
    default: state<=IDLE;
   endcase
  end
 end
endmodule
