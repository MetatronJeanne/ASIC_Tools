// Copyright (c) 2026 MetatronJeanne
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module data_pair #(parameter W = 8) (
    input logic [W-1:0] a, b,
    output logic [W-1:0] y
);
    assign y = a ^ b;
endmodule
