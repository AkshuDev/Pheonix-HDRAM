// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// This source file is part of Pheonix-HDRAM
// Licensed under the CERN-OHL-S v2 (https://cern-ohl.web.cern.ch).
// You may redistribute and modify this file under the terms of the CERN-OHL-S v2.

`timescale 1ns/1ps

module tb_px_8gvtdr_hr_hdram #(
    parameter DQ_WIDTH = 16,
    parameter ADDR_WIDTH = 7,
    parameter BANK_WIDTH = 1, // 4 (Final)
    parameter DM_WIDTH = 2,
    parameter NUM_BANKS = (1<<BANK_WIDTH),
    parameter ROW_BITS = 3, // 14 (Final)
    parameter COL_BITS = 4, // 10 (Final)
    parameter ROW_POSE = 7, // Row Position End
    parameter COL_POSE = 4, // Column Position End
    parameter SIM_SIZE = NUM_BANKS*(1<<COL_BITS) // SIM
);

    // Clock with jitter
    reg clk = 0;
    real base_period = 0.2; // 10.0=100 MHz 1.0=1 GHz 0.2=5GHz
    real jitter;

    always begin
        jitter = ($urandom_range(600) - 300) * 0.001; // +/- 300ps
        #((base_period/2.0) + jitter) clk = ~clk;
    end

    // Signals
    reg reset_n;
    reg cs_n, ras_n, cas_n, we_n, cke;
    reg [ADDR_WIDTH-1:0] addr;
    reg [BANK_WIDTH-1:0] ba;
    wire [DQ_WIDTH-1:0] dq;
    reg [DM_WIDTH-1:0] dm;

    wire tdr_a;
    wire async_bs;
    wire bit_arm;
    reg ddr_mode_n;
    reg bit_ackn;

    reg [DQ_WIDTH-1:0] dq_drv;
    reg dq_oe;
    assign dq = dq_oe ? dq_drv : {DQ_WIDTH{1'hz}};

    // DUT
    px_8gvtdr_hr_hdram dut (
        .clk(clk),
        .reset_n(reset_n),
        .cs_n(cs_n),
        .ras_n(ras_n),
        .cas_n(cas_n),
        .we_n(we_n),
        .cke(cke),
        .addr(addr),
        .ba(ba),
        .dq(dq),
        .dm(dm),
        .tdr_a(tdr_a),
        .async_bs(async_bs),
        .barm(bit_arm),
        .mddr_n(ddr_mode_n),
        .backn(bit_ackn)
    );

    // Golden memory
    reg [DQ_WIDTH-1:0] golden_mem [0:SIM_SIZE-1];

    // Reading TDR setup
    reg read_start;
    reg read_done;
    integer read_bursts;
    reg [DQ_WIDTH-1:0] read_samples [0:2];
    reg read_bit_armed;
    reg [BANK_WIDTH-1:0] read_bank;
    reg [COL_BITS-1:0] read_col;
    reg read_async_bit_done;

    always @(posedge clk) begin
        if (read_start && !read_done) begin
            #1;
            if (bit_arm && !read_bit_armed) begin
                read_samples[0] = dq;
                bit_ackn = 1;
                read_bit_armed = 1;
                read_bursts = 1;
                $display("Debug: Rising edge burst %0d -> bank=%0d col=%0d data=0x%h @%0t", read_bursts, read_bank, read_col, read_samples[0], $time);
            end
        end
    end

    always @(negedge clk) begin
        if (read_start && !read_done) begin
            #1;
            if (read_bit_armed && tdr_a) begin
                read_samples[2] = dq;
                bit_ackn = 0;
                read_bit_armed = 0;
                read_bursts = read_bursts + 1;
                read_done = 1;
                $display("Debug: Falling edge burst %0d -> bank=%0d col=%0d data=0x%h mode=TDR @%0t", read_bursts, read_bank, read_col, read_samples[2], $time);
            end else if (read_bit_armed && !tdr_a) begin
                read_bursts = read_bursts + 1;
                read_bit_armed = 0;
                read_done = 1;
                $display("Debug: Falling edge -> bank=%0d col=%0d mode=DDR @%0t", read_bank, read_col, $time);
            end
        end
    end

    always @(*) begin
        if (read_start && !read_done) begin
            if (read_bit_armed && async_bs && !read_async_bit_done) begin
                read_samples[1] = dq;
                read_bursts = read_bursts + 1;
                read_async_bit_done = 1;
                $display("Debug: Async burst 50d -> bank=%0d col=%0d data=0x%h @%0t", read_bursts, read_bank, read_col, read_samples[1], $time);
            end
        end
    end

    // Reset
    initial begin
        reset_n = 0;
        cs_n = 1; ras_n = 1; cas_n = 1; we_n = 1; cke = 1;
        dq_oe = 0; dm = 0; addr = 0; ba = 0;

        repeat (8) @(posedge clk);
        reset_n = 1;
        repeat ($urandom_range(2,10)) @(posedge clk);
    end

    // IC commands
    task activate(input [BANK_WIDTH-1:0] bank, input [ROW_BITS-1:0] row);
        begin
            @(posedge clk);
            ba <= bank;
            addr <= row;
            cs_n <= 0; ras_n <= 0; cas_n <= 1; we_n <= 1;
            @(posedge clk);
            cs_n <= 1; ras_n <= 1;
            $display("Debug: Bank %0d Row %0d has been activated!", bank, row);
        end
    endtask

    task write_mem(input [BANK_WIDTH-1:0] bank, input [ROW_BITS-1:0] row, input [COL_BITS-1:0] col, input [DQ_WIDTH-1:0] data);
        begin
            repeat ($urandom_range(1,3)) @(posedge clk);
            golden_mem[{bank,col}] = data;

            @(posedge clk);
            ba <= bank; addr <= col; cs_n <= 0; ras_n <= 1; cas_n <= 0; we_n <= 0;
            dq_drv <= data; dq_oe <= 1;
            @(posedge clk);
            dq_oe <= 0; cs_n <= 1; cas_n <= 1; we_n <= 1;
            $display("Debug: Written data 0x%h @%0t", data, $time);
        end
    endtask

    task read_mem(input [BANK_WIDTH-1:0] bank, input [ROW_BITS-1:0] row, input [COL_BITS-1:0] col);
        begin
            repeat ($urandom_range(1,4)) @(posedge clk);

            @(posedge clk);
            ba <= bank; addr <= col; cs_n <= 0; ras_n <= 1; cas_n <= 0; we_n <= 1; ddr_mode_n <= 1;
            @(posedge clk);
            cs_n <= 1; cas_n <= 1;

            read_samples[0] = 0;
            read_samples[1] = 0;
            read_samples[2] = 0;
            bit_ackn = 0;
            read_bursts = 0;
            read_bit_armed = 0;
            read_done = 0;
            read_bank = bank;
            read_col = col;
            read_start = 1;
            read_async_bit_done = 0;

            // Wait for TDR beats
            wait (read_done || read_bursts >= 3);

            read_start = 0;
            read_done = 0;
            bit_ackn = 0;
            read_bursts = 0;
            read_bit_armed = 0;

            if (read_samples[0] !== golden_mem[{bank,row,col}]) begin
                $display("Error: Read mismatch bank=%0d row=%0d col=%0d exp=0x%h got=0x%h @%0t", bank, row, col, golden_mem[{bank,row,col}], read_samples[0], $time);
                $stop;
            end else begin
                $display("Ok: Read bank=%0d col=%0d data=0x%h", bank, col, read_samples[0]);
            end
        end
    endtask

    task read_mem_tdr(input [BANK_WIDTH-1:0] bank, input [ROW_BITS-1:0] row, input [COL_BITS-1:0] col);
        begin
            repeat ($urandom_range(1,4)) @(posedge clk);

            @(posedge clk);
            ba <= bank; addr <= col; cs_n <= 0; ras_n <= 1; cas_n <= 0; we_n <= 1; ddr_mode_n <= 1;
            @(posedge clk);
            cs_n <= 1; cas_n <= 1;

            read_samples[0] = 0;
            read_samples[1] = 0;
            read_samples[2] = 0;
            bit_ackn = 0;
            read_bursts = 0;
            read_bit_armed = 0;
            read_done = 0;
            read_bank = bank;
            read_col = col;
            read_start = 1;
            read_async_bit_done = 0;

            // Wait for TDR beats
            wait (read_done || read_bursts >= 3);

            read_start = 0;
            read_done = 0;
            bit_ackn = 0;
            read_bursts = 0;
            read_bit_armed = 0;

            if (read_samples[0] !== golden_mem[{bank,row,col}] || read_samples[1] !== golden_mem[{bank,row,col+2'd1}] || read_samples[2] !== golden_mem[{bank,row,col+2'd2}]) begin
                $display("Error: Read mismatch bank=%0d row=%0d col=%0d exp=0x%h%h%h got=0x%h%h%h @%0t", bank, row, col, golden_mem[{bank,row,col}],
                    golden_mem[{bank,row,col+2'd1}], golden_mem[{bank,row,col+2'd2}], read_samples[0], read_samples[1], read_samples[2], $time);
                $stop;
            end else begin
                $display("Ok: Read bank=%0d col=%0d data=0x%h%h%h", bank, col, read_samples[0], read_samples[1], read_samples[2]);
            end
        end
    endtask

    task precharge(input [BANK_WIDTH-1:0] bank);
        begin
            @(posedge clk);
            ba <= bank; cs_n <= 0; ras_n <= 0; cas_n <= 1; we_n <= 0;
            @(posedge clk);
            cs_n <= 1; ras_n <= 1; we_n <= 1;
        end
    endtask

    // Stress test
    integer i;
    reg [DQ_WIDTH-1:0] data;

    initial begin
        @(posedge reset_n);
        for (i = 0; i < 50; i=i+1) begin
            ba = $urandom_range(0,BANK_WIDTH-1);
            addr = $urandom_range(0,127);
            data = $random;

            activate(ba, addr[ROW_POSE-1:COL_POSE]);
            write_mem(ba, addr[ROW_POSE-1:COL_POSE], addr[COL_POSE-1:0], data);
            read_mem(ba, addr[ROW_POSE-1:COL_POSE], addr[COL_POSE-1:0]);
            read_mem_tdr(ba, addr[ROW_POSE-1:COL_POSE], addr[COL_POSE-1:0]);
            precharge(ba);

            repeat ($urandom_range(2,8)) @(posedge clk);
        end
        $display("Success: All Tests Passed!");
        #100 $finish;
    end

    // Waveform
    initial begin
        $dumpfile("tests/waveforms/main_t.vcd");
        $dumpvars(0, tb_px_8gvtdr_hr_hdram);
    end

endmodule
