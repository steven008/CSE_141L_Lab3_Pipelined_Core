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
    if (wen_i) begin
	  //$display("******************************");
	  //$display("mem[%d] <= %d", addr_i, instruction_i.opcode);
      mem[addr_i] <= instruction_i;
	end
	else if (nop_i) begin //insert nop instruction
	  //$display("******************************");
	  //$display("NOP");
	  instruction_o <= 0;
	end
    else begin 
	  //$display("******************************");
	  //$display("%d <= mem[%d]", mem[addr_i].opcode, addr_i);
      instruction_o <= mem[addr_i];
	end
  end
endmodule
