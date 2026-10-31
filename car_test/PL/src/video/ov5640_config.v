`include "ov5640_table.vh"
module ov5640_config #(
    parameter POWERUP_CYCLES=1000000, RESET_CYCLES=100000,
    parameter WRITE_DELAY_CYCLES=50000, HALF_PERIOD=250,
    parameter TABLE_FILE="car_test/PL/data/ov5640_vga_rgb888.hex",
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
