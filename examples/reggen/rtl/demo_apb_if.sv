// Copyright (c) 2026 MetatronJeanne
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
interface demo_apb_if;
    logic [31:0] paddr, pwdata, prdata;
    logic psel, penable, pwrite, pready, pslverr;
    modport s (input paddr, pwdata, psel, penable, pwrite,
               output prdata, pready, pslverr);
endinterface
