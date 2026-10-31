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
