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

    reg [DQ_WIDTH-1:0] dq_tmp;
    reg [DQ_WIDTH-1:0] dq_p1;
    reg [DQ_WIDTH-1:0] dq_p2;
    reg [DQ_WIDTH-1:0] dq_p3;
    reg dq_drive; // Controls when the chip drives the DQ
    reg dq_final_drive; // Secondry Control, allows Beat 3 to prevent dq drive and assign

    reg [ROW_BITS-1:0] active_row [0:NUM_BANKS-1];
    reg row_open [0:NUM_BANKS-1];

    wire [ROW_BITS-1:0] row;
    wire [COL_BITS-1:0] col;
    reg [ROW_BITS-1:0] latched_row;
    reg [COL_BITS-1:0] latched_col;
    reg [BANK_WIDTH-1:0] latched_ba;
    assign row = addr[ROW_POSE-1:COL_POSE];
    assign col = addr[COL_POSE-1:0];

    assign dq = (dq_drive && clk) ? // This logic went to crazy, too fast so i added a touch of beauty!
                    !sbt ? 
                        dq_p1
                    : 
                        dq_p2
                :
                    (dq_final_drive && !clk) ?
                        dq_p3
                    :
                        {DQ_WIDTH{1'bz}};

    // Timing
    integer trcd_count, trp_count, cas_delay;
    localparam trcd = 2, trp = 2, tcas = 2;

    // Triple Data Rate
    reg cas_fire;
    wire tdr_mode;
    assign tdr_mode = mddr_n ? 1 : 0;

    integer i;
    integer w;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dq_p1 <= 0;
            dq_p2 <= 0;
            dq_p3 <= 0;
            trcd_count <= 0;
            trp_count <= 0;
            cas_delay <= 0;
            latched_row <= 0;
            latched_col <= 0;
            latched_ba <= 0;
            dq_final_drive <= 0;

            for (i = 0; i < NUM_BANKS; i=i+1) begin
                row_open[i] <= 1'b0;
                active_row[i] <= 0;
            end
        end else if (!cs_n) begin
            if (!ras_n && cas_n && we_n) begin // Active CMD
                row_open[ba] <= 1'b1;
                active_row[ba] <= row;
                latched_row <= row;
                latched_col <= col;
                latched_ba <= ba;
                trcd_count <= trcd; // start timing
            end else if (ras_n && !cas_n && we_n && row_open[ba] && trcd_count == 0) begin // Read CMD
                cas_delay <= tcas;
                latched_row <= row;
                latched_col <= col;
                latched_ba <= ba;
                dq_drive <= 0;
            end else if (ras_n && !cas_n && !we_n && row_open[ba] && trcd_count == 0) begin // Write CMD
                dq_tmp = mem[{ba, row, col}];
                for (w = 0; w < (DQ_WIDTH/8); w=w+1)
                    if (!dm[w]) 
                        dq_tmp[w*8 +: 8] = dq[w*8 +: 8];
                mem[{ba, row, col}] <= dq_tmp;
            end else if (!ras_n && cas_n && !we_n) begin // Precharge CMD
                row_open[ba] <= 1'b0;
                latched_row <= row;
                latched_col <= col;
                latched_ba <= ba;
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
            dq_drive <= 0;
            barm <= 0;
        end else if (cas_fire && row_open[ba]) begin
            dq_drive <= 1;
            dq_p1 <= mem[{latched_ba, latched_row, latched_col}];
            barm <= 1;
        end
    end

    always @(posedge cas_fire or posedge sbt) begin
        if (cas_fire && tdr_mode && reset_n) begin
            dq_p2 <= mem[{latched_ba, latched_row, latched_col + 2'd1}];
        end
    end

    always @(negedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tdr_a <= 0;
        end else if (cas_fire) begin // TDR Mode
            tdr_a <= tdr_mode ? 1 : 0;
            dq_p3 <= tdr_mode ? mem[{latched_ba, latched_row, latched_col + 2'd2}] : mem[{latched_ba, latched_row, latched_col + 2'd1}];
            dq_drive <= 0;
            dq_final_drive <= 1;
            
            barm <= 0;
        end else begin
            dq_final_drive <= 0;
            tdr_a <= 0;
        end
    end
endmodule
