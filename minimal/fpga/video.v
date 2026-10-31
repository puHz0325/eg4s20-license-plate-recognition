// car_test/PL/teacher/rtl/teacher_byte_reader.v
// One-entry 16-byte read cache. Exactly one byte request/response outstanding.
module teacher_byte_reader (
    input wire clk,input wire reset_n,input wire invalidate,
    input wire byte_req_valid,output wire byte_req_ready,input wire [22:0] byte_addr,
    output wire byte_valid,input wire byte_ready,output reg [7:0] byte_data,
    output wire req_valid,input wire req_ready,output wire [22:0] req_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [127:0] rsp_data
);
    localparam IDLE=0,REQUEST=1,RESPONSE=2,DELIVER=3;
    reg [1:0] state;
    reg cache_valid;
    reg [18:0] cache_tag;
    reg [127:0] cache_data;
    reg [22:0] saved_addr;
    assign byte_req_ready=state==IDLE && !invalidate;
    assign byte_valid=state==DELIVER;
    assign req_valid=state==REQUEST;
    assign req_addr={saved_addr[22:4],4'b0};
    assign rsp_ready=state==RESPONSE;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; cache_valid<=0; cache_tag<=0; cache_data<=0;
            saved_addr<=0; byte_data<=0;
        end else begin
            if(invalidate) cache_valid<=0;
            case(state)
                IDLE: if(byte_req_valid && byte_req_ready) begin
                    saved_addr<=byte_addr;
                    if(cache_valid && cache_tag==byte_addr[22:4]) begin
                        byte_data<=cache_data[byte_addr[3:0]*8+:8]; state<=DELIVER;
                    end else state<=REQUEST;
                end
                REQUEST: if(req_ready) state<=RESPONSE;
                RESPONSE: if(rsp_valid) begin
                    cache_tag<=saved_addr[22:4]; cache_data<=rsp_data;
                    cache_valid<=!invalidate;
                    byte_data<=rsp_data[saved_addr[3:0]*8+:8]; state<=DELIVER;
                end
                DELIVER: if(byte_ready) state<=IDLE;
                default: begin state<=IDLE; cache_valid<=0; end
            endcase
        end
    end
endmodule

// car_test/PL/teacher/rtl/teacher_ctc.v
// Raw CTC with elastic character output. No grammar correction or length padding.
module teacher_ctc (
    input wire clk,input wire reset_n,input wire start,
    input wire symbol_valid,output wire symbol_ready,
    input wire [6:0] symbol,input wire symbol_last,
    output reg char_valid,input wire char_ready,output reg [6:0] char_data,
    output reg done,output reg [5:0] length
);
    reg running,end_pending;
    reg [6:0] previous;
    assign symbol_ready=running && (!char_valid || char_ready);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            running<=0; end_pending<=0; previous<=67;
            char_valid<=0; char_data<=0; done<=0; length<=0;
        end else begin
            done<=0;
            if(char_valid && char_ready) char_valid<=0;
            if(start) begin
                running<=1; end_pending<=0; previous<=67; char_valid<=0; length<=0;
            end else begin
                if(symbol_valid && symbol_ready) begin
                    previous<=symbol;
                    if(symbol!=67 && symbol!=previous) begin
                        char_data<=symbol; char_valid<=1; length<=length+1'b1;
                    end
                    if(symbol_last) begin running<=0; end_pending<=1; end
                end
                if(end_pending && (!char_valid || char_ready)) begin
                    done<=1; end_pending<=0;
                end
            end
        end
    end
endmodule

// car_test/PL/teacher/rtl/teacher_inference.v
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
        // Generated from frozen rtl_model.json; addresses in bytes.
case(layer_index)
3'd0: begin
    cfg_in_h = 32;
    cfg_in_w = 128;
    cfg_in_ch = 1;
    cfg_out_h = 32;
    cfg_out_w = 128;
    cfg_out_ch = 16;
    cfg_kernel_h = 3;
    cfg_kernel_w = 3;
    cfg_pad_h = 1;
    cfg_pad_w = 1;
    cfg_pool_h = 1;
    cfg_pool_w = 1;
    cfg_shift = 9;
    cfg_relu = 1;
    cfg_weight_base = 1048576;
    cfg_bias_base = 1203088;
end
3'd1: begin
    cfg_in_h = 32;
    cfg_in_w = 128;
    cfg_in_ch = 16;
    cfg_out_h = 16;
    cfg_out_w = 64;
    cfg_out_ch = 16;
    cfg_kernel_h = 3;
    cfg_kernel_w = 3;
    cfg_pad_h = 1;
    cfg_pad_w = 1;
    cfg_pool_h = 2;
    cfg_pool_w = 2;
    cfg_shift = 7;
    cfg_relu = 1;
    cfg_weight_base = 1048720;
    cfg_bias_base = 1203152;
end
3'd2: begin
    cfg_in_h = 16;
    cfg_in_w = 64;
    cfg_in_ch = 16;
    cfg_out_h = 8;
    cfg_out_w = 32;
    cfg_out_ch = 32;
    cfg_kernel_h = 3;
    cfg_kernel_w = 3;
    cfg_pad_h = 1;
    cfg_pad_w = 1;
    cfg_pool_h = 2;
    cfg_pool_w = 2;
    cfg_shift = 8;
    cfg_relu = 1;
    cfg_weight_base = 1051024;
    cfg_bias_base = 1203216;
end
3'd3: begin
    cfg_in_h = 8;
    cfg_in_w = 32;
    cfg_in_ch = 32;
    cfg_out_h = 8;
    cfg_out_w = 32;
    cfg_out_ch = 48;
    cfg_kernel_h = 3;
    cfg_kernel_w = 3;
    cfg_pad_h = 1;
    cfg_pad_w = 1;
    cfg_pool_h = 1;
    cfg_pool_w = 1;
    cfg_shift = 8;
    cfg_relu = 1;
    cfg_weight_base = 1055632;
    cfg_bias_base = 1203344;
end
3'd4: begin
    cfg_in_h = 8;
    cfg_in_w = 32;
    cfg_in_ch = 48;
    cfg_out_h = 4;
    cfg_out_w = 32;
    cfg_out_ch = 64;
    cfg_kernel_h = 3;
    cfg_kernel_w = 3;
    cfg_pad_h = 1;
    cfg_pad_w = 1;
    cfg_pool_h = 2;
    cfg_pool_w = 1;
    cfg_shift = 8;
    cfg_relu = 1;
    cfg_weight_base = 1069456;
    cfg_bias_base = 1203536;
end
3'd5: begin
    cfg_in_h = 4;
    cfg_in_w = 32;
    cfg_in_ch = 64;
    cfg_out_h = 1;
    cfg_out_w = 32;
    cfg_out_ch = 64;
    cfg_kernel_h = 3;
    cfg_kernel_w = 3;
    cfg_pad_h = 1;
    cfg_pad_w = 1;
    cfg_pool_h = 4;
    cfg_pool_w = 1;
    cfg_shift = 7;
    cfg_relu = 1;
    cfg_weight_base = 1097104;
    cfg_bias_base = 1203792;
end
3'd6: begin
    cfg_in_h = 1;
    cfg_in_w = 32;
    cfg_in_ch = 64;
    cfg_out_h = 1;
    cfg_out_w = 32;
    cfg_out_ch = 128;
    cfg_kernel_h = 1;
    cfg_kernel_w = 1;
    cfg_pad_h = 0;
    cfg_pad_w = 0;
    cfg_pool_h = 1;
    cfg_pool_w = 1;
    cfg_shift = 7;
    cfg_relu = 1;
    cfg_weight_base = 1133968;
    cfg_bias_base = 1204048;
end
3'd7: begin
    cfg_in_h = 1;
    cfg_in_w = 32;
    cfg_in_ch = 128;
    cfg_out_h = 1;
    cfg_out_w = 32;
    cfg_out_ch = 68;
    cfg_kernel_h = 1;
    cfg_kernel_w = 7;
    cfg_pad_h = 0;
    cfg_pad_w = 3;
    cfg_pool_h = 1;
    cfg_pool_w = 1;
    cfg_shift = 3;
    cfg_relu = 0;
    cfg_weight_base = 1142160;
    cfg_bias_base = 1204560;
end
default: begin end
endcase

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

// car_test/PL/teacher/rtl/teacher_mac8.v
// READ is external, then multiply_enable, then add_enable: one K per 3 clocks.
module teacher_mac8 (
    input wire clk, input wire reset_n,
    input wire load_bias, input wire [255:0] biases,
    input wire multiply_enable, input wire add_enable,
    input wire signed [8:0] feature, input wire [63:0] weights,
    output wire [255:0] sums, output wire overflow
);
    wire [7:0] overflow_lanes;
    genvar lane;
    generate for(lane=0; lane<8; lane=lane+1) begin: lanes
        reg signed [16:0] product;
        reg signed [31:0] accum;
        reg overflow_q;
        wire signed [7:0] weight=$signed(weights[lane*8+:8]);
        wire signed [32:0] next_sum=
            $signed({accum[31],accum})+$signed({{16{product[16]}},product});
        assign sums[lane*32+:32]=accum;
        assign overflow_lanes[lane]=overflow_q;
        always @(posedge clk or negedge reset_n) begin
            if(!reset_n) begin product<=0; accum<=0; overflow_q<=0; end
            else begin
                if(load_bias) accum<=$signed(biases[lane*32+:32]);
                else if(add_enable) begin
                    accum<=next_sum[31:0];
                    if(next_sum[32]!=next_sum[31]) overflow_q<=1;
                end
                if(multiply_enable) product<=feature*weight;
            end
        end
    end endgenerate
    assign overflow=|overflow_lanes;
endmodule

// car_test/PL/teacher/rtl/teacher_mem_arbiter.v
// Registered grant, held through response. A pending store gets next idle slot.
module teacher_mem_arbiter (
    input wire clk,input wire reset_n,
    input wire r_req_valid,output wire r_req_ready,input wire [22:0] r_req_addr,
    output wire r_rsp_valid,input wire r_rsp_ready,output wire [127:0] r_rsp_data,
    input wire w_req_valid,output wire w_req_ready,input wire [22:0] w_req_addr,
    input wire [127:0] w_req_data,input wire [15:0] w_req_strobe,
    output wire w_rsp_valid,input wire w_rsp_ready,
    output wire mem_req_valid,input wire mem_req_ready,output wire mem_req_write,
    output wire [22:0] mem_req_addr,output wire [127:0] mem_req_wdata,
    output wire [15:0] mem_req_wstrb,
    input wire mem_rsp_valid,output wire mem_rsp_ready,input wire [127:0] mem_rsp_rdata
);
    localparam IDLE=0,READ_REQ=1,READ_RSP=2,WRITE_REQ=3,WRITE_RSP=4;
    reg [2:0] state;
    assign mem_req_valid=state==READ_REQ ? r_req_valid : state==WRITE_REQ ? w_req_valid : 1'b0;
    assign mem_req_write=state==WRITE_REQ;
    assign mem_req_addr=state==WRITE_REQ ? w_req_addr:r_req_addr;
    assign mem_req_wdata=state==WRITE_REQ ? w_req_data:128'b0;
    assign mem_req_wstrb=state==WRITE_REQ ? w_req_strobe:16'b0;
    assign r_req_ready=state==READ_REQ && mem_req_ready;
    assign w_req_ready=state==WRITE_REQ && mem_req_ready;
    assign r_rsp_valid=state==READ_RSP && mem_rsp_valid;
    assign w_rsp_valid=state==WRITE_RSP && mem_rsp_valid;
    assign r_rsp_data=mem_rsp_rdata;
    assign mem_rsp_ready=state==READ_RSP ? r_rsp_ready:state==WRITE_RSP ? w_rsp_ready:1'b0;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) state<=IDLE;
        else case(state)
            IDLE: if(w_req_valid) state<=WRITE_REQ; else if(r_req_valid) state<=READ_REQ;
            READ_REQ: if(mem_req_valid && mem_req_ready) state<=READ_RSP;
            WRITE_REQ: if(mem_req_valid && mem_req_ready) state<=WRITE_RSP;
            READ_RSP,WRITE_RSP: if(mem_rsp_valid && mem_rsp_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule

// car_test/PL/teacher/rtl/teacher_patch_buffer.v
module teacher_patch_buffer(
    input wire clk,input wire write_enable,input wire [9:0] write_addr,input wire [8:0] write_data,
    input wire read_enable,input wire [9:0] read_addr,output reg [8:0] read_data
);
    (* ram_style="block" *) reg [8:0] memory[0:1023];
    always @(posedge clk) begin
        if(write_enable) memory[write_addr]<=write_data;
        if(read_enable) read_data<=memory[read_addr];
    end
endmodule

// car_test/PL/teacher/rtl/teacher_patch_loader.v
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

// car_test/PL/teacher/rtl/teacher_store.v
// Write 1..16 consecutive bytes; split at burst boundary, wait for every ACK.
module teacher_store (
    input wire clk,input wire reset_n,
    input wire start,output wire ready,input wire [22:0] address,
    input wire [127:0] data,input wire [4:0] count,output reg done,
    output wire req_valid,input wire req_ready,output wire [22:0] req_addr,
    output wire [127:0] req_data,output wire [15:0] req_strobe,
    input wire rsp_valid,output wire rsp_ready
);
    localparam IDLE=0,REQUEST=1,RESPONSE=2;
    reg [1:0] state;
    reg [22:0] saved_addr;
    reg [255:0] expanded_data;
    reg [31:0] expanded_mask;
    assign ready=state==IDLE;
    assign req_valid=state==REQUEST;
    assign req_addr=saved_addr;
    assign req_data=expanded_data[127:0];
    assign req_strobe=expanded_mask[15:0];
    assign rsp_ready=state==RESPONSE;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; saved_addr<=0; expanded_data<=0; expanded_mask<=0; done<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    saved_addr<={address[22:4],4'b0};
                    expanded_data<={128'b0,data}<<(address[3:0]*8);
                    expanded_mask<=((32'h1<<count)-1'b1)<<address[3:0];
                    state<=REQUEST;
                end
                REQUEST: if(req_ready) state<=RESPONSE;
                RESPONSE: if(rsp_valid) begin
                    if(|expanded_mask[31:16]) begin
                        saved_addr<=saved_addr+23'd16;
                        expanded_data<=expanded_data>>128; expanded_mask<=expanded_mask>>16;
                        state<=REQUEST;
                    end else begin state<=IDLE; done<=1; end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// car_test/PL/teacher/rtl/teacher_weight_buffer.v
// Dedicated simple dual-port block RAM per MAC lane. No reset of storage.
module teacher_weight_buffer (
    input wire clk,input wire write_enable,input wire [9:0] write_addr,input wire [7:0] write_data,
    input wire read_enable,input wire [9:0] read_addr,output reg [7:0] read_data
);
    (* ram_style="block" *) reg [7:0] memory[0:1023];
    always @(posedge clk) begin
        if(write_enable) memory[write_addr]<=write_data;
        if(read_enable) read_data<=memory[read_addr];
    end
endmodule

// car_test/PL/teacher/board/teacher_board_service.v
// UART byte protocol, model CRC, inference, and physical-memory layer CRCs.
// Generated model integrity gate; protocol and timing remain unchanged.
`ifndef TEACHER_MODEL_IDENTITY_VH
`define TEACHER_MODEL_IDENTITY_VH
`define TEACHER_MODEL_CRC32 32'hD5CA7402
`endif

module teacher_board_service #(parameter CLOCK_HZ=25000000,VIDEO_STATUS=0)(
    input wire clk,input wire reset_n,input wire initialized,
    input wire rx_valid,input wire [7:0] rx_data,output wire rx_ready,output wire command_idle,
    output wire tx_valid,input wire tx_ready,output reg [7:0] tx_data,
    output reg model_ready,output wire busy,output wire error,output reg [2:0] read_delay,output reg camera_mode,
    input wire [127:0] video_status,
    output wire mem_req_valid,input wire mem_req_ready,output wire mem_req_write,
    output wire [22:0] mem_req_addr,output wire [127:0] mem_req_wdata,output wire [15:0] mem_req_wstrb,
    input wire mem_rsp_valid,output wire mem_rsp_ready,input wire [127:0] mem_rsp_rdata
);
    localparam IDLE=0,ADDRESS=1,LENGTH=2,UPLOAD=3,WRITE_REQ=4,WRITE_WAIT=5,UPLOAD_CRC=6,
        SCAN_REQ=7,SCAN_WAIT=8,SCAN_BYTES=9,INFER_START=10,INFER_WAIT=11,TRANSMIT=12,
        TIMING=13,RAW_REQ=14,RAW_WAIT=15;
    reg [3:0] state;
    reg [7:0] command;
    reg [1:0] field_index;
    reg [3:0] byte_index;
    reg [22:0] upload_addr,scan_addr;
    reg [15:0] upload_blocks;
    reg [13:0] scan_blocks;
    reg [127:0] block_data;
    reg [31:0] crc,expected_crc,model_crc,upload_crc,packet_crc;
    reg [6:0] tx_index;
    reg protocol_error,scan_overrun,finished,scan_model;
    reg [2:0] scan_layer;
    reg [255:0] layer_crc,layer_cycles,characters;
    reg [5:0] character_count;
    wire core_start_ready,core_done,core_error,core_char_valid,core_layer_done;
    wire [6:0] core_char;
    wire [5:0] core_length;
    wire [2:0] core_layer;
    wire [31:0] core_cycles,core_wait;
    wire c_valid,c_ready,c_write,c_rsp_valid,c_rsp_ready;
    wire [22:0] c_addr;
    wire [127:0] c_wdata;
    wire [15:0] c_strobe;
    teacher_inference core(.clk(clk),.reset_n(reset_n),.model_ready(model_ready),
        .start(state==INFER_START),.start_ready(core_start_ready),.busy(busy),.done(core_done),.error(core_error),
        .char_valid(core_char_valid),.char_ready(1'b1),.char_data(core_char),.result_length(core_length),
        .layer_done(core_layer_done),.completed_layer(core_layer),.cycles(core_cycles),.prefetch_wait_cycles(core_wait),
        .mem_req_valid(c_valid),.mem_req_ready(c_ready),.mem_req_write(c_write),.mem_req_addr(c_addr),
        .mem_req_wdata(c_wdata),.mem_req_wstrb(c_strobe),.mem_rsp_valid(c_rsp_valid),.mem_rsp_ready(c_rsp_ready),.mem_rsp_rdata(mem_rsp_rdata));
    assign error=core_error || protocol_error || scan_overrun;
    assign command_idle=state==IDLE;
    assign rx_ready=state==IDLE || state==ADDRESS || state==LENGTH || state==UPLOAD || state==UPLOAD_CRC || state==TIMING;
    function [31:0] crc_byte;
        input [31:0] prior; input [7:0] data;
        reg [31:0] temp; integer j;
        begin
            temp=prior^{24'b0,data};
            for(j=0;j<8;j=j+1) temp=temp[0] ? (temp>>1)^32'hedb88320:temp>>1;
            crc_byte=temp;
        end
    endfunction
    function [13:0] layer_blocks;
        input [2:0] layer;
        begin case(layer)
            0:layer_blocks=4096;1:layer_blocks=1024;2:layer_blocks=512;3:layer_blocks=768;
            4:layer_blocks=512;5:layer_blocks=128;6:layer_blocks=256;7:layer_blocks=272;
        endcase end
    endfunction
    wire h_valid=state==WRITE_REQ || state==SCAN_REQ || state==RAW_REQ;
    wire h_ready,h_rsp_valid;
    wire h_rsp_ready=state==WRITE_WAIT || state==SCAN_WAIT || state==RAW_WAIT;
    // Hold selection until ACK; both request payloads remain stable under stalls.
    localparam A_IDLE=0,H_REQ=1,H_RSP=2,C_REQ=3,C_RSP=4;
    reg [2:0] owner;
    assign mem_req_valid=owner==H_REQ ? h_valid:owner==C_REQ ? c_valid:1'b0;
    assign mem_req_write=owner==H_REQ ? state==WRITE_REQ:owner==C_REQ ? c_write:1'b0;
    assign mem_req_addr=owner==H_REQ ? (state==WRITE_REQ || state==RAW_REQ ? upload_addr:scan_addr):c_addr;
    assign mem_req_wdata=owner==H_REQ ? (state==WRITE_REQ ? block_data:128'b0):owner==C_REQ ? c_wdata:128'b0;
    assign mem_req_wstrb=owner==H_REQ ? (state==WRITE_REQ ? 16'hffff:16'b0):owner==C_REQ ? c_strobe:16'b0;
    assign h_ready=owner==H_REQ && mem_req_ready;
    assign c_ready=owner==C_REQ && mem_req_ready;
    assign h_rsp_valid=owner==H_RSP && mem_rsp_valid;
    assign c_rsp_valid=owner==C_RSP && mem_rsp_valid;
    assign mem_rsp_ready=owner==H_RSP ? h_rsp_ready:owner==C_RSP ? c_rsp_ready:1'b0;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) owner<=A_IDLE;
        else case(owner)
            A_IDLE: if(h_valid) owner<=H_REQ; else if(c_valid) owner<=C_REQ;
            H_REQ: if(mem_req_valid && mem_req_ready) owner<=H_RSP;
            C_REQ: if(mem_req_valid && mem_req_ready) owner<=C_RSP;
            H_RSP,C_RSP: if(mem_rsp_valid && mem_rsp_ready) owner<=A_IDLE;
            default: owner<=A_IDLE;
        endcase
    end
    localparam [1:0] CLOCK_CODE=CLOCK_HZ==25000000 ? 2'd1:2'd0;
    wire [7:0] flags={CLOCK_CODE,finished,scan_overrun,protocol_error,core_error,model_ready,initialized};
    assign tx_valid=state==TRANSMIT;
    always @(*) begin
        tx_data=0;
        case(tx_index)
            0:tx_data="T";1:tx_data="C";2:tx_data="H";3:tx_data="1";
            4:tx_data=command;5:tx_data=flags;6:tx_data={2'b0,character_count};7:tx_data=1;
            120:tx_data=8'h28;121:tx_data=8'h10;122:tx_data=8'h26;123:tx_data=8'h20;
            default: begin
                if(tx_index<12) tx_data=model_crc[(tx_index-8)*8+:8];
                else if(tx_index<16) tx_data=upload_crc[(tx_index-12)*8+:8];
                else if(tx_index<20) tx_data=core_cycles[(tx_index-16)*8+:8];
                else if(tx_index<24) tx_data=core_wait[(tx_index-20)*8+:8];
                else if(tx_index<56) tx_data=command=="T" && tx_index==24 ? {5'b0,read_delay}:
                    (command=="A" || command=="B") && tx_index==24 ? {7'b0,camera_mode}:characters[(tx_index-24)*8+:8];
                else if(tx_index<88) tx_data=layer_crc[(tx_index-56)*8+:8];
                else if(tx_index<120) tx_data=layer_cycles[(tx_index-88)*8+:8];
                else tx_data=(~packet_crc)>>((tx_index-124)*8);
            end
        endcase
    end
    task begin_response;
        begin state<=TRANSMIT;tx_index<=0;packet_crc<=32'hffffffff;end
    endtask
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; command<=0; field_index<=0; byte_index<=0; upload_addr<=0; scan_addr<=0;
            upload_blocks<=0;scan_blocks<=0;block_data<=0;crc<=32'hffffffff;expected_crc<=0;
            model_crc<=0;upload_crc<=0;packet_crc<=32'hffffffff;tx_index<=0;model_ready<=0;
            protocol_error<=0;scan_overrun<=0;finished<=0;scan_model<=0;scan_layer<=0;
            layer_crc<=0;layer_cycles<=0;characters<=0;character_count<=0;
            read_delay<=3;
            camera_mode<=0;
        end else begin
            if(core_done) finished<=1;
            if(core_char_valid) begin
                if(character_count<32) characters[character_count*8+:8]<={1'b0,core_char};
                character_count<=character_count+1'b1;
            end
            if(core_layer_done && state!=INFER_WAIT) scan_overrun<=1;
            case(state)
                IDLE: if(rx_valid) begin
                    command<=rx_data;protocol_error<=0;
                    case(rx_data)
                        "P": begin_response();
                        "A": begin camera_mode<=1;begin_response();end
                        "B": begin camera_mode<=0;begin_response();end
                        "S": begin
                            if(VIDEO_STATUS) layer_crc[127:0]<=video_status;else protocol_error<=1;
                            begin_response();
                        end
                        "W","R": begin state<=ADDRESS;field_index<=0;upload_addr<=0;end
                        "T": state<=TIMING;
                        "V": if(initialized) begin
                            model_ready<=0;scan_model<=1;scan_addr<=23'h100000;scan_blocks<=9766;
                            crc<=32'hffffffff;state<=SCAN_REQ;
                        end else begin protocol_error<=1;begin_response();end
                        "I": if(initialized && model_ready && core_start_ready) begin
                            finished<=0;scan_overrun<=0;characters<=0;character_count<=0;layer_crc<=0;layer_cycles<=0;state<=INFER_START;
                        end else begin protocol_error<=1;begin_response();end
                        default: begin protocol_error<=1;begin_response();end
                    endcase
                end
                ADDRESS: if(rx_valid) begin
                    if(field_index==2) upload_addr[22:16]<=rx_data[6:0];
                    else upload_addr[field_index*8+:8]<=rx_data;
                    if(field_index==2) begin state<=command=="R" ? RAW_REQ:LENGTH;field_index<=0;end else field_index<=field_index+1'b1;
                end
                TIMING: if(rx_valid) begin
                    if(rx_data<2 || rx_data>4) protocol_error<=1;
                    else begin read_delay<=rx_data[2:0];model_ready<=0;end
                    begin_response();
                end
                RAW_REQ: if(h_ready) state<=RAW_WAIT;
                RAW_WAIT: if(h_rsp_valid) begin layer_crc[127:0]<=mem_rsp_rdata;begin_response();end
                LENGTH: if(rx_valid) begin
                    upload_blocks[field_index*8+:8]<=rx_data;
                    if(field_index==1) begin
                        if(upload_addr[3:0]!=0 || upload_addr<23'h100000 ||
                           upload_addr+({rx_data,upload_blocks[7:0]}<<4)>23'h150000 ||
                           {rx_data,upload_blocks[7:0]}==0 || {rx_data,upload_blocks[7:0]}>1024) begin
                            protocol_error<=1;begin_response();
                        end else begin
                            if(upload_addr<23'h140000) model_ready<=0;
                            byte_index<=0;crc<=32'hffffffff;state<=UPLOAD;
                        end
                    end else field_index<=1;
                end
                UPLOAD: if(rx_valid) begin
                    block_data[byte_index*8+:8]<=rx_data;crc<=crc_byte(crc,rx_data);
                    if(byte_index==15) begin byte_index<=0;state<=WRITE_REQ;end else byte_index<=byte_index+1'b1;
                end
                WRITE_REQ: if(h_ready) state<=WRITE_WAIT;
                WRITE_WAIT: if(h_rsp_valid) begin
                    upload_addr<=upload_addr+16;
                    if(upload_blocks==1) begin state<=UPLOAD_CRC;field_index<=0;expected_crc<=0;upload_crc<=~crc;end
                    else begin upload_blocks<=upload_blocks-1'b1;state<=UPLOAD;end
                end
                UPLOAD_CRC: if(rx_valid) begin
                    expected_crc[field_index*8+:8]<=rx_data;
                    if(field_index==3) begin
                        if({rx_data,expected_crc[23:0]}!=upload_crc) protocol_error<=1;
                        begin_response();
                    end else field_index<=field_index+1'b1;
                end
                INFER_START: if(core_start_ready) state<=INFER_WAIT;
                INFER_WAIT: begin
                    if(core_layer_done) begin
                        scan_model<=0;scan_layer<=core_layer;
                        scan_addr<=core_layer[0] ? 23'h190000:23'h150000;
                        scan_blocks<=layer_blocks(core_layer);crc<=32'hffffffff;
                        layer_cycles[core_layer*32+:32]<=core_cycles;state<=SCAN_REQ;
                    end else if(finished) begin_response();
                end
                SCAN_REQ: if(h_ready) state<=SCAN_WAIT;
                SCAN_WAIT: if(h_rsp_valid) begin block_data<=mem_rsp_rdata;byte_index<=0;state<=SCAN_BYTES;end
                SCAN_BYTES: begin
                    crc<=crc_byte(crc,block_data[byte_index*8+:8]);
                    if(byte_index==15) begin
                        if(scan_blocks==1) begin
                            if(scan_model) begin
                                model_crc<=~crc_byte(crc,block_data[127:120]);
                                model_ready<=~crc_byte(crc,block_data[127:120])==`TEACHER_MODEL_CRC32;
                                if(~crc_byte(crc,block_data[127:120])!=`TEACHER_MODEL_CRC32) protocol_error<=1;
                                begin_response();
                            end else begin
                                layer_crc[scan_layer*32+:32]<=~crc_byte(crc,block_data[127:120]);state<=INFER_WAIT;
                            end
                        end else begin scan_blocks<=scan_blocks-1'b1;scan_addr<=scan_addr+16;state<=SCAN_REQ;end
                    end else byte_index<=byte_index+1'b1;
                end
                TRANSMIT: if(tx_ready) begin
                    if(tx_index<124) packet_crc<=crc_byte(packet_crc,tx_data);
                    if(tx_index==127) state<=IDLE;else tx_index<=tx_index+1'b1;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// car_test/PL/teacher/board/teacher_sdram_adapter.v
// Single outstanding command; preserve bytes via read-modify-write for masks.
module teacher_sdram_adapter # (parameter INIT_CYCLES=15000,REFRESH_CYCLES=150,SAMPLE_RISING=1)(
    input wire clk,input wire reset_n,input wire [2:0] read_delay,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [22:0] req_addr,input wire [127:0] req_wdata,input wire [15:0] req_wstrb,
    output wire rsp_valid,input wire rsp_ready,output reg [127:0] rsp_data,
    output wire initialized,output wire ras_n,cas_n,we_n,
    output wire [10:0] addr,output wire [1:0] ba,output wire [3:0] dm,
    inout wire [31:0] dq,output wire cke,cs_n
);
    localparam IDLE=0,READ_REQ=1,READ_WAIT=2,WRITE_REQ=3,WRITE_WAIT=4,RESPONSE=5;
    reg [2:0] state;
    reg [20:0] saved_addr;
    reg [127:0] saved_data,merged;
    reg [15:0] saved_strobe;
    reg saved_write;
    reg [2:0] saved_delay;
    wire ctrl_ready,ctrl_done;
    wire [127:0] ctrl_data;
    integer b;
    assign req_ready=state==IDLE && initialized;
    assign rsp_valid=state==RESPONSE;
    teacher_sdram_controller #(.INIT_CYCLES(INIT_CYCLES),.REFRESH_CYCLES(REFRESH_CYCLES),.SAMPLE_RISING(SAMPLE_RISING)) controller(
        .clk(clk),.reset_n(reset_n),.read_delay(saved_delay),.request_valid(state==READ_REQ || state==WRITE_REQ),
        .request_ready(ctrl_ready),.request_write(state==WRITE_REQ),.request_addr(saved_addr),
        .request_data(merged),.done(ctrl_done),.read_data(ctrl_data),.initialized(initialized),
        .ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.addr(addr),.ba(ba),.dm(dm),.dq(dq),.cke(cke),.cs_n(cs_n));
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin state<=IDLE; saved_addr<=0; saved_data<=0; merged<=0; saved_strobe<=0; saved_write<=0; rsp_data<=0;saved_delay<=3;end
        else case(state)
            IDLE: if(req_valid && req_ready) begin
                saved_addr<=req_addr[22:2]; saved_data<=req_wdata; saved_strobe<=req_wstrb;
                saved_write<=req_write;
                saved_delay<=read_delay;
                if(req_write && req_wstrb==16'hffff) begin merged<=req_wdata; state<=WRITE_REQ; end
                else state<=READ_REQ;
            end
            READ_REQ: if(ctrl_ready) state<=READ_WAIT;
            READ_WAIT: if(ctrl_done) begin
                rsp_data<=ctrl_data;
                if(saved_write) begin
                    for(b=0;b<16;b=b+1) merged[b*8+:8]<=saved_strobe[b] ? saved_data[b*8+:8]:ctrl_data[b*8+:8];
                    state<=WRITE_REQ;
                end else state<=RESPONSE;
            end
            WRITE_REQ: if(ctrl_ready) state<=WRITE_WAIT;
            WRITE_WAIT: if(ctrl_done) state<=RESPONSE;
            RESPONSE: if(rsp_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule

// car_test/PL/teacher/board/teacher_sdram_controller.v
// Diagnostic-specific controller with runtime read-wait calibration.
// 2M x 32 SDR SDRAM, geometry: bank[20:19], row[18:8], column[7:0].
// Commands are sampled on the opposite clock edge (phase-shifted memory clock).
// One aligned 4-word burst per request; ready/valid acceptance, done exactly once.
module teacher_sdram_controller #(parameter INIT_CYCLES=15000, REFRESH_CYCLES=150,SAMPLE_RISING=1)(
    input wire clk,input wire reset_n,input wire [2:0] read_delay,
    input wire request_valid,output wire request_ready,input wire request_write,
    input wire [20:0] request_addr,input wire [127:0] request_data,
    output reg done,output reg [127:0] read_data,output reg initialized,
    output reg ras_n,cas_n,we_n,output reg [10:0] addr,output reg [1:0] ba,
    output wire [3:0] dm,inout wire [31:0] dq,output wire cke,cs_n
);
    localparam INIT=0,IPRE=1,IWAIT=2,IREF1=3,IREF2=4,IMODE=5,IDLE=6,
        ACT=7,ACTWAIT=8,WCMD=9,WDATA=10,WREC=11,RCMD=12,RWAIT=13,
        RDATA=14,PRE=15,PWAIT=16,REF=17,REFWAIT=18;
    reg [4:0] state,next_wait;
    reg [15:0] delay_count,refresh_count;
    reg [20:0] saved_addr;
    reg [127:0] saved_data;
    reg saved_write;
    reg [1:0] word_index;
    reg [31:0] write_dq;
    reg dq_enable;
    // Legacy video keeps falling-edge capture. The diagnostic clock uses rising-
    // edge capture, half a clock after SDRAM launch. Its old value is consumed by
    // the result register on the next rising edge, preserving the CAS3 schedule.
    reg [31:0] sampled_dq;
    generate if(SAMPLE_RISING) begin: rising_capture
        always @(posedge clk) sampled_dq<=dq;
    end else begin: falling_capture
        always @(negedge clk) sampled_dq<=dq;
    end endgenerate
    assign dq=dq_enable ? write_dq:32'bz;
    assign dm=4'b0;
    assign cke=reset_n;
    assign cs_n=1'b0;
    assign request_ready=state==IDLE && refresh_count<REFRESH_CYCLES;
    always @(*) begin
        ras_n=1; cas_n=1; we_n=1; addr=0; ba=saved_addr[20:19];
        case(state)
            IPRE,PRE: begin ras_n=0; we_n=0; addr[10]=1; end
            IREF1,IREF2,REF: begin ras_n=0; cas_n=0; end
            IMODE: begin ras_n=0; cas_n=0; we_n=0; ba=0; addr=11'h032; end
            ACT: begin ras_n=0; addr=saved_addr[18:8]; end
            WCMD: begin cas_n=0; we_n=0; addr={3'b000,saved_addr[7:0]}; end
            RCMD: begin cas_n=0; addr={3'b000,saved_addr[7:0]}; end
            default: begin end
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=INIT; next_wait<=0; delay_count<=INIT_CYCLES-1; refresh_count<=0;
            saved_addr<=0; saved_data<=0; saved_write<=0; word_index<=0;
            write_dq<=0; dq_enable<=0;
            done<=0; initialized<=0; read_data<=0;
        end else begin
            done<=0;
            if(initialized && refresh_count<65535) refresh_count<=refresh_count+1'b1;
            case(state)
                INIT: if(delay_count==0) state<=IPRE; else delay_count<=delay_count-1'b1;
                IPRE: begin state<=IWAIT; delay_count<=2; next_wait<=IREF1; end
                IWAIT: if(delay_count==0) state<=next_wait; else delay_count<=delay_count-1'b1;
                IREF1: begin state<=IWAIT; delay_count<=7; next_wait<=IREF2; end
                IREF2: begin state<=IWAIT; delay_count<=7; next_wait<=IMODE; end
                IMODE: begin state<=IWAIT; delay_count<=2; next_wait<=IDLE; initialized<=1; refresh_count<=0; end
                IDLE: begin
                    if(refresh_count>=REFRESH_CYCLES) state<=REF;
                    else if(request_valid) begin
                        saved_addr<={request_addr[20:2],2'b00}; saved_data<=request_data;
                        write_dq<=request_data[31:0];
                        saved_write<=request_write; word_index<=0; state<=ACT;
                    end
                end
                ACT: begin state<=ACTWAIT; delay_count<=1; end
                ACTWAIT: if(delay_count==0) begin state<=saved_write ? WCMD:RCMD; dq_enable<=saved_write; end
                         else delay_count<=delay_count-1'b1;
                WCMD: begin
                    word_index<=1; state<=WDATA; write_dq<=saved_data[63:32]; saved_data<=saved_data>>32;
                end
                WDATA: if(word_index==3) begin state<=WREC; delay_count<=2; dq_enable<=0; end
                       else begin
                           word_index<=word_index+1'b1;
                           write_dq<=saved_data[63:32]; saved_data<=saved_data>>32;
                       end
                WREC: if(delay_count==0) state<=PRE; else delay_count<=delay_count-1'b1;
                RCMD: begin state<=RWAIT; delay_count<=read_delay; end
                RWAIT: if(delay_count==0) begin read_data[31:0]<=sampled_dq; word_index<=1; state<=RDATA; end
                       else delay_count<=delay_count-1'b1;
                RDATA: begin
                    read_data[word_index*32+:32]<=sampled_dq;
                    if(word_index==3) state<=PRE; else word_index<=word_index+1'b1;
                end
                PRE: begin state<=PWAIT; delay_count<=1; end
                PWAIT: if(delay_count==0) begin done<=1; state<=IDLE; end else delay_count<=delay_count-1'b1;
                REF: begin refresh_count<=0; state<=REFWAIT; delay_count<=7; end
                REFWAIT: if(delay_count==0) state<=IDLE; else delay_count<=delay_count-1'b1;
                default: begin state<=INIT; delay_count<=INIT_CYCLES-1; initialized<=0; end
            endcase
        end
    end
endmodule

// car_test/PL/teacher/video/teacher_camera_bridge.v
// Internal ready/valid byte master for camera W->V->I, sharing the proven service.
// PC commands have priority at transaction boundaries. Internal W/V ACKs stay local.
// Generated model integrity gate; protocol and timing remain unchanged.
`ifndef TEACHER_MODEL_IDENTITY_VH
`define TEACHER_MODEL_IDENTITY_VH
`define TEACHER_MODEL_CRC32 32'hD5CA7402
`endif

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

// car_test/PL/teacher/video/teacher_mem_cdc.v
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

// car_test/PL/teacher/video/teacher_roi_snapshot.v
// Generated from teacher/video/preprocess.json; do not hand-edit.
`ifndef TEACHER_PREPROCESS_VH
`define TEACHER_PREPROCESS_VH
`define TEACHER_ROI_X 128
`define TEACHER_ROI_Y 176
`define TEACHER_ROI_WIDTH 384
`define TEACHER_ROI_HEIGHT 128
`endif

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

// car_test/PL/teacher/video/teacher_video_clocks.v
module teacher_video_clocks(input wire clk_50m,reset_n,
 output wire mem_clk,mem_shift,cam_xclk,core_clk,serial_clk,output wire locked);
 wire lm,lv,unused;
 video_pll_core #(.C0DIV(12),.C1DIV(8),.C2DIV(8),.C2PHASE(11),.C3DIV(25))
  memory_pll(clk_50m,!reset_n,lm,mem_clk,mem_shift,cam_xclk);
 video_pll_core #(.C0DIV(20),.C1DIV(40),.C2DIV(8),.C2PHASE(7),.C3DIV(40))
  display_pll(clk_50m,!reset_n,lv,core_clk,serial_clk,unused);
 assign locked=lm && lv;
endmodule

// car_test/PL/teacher/video/teacher_video_frontend.v
// Existing full-resolution video transport, exposing its single memory master.
// Generated from teacher/video/preprocess.json; do not hand-edit.
`ifndef TEACHER_PREPROCESS_VH
`define TEACHER_PREPROCESS_VH
`define TEACHER_ROI_X 128
`define TEACHER_ROI_Y 176
`define TEACHER_ROI_WIDTH 384
`define TEACHER_ROI_HEIGHT 128
`endif

module teacher_video_frontend #(parameter WIDTH=640,HEIGHT=480)(
 input wire cam_clk,mem_clk,pixel_clk,cam_reset_n,mem_reset_n,pixel_reset_n,
 input wire camera_enable,cam_vsync,cam_href,input wire [7:0] cam_data,
 input wire initialized,output wire hs,vs,de,output wire [23:0] rgb,
 output wire [11:0] x,y,output wire frame_start,
 output wire req_valid,input wire req_ready,output wire req_write,
 output wire [20:0] req_addr,output wire [127:0] req_data,
 input wire done,input wire [127:0] read_data,
 output wire [35:0] capture_token,output wire capture_valid,
 output wire [31:0] camera_good,camera_bad,published,rejected,underflows
);
 (* ASYNC_REG="TRUE" *) reg en1,en2;
 always @(posedge cam_clk or negedge cam_reset_n)
  if(!cam_reset_n) begin en1<=0;en2<=0;end else begin en1<=camera_enable;en2<=en1;end
 wire [35:0] cap_data,cap_q,disp_data,disp_q;
 wire cap_valid,cap_ready,cap_qvalid,cap_qready,disp_valid,disp_ready,disp_qvalid,disp_qready;
 wire display_request;
 dvp_capture #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) capture(cam_clk,cam_reset_n,en2,cam_vsync,cam_href,cam_data,
  cap_data,cap_valid,cap_ready,camera_good,camera_bad);
 video_async_fifo #(.WIDTH(36),.AW(9)) capture_fifo(cam_clk,cam_reset_n,cap_data,cap_valid,cap_ready,
  mem_clk,mem_reset_n,cap_q,cap_qvalid,cap_qready);
 assign capture_token=cap_q;assign capture_valid=cap_qvalid && cap_qready;
 video_timing #(.H_ACTIVE(WIDTH),.V_ACTIVE(HEIGHT)) timing(pixel_clk,pixel_reset_n,hs,vs,de,frame_start,x,y);
 video_display #(.ROI_X(`TEACHER_ROI_X),.ROI_Y(`TEACHER_ROI_Y),.ROI_WIDTH(`TEACHER_ROI_WIDTH),.ROI_HEIGHT(`TEACHER_ROI_HEIGHT)) display(
  pixel_clk,pixel_reset_n,frame_start,de,x,y,disp_q,disp_qvalid,disp_qready,display_request,rgb,underflows);
 video_async_fifo #(.WIDTH(36),.AW(10)) display_fifo(mem_clk,mem_reset_n,disp_data,disp_valid,disp_ready,
  pixel_clk,pixel_reset_n,disp_q,disp_qvalid,disp_qready);
 video_frame_store #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) store(mem_clk,mem_reset_n,initialized,
  cap_q,cap_qvalid,cap_qready,display_request,disp_data,disp_valid,disp_ready,
  req_valid,req_ready,req_write,req_addr,req_data,done,read_data,published,rejected);
endmodule

// car_test/PL/teacher/video/teacher_video_memory.v
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

// car_test/PL/teacher/video/teacher_video_system.v
// Generated from teacher/video/preprocess.json; do not hand-edit.
`ifndef TEACHER_PREPROCESS_VH
`define TEACHER_PREPROCESS_VH
`define TEACHER_ROI_X 128
`define TEACHER_ROI_Y 176
`define TEACHER_ROI_WIDTH 384
`define TEACHER_ROI_HEIGHT 128
`endif

module teacher_video_system #(parameter WIDTH=640,HEIGHT=480,INIT_CYCLES=20000)(
 input wire cam_clk,mem_clk,core_clk,cam_reset_n,mem_reset_n,core_reset_n,
 input wire configured,camera_fault,input wire [3:0] fault_code,input wire [1:0] retries,
 input wire cam_vsync,cam_href,input wire [7:0] cam_data,
 input wire uart_rx_valid,input wire [7:0] uart_rx_data,
 output wire uart_tx_valid,input wire uart_tx_ready,output wire [7:0] uart_tx_data,
 output wire hs,vs,de,output wire [23:0] rgb,
 output wire ras_n,cas_n,we_n,output wire [10:0] addr,output wire [1:0] ba,output wire [3:0] dm,
 inout wire [31:0] dq,output wire cke,cs_n,
 output wire initialized,model_ready,camera_mode,cnn_busy,system_error,
 output wire [31:0] camera_good,camera_bad,published,rejected,underflows,
 output wire [31:0] inference_count
);
 wire f_req_valid,f_req_ready,f_req_write,f_done;
 wire [20:0] f_req_addr;
 wire [127:0] f_req_data,f_read_data;
 wire base_hs,base_vs,base_de,frame_start;
 wire [23:0] base_rgb;
 wire [11:0] x,y;
 wire [35:0] capture_token;
 wire capture_valid;
 teacher_video_frontend #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) frontend(
  cam_clk,mem_clk,core_clk,cam_reset_n,mem_reset_n,core_reset_n,configured,cam_vsync,cam_href,cam_data,
  initialized,base_hs,base_vs,base_de,base_rgb,x,y,frame_start,
  f_req_valid,f_req_ready,f_req_write,f_req_addr,f_req_data,f_done,f_read_data,
  capture_token,capture_valid,camera_good,camera_bad,published,rejected,underflows);
 wire snapshot_valid,snapshot_take,snapshot_release,snapshot_read;
 wire [31:0] snapshot_frame;
 wire [11:0] snapshot_addr;
 wire [7:0] snapshot_data;
 teacher_roi_snapshot #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) snapshots(
  mem_clk,mem_reset_n,capture_token,capture_valid,core_clk,core_reset_n,
  snapshot_valid,snapshot_frame,snapshot_take,snapshot_release,snapshot_read,snapshot_addr,snapshot_data, , , );
 wire service_rx_valid,service_rx_ready,service_tx_valid,service_tx_ready,service_idle;
 wire [7:0] service_rx_data,service_tx_data;
 wire bridge_fault,service_error,result_event,result_error;
 wire [31:0] result_frame;
 wire [4:0] result_length;
 wire [160:0] result_chars;
 teacher_camera_bridge bridge(core_clk,core_reset_n,uart_rx_valid,uart_rx_data,
  uart_tx_valid,uart_tx_ready,uart_tx_data,
  service_rx_valid,service_rx_ready,service_rx_data,service_tx_valid,service_tx_ready,service_tx_data,
  service_idle,model_ready,camera_mode,snapshot_valid,snapshot_frame,snapshot_take,snapshot_release,
  snapshot_read,snapshot_addr,snapshot_data,result_event,result_frame,result_length,result_chars,result_error,bridge_fault,inference_count);
 (* ASYNC_REG="TRUE" *) reg init1,init2,pub1,pub2,cfg1,cfg2,flt1,flt2;
 reg pub_seen,model_available;
 reg [31:0] frame_count;
 reg [3:0] fault_code_held;
 reg [1:0] retries_held;
 always @(posedge core_clk or negedge core_reset_n) begin
  if(!core_reset_n) begin init1<=0;init2<=0;pub1<=0;pub2<=0;pub_seen<=0;cfg1<=0;cfg2<=0;flt1<=0;flt2<=0;model_available<=0;frame_count<=0;fault_code_held<=0;retries_held<=0;end
  else begin
   init1<=initialized;init2<=init1;pub1<=published[0];pub2<=pub1;pub_seen<=pub2;
   cfg1<=configured;cfg2<=cfg1;flt1<=camera_fault;flt2<=flt1;
   if(pub2^pub_seen) frame_count<=frame_count+1'b1;
   // Camera fault metadata is held in its source domain before the synchronized qualifier is consumed.
   if(flt2) begin fault_code_held<=fault_code;retries_held<=retries;end
   if(bridge_fault || (!camera_mode && !model_ready)) model_available<=0;
   else if(model_ready) model_available<=1;
  end
 end
 wire c_req_valid,c_req_ready,c_req_write,c_rsp_valid,c_rsp_ready;
 wire [22:0] c_req_addr;
 wire [127:0] c_req_data,c_rsp_data;
 wire [15:0] c_req_strobe;
 wire [2:0] read_delay;
 wire [31:0] video_flags={18'b0,retries_held,fault_code_held,service_error,bridge_fault,cnn_busy,camera_mode,model_ready,init2,flt2,cfg2};
 teacher_board_service #(.VIDEO_STATUS(1)) service(.clk(core_clk),.reset_n(core_reset_n),.initialized(init2),
  .rx_valid(service_rx_valid),.rx_data(service_rx_data),.rx_ready(service_rx_ready),.command_idle(service_idle),
  .tx_valid(service_tx_valid),.tx_ready(service_tx_ready),.tx_data(service_tx_data),
  .model_ready(model_ready),.busy(cnn_busy),.error(service_error),.read_delay(read_delay),.camera_mode(camera_mode),
  .video_status({inference_count,underflows,frame_count,video_flags}),
  .mem_req_valid(c_req_valid),.mem_req_ready(c_req_ready),.mem_req_write(c_req_write),.mem_req_addr(c_req_addr),
  .mem_req_wdata(c_req_data),.mem_req_wstrb(c_req_strobe),.mem_rsp_valid(c_rsp_valid),.mem_rsp_ready(c_rsp_ready),.mem_rsp_rdata(c_rsp_data));
 wire m_req_valid,m_req_ready,m_rsp_valid,m_rsp_ready;
 wire [170:0] m_command;
 wire [127:0] m_rsp_data;
 teacher_mem_cdc memory_bridge(core_clk,core_reset_n,mem_clk,mem_reset_n,
  c_req_valid,c_req_ready,{read_delay,c_req_write,c_req_addr,c_req_data,c_req_strobe},
  c_rsp_valid,c_rsp_ready,c_rsp_data,m_req_valid,m_req_ready,m_command,m_rsp_valid,m_rsp_ready,m_rsp_data);
 teacher_video_memory #(.INIT_CYCLES(INIT_CYCLES)) storage(mem_clk,mem_reset_n,
  f_req_valid,f_req_ready,f_req_write,f_req_addr,f_req_data,f_done,f_read_data,
  m_req_valid,m_req_ready,m_command,m_rsp_valid,m_rsp_ready,m_rsp_data,
  initialized, ,ras_n,cas_n,we_n,addr,ba,dm,dq,cke,cs_n);
 wire confirmed,display_confirmed,frame_alive,result_alive,last_format,candidate_valid;
 wire [48:0] confirmed_chars,last_chars;
 wire [4:0] last_length;
 wire [2:0] votes;
 wire [3:0] health_status;
 wire vote_reset=core_reset_n && cfg2 && !flt2 && init2 && frame_alive && model_available;
 lpr_vote #(.CLK_HZ(25000000),.TIMEOUT_MS(5000)) voter(core_clk,vote_reset,
  result_event,result_frame,result_length,result_chars,result_error,confirmed,confirmed_chars,votes,candidate_valid);
 lpr_health #(.CLK_HZ(25000000),.TIMEOUT_MS(5000)) health(core_clk,core_reset_n,cfg2,flt2,
  init2 && model_available,pub2^pub_seen,result_event,result_length,result_chars,result_error,
  confirmed,health_status,display_confirmed,frame_alive,result_alive,last_length,last_chars,last_format);
 lpr_osd #(.PANEL_BOTTOM(`TEACHER_ROI_Y)) osd(core_clk,core_reset_n,display_confirmed,confirmed_chars,
  core_clk,core_reset_n,frame_start,x,y,base_hs,base_vs,base_de,base_rgb,
  hs,vs,de,rgb,health_status,last_chars,last_length,result_alive ? votes:3'b0,
  last_format && result_alive,fault_code_held,retries_held);
 assign system_error=bridge_fault || service_error;
endmodule

// car_test/PL/teacher/video/teacher_video_top.v
module teacher_video_top(
 input wire clk_50m,rst_n,uart_rxd,cam_pclk,cam_vsync,cam_href,input wire [7:0] cam_data,
 output wire uart_txd,cam_xclk,cam_rst_n,cam_pwdn,inout wire cam_scl,cam_sda,
 output wire hdmi_clk_p,hdmi_d0_p,hdmi_d1_p,hdmi_d2_p,output wire [3:0] status_led
);
 wire mem_clk,mem_shift,core_clk,serial_clk,locked;
 teacher_video_clocks clocks(clk_50m,rst_n,mem_clk,mem_shift,cam_xclk,core_clk,serial_clk,locked);
 wire sys_reset_n,cam_reset_n,mem_reset_n,core_reset_n;
 video_reset rs(clk_50m,rst_n && locked,sys_reset_n);
 video_reset rc(cam_pclk,rst_n && locked,cam_reset_n);
 video_reset rm(mem_clk,rst_n && locked,mem_reset_n);
 video_reset rp(core_clk,rst_n && locked,core_reset_n);
 wire configured,camera_fault;
 wire [3:0] fault_code;
 wire [8:0] config_index;
 wire [1:0] retries;
 ov5640_config camera_config(clk_50m,sys_reset_n,cam_scl,cam_sda,
  cam_rst_n,cam_pwdn,configured,camera_fault,fault_code,config_index,retries);
 wire rx_valid,tx_valid,tx_busy;
 wire [7:0] rx_data,tx_data;
 uart_rx #(.CLKS_PER_BIT(217)) receiver(core_clk,core_reset_n,uart_rxd,rx_data,rx_valid);
 uart_tx #(.CLKS_PER_BIT(217)) transmitter(core_clk,core_reset_n,tx_data,tx_valid && !tx_busy,uart_txd,tx_busy);
 wire hs,vs,de;wire [23:0] rgb;
 wire ras_n,cas_n,we_n,cke,cs_n;wire [10:0] addr;wire [1:0] ba;wire [3:0] dm;wire [31:0] dq;
 wire initialized,model_ready,camera_mode,cnn_busy,system_error;
 wire [31:0] camera_good,camera_bad,published,rejected,underflows,inference_count;
 teacher_video_system system(cam_pclk,mem_clk,core_clk,cam_reset_n,mem_reset_n,core_reset_n,
  configured,camera_fault,fault_code,retries,cam_vsync,cam_href,cam_data,
  rx_valid,rx_data,tx_valid,!tx_busy,tx_data,hs,vs,de,rgb,
  ras_n,cas_n,we_n,addr,ba,dm,dq,cke,cs_n,initialized,model_ready,camera_mode,cnn_busy,system_error,
  camera_good,camera_bad,published,rejected,underflows,inference_count);
 EG_PHY_SDRAM_2M_32 memory(.clk(mem_shift),.ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),
  .addr(addr),.ba(ba),.dq(dq),.cs_n(cs_n),.cke(cke),.dm0(dm[0]),.dm1(dm[1]),.dm2(dm[2]),.dm3(dm[3]));
 wire [9:0] blue,green,red;
 tmds_encoder eb(core_clk,core_reset_n,rgb[7:0],de,hs,vs,blue);
 tmds_encoder eg(core_clk,core_reset_n,rgb[15:8],de,1'b0,1'b0,green);
 tmds_encoder er(core_clk,core_reset_n,rgb[23:16],de,1'b0,1'b0,red);
 tmds_serializer sb(serial_clk,core_reset_n,blue,hdmi_d0_p);
 tmds_serializer sg(serial_clk,core_reset_n,green,hdmi_d1_p);
 tmds_serializer sr(serial_clk,core_reset_n,red,hdmi_d2_p);
 tmds_serializer sc(serial_clk,core_reset_n,10'b0000011111,hdmi_clk_p);
 assign status_led={camera_fault || system_error,underflows!=0,published!=0,model_ready && initialized};
endmodule

// car_test/PL/src/video/dvp_capture.v
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

// car_test/PL/src/video/video_async_fifo.v
// Dual-clock RAM with a registered, elastic read output. AW must be >= 2.
// The read pointer advances on prefetch; the output register owns that word thereafter.
module video_async_fifo #(parameter WIDTH=36, parameter AW=9)(
    input wire wr_clk, input wire wr_reset_n,
    input wire [WIDTH-1:0] wr_data, input wire wr_valid, output wire wr_ready,
    input wire rd_clk, input wire rd_reset_n,
    output reg [WIDTH-1:0] rd_data, output reg rd_valid, input wire rd_ready
);
    reg [WIDTH-1:0] mem[0:(1<<AW)-1];
    reg [AW:0] wbin,wgray,rbin,rgray;
    (* ASYNC_REG="TRUE" *) reg [AW:0] rg1,rg2,wg1,wg2;
    wire [AW:0] wn=wbin+1'b1, rn=rbin+1'b1;
    assign wr_ready=wgray!={~rg2[AW:AW-1],rg2[AW-2:0]};
    wire empty=rgray==wg2;
    always @(posedge wr_clk or negedge wr_reset_n) begin
        if(!wr_reset_n) begin wbin<=0; wgray<=0; rg1<=0; rg2<=0; end
        else begin
            rg1<=rgray; rg2<=rg1;
            if(wr_valid && wr_ready) begin wbin<=wn; wgray<=(wn>>1)^wn; end
        end
    end
    always @(posedge wr_clk) if(wr_valid && wr_ready) mem[wbin[AW-1:0]]<=wr_data;
    always @(posedge rd_clk or negedge rd_reset_n) begin
        if(!rd_reset_n) begin rbin<=0; rgray<=0; wg1<=0; wg2<=0; rd_valid<=0; end
        else begin
            wg1<=wgray; wg2<=wg1;
            if(!rd_valid || rd_ready) begin
                rd_valid<=!empty;
                if(!empty) begin rbin<=rn; rgray<=(rn>>1)^rn; end
            end
        end
    end
    always @(posedge rd_clk)
        if((!rd_valid || rd_ready) && !empty) rd_data<=mem[rbin[AW-1:0]];
endmodule

// car_test/PL/src/video/video_frame_store.v
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

// car_test/PL/src/video/video_timing.v
module video_timing #(
    parameter H_ACTIVE=640,H_FRONT=16,H_SYNC=96,H_BACK=48,
    parameter V_ACTIVE=480,V_FRONT=10,V_SYNC=2,V_BACK=33
)(input wire clk,input wire reset_n,output wire hs,vs,de,frame_start,
    output wire [11:0] x,y);
    localparam HT=H_ACTIVE+H_FRONT+H_SYNC+H_BACK, VT=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
    reg [11:0] h,v;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin h<=0; v<=0; end
        else if(h==HT-1) begin h<=0; if(v==VT-1) v<=0; else v<=v+1'b1; end
        else h<=h+1'b1;
    end
    assign hs=!(h<H_SYNC);
    assign vs=!(v<V_SYNC);
    assign de=h>=H_SYNC+H_BACK && h<H_SYNC+H_BACK+H_ACTIVE &&
              v>=V_SYNC+V_BACK && v<V_SYNC+V_BACK+V_ACTIVE;
    assign x=h-(H_SYNC+H_BACK);
    assign y=v-(V_SYNC+V_BACK);
    assign frame_start=h==0 && v==0;
endmodule

// car_test/PL/src/video/video_display.v
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

// car_test/PL/src/video/video_reset.v
module video_reset(input wire clk, input wire async_reset_n, output wire reset_n);
    (* ASYNC_REG="TRUE" *) reg [2:0] sync;
    always @(posedge clk or negedge async_reset_n)
        if(!async_reset_n) sync<=0;
        else sync<={sync[1:0],1'b1};
    assign reset_n=sync[2];
endmodule

// car_test/PL/src/video/video_clocks.v
// Two native EG4 PLLs: SDRAM 75 MHz / shifted 75 MHz / camera 24 MHz;
// display 25 MHz and 125 MHz. VGA totals 800x525 -> 59.524 Hz.
module video_pll_core #(parameter C0DIV=12,C1DIV=8,C2DIV=8,C2PHASE=11,C3DIV=25)(
    input wire clk,input wire reset,output wire locked,output wire c1,c2,c3
);
    wire feedback_raw,feedback;
    wire [4:0] clocks;
    assign feedback_raw=clocks[0];
    assign c1=clocks[1]; assign c2=clocks[2]; assign c3=clocks[3];
    EG_LOGIC_BUFG fb(.i(feedback_raw),.o(feedback));
    EG_PHY_PLL #(.DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000"),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),.STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),.DERIVE_PLL_CLOCKS("DISABLE"),
        .GEN_BASIC_CLOCK("DISABLE"),.GMC_GAIN(2),.ICP_CURRENT(9),.KVCO(2),
        .LPF_CAPACITOR(1),.LPF_RESISTOR(8),.REFCLK_DIV(1),.FBCLK_DIV(1),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(C0DIV),.CLKC0_CPHASE(C0DIV-1),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(C1DIV),.CLKC1_CPHASE(C1DIV-1),.CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(C2DIV),.CLKC2_CPHASE(C2PHASE),.CLKC2_FPHASE(0),
        .CLKC3_ENABLE("ENABLE"),.CLKC3_DIV(C3DIV),.CLKC3_CPHASE(C3DIV-1),.CLKC3_FPHASE(0)
    ) pll(.refclk(clk),.reset(reset),.stdby(1'b0),.extlock(locked),.load_reg(1'b0),
        .psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'b0),.dclk(1'b0),
        .dcs(1'b0),.dwe(1'b0),.di(8'b0),.daddr(6'b0),.fbclk(feedback),.clkc(clocks));
endmodule

module video_clocks(input wire clk_50m,input wire reset_n,
    output wire mem_clk,mem_clk_shift,cam_xclk,pixel_clk,serial_clk,output wire locked);
    wire lm,lv,unused;
    video_pll_core memory_pll(clk_50m,!reset_n,lm,mem_clk,mem_clk_shift,cam_xclk);
    video_pll_core #(.C0DIV(20),.C1DIV(40),.C2DIV(8),.C2PHASE(7),.C3DIV(40))
        display_pll(clk_50m,!reset_n,lv,pixel_clk,serial_clk,unused);
    assign locked=lm && lv;
endmodule

// car_test/PL/src/video/tmds_encoder.v
module tmds_encoder(input wire clk,input wire reset_n,input wire [7:0] data,
    input wire de,input wire c0,c1,output reg [9:0] symbol);
    wire [3:0] ones={3'b0,data[0]}+{3'b0,data[1]}+{3'b0,data[2]}+{3'b0,data[3]}+
                    {3'b0,data[4]}+{3'b0,data[5]}+{3'b0,data[6]}+{3'b0,data[7]};
    wire xnor_mode=ones>4 || (ones==4 && !data[0]);
    wire [8:0] q;
    assign q[0]=data[0];
    assign q[8]=!xnor_mode;
    genvar n;
    generate for(n=1;n<8;n=n+1) begin: encode_chain
        // Prefix parity avoids a vector self-reference in TD's HDL frontend.
        assign q[n]=(^data[n:0]) ^ (xnor_mode && (n%2==1));
    end endgenerate
    wire [3:0] qones={3'b0,q[0]}+{3'b0,q[1]}+{3'b0,q[2]}+{3'b0,q[3]}+
                     {3'b0,q[4]}+{3'b0,q[5]}+{3'b0,q[6]}+{3'b0,q[7]};
    reg signed [5:0] disparity;
    wire signed [5:0] balance=$signed({1'b0,qones,1'b0})-6'sd8;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin disparity<=0; symbol<=10'b1101010100; end
        else if(!de) begin
            disparity<=0;
            case({c1,c0})
                0:symbol<=10'b1101010100;
                1:symbol<=10'b0010101011;
                2:symbol<=10'b0101010100;
                3:symbol<=10'b1010101011;
            endcase
        end else if(disparity==0 || balance==0) begin
            symbol<={~q[8],q[8],q[8] ? q[7:0]:~q[7:0]};
            disparity<=disparity+(q[8] ? balance:-balance);
        end else if((disparity>0 && balance>0)||(disparity<0 && balance<0)) begin
            symbol<={1'b1,q[8],~q[7:0]};
            disparity<=disparity-balance+(q[8] ? 6'sd2:6'sd0);
        end else begin
            symbol<={1'b0,q[8],q[7:0]};
            disparity<=disparity+balance-(q[8] ? 6'sd0:6'sd2);
        end
    end
endmodule

// car_test/PL/src/video/tmds_serializer.v
// One ten-bit TMDS symbol, LSB first, five DDR cycles. Related clocks are required.
module tmds_serializer(input wire serial_clk,input wire reset_n,
    input wire [9:0] symbol,output wire serial_out);
    reg [2:0] pair_index;
    reg [9:0] shift;
    reg [1:0] pair_bits;
    // Prepare both bits half a serial clock before the ODDR capture edge.
    // This also separates pixel-clock symbol updates from the I/O hold window.
    always @(negedge serial_clk or negedge reset_n) begin
        if(!reset_n) begin pair_index<=0; shift<=0; pair_bits<=0; end
        else begin
            pair_bits<=pair_index==0 ? symbol[1:0]:shift[1:0];
            if(pair_index==4) pair_index<=0; else pair_index<=pair_index+1'b1;
            if(pair_index==0) shift<={2'b0,symbol[9:2]}; else shift<={2'b0,shift[9:2]};
        end
    end
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) ddr(
        .q(serial_out),.clk(serial_clk),.d0(pair_bits[0]),.d1(pair_bits[1]),.rst(!reset_n));
endmodule

// car_test/PL/src/video/ov5640_config.v
`ifndef OV5640_TABLE_COUNT
`define OV5640_TABLE_COUNT 265
`endif

module ov5640_config #(
    parameter POWERUP_CYCLES=1000000, RESET_CYCLES=100000,
    parameter WRITE_DELAY_CYCLES=50000, HALF_PERIOD=250,
    parameter TABLE_FILE="assets/ov5640_vga_rgb888.hex",
    parameter RETRY_CYCLES=50000000,MAX_RETRIES=2
)(input wire clk,input wire reset_n,inout wire scl,sda,
    output reg camera_reset_n,output reg camera_pwdn,output reg configured,
    output reg fault,output reg [3:0] fault_code,output wire [8:0] register_index,
    output reg [1:0] retries);
    localparam POWER=0,RESET=1,SETTLE=2,IDH=3,IDHWAIT=4,IDL=5,IDLWAIT=6,
        FETCH=7,ISSUE=8,WRITEWAIT=9,DELAY=10,FINISH=11,FAIL=12;
    reg [3:0] state;
    reg [31:0] count;
    reg [8:0] index;
    reg [23:0] rom[0:511];
    reg [23:0] entry;
    reg start,read;
    reg [15:0] address;
    reg [7:0] data;
    wire busy,done,error;
    wire [7:0] result;
    initial $readmemh(TABLE_FILE,rom);
    assign register_index=index;
    always @(posedge clk) entry<=rom[index];
    sccb_master #(.HALF_PERIOD(HALF_PERIOD)) bus(clk,reset_n,start,read,address,data,busy,done,error,result,scl,sda);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=POWER; count<=POWERUP_CYCLES-1; index<=0; camera_reset_n<=0;
            camera_pwdn<=1; configured<=0; fault<=0; fault_code<=0;
            start<=0; read<=0; address<=0; data<=0;
            retries<=0;
        end else begin
            start<=0;
            case(state)
                POWER: if(count==0) begin camera_pwdn<=0; count<=RESET_CYCLES-1; state<=RESET; end else count<=count-1'b1;
                RESET: if(count==0) begin camera_reset_n<=1; count<=POWERUP_CYCLES-1; state<=SETTLE; end else count<=count-1'b1;
                SETTLE: if(count==0) state<=IDH; else count<=count-1'b1;
                IDH: begin address<=16'h300a; read<=1; start<=1; state<=IDHWAIT; end
                IDHWAIT: if(done) begin
                    if(error || result!=8'h56) begin fault_code<=error ? 1:2; count<=0;state<=FAIL; end else state<=IDL;
                end
                IDL: begin address<=16'h300b; start<=1; state<=IDLWAIT; end
                IDLWAIT: if(done) begin
                    if(error || result!=8'h40) begin fault_code<=error ? 1:2;count<=0;state<=FAIL; end else begin state<=FETCH; index<=0; end
                end
                FETCH: state<=ISSUE;
                ISSUE: begin read<=0; address<=entry[23:8]; data<=entry[7:0]; start<=1; state<=WRITEWAIT; end
                WRITEWAIT: if(done) begin
                    if(error) begin fault_code<=3; count<=0;state<=FAIL; end
                    else begin
                        count<=(address==16'h3008 && data==8'h82) ? WRITE_DELAY_CYCLES*5-1:WRITE_DELAY_CYCLES-1;
                        state<=DELAY;
                    end
                end
                DELAY: if(count==0) begin
                    if(index==`OV5640_TABLE_COUNT-1) state<=FINISH;
                    else begin index<=index+1'b1; state<=FETCH; end
                end else count<=count-1'b1;
                FINISH: configured<=1;
                FAIL: begin
                    fault<=1;
                    if(retries<MAX_RETRIES) begin
                        if(count==RETRY_CYCLES-1) begin
                            retries<=retries+1'b1;camera_reset_n<=0;camera_pwdn<=1;
                            configured<=0;fault<=0;fault_code<=0;index<=0;
                            count<=POWERUP_CYCLES-1;state<=POWER;
                        end else count<=count+1'b1;
                    end
                end
                default: begin fault_code<=4;count<=0;state<=FAIL; end
            endcase
        end
    end
endmodule

// car_test/PL/src/video/sccb_master.v
// SCCB/I2C 7-bit address 0x3c, 16-bit register address. Open-drain SCL/SDA.
// A read uses address-write, repeated START, address-read, one byte, NACK, STOP.
module sccb_master #(parameter HALF_PERIOD=250, TIMEOUT_CYCLES=50000)(
    input wire clk,input wire reset_n,input wire start,input wire read,
    input wire [15:0] reg_addr,input wire [7:0] write_data,
    output reg busy,done,error,output reg [7:0] read_data,
    inout wire scl,inout wire sda
);
    localparam IDLE=0,START0=1,START1=2,BITLOW=3,BITHIGH=4,
        ACKLOW=5,ACKHIGH=6,ACKEND=7,RESTART0=8,RESTART1=9,
        READLOW=10,READHIGH=11,NACKLOW=12,NACKHIGH=13,STOP0=14,STOP1=15,STOP2=16;
    reg [4:0] state;
    reg scl_low,sda_low;
    reg [15:0] divider,timeout_count,saved_addr;
    reg [7:0] saved_data,shift;
    reg saved_read,read_address;
    reg [2:0] bit_index,byte_index;
    (* ASYNC_REG="TRUE" *) reg [1:0] scl_sync,sda_sync;
    always @(posedge clk or negedge reset_n)
        if(!reset_n) begin scl_sync<=2'b11; sda_sync<=2'b11; end
        else begin scl_sync<={scl_sync[0],scl}; sda_sync<={sda_sync[0],sda}; end
    wire tick=divider==HALF_PERIOD-1;
    wire waiting_high=!scl_low && !scl_sync[1];
    assign scl=scl_low ? 1'b0:1'bz;
    assign sda=sda_low ? 1'b0:1'bz;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; scl_low<=0; sda_low<=0; divider<=0; timeout_count<=0;
            saved_addr<=0; saved_data<=0; saved_read<=0; shift<=0;
            read_address<=0; bit_index<=7; byte_index<=0;
            busy<=0; done<=0; error<=0; read_data<=0;
        end else begin
            done<=0;
            if(busy && (waiting_high || (state==START0 && !sda_sync[1]))) begin
                if(timeout_count==TIMEOUT_CYCLES-1) begin
                    busy<=0; error<=1; done<=1; state<=IDLE; scl_low<=0; sda_low<=0;
                end else timeout_count<=timeout_count+1'b1;
            end else begin
                timeout_count<=0;
                if(state==IDLE) begin
                    divider<=0;
                    if(start) begin
                        busy<=1; error<=0; saved_addr<=reg_addr; saved_data<=write_data;
                        saved_read<=read; read_address<=0; byte_index<=0; bit_index<=7;
                        shift<=8'h78; state<=START0; scl_low<=0; sda_low<=0;
                    end
                end else if(tick) begin
                    divider<=0;
                    case(state)
                        START0: begin sda_low<=1; state<=START1; end
                        START1: begin scl_low<=1; sda_low<=!shift[7]; state<=BITLOW; end
                        BITLOW: begin scl_low<=0; state<=BITHIGH; end
                        BITHIGH: begin
                            scl_low<=1;
                            if(bit_index==0) begin sda_low<=0; state<=ACKLOW; end
                            else begin bit_index<=bit_index-1'b1; shift<={shift[6:0],1'b0}; sda_low<=!shift[6]; state<=BITLOW; end
                        end
                        ACKLOW: begin scl_low<=0; state<=ACKHIGH; end
                        ACKHIGH: begin
                            if(sda_sync[1]) error<=1;
                            scl_low<=1; state<=ACKEND;
                        end
                        ACKEND: begin
                            bit_index<=7;
                            if(error) begin sda_low<=1; state<=STOP0; end
                            else if(read_address) begin sda_low<=0; state<=READLOW; end
                            else if(byte_index==2 && saved_read) begin sda_low<=0; state<=RESTART0; end
                            else if(byte_index==3) begin sda_low<=1; state<=STOP0; end
                            else begin
                                byte_index<=byte_index+1'b1;
                                case(byte_index)
                                    0: begin shift<=saved_addr[15:8]; sda_low<=!saved_addr[15]; end
                                    1: begin shift<=saved_addr[7:0]; sda_low<=!saved_addr[7]; end
                                    2: begin shift<=saved_data; sda_low<=!saved_data[7]; end
                                endcase
                                state<=BITLOW;
                            end
                        end
                        RESTART0: begin scl_low<=0; state<=RESTART1; end
                        RESTART1: begin sda_low<=1; shift<=8'h79; read_address<=1; state<=START1; end
                        READLOW: begin scl_low<=0; state<=READHIGH; end
                        READHIGH: begin
                            shift<={shift[6:0],sda_sync[1]}; scl_low<=1;
                            if(bit_index==0) begin read_data<={shift[6:0],sda_sync[1]}; state<=NACKLOW; end
                            else begin bit_index<=bit_index-1'b1; state<=READLOW; end
                        end
                        NACKLOW: begin scl_low<=0; state<=NACKHIGH; end
                        NACKHIGH: begin scl_low<=1; sda_low<=1; state<=STOP0; end
                        STOP0: begin scl_low<=0; state<=STOP1; end
                        STOP1: begin sda_low<=0; state<=STOP2; end
                        STOP2: begin busy<=0; done<=1; state<=IDLE; end
                        default: begin state<=IDLE; busy<=0; error<=1; done<=1; scl_low<=0; sda_low<=0; end
                    endcase
                end else divider<=divider+1'b1;
            end
        end
    end
