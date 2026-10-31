// One outstanding request; payloads cross only through dual-clock FIFO storage.
module teacher_mem_cdc(
 input wire s_clk,s_reset_n,m_clk,m_reset_n,
 input wire s_valid,output wire s_ready,input wire [170:0] s_command,
 output wire s_rsp_valid,input wire s_rsp_ready,output wire [127:0] s_rsp_data,
 output wire m_valid,input wire m_ready,output wire [170:0] m_command,
 input wire m_rsp_valid,output wire m_rsp_ready,input wire [127:0] m_rsp_data
);
 reg source_busy,memory_busy;
 wire command_ready,command_valid,response_ready;
 assign s_ready=!source_busy && command_ready;
 assign m_valid=command_valid && !memory_busy;
 assign m_rsp_ready=memory_busy && response_ready;
 video_async_fifo #(.WIDTH(171),.AW(2)) requests(
  s_clk,s_reset_n,s_command,s_valid && !source_busy,command_ready,
  m_clk,m_reset_n,m_command,command_valid,m_ready && !memory_busy);
 video_async_fifo #(.WIDTH(128),.AW(2)) responses(
  m_clk,m_reset_n,m_rsp_data,m_rsp_valid && memory_busy,response_ready,
  s_clk,s_reset_n,s_rsp_data,s_rsp_valid,s_rsp_ready);
 always @(posedge s_clk or negedge s_reset_n)
  if(!s_reset_n) source_busy<=0;
  else if(s_valid && s_ready) source_busy<=1;
  else if(s_rsp_valid && s_rsp_ready) source_busy<=0;
 always @(posedge m_clk or negedge m_reset_n)
  if(!m_reset_n) memory_busy<=0;
  else if(m_valid && m_ready) memory_busy<=1;
  else if(m_rsp_valid && m_rsp_ready) memory_busy<=0;
endmodule
