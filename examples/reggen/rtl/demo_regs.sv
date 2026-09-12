// Copyright (c) 2026 MetatronJeanne
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
`include "reg_inc.v"

module demo_regs (
    //reggen_port_on
    //reggen_port_off
    input logic clk,
    input logic reset_n,
    demo_apb_if.s apb
);
    assign apb.pready = 1'b1;
    assign apb.pslverr = 1'b0;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            //reggen_default_on
            //reggen_default_off
        end else if (apb.psel && apb.penable && apb.pwrite) begin
            case (apb.paddr)
                //reggen_write_on
                //reggen_write_off
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            apb.prdata <= '0;
        end else if (apb.psel && !apb.pwrite) begin
            case (apb.paddr)
                //reggen_read_on
                //reggen_read_off
                default: apb.prdata <= '0;
            endcase
        end
    end
endmodule