endmodule

// car_test/PL/src/video/lpr_vote.v
// Six most recent distinct source frames, four equal full plates to confirm.
// Invalid results occupy a slot; each vote and the displayed plate expire.
module lpr_vote #(parameter CLK_HZ=50000000,TIMEOUT_MS=2000)(
    input wire clk,reset_n,result_event,input wire [31:0] frame_id,
    input wire [4:0] length,input wire [160:0] chars,input wire error,
    output reg confirmed_valid,output reg [48:0] confirmed_chars,
    output reg [2:0] candidate_votes,output reg candidate_valid
);
    localparam MS_CYCLES=CLK_HZ/1000;
    localparam TICK_BITS=MS_CYCLES>1 ? $clog2(MS_CYCLES):1;
    localparam AGE_BITS=$clog2(TIMEOUT_MS+1)>0 ? $clog2(TIMEOUT_MS+1):1;
    reg [TICK_BITS-1:0] millisecond_divider;
    wire tick=millisecond_divider==MS_CYCLES-1;
    reg [48:0] history[0:5];
    reg [AGE_BITS-1:0] age[0:5];
    reg [5:0] valid;
    reg [2:0] head;
    reg seen_frame;
    reg [31:0] last_frame;
    reg [AGE_BITS-1:0] confirmed_age;
    // Monotonic source tags, including 32-bit wrap; reject replayed/old frames.
    wire fresh=result_event && (!seen_frame || $signed(frame_id-last_frame)>0);
    reg format_ok;
    reg [2:0] matches;
    integer i,j;
    always @(*) begin
        format_ok=!error && length==7 && chars[6:0]<31 &&
                  chars[13:7]>=41 && chars[13:7]<=64;
        for(j=2;j<7;j=j+1)
            if(chars[j*7+:7]<31 || chars[j*7+:7]>64) format_ok=0;
        matches=1;
        for(j=0;j<6;j=j+1)
            if(j!=head && valid[j] && age[j]<TIMEOUT_MS && history[j]==chars[48:0])
                matches=matches+1'b1;
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            millisecond_divider<=0; valid<=0; head<=0; seen_frame<=0; last_frame<=0;
            confirmed_valid<=0; confirmed_chars<=0; confirmed_age<=0;
            candidate_votes<=0; candidate_valid<=0;
            for(i=0;i<6;i=i+1) begin history[i]<=0; age[i]<=0; end
        end else begin
            if(tick) millisecond_divider<=0;
            else millisecond_divider<=millisecond_divider+1'b1;
            if(tick) begin
                for(i=0;i<6;i=i+1) if(valid[i]) begin
                    if(age[i]>=TIMEOUT_MS-1) valid[i]<=0;
                    else age[i]<=age[i]+1'b1;
                end
                if(confirmed_valid) begin
                    if(confirmed_age>=TIMEOUT_MS-1) begin confirmed_valid<=0; confirmed_chars<=0; end
                    else confirmed_age<=confirmed_age+1'b1;
                end
            end
            if(fresh) begin
                seen_frame<=1; last_frame<=frame_id;
                history[head]<=chars[48:0]; valid[head]<=format_ok; age[head]<=0;
                head<=head==5 ? 0:head+1'b1;
                candidate_valid<=format_ok;
                candidate_votes<=format_ok ? matches:3'b0;
                if(format_ok && matches>=4) begin
                    confirmed_valid<=1; confirmed_chars<=chars[48:0]; confirmed_age<=0;
                end else if(format_ok && confirmed_valid && chars[48:0]==confirmed_chars)
                    confirmed_age<=0;
            end
        end
    end
