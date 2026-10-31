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
