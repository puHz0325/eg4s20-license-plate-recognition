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