endmodule

// car_test/PL/src/video/lpr_health.v
// System-domain status. frame_event is a synchronized published-frame toggle
// edge, never an unsynchronized multi-bit camera counter. All ages are ms.
module lpr_health #(parameter CLK_HZ=50000000,TIMEOUT_MS=2000)(
    input wire clk,reset_n,configured,camera_fault,memory_ready,frame_event,
    input wire result_event,input wire [4:0] raw_length,
    input wire [160:0] raw_chars,input wire raw_error,
    input wire confirmed_valid,
    output reg [3:0] status,output wire display_confirmed,
    output reg frame_alive,result_alive,output reg [4:0] last_length,
    output reg [48:0] last_chars,output reg last_format_valid
);
    localparam DIV=CLK_HZ/1000, BITS=DIV>1 ? $clog2(DIV):1;
    localparam AGE_BITS=$clog2(TIMEOUT_MS+1)>0 ? $clog2(TIMEOUT_MS+1):1;
    reg [BITS-1:0] divider;
    wire tick=divider==DIV-1;
    reg [AGE_BITS-1:0] frame_age,result_age;
    reg seen_result,last_error;
    reg format_ok;
    integer i;
    always @(*) begin
        format_ok=!raw_error && raw_length==7 && raw_chars[6:0]<31 &&
            raw_chars[13:7]>=41 && raw_chars[13:7]<=64;
        for(i=2;i<7;i=i+1)
            if(raw_chars[i*7+:7]<31 || raw_chars[i*7+:7]>64) format_ok=0;
        if(camera_fault) status=1;
        else if(!configured) status=0;
        else if(!memory_ready) status=2;
        else if(!frame_alive) status=3;
        else if(!seen_result) status=4;
        else if(!result_alive) status=8;
        else if(last_error) status=9;
        else if(confirmed_valid) status=7;
        else if(!last_format_valid) status=5;
        else status=6;
    end
    assign display_confirmed=status==7;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            divider<=0;frame_age<=0;result_age<=0;frame_alive<=0;result_alive<=0;
            seen_result<=0;last_error<=0;last_length<=0;last_chars<=0;last_format_valid<=0;
        end else begin
            divider<=tick ? 0:divider+1'b1;
            if(tick) begin
                if(frame_alive) begin
                    if(frame_age>=TIMEOUT_MS-1) frame_alive<=0;
                    else frame_age<=frame_age+1'b1;
                end
                if(result_alive) begin
                    if(result_age>=TIMEOUT_MS-1) begin
                        result_alive<=0;last_length<=0;last_chars<=0;last_format_valid<=0;
                    end
                    else result_age<=result_age+1'b1;
                end
            end
            if(frame_event) begin frame_age<=0;frame_alive<=1;end
            if(result_event) begin
                seen_result<=1;result_alive<=1;result_age<=0;last_error<=raw_error;
                last_length<=raw_length;last_chars<=raw_chars[48:0];last_format_valid<=format_ok;
            end
            if(!configured || camera_fault || !memory_ready) begin
                frame_alive<=0;result_alive<=0;seen_result<=0;
                last_length<=0;last_chars<=0;last_format_valid<=0;last_error<=0;
            end
        end
    end
