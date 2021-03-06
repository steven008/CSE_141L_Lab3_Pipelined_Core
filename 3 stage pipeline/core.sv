`include "definitions.sv"

module core #(parameter imem_addr_width_p=10
                       ,net_ID_p = 10'b0000000001)
             (input  clk
             ,input  reset

             ,input  net_packet_s net_packet_i
             ,output net_packet_s net_packet_o

             ,input  mem_out_s from_mem_i
             ,output mem_in_s  to_mem_o

             ,output logic [mask_length_gp-1:0] barrier_o
             ,output logic                      exception_o
             ,output debug_s                    debug_o
             ,output logic [31:0]               data_mem_addr
             );

//---- Addresses and Data ----//
// Ins. memory address signals
logic [imem_addr_width_p-1:0] PC_r, PC_n,
                              pc_plus1, imem_addr,
                              imm_jump_add;
// Ins. memory output
instruction_s instruction, imem_out, instruction_r;

// Result of ALU, Register file outputs, Data memory output data
logic [31:0] alu_result, rs_val_or_zero, rd_val_or_zero, rs_val, rd_val;

// Reg. File address
logic [($bits(instruction.rs_imm))-1:0] wa_addr, rs_addr, rd_addr;

// Data for Reg. File signals
logic [31:0] rf_wd;

//---- Control signals ----//
// ALU output to determine whether to jump or not
logic jump_now;

// controller output signals
logic valid_to_mem_c, PC_wen, PC_wen_r;

// Handshake protocol signals for memory
logic yumi_to_mem_c;

// Final signals after network interfere
logic imem_wen, rf_wen;

// Network operation signals
logic net_ID_match,      net_PC_write_cmd,  net_imem_write_cmd,
      net_reg_write_cmd, net_bar_write_cmd, net_PC_write_cmd_IDLE;

// Memory stages and stall signals
logic [1:0] mem_stage_r, mem_stage_n;
logic stall, stall_non_mem;

// Exception signal
logic exception_n;

// State machine signals
state_e state_r,state_n;

//---- network and barrier signals ----//
instruction_s net_instruction;
logic [mask_length_gp-1:0] barrier_r,      barrier_n,
                           barrier_mask_r, barrier_mask_n;

//---- Connection to external modules ----//

// Suppress warnings
assign net_packet_o = net_packet_i;

// DEBUG Struct
assign debug_o = {PC_r, instruction, state_r, barrier_mask_r, barrier_r};

// pipe register structs
IF_ID_reg IF_ID_r, IF_ID_n;
ID_EX_reg ID_EX_r, ID_EX_n;

//control signal output from decode module
ctrl_sigs ctrl_sig_o;

// nop_ctr used to add 2 nop per instruction read
logic [1:0] nop_ctr; 
logic nop;
assign nop = (nop_ctr != 0);

// Since imem has one cycle delay and we send next cycle's address, PC_n,
// if the PC is not written, the instruction must not change
assign instruction = (PC_wen_r) ? imem_out : instruction_r;

// Determine next PC
assign imm_jump_add = $signed(instruction.rs_imm) + $signed(PC_r);
assign PC_wen = net_PC_write_cmd_IDLE || ~stall || !nop;
assign pc_plus1 = PC_r + 1'b1;

// Next pc is based on network or the instruction
always_comb
  begin
    PC_n = nop ? PC_r : pc_plus1; // don't change PC on nop
    if (net_PC_write_cmd_IDLE)
      PC_n = net_packet_i.net_addr;
    else           
      unique casez (ID_EX_r.instruction) // branches and jumps happen in execute stage
        `kJALR:
          PC_n = alu_result[0+:imem_addr_width_p];

        `kBNEQZ,`kBEQZ,`kBLTZ,`kBGTZ:
          if (jump_now)
            PC_n = ID_EX_r.imm_jump_add;

        default: begin end
      endcase
	//$display("******");
	//if(nop) 
	//   $display("NOP");
	//else 
	//   $display("OP");
	//$display("PC = %d", PC_n);
  end

// Selection between network and core for instruction address
assign imem_addr = (net_imem_write_cmd) ? net_packet_i.net_addr: PC_n;

// Instruction memory
instr_mem #(.addr_width_p(imem_addr_width_p)) imem
           (.clk(clk)
           ,.addr_i(imem_addr)
           ,.instruction_i(net_instruction)
           ,.wen_i(imem_wen)
           ,.nop_i(nop)
           ,.instruction_o(imem_out)
           );

