// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// This source file is part of Pheonix-HDRAM
// Licensed under the CERN-OHL-S v2 (https://cern-ohl.web.cern.ch).
// You may redistribute and modify this file under the terms of the CERN-OHL-S v2.

module px_8gvtdr_hr_hdram #(
    parameter DQ_WIDTH = 16,
    parameter ADDR_WIDTH = 24,
    parameter BANK_WIDTH = 4,
    parameter DM_WIDTH = 2,
    parameter NUM_BANKS = (1<<BANK_WIDTH),
    parameter ROW_BITS = 14,
    parameter COL_BITS = 10,
    parameter SIM_SIZE = NUM_BANKS*(1<<COL_BITS) // SIM
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

    // Address
    input wire [ADDR_WIDTH-1:0] addr,
    input wire [BANK_WIDTH-1:0] ba,

    // Data
    inout wire [DQ_WIDTH-1:0] dq,
    input wire [DM_WIDTH-1:0] dm,
    output reg tdr_a, // TDR Active
    output reg async_bs, // Async Bit Sent
    output reg barm // Bit Arm, 1 whenever bits have started being sent
);
    reg [DQ_WIDTH-1:0] mem [0:SIM_SIZE-1];

    reg async_bs_next;
    reg [DQ_WIDTH-1:0] dq_next; // Sync Precomputed data

    reg [DQ_WIDTH-1:0] dq_out;
    reg [DQ_WIDTH-1:0] dq_next1; // Async Precomputed Data
    reg dq_drive; // Controls when the chip drives the DQ

    reg [ROW_BITS-1:0] active_row [0:NUM_BANKS-1];
    reg row_open [0:NUM_BANKS-1];

    assign dq = dq_drive ? dq_out : {DQ_WIDTH{1'bz}};

    // Timing
    integer trcd_count, trp_count, cas_delay;
    localparam trcd = 2, trp = 2, tcas = 2;

    // Triple Data Rate
    reg tdr_req;
    reg [2:0] bit_count;

    reg cas_fire;

    integer i;
    integer w;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dq_out <= 0;
            trcd_count <= 0;
            trp_count <= 0;
            cas_delay <= 0;

            for (i = 0; i < NUM_BANKS; i=i+1) begin
                row_open[i] <= 1'b0;
                active_row[i] <= 0;
            end
        end else if (!cs_n) begin
            if (!ras_n && cas_n && we_n) begin // Active CMD
                row_open[ba] <= 1'b1;
                active_row[ba] <= addr[ROW_BITS-1:0];
                trcd_count <= trcd; // start timing
            end else if (ras_n && !cas_n && we_n && row_open[ba] && trcd_count == 0) begin // Read CMD
                cas_delay <= tcas;
                dq_drive <= 0;
                bit_count <= 0;
            end else if (ras_n && !cas_n && !we_n && row_open[ba] && trcd_count == 0) begin // Write CMD
                for (w = 0; w < (DQ_WIDTH/8); w=w+1)
                    if (!dm[w]) 
                        mem[{ba, addr[COL_BITS-1:0]}] <= dq[w*8 +: 8];
            end else if (!ras_n && cas_n && !we_n) begin // Precharge CMD
                row_open[ba] <= 1'b0;
                trp_count <= trp;
            end else begin
                dq_drive <= 0;
            end
        end

        if (trcd_count > 0) trcd_count <= trcd_count - 1;
        if (trp_count > 0) trp_count <= trp_count - 1;

        cas_fire <= (cas_delay - 1 == 1);
        if (cas_delay > 0) begin
            cas_delay <= cas_delay - 1;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tdr_req <= 0;
            bit_count <= 0;
            dq_drive <= 0;
            async_bs <= 0;
            barm <= 0;
        end else if (cas_fire && row_open[ba]) begin
            dq_drive <= 1;
            dq_out <= mem[{ba, addr[COL_BITS-1:0]}];
            bit_count <= 1;
            barm <= 1;
            dq_next = mem[{ba, addr[COL_BITS-1:0]}];
            $display("Sync bit: 0x%h", dq_next);
            tdr_req = 1;
        end
    end

    always @(*) begin
        if (cas_fire && tdr_req && reset_n) begin
            dq_next1 = mem[{ba, addr[COL_BITS-1:0]}];
            $display("Async Bit: 0x%h", dq_next1);
            async_bs_next = 1;
            bit_count = 2;
            tdr_req = 0;
        end else if (reset_n && cas_delay == 0 && async_bs_next) begin
            if (dq == dq_next) begin // Data is stable and sent
                dq_out = dq_next1;
                async_bs = async_bs_next;
                async_bs_next = 0;
            end
        end
    end

    always @(negedge clk or negedge reset_n) begin
        if (reset_n && async_bs)
            async_bs <= 0;

        if (!reset_n) begin
            tdr_a <= 0;
        end else if (cas_fire) begin
            tdr_a <= 0;

            if (tdr_req == 0 && bit_count > 1) begin // Send bit 3
                bit_count <= 3;
                dq_out <= mem[{ba, addr[COL_BITS-1:0]}];
                tdr_a <= 1;
                dq_drive <= 0;
            end else if (tdr_req == 1 && bit_count >= 1) begin
                tdr_a <= 0;
                dq_drive <= 0;
            end

            barm <= 0;
        end
    end
endmodule
