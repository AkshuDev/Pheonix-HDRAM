// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// This source file is part of Pheonix-HDRAM
// Licensed under the CERN-OHL-S v2 (https://cern-ohl.web.cern.ch).
// You may redistribute and modify this file under the terms of the CERN-OHL-S v2.

`timescale 1ns/1ps

module px_8gvtdr_hr_hdram #(
    parameter DQ_WIDTH = 16,
    parameter ADDR_WIDTH = 7,
    parameter BANK_WIDTH = 1, // 4 (Final)
    parameter DM_WIDTH = 2,
    parameter NUM_BANKS = (1<<BANK_WIDTH),
    parameter ROW_BITS = 3, // 14 (Final)
    parameter COL_BITS = 4, // 10 (Final)
    parameter ROW_POSE = 7, // Row Position End
    parameter COL_POSE = 4, // Column Position End
    parameter SIM_SIZE = NUM_BANKS*(1<<ROW_BITS)*(1<<COL_BITS) // SIM
) (
    // Clocks
    input wire clk,
    input wire reset_n,

    // Control signals
    input wire cs_n,
    input wire ras_n,
    input wire cas_n,
    input wire we_n,
    input wire cke,
    input wire mddr_n, // Mode Double Data Rate (Active-Low)

    // Address
    input wire [ADDR_WIDTH-1:0] addr,
    input wire [BANK_WIDTH-1:0] ba,

    // Data
    inout wire [DQ_WIDTH-1:0] dq,
    input wire [DM_WIDTH-1:0] dm,
    output reg tdr_a, // TDR Active
    input wire sbt, // Send Bit 3, Controlled internally and externally
    output reg barm // Bit Arm, 1 whenever bits have started being sent, 0 at end of clock cycles
);
    reg [DQ_WIDTH-1:0] mem [0:SIM_SIZE-1];

	reg dq_oe;
	reg [DQ_WIDTH-1:0] dq_out;

	reg [DQ_WIDTH-1:0] dq_out_0;
	reg [DQ_WIDTH-1:0] dq_out_1;
	reg [DQ_WIDTH-1:0] dq_out_2;
	reg dq_out_2_active;

	assign dq = dq_oe ? dq_out : {DQ_WIDTH{1'bz}};

	always @(*) begin // Multiplexer
		if (dq_out_2_active)
			dq_out = dq_out_2;
		else if (tdr_a)
			dq_out = dq_out_1;
		else
			dq_out = dq_out_0;
	end

	always @(posedge clk or negedge reset_n) begin // Control-Level-1 Transmistter (Highest Control)
		if (!reset_n) begin
			dq_out_0 <= {DQ_WIDTH{1'b0}};
			barm <= 0;
		end else if (dq_oe) begin // B0
			barm <= 1;
			dq_out_0 <= mem[...];
		end
	end

	always @(negedge clk or negedge reset_n) begin // Control-Level-2 Transmistter (Second Highest Control)
		if (!reset_n) begin
			dq_out_1 <= {DQ_WIDTH{1'b0}};
		end else if (dq_oe) begin // B1
			dq_out_1 <= mem[...];

			// Extra info
			tdr_a <= sbt ? 0 : 1;
			barm <= 0;
		end
	end

	always @(*) begin // Control-Level-3 Transmistter (Least Control)
		dq_out_2_active = dq_oe && sbt;

		if (dq_out_2_active)
			dq_out_2 = mem[...];
		else
			dq_out_2 = {DQ_WIDTH{1'b0}};
	end
endmodule