endmodule

// car_test/PL/src/video/lpr_osd.v
// Generated by sim/export_osd_font.py
`define OSD_STATE_0 49'h122448912e549
`define OSD_STATE_1 49'h1224489f3a6cc
`define OSD_STATE_2 49'h122448a74a8d0
`define OSD_STATE_3 49'h122448af5aad4
`define OSD_STATE_4 49'h122448b76a9d2
`define OSD_STATE_5 49'h122448ad52cd8
`define OSD_STATE_6 49'h122448911a2d3
`define OSD_STATE_7 49'h122448911a2c4
`define OSD_STATE_8 49'h122448bb72dda
`define OSD_STATE_9 49'h1224489f3afde
`define OSD_LABEL_CONFIRM 14'h2345
`define OSD_LABEL_RAW 14'h2562
`define OSD_LABEL_LENGTH 14'h30e3
`define OSD_LABEL_VOTES 14'h30e0
`define OSD_LABEL_FAULT 14'h27ce
`define OSD_LABEL_RETRIES 14'h32e4
`define OSD_GLYPH_SPACE 7'd72
`define OSD_GLYPH_DASH 7'd71
`define OSD_GLYPH_SLASH 7'd104
`define OSD_GLYPH_I 7'd102
`define OSD_GLYPH_O 7'd103

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
 lpr_font_tile #(.FILE("assets/osd_font0.hex")) t0(clk,address[8:0],d0);
 lpr_font_tile #(.FILE("assets/osd_font1.hex")) t1(clk,address[8:0],d1);
 lpr_font_tile #(.FILE("assets/osd_font2.hex")) t2(clk,address[8:0],d2);
 lpr_font_tile #(.FILE("assets/osd_font3.hex")) t3(clk,address[8:0],d3);
 assign data=tile==0 ? d0:tile==1 ? d1:tile==2 ? d2:d3;
endmodule
module lpr_font_tile #(parameter FILE="")(
 input wire clk,input wire [8:0] address,output reg [15:0] data
);
 (* ram_style="block" *) reg [15:0] rows[0:511];
 initial $readmemh(FILE,rows);
 always @(posedge clk) data<=rows[address];
endmodule

// car_test/PL/src/cnn/requantize.v
module requantize (
    input wire signed [31:0] accum, input wire [3:0] shift, input wire relu,
    output reg signed [15:0] value
);
    reg [14:0] rounding_bias;
    reg signed [32:0] biased,rounded;
    always @(*) begin
        // Arithmetic shift rounds toward -infinity. For shift>0, adding
        // half minus the sign bit gives nearest, ties away from zero.
        // The 33-bit sum also handles INT32_MIN/MAX without overflow.
        if(shift==0) rounding_bias=0;
        else rounding_bias=(15'd1<<(shift-1'b1))-{14'd0,accum[31]};
        biased=$signed({accum[31],accum})+$signed({18'd0,rounding_bias});
        rounded=biased>>>shift;
        if(relu) begin
            if(rounded[32]) value=16'sd0;
            else if(|rounded[31:8]) value=16'sd255;
            else value={8'd0,rounded[7:0]};
        end else begin
            if(rounded[32] && !(&rounded[31:15])) value=16'sh8000;
            else if(!rounded[32] && |rounded[31:15]) value=16'sd32767;
            else value=rounded[15:0];
        end
    end
endmodule

// car_test/PL/src/comm/uart_rx.v
module uart_rx #(parameter CLKS_PER_BIT=434) (
    input wire clk, input wire rst_n, input wire rxd,
    output reg [7:0] data_out, output reg data_valid
);
    localparam IDLE=0, START=1, DATA=2, STOP=3;
    reg [1:0] state;
    reg [31:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;
    (* ASYNC_REG="TRUE" *) reg rx_meta,rx_sync;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin rx_meta<=1; rx_sync<=1; end
        else begin rx_meta<=rxd; rx_sync<=rx_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=IDLE; count<=0; bit_index<=0; shift<=0; data_out<=0; data_valid<=0; end
        else begin
            data_valid<=0;
            case(state)
                IDLE: if(!rx_sync) begin count<=0; state<=START; end
                START: begin
                    if(count==(CLKS_PER_BIT/2)-1) begin
                        count<=0;
                        if(!rx_sync) begin state<=DATA; bit_index<=0; end
                        else state<=IDLE;
                    end else count<=count+1'b1;
                end
                DATA: begin
                    if(count==CLKS_PER_BIT-1) begin
                        count<=0; shift[bit_index]<=rx_sync;
                        if(bit_index==7) state<=STOP;
                        else bit_index<=bit_index+1'b1;
                    end else count<=count+1'b1;
                end
                STOP: begin
                    if(count==CLKS_PER_BIT-1) begin
                        count<=0; state<=IDLE;
                        if(rx_sync) begin data_out<=shift; data_valid<=1; end
                    end else count<=count+1'b1;
                end
            endcase
        end
    end
endmodule

// car_test/PL/src/comm/uart_tx.v
module uart_tx #(parameter CLKS_PER_BIT=434) (
    input wire clk, input wire rst_n, input wire [7:0] data_in, input wire data_valid,
    output reg txd, output reg busy
);
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg [31:0] count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin txd<=1; busy<=0; shift<=10'h3ff; bit_index<=0; count<=0; end
        else if(!busy) begin
            txd<=1;
            if(data_valid) begin
                shift<={1'b1,data_in,1'b0}; bit_index<=0; count<=0; txd<=0; busy<=1;
            end
        end else if(count==CLKS_PER_BIT-1) begin
            count<=0;
            if(bit_index==9) begin busy<=0; txd<=1; end
            else begin bit_index<=bit_index+1'b1; shift<={1'b1,shift[9:1]}; txd<=shift[1]; end
        end else count<=count+1'b1;
    end
endmodule
