create_clock -name board_clk -period 20.000 [get_ports clk_50m]
create_clock -name camera_pclk -period 41.667 [get_ports cam_pclk]
derive_pll_clocks
set_clock_groups -asynchronous -group [get_clocks {board_clk clocks/memory_pll/pll.*}] -group [get_clocks {clocks/display_pll/pll.*}] -group [get_clocks camera_pclk]
set_input_delay -max 5.000 -clock camera_pclk -clock_fall [get_ports {cam_data[*] cam_href cam_vsync}]
set_input_delay -min 0.500 -clock camera_pclk -clock_fall [get_ports {cam_data[*] cam_href cam_vsync}]
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports uart_rxd] -through [get_nets {receiver/rx_meta*}]
