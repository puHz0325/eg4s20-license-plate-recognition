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
