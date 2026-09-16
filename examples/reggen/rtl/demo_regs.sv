// Copyright (c) 2026 MetatronJeanne
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
`include "reg_inc.v"

module demo_regs (
    input logic clk,
    input logic reset_n,
    demo_apb_if.s apb
`include "DEMO_reg_port.svh"
);
    assign apb.pready = 1'b1;
    assign apb.pslverr = 1'b0;

`include "DEMO_reg_logic.svh"
endmodule
