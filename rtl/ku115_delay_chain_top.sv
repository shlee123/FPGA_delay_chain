`timescale 1ns/1ps

// Standalone integration example for xcku115-flvb1760-1-c.
//
// clk80_in and refclk300_in are external-clock examples. If the clocks are
// already generated and globally buffered elsewhere in the design, remove
// these BUFG instances and connect those internal clocks directly.
module ku115_delay_chain_top (
    input  wire       clk80_in,
    input  wire       refclk300_in,
    input  wire       rst,
    input  wire [1:0] sel,
    // Input-port path: IBUF -> IDELAY/ODELAY component-mode cascade -> fabric.
    input  wire       data_in,

    output wire       ddr_clk_p,
    output wire       ddr_clk_n,
    output wire       delay_ready,
    output wire       update_busy,
    output wire       idelayctrl_ready,
    output wire [1:0] sel_active,
    output wire       cal_error,
    output wire       data_to_fabric,
    output wire       input_delay_ready,
    output wire       input_update_busy,
    output wire       input_idelayctrl_ready,
    output wire [1:0] input_sel_active,
    output wire       input_cal_error
);

    wire clk80;
    wire refclk300;
    wire fwd_clk_raw;
    wire fwd_clk_delayed;
    wire data_in_buffered;

    BUFG u_bufg_clk80 (
        .I (clk80_in),
        .O (clk80)
    );

    BUFG u_bufg_refclk300 (
        .I (refclk300_in),
        .O (refclk300)
    );

    // Generate a 50% duty-cycle, 80 MHz forwarded clock in the output logic.
    ODDRE1 #(
        .IS_C_INVERTED (1'b0),
        .IS_D1_INVERTED(1'b0),
        .IS_D2_INVERTED(1'b0),
        .SIM_DEVICE    ("ULTRASCALE"),
        .SRVAL         (1'b0)
    ) u_fwd_clk_oddr (
        .Q  (fwd_clk_raw),
        .C  (clk80),
        .D1 (1'b1),
        .D2 (1'b0),
        .SR (rst)
    );

    ku115_odelay4_select u_delay_chain (
        .data_in          (fwd_clk_raw),
        .cfg_clk          (clk80),
        .refclk_300       (refclk300),
        .rst              (rst),
        .sel              (sel),
        .data_out         (fwd_clk_delayed),
        .delay_ready      (delay_ready),
        .update_busy      (update_busy),
        .idelayctrl_ready (idelayctrl_ready),
        .sel_active       (sel_active),
        .cal_error        (cal_error)
    );

    // Keep the cascade output on the dedicated output path. Do not insert a
    // LUT or fabric mux between fwd_clk_delayed and this output buffer.
    OBUFDS u_ddr_clk_obufds (
        .I  (fwd_clk_delayed),
        .O  (ddr_clk_p),
        .OB (ddr_clk_n)
    );

    // Keep the input-port connection in the I/O path.  The output of the
    // four-element cascade is a fabric signal; do not insert a LUT or fabric
    // mux between this IBUF and u_input_delay_chain.
    IBUF u_data_in_ibuf (
        .I (data_in),
        .O (data_in_buffered)
    );

    ku115_idelay4_select u_input_delay_chain (
        .data_in          (data_in_buffered),
        .cfg_clk          (clk80),
        .refclk_300       (refclk300),
        .rst              (rst),
        .sel              (sel),
        .data_out         (data_to_fabric),
        .delay_ready      (input_delay_ready),
        .update_busy      (input_update_busy),
        .idelayctrl_ready (input_idelayctrl_ready),
        .sel_active       (input_sel_active),
        .cal_error        (input_cal_error)
    );

endmodule
