// Independent 8-lane teacher accelerator. Memory: aligned 128-bit bursts, HWC features.
module teacher_inference (
    input wire clk,input wire reset_n,input wire model_ready,
    input wire start,output wire start_ready,output wire busy,
    output reg done,output wire error,
    output wire char_valid,input wire char_ready,output wire [6:0] char_data,
    output wire [5:0] result_length,
    output reg layer_done,output reg [2:0] completed_layer,
    output reg [31:0] cycles,output reg [31:0] prefetch_wait_cycles,
    output wire mem_req_valid,input wire mem_req_ready,output wire mem_req_write,
    output wire [22:0] mem_req_addr,output wire [127:0] mem_req_wdata,
    output wire [15:0] mem_req_wstrb,
    input wire mem_rsp_valid,output wire mem_rsp_ready,input wire [127:0] mem_rsp_rdata
);
    localparam IDLE=0,LAYER_INIT=1,WEIGHT_REQ=2,WEIGHT_RSP=3,BIAS_REQ=4,BIAS_RSP=5,
        GROUP_INIT=6,WAIT_PATCH=7,LOAD_BIAS=8,READ_K=9,MULT_K=10,ADD_K=11,
        FINISH_POINT=12,STORE_START=13,STORE_WAIT=14,GROUP_END=15,LAYER_END=16,
        CTC_START=17,CTC_STREAM=18,CTC_WAIT=19,COMPLETE=20,ARGMAX_SCAN=21,ARGMAX_COMMIT=22;
    reg [4:0] state;
    reg [2:0] layer_index;
    reg [7:0] cfg_in_h,cfg_in_w,cfg_in_ch,cfg_out_h,cfg_out_w,cfg_out_ch;
    reg [3:0] cfg_kernel_h,cfg_kernel_w,cfg_pad_h,cfg_pad_w,cfg_pool_h,cfg_pool_w,cfg_shift;
    reg cfg_relu;
    reg [22:0] cfg_weight_base,cfg_bias_base;
    always @(*) begin
        cfg_in_h=0; cfg_in_w=0; cfg_in_ch=0; cfg_out_h=0; cfg_out_w=0; cfg_out_ch=0;
        cfg_kernel_h=1; cfg_kernel_w=1; cfg_pad_h=0; cfg_pad_w=0;
        cfg_pool_h=1; cfg_pool_w=1; cfg_shift=0; cfg_relu=1;
        cfg_weight_base=0; cfg_bias_base=0;
        `include "teacher_config.vh"
    end
    wire [10:0] kernel_count=cfg_in_ch*cfg_kernel_h*cfg_kernel_w;
    wire [12:0] point_count=cfg_out_h*cfg_out_w*cfg_pool_h*cfg_pool_w;
    wire [22:0] input_base=layer_index==0 ? 23'h140000:
        layer_index[0] ? 23'h150000:23'h190000;
    wire [22:0] output_base=layer_index[0] ? 23'h190000:23'h150000;
    reg [7:0] group_channel;
    wire [3:0] active_lanes=cfg_out_ch-group_channel>=8 ? 4'd8:cfg_out_ch-group_channel;
    reg [2:0] weight_lane;
    reg [10:0] weight_k,compute_k;
    reg [1:0] bias_byte;
    reg [255:0] biases;

    // Independent producer and consumer cursors, both in pool-window order.
    reg [7:0] load_y,load_x,compute_y,compute_x;
    reg [3:0] load_py,load_px,compute_py,compute_px;
    reg [12:0] issued_points,consumed_points;
    reg load_bank,compute_bank;
    reg [1:0] patch_full;
    wire patch_ready,patch_done,patch_write;
    wire group_running=(state>=WAIT_PATCH && state<=STORE_WAIT) || state==ARGMAX_SCAN || state==ARGMAX_COMMIT;
    wire patch_start=group_running && patch_ready && !patch_done && !patch_full[load_bank] && issued_points<point_count;
    wire [10:0] patch_write_addr;
    wire signed [8:0] patch_write_data;
    wire patch_req_valid,patch_req_ready,patch_byte_ready;
    wire [22:0] patch_byte_addr;
    wire weight_read=state==WEIGHT_REQ || state==BIAS_REQ;
    wire weight_response=state==WEIGHT_RSP || state==BIAS_RSP;
    wire byte_req_valid=weight_read || patch_req_valid;
    wire byte_req_ready,byte_valid,byte_ready;
    wire [7:0] byte_data;
    wire [22:0] weight_byte_addr=state==BIAS_REQ ?
        cfg_bias_base+(group_channel+weight_lane)*4+bias_byte:
        cfg_weight_base+(group_channel+weight_lane)*kernel_count+weight_k;
    wire [22:0] byte_addr=weight_read ? weight_byte_addr:patch_byte_addr;
    assign patch_req_ready=!weight_read && byte_req_ready;
    assign byte_ready=weight_response || patch_byte_ready;
    teacher_patch_loader patch_loader (
        .clk(clk),.reset_n(reset_n),.start(patch_start),.ready(patch_ready),
        .input_base(input_base),.input_h(cfg_in_h),.input_w(cfg_in_w),.input_ch(cfg_in_ch),
        .kernel_h(cfg_kernel_h),.kernel_w(cfg_kernel_w),.pad_h(cfg_pad_h),.pad_w(cfg_pad_w),
        .center_y(load_y*cfg_pool_h+load_py),.center_x(load_x*cfg_pool_w+load_px),.first_layer(layer_index==0),
        .byte_req_valid(patch_req_valid),.byte_req_ready(patch_req_ready),.byte_addr(patch_byte_addr),
        .byte_valid(byte_valid && !weight_response),.byte_ready(patch_byte_ready),.byte_data(byte_data),
        .write_enable(patch_write),.write_addr(patch_write_addr),.write_data(patch_write_data),.done(patch_done)
    );
    wire [8:0] patch_q0,patch_q1;
    wire signed [8:0] feature_q=compute_bank ? patch_q1:patch_q0;
    teacher_patch_buffer input0(.clk(clk),.write_enable(patch_write && !load_bank),
        .write_addr(patch_write_addr[9:0]),.write_data(patch_write_data),
        .read_enable(state==READ_K),.read_addr(compute_k[9:0]),.read_data(patch_q0));
    teacher_patch_buffer input1(.clk(clk),.write_enable(patch_write && load_bank),
        .write_addr(patch_write_addr[9:0]),.write_data(patch_write_data),
        .read_enable(state==READ_K),.read_addr(compute_k[9:0]),.read_data(patch_q1));
    wire [63:0] weight_q;
    genvar g;
    generate for(g=0;g<8;g=g+1) begin: weight_banks
        teacher_weight_buffer bank(.clk(clk),
            .write_enable(state==WEIGHT_RSP && byte_valid && weight_lane==g),
            .write_addr(weight_k[9:0]),.write_data(byte_data),
            .read_enable(state==READ_K),.read_addr(compute_k[9:0]),.read_data(weight_q[g*8+:8]));
    end endgenerate
    wire [255:0] sums;
    teacher_mac8 mac (
        .clk(clk),.reset_n(reset_n),.load_bias(state==LOAD_BIAS),.biases(biases),
        .multiply_enable(state==MULT_K),.add_enable(state==ADD_K),
        .feature(feature_q),.weights(weight_q),.sums(sums),.overflow(error)
    );
    wire [127:0] quantized;
    generate for(g=0;g<8;g=g+1) begin: quantizers
        requantize quant (.accum($signed(sums[g*32+:32])),.shift(cfg_shift),.relu(cfg_relu),
                          .value(quantized[g*16+:16]));
    end endgenerate
    reg signed [15:0] pool_max[0:7];
    reg [127:0] pooled;
    reg signed [15:0] arg_best;
    reg [6:0] arg_class;
    reg [3:0] arg_lane;
    integer lane;
    always @(*) begin
        pooled=0;
        for(integer i=0;i<8;i=i+1) begin
            if(compute_py==0 && compute_px==0) pooled[i*16+:16]=quantized[i*16+:16];
            else pooled[i*16+:16]=$signed(quantized[i*16+:16])>$signed(pool_max[i]) ?
                quantized[i*16+:16]:pool_max[i];
        end
    end
    wire pool_last=compute_py==cfg_pool_h-1'b1 && compute_px==cfg_pool_w-1'b1;
    reg signed [15:0] best_logit[0:31];
    reg [6:0] best_class[0:31];
    reg [127:0] store_data;
    reg [22:0] store_address;
    wire store_ready,store_done;
    wire w_req_valid,w_req_ready,w_rsp_valid,w_rsp_ready;
    wire [22:0] w_req_addr;
    wire [127:0] w_req_data;
    wire [15:0] w_req_strobe;
    teacher_store store (
        .clk(clk),.reset_n(reset_n),.start(state==STORE_START),.ready(store_ready),
        .address(store_address),.data(store_data),.count(layer_index==7 ? {active_lanes,1'b0}:{1'b0,active_lanes}),.done(store_done),
        .req_valid(w_req_valid),.req_ready(w_req_ready),.req_addr(w_req_addr),.req_data(w_req_data),.req_strobe(w_req_strobe),
        .rsp_valid(w_rsp_valid),.rsp_ready(w_rsp_ready)
    );
    wire r_req_valid,r_req_ready,r_rsp_valid,r_rsp_ready;
    wire [22:0] r_req_addr;
    wire [127:0] r_rsp_data;
    teacher_byte_reader reader (
        .clk(clk),.reset_n(reset_n),.invalidate(state==LAYER_INIT),
        .byte_req_valid(byte_req_valid),.byte_req_ready(byte_req_ready),.byte_addr(byte_addr),
        .byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data),
        .req_valid(r_req_valid),.req_ready(r_req_ready),.req_addr(r_req_addr),
        .rsp_valid(r_rsp_valid),.rsp_ready(r_rsp_ready),.rsp_data(r_rsp_data)
    );
    teacher_mem_arbiter arbiter (
        .clk(clk),.reset_n(reset_n),.r_req_valid(r_req_valid),.r_req_ready(r_req_ready),.r_req_addr(r_req_addr),
        .r_rsp_valid(r_rsp_valid),.r_rsp_ready(r_rsp_ready),.r_rsp_data(r_rsp_data),
        .w_req_valid(w_req_valid),.w_req_ready(w_req_ready),.w_req_addr(w_req_addr),
        .w_req_data(w_req_data),.w_req_strobe(w_req_strobe),.w_rsp_valid(w_rsp_valid),.w_rsp_ready(w_rsp_ready),
        .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),.mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),.mem_req_wdata(mem_req_wdata),.mem_req_wstrb(mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),.mem_rsp_rdata(mem_rsp_rdata)
    );
    reg [4:0] ctc_index;
    wire ctc_ready,ctc_done;
    teacher_ctc decoder (
        .clk(clk),.reset_n(reset_n),.start(state==CTC_START),
        .symbol_valid(state==CTC_STREAM),.symbol_ready(ctc_ready),.symbol(best_class[ctc_index]),.symbol_last(ctc_index==31),
        .char_valid(char_valid),.char_ready(char_ready),.char_data(char_data),.done(ctc_done),.length(result_length)
    );
    assign busy=state!=IDLE;
    assign start_ready=state==IDLE && model_ready;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; layer_index<=0; group_channel<=0; weight_lane<=0; weight_k<=0; compute_k<=0;
            bias_byte<=0; biases<=0; load_y<=0; load_x<=0; compute_y<=0; compute_x<=0;
            load_py<=0; load_px<=0; compute_py<=0; compute_px<=0;
            issued_points<=0; consumed_points<=0; load_bank<=0; compute_bank<=0; patch_full<=0;
            store_data<=0; store_address<=0; ctc_index<=0; done<=0; layer_done<=0; completed_layer<=0;
            cycles<=0; prefetch_wait_cycles<=0;
            arg_best<=0;arg_class<=0;arg_lane<=0;
            for(lane=0;lane<8;lane=lane+1) pool_max[lane]<=0;
        end else begin
            done<=0; layer_done<=0;
            if(busy) cycles<=cycles+1'b1;
            if(state==WAIT_PATCH && !patch_full[compute_bank]) prefetch_wait_cycles<=prefetch_wait_cycles+1'b1;
            if(patch_start) begin
                issued_points<=issued_points+1'b1;
                if(load_px==cfg_pool_w-1'b1) begin
                    load_px<=0;
                    if(load_py==cfg_pool_h-1'b1) begin
                        load_py<=0;
                        if(load_x==cfg_out_w-1'b1) begin load_x<=0; load_y<=load_y+1'b1; end
                        else load_x<=load_x+1'b1;
                    end else load_py<=load_py+1'b1;
                end else load_px<=load_px+1'b1;
            end
            if(patch_done) begin patch_full[load_bank]<=1; load_bank<=!load_bank; end
            case(state)
                IDLE: if(start && start_ready) begin
                    state<=LAYER_INIT; layer_index<=0; cycles<=0; prefetch_wait_cycles<=0;
                end
                LAYER_INIT: begin
                    group_channel<=0; weight_lane<=0; weight_k<=0; biases<=0; state<=WEIGHT_REQ;
                end
                WEIGHT_REQ: if(byte_req_ready) state<=WEIGHT_RSP;
                WEIGHT_RSP: if(byte_valid) begin
                    if(weight_k==kernel_count-1'b1) begin
                        weight_k<=0;
                        if(weight_lane==active_lanes-1'b1) begin weight_lane<=0; bias_byte<=0; state<=BIAS_REQ; end
                        else begin weight_lane<=weight_lane+1'b1; state<=WEIGHT_REQ; end
                    end else begin weight_k<=weight_k+1'b1; state<=WEIGHT_REQ; end
                end
                BIAS_REQ: if(byte_req_ready) state<=BIAS_RSP;
                BIAS_RSP: if(byte_valid) begin
                    biases[weight_lane*32+bias_byte*8+:8]<=byte_data;
                    if(bias_byte==3) begin
                        bias_byte<=0;
                        if(weight_lane==active_lanes-1'b1) state<=GROUP_INIT;
                        else begin weight_lane<=weight_lane+1'b1; state<=BIAS_REQ; end
                    end else begin bias_byte<=bias_byte+1'b1; state<=BIAS_REQ; end
                end
                GROUP_INIT: begin
                    issued_points<=0; consumed_points<=0; load_bank<=0; compute_bank<=0; patch_full<=0;
                    load_y<=0; load_x<=0; load_py<=0; load_px<=0;
                    compute_y<=0; compute_x<=0; compute_py<=0; compute_px<=0;
                    state<=WAIT_PATCH;
                end
                WAIT_PATCH: if(patch_full[compute_bank]) begin compute_k<=0; state<=LOAD_BIAS; end
                LOAD_BIAS: state<=READ_K;
                READ_K: state<=MULT_K;
                MULT_K: state<=ADD_K;
                ADD_K: if(compute_k==kernel_count-1'b1) state<=FINISH_POINT;
                       else begin compute_k<=compute_k+1'b1; state<=READ_K; end
                FINISH_POINT: begin
                    for(lane=0;lane<8;lane=lane+1) pool_max[lane]<=$signed(pooled[lane*16+:16]);
                    patch_full[compute_bank]<=0; compute_bank<=!compute_bank;
                    consumed_points<=consumed_points+1'b1;
                    if(pool_last) begin
                        store_address<=output_base+((compute_y*cfg_out_w+compute_x)*cfg_out_ch+group_channel)*(layer_index==7 ? 2:1);
                        if(layer_index==7) begin
                            store_data<=pooled;
                            arg_best<=$signed(pooled[15:0]);arg_class<=group_channel[6:0];arg_lane<=1;
                            state<=ARGMAX_SCAN;
                        end else begin
                            for(lane=0;lane<8;lane=lane+1) store_data[lane*8+:8]<=pooled[lane*16+:8];
                            state<=STORE_START;
                        end
                        compute_py<=0; compute_px<=0;
                    end else begin
                        if(compute_px==cfg_pool_w-1'b1) begin compute_px<=0; compute_py<=compute_py+1'b1; end
                        else compute_px<=compute_px+1'b1;
                        state<=WAIT_PATCH;
                    end
                end
                ARGMAX_SCAN: if(arg_lane<active_lanes) begin
                    if($signed(store_data[arg_lane*16+:16])>arg_best) begin
                        arg_best<=$signed(store_data[arg_lane*16+:16]);arg_class<=group_channel[6:0]+arg_lane;
                    end
                    arg_lane<=arg_lane+1'b1;
                end else state<=ARGMAX_COMMIT;
                ARGMAX_COMMIT: begin
                    if(group_channel==0 || arg_best>best_logit[compute_x]) begin
                        best_logit[compute_x]<=arg_best;best_class[compute_x]<=arg_class;
                    end
                    state<=STORE_START;
                end
                STORE_START: if(store_ready) state<=STORE_WAIT;
                STORE_WAIT: if(store_done) begin
                    if(consumed_points==point_count) state<=GROUP_END;
                    else begin
                        if(compute_x==cfg_out_w-1'b1) begin compute_x<=0; compute_y<=compute_y+1'b1; end
                        else compute_x<=compute_x+1'b1;
                        state<=WAIT_PATCH;
                    end
                end
                GROUP_END: if(group_channel+8>=cfg_out_ch) state<=LAYER_END;
                    else begin
                        group_channel<=group_channel+8; weight_lane<=0; weight_k<=0; biases<=0; state<=WEIGHT_REQ;
                    end
                LAYER_END: begin
                    completed_layer<=layer_index; layer_done<=1;
                    if(layer_index==7) begin ctc_index<=0; state<=CTC_START; end
                    else begin layer_index<=layer_index+1'b1; state<=LAYER_INIT; end
                end
                CTC_START: state<=CTC_STREAM;
                CTC_STREAM: if(ctc_ready) begin
                    if(ctc_index==31) state<=CTC_WAIT; else ctc_index<=ctc_index+1'b1;
                end
                CTC_WAIT: if(ctc_done) state<=COMPLETE;
                COMPLETE: begin done<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
