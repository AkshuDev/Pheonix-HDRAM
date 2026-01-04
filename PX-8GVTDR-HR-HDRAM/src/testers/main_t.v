// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// This source file is part of Pheonix-HDRAM
// Licensed under the CERN-OHL-S v2 (https://cern-ohl.web.cern.ch).
// You may redistribute and modify this file under the terms of the CERN-OHL-S v2.

`timescale 1ns/1ps

module tb_px_8gvtdr_hr_hdram;

    // Clock with jitter
    reg clk = 0;
    real base_period = 10.0; // 100 MHz
    real jitter;

    always begin
        jitter = ($urandom_range(-300,300)) * 0.001; // +/- 0.3ns
        #(base_period/2.0 + jitter) clk = ~clk;
    end

    // Signals
    reg reset_n;
    reg cs_n, ras_n, cas_n, we_n, cke;
    reg [23:0] addr;
    reg [3:0] ba;
    wire [15:0] dq;
    reg [1:0] dm;

    wire tdr_a;
    wire async_bs;
    wire bit_arm;

    reg [15:0] dq_drv;
    reg dq_oe;
    assign dq = dq_oe ? dq_drv : 16'hzzzz;

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
        .barm(bit_arm)
    );

    // Golden memory
    reg [15:0] golden_mem [0:4095];

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
    task activate(input [3:0] bank, input [13:0] row);
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

    task write_mem(input [3:0] bank, input [9:0] col, input [15:0] data);
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

    task read_mem(input [3:0] bank, input [9:0] col);
        reg [15:0] sampled;
        integer beat;
        reg bit_armed;
        begin
            repeat ($urandom_range(1,4)) @(posedge clk);

            @(posedge clk);
            ba <= bank; addr <= col; cs_n <= 0; ras_n <= 1; cas_n <= 0; we_n <= 1;
            @(posedge clk);
            cs_n <= 1; cas_n <= 1;

            beat = 0;
            sampled = 0;
            bit_armed = 0;

            // Wait for TDR beats
            while (beat < 3) begin
                // Async Sampling
                if (async_bs && bit_armed) begin
                    sampled = dq;
                    $display("Debug: Async beat 50d -> bank=%0d col=%0d data=0x%h @%0t", beat, bank, col, sampled, $time);
                    beat = beat + 1;
                end

                // Rising edge sampling
                @(posedge clk);
                if (bit_arm && !bit_armed) begin
                    sampled = dq;
                    $display("Debug: Rising edge beat %0d -> bank=%0d col=%0d data=0x%h @%0t", beat, bank, col, sampled, $time);
                    beat = beat + 1;
                    bit_armed = 1;
                end

                // Falling edge sampling
                @(negedge clk);
                if (tdr_a && bit_armed) begin
                    sampled = dq;
                    $display("Debug: Falling edge beat %0d -> bank=%0d col=%0d data=0x%h @%0t", beat, bank, col, sampled, $time);
                    beat = beat + 1;
                end else if (bit_armed) begin
                    bit_armed = 0;
                end
            end

            if (sampled !== golden_mem[{bank,col}]) begin
                $display("Error: Read mismatch bank=%0d col=%0d exp=0x%h got=0x%h @%0t", bank, col, golden_mem[{bank,col}], sampled, $time);
                $stop;
            end else begin
                $display("Ok: Read bank=%0d col=%0d data=0x%h", bank, col, sampled);
            end
        end
    endtask

    task precharge(input [3:0] bank);
        begin
            @(posedge clk);
            ba <= bank; cs_n <= 0; ras_n <= 0; cas_n <= 1; we_n <= 0;
            @(posedge clk);
            cs_n <= 1; ras_n <= 1; we_n <= 1;
        end
    endtask

    // Stress test
    integer i;
    reg [15:0] data;

    initial begin
        @(posedge reset_n);
        for (i = 0; i < 50; i=i+1) begin
            ba = $urandom_range(0,3);
            addr = $urandom_range(0,1023);
            data = $random;

            activate(ba, addr[13:0]);
            write_mem(ba, addr[9:0], data);
            read_mem(ba, addr[9:0]);
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
