// Copyright (c) 2026 MetatronJeanne
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module demo_top_tb;
    logic [15:0] a, b, y;
    demo_top dut (.*);
    initial begin
        for (int i = 0; i < 64; i++) begin
            a = 16'(i * 911);
            b = 16'(~(i * 319));
            #1;
            if (y !== (a ^ b)) $fatal(1, "Stitched datapath mismatch");
        end
        $display("TOPSTITCH_EXAMPLE_PASS");
        $finish;
    end
endmodule
