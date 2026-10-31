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
