`include "definitions.sv"

// A synchronous instruction memory

module instr_mem #(parameter addr_width_p = 10)
                 (input clk
                 ,input [addr_width_p-1:0] addr_i
                 ,input instruction_s instruction_i
                 ,input wen_i
				 ,input nop_i
                 ,output instruction_s instruction_o
                 );

instruction_s [(2**addr_width_p)-1:0] mem;
                                    
always_ff @ (posedge clk)
  begin
    if (wen_i)
      mem[addr_i] <= instruction_i;
	else if (nop_i) //insert nop instruction
	  instruction_o <= 0;
    else
      instruction_o <= mem[addr_i];
  end
endmodule