// next pipeline register
assign IF_ID_n.instruction = instruction;
assign IF_ID_n.imm_jump_add = imm_jump_add;
assign IF_ID_n.pc_plus1 = pc_plus1;

// Decode module                 
cl_decode decode (.instruction_i(IF_ID_r.instruction)
                  ,.ctrl_sigs_o(ctrl_sigs_o)
                  );
                  
// State machine                                
cl_state_machine state_machine (.instruction_i(ID_EX_r.instruction)
                               ,.state_i(state_r)
                               ,.exception_i(exception_o)
                               ,.net_PC_write_cmd_IDLE_i(net_PC_write_cmd_IDLE)
                               ,.stall_i(stall)
                               ,.state_o(state_n)
                               );
 
// Register write could be from network or the controller
// writes occur in the execute stage
assign rf_wen    = net_reg_write_cmd || (ID_EX_r.ctrl_sigs.op_writes_rf_c && ~stall);
 
// register file addresses   
assign rs_addr = IF_ID_r.instruction.rs_imm;

// Selection between network and address included in the instruction which is exeuted
// Address for Reg. File is shorter than address of Ins. memory in network data
// Since network can write into immediate registers, the address is wider
// assign rd_addr = IF_ID_r.instruction.rs_imm;but for the destination register in an instruction the extra bits must be zero
assign rd_addr = (net_reg_write_cmd)
                 ? (net_packet_i.net_addr [0+:($bits(instruction.rs_imm))])
                 : ({{($bits(instruction.rs_imm)-$bits(instruction.rd)){1'b0}},
                    {IF_ID_r.instruction.rd}});
                    
					 
// writes occur in the execute stage
assign wa_addr = (net_reg_write_cmd)
    ? (net_packet_i.net_addr [0+:($bits(instruction.rs_imm))])
    : ({{($bits(instruction.rs_imm)-$bits(instruction.rd)){1'b0}},
       {ID_EX_r.instruction.rd}});
                       
// Register file
reg_file #(.addr_width_p($bits(instruction.rs_imm))) rf
          (.clk
          ,.wen_i(rf_wen)
          ,.wa_i(wa_addr)
          ,.write_data_i(rf_wd)
          ,.rs_addr_i(rs_addr)
          ,.rd_addr_i(rd_addr)
          ,.rs_val_o(rs_val)
          ,.rd_val_o(rd_val)
          );
    
//register file values
assign rs_val_or_zero = rs_addr ? rs_val : 32'b0;
assign rd_val_or_zero = rd_addr ? rd_val : 32'b0;

//next pipeline register 
assign ID_EX_n.ctrl_sigs = ctrl_sigs_o;
assign ID_EX_n.instruction = IF_ID_r.instruction;
assign ID_EX_n.rs_val_or_zero = rs_val_or_zero;
assign ID_EX_n.rd_val_or_zero = rd_val_or_zero;
assign ID_EX_n.imm_jump_add = IF_ID_r.imm_jump_add;
assign ID_EX_n.pc_plus1 = IF_ID_r.pc_plus1;


// ALU
alu alu_1 (.rd_i(ID_EX_r.rd_val_or_zero)
          ,.rs_i(ID_EX_r.rs_val_or_zero)
          ,.op_i(ID_EX_r.instruction)
          ,.result_o(alu_result)
          ,.jump_now_o(jump_now)
          );
          
// Data_mem
assign to_mem_o = '{write_data    : ID_EX_r.rs_val_or_zero
                   ,valid         : valid_to_mem_c
                   ,wen           : ID_EX_r.ctrl_sigs.is_store_op_c
                   ,byte_not_word : ID_EX_r.ctrl_sigs.is_byte_op_c
                   ,yumi          : yumi_to_mem_c
                   };
assign data_mem_addr = alu_result;   

// select the input data for Register file, from network, the PC_plus1 for JALR,
// Data Memory or ALU result
always_comb
  begin
    if (net_reg_write_cmd)
      rf_wd = net_packet_i.net_data;

    else if (ID_EX_r.instruction==?`kJALR)
      // rf_wd = ID_EX_r.pc_plus1;
      rf_wd = ID_EX_r.instruction.rd ? ID_EX_r.pc_plus1 : 0;

    else if (ID_EX_r.ctrl_sigs.is_load_op_c)
      rf_wd = from_mem_i.read_data;

    else
      rf_wd = alu_result;
  end
  
// Sequential part, including PC, barrier, exception and state
always_ff @ (posedge clk) begin
    if (!reset) begin
        PC_r            <= 0;
        barrier_mask_r  <= {(mask_length_gp){1'b0}};
        barrier_r       <= {(mask_length_gp){1'b0}};
        state_r         <= IDLE;
        instruction_r   <= 0;
        PC_wen_r        <= 0;
        exception_o     <= 0;
        mem_stage_r     <= 2'b00;
		
        // pipeline registers
        IF_ID_r <= 0;
        ID_EX_r <= 0;
        
        nop_ctr <= 0;
    end
    else begin
        nop_ctr <= (nop_ctr +1)%3;
		
        if (PC_wen) begin
          PC_r <= PC_n;
		  
          if (net_PC_write_cmd_IDLE) begin 
            IF_ID_r <= 0;
            ID_EX_r <= 0;
          end
          else begin // move pipeline registers
            IF_ID_r <= IF_ID_n;
            ID_EX_r <= ID_EX_n;
          end
        end
		
        barrier_mask_r <= barrier_mask_n;
        barrier_r      <= barrier_n;
        state_r        <= state_n;
        instruction_r  <= instruction;
        PC_wen_r       <= PC_wen;
        exception_o    <= exception_n;
        mem_stage_r    <= mem_stage_n;
    end
  end

// stall and memory stages signals
// rf structural hazard and imem structural hazard (can't load next instruction)
// network is writing to the register file or writing an instruction to instruction memory
assign stall_non_mem = (net_reg_write_cmd && ID_EX_r.ctrl_sigs.op_writes_rf_c)
                    || (net_imem_write_cmd);
// Stall if LD/ST still active; or in non-RUN state
assign stall = stall_non_mem || (mem_stage_n != 0) || (state_r != RUN);

// Launch LD/ST
assign valid_to_mem_c = ID_EX_r.ctrl_sigs.is_mem_op_c & (mem_stage_r < 2'b10);

always_comb
  begin
    yumi_to_mem_c = 1'b0;
    mem_stage_n   = mem_stage_r;

    if (valid_to_mem_c)
        mem_stage_n   = 2'b01;

    if (from_mem_i.yumi)
        mem_stage_n   = 2'b10;

    // If we can commit the LD/ST this cycle, the acknowledge dmem's response
    if (from_mem_i.valid & ~stall_non_mem)
      begin
        mem_stage_n   = 2'b00;
        yumi_to_mem_c = 1'b1;
      end
  end



//---- Datapath with network ----//
// Detect a valid packet for this core
assign net_ID_match = (net_packet_i.ID==net_ID_p);

// Network operation
assign net_PC_write_cmd      = (net_ID_match && (net_packet_i.net_op==PC));
assign net_imem_write_cmd    = (net_ID_match && (net_packet_i.net_op==INSTR));
assign net_reg_write_cmd     = (net_ID_match && (net_packet_i.net_op==REG));
assign net_bar_write_cmd     = (net_ID_match && (net_packet_i.net_op==BAR));
assign net_PC_write_cmd_IDLE = (net_PC_write_cmd && (state_r==IDLE));

// Barrier final result, in the barrier mask, 1 means not mask and 0 means mask
assign barrier_o = barrier_mask_r & barrier_r;

// The instruction write is just for network
assign imem_wen  = net_imem_write_cmd;

// Instructions are shorter than 32 bits of network data
assign net_instruction = net_packet_i.net_data [0+:($bits(instruction))];

// barrier_mask_n, which stores the mask for barrier signal
always_comb
  // Change PC packet
  if (net_bar_write_cmd && (state_r != ERR))
    barrier_mask_n = net_packet_i.net_data [0+:mask_length_gp];
  else
    barrier_mask_n = barrier_mask_r;

// barrier_n signal, which contains the barrier value
// it can be set by PC write network command if in IDLE
// or by an an BAR instruction that is committing
assign barrier_n = net_PC_write_cmd_IDLE
                   ? net_packet_i.net_data[0+:mask_length_gp]
                   : ((instruction==?`kBAR) & ~stall)
                     ? alu_result [0+:mask_length_gp]
                     : barrier_r;

// exception_n signal, which indicates an exception
// We cannot determine next state as ERR in WORK state, since the instruction
// must be completed, WORK state means start of any operation and in memory
// instructions which could take some cycles, it could mean wait for the
// response of the memory to acknowledge the command. So we signal that we recieved
// a wrong package, but do not stop the execution. Afterwards the exception_r
// register is used to avoid extra fetch after this instruction.
always_comb
  if ((state_r==ERR) || (net_PC_write_cmd && (state_r!=IDLE)))
    exception_n = 1'b1;
  else
    exception_n = exception_o;

endmodule

