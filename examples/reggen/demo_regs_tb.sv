// Copyright (c) 2026 MetatronJeanne
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module demo_regs_tb;
    logic clk = 0;
    logic reset_n = 0;
    always #5 clk = ~clk;
    demo_apb_if apb();
    demo_control_if ctrl0(), ctrl1();
    demo_status_if status();
    logic [7:0] clear_flags, set_flags;
    logic [47:0] wide_value;
    assign status.hw_status = 8'ha5;
    demo_regs dut (.*);

    task automatic transfer(input bit wr, input logic [31:0] addr, value);
        @(negedge clk);
        apb.psel = 1;
        apb.penable = 0;
        apb.pwrite = wr;
        apb.paddr = addr;
        apb.pwdata = value;
        @(negedge clk);
        apb.penable = 1;
        @(posedge clk);
        #1;
        if (!apb.pready || apb.pslverr) $fatal(1, "APB handshake failure");
        if (!wr && apb.prdata !== value)
            $fatal(1, "Read %h: got %h, expected %h", addr, apb.prdata, value);
        @(negedge clk);
        apb.psel = 0;
        apb.penable = 0;
    endtask

    initial begin
        apb.paddr = 0;
        apb.pwdata = 0;
        apb.psel = 0;
        apb.penable = 0;
        apb.pwrite = 0;
        repeat (3) @(negedge clk);
        reset_n = 1;
        transfer(0, 'h00, 'h12);
        transfer(0, 'h10, 'h56789abc);
        transfer(0, 'h14, 'h1234);
        transfer(1, 'h00, 'hffffffab);
        transfer(0, 'h00, 'hab);
        transfer(1, 'h18, 'h34);
        transfer(0, 'h18, 'h34);
        transfer(0, 'h00, 'hab);
        transfer(1, 'h04, 'h00);
        transfer(0, 'h04, 'ha5);
        transfer(1, 'h08, 'h0f);
        transfer(0, 'h08, 'hf0);
        transfer(1, 'h08, 'h00);
        transfer(0, 'h08, 'hf0);
        transfer(1, 'h0c, 'h81);
        transfer(1, 'h0c, 'h02);
        transfer(0, 'h0c, 'h83);
        transfer(1, 'h10, 'hdeadbeef);
        transfer(1, 'h14, 'hface);
        transfer(0, 'h10, 'hdeadbeef);
        transfer(0, 'h14, 'hface);
        if (wide_value !== 48'hfacedeadbeef) $fatal(1, "Wide output mismatch");
        transfer(0, 'hfc, 'h0);
        $display("REGGEN_EXAMPLE_PASS");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "Timeout");
    end
endmodule
