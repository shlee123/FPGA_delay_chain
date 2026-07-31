`timescale 1ps/1ps

// Lightweight behavioral models for open-source simulation only.
//
// These models intentionally cover only the ports and modes used by this
// repository. They make the control FSM and selectable delay observable in
// CI; they are not replacements for AMD UNISIM or post-route SDF simulation.

module BUFG (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule

module IBUF (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule

module OBUFDS (
    input  wire I,
    output wire O,
    output wire OB
);
    assign O  = I;
    assign OB = ~I;
endmodule

module ODDRE1 #(
    parameter IS_C_INVERTED  = 1'b0,
    parameter IS_D1_INVERTED = 1'b0,
    parameter IS_D2_INVERTED = 1'b0,
    parameter SIM_DEVICE     = "ULTRASCALE",
    parameter SRVAL          = 1'b0
) (
    output reg  Q,
    input  wire C,
    input  wire D1,
    input  wire D2,
    input  wire SR
);
    wire c_int;
    assign c_int = C ^ IS_C_INVERTED;

    initial Q = SRVAL;

    always @(c_int or SR or D1 or D2) begin
        if (SR)
            Q <= SRVAL;
        else if (c_int)
            Q <= D1 ^ IS_D1_INVERTED;
        else
            Q <= D2 ^ IS_D2_INVERTED;
    end
endmodule

module IDELAYCTRL #(
    parameter SIM_DEVICE = "ULTRASCALE"
) (
    output reg  RDY,
    input  wire REFCLK,
    input  wire RST
);
    integer refclk_count;
    time last_refclk_rise;

    initial begin
        RDY          = 1'b0;
        refclk_count = 0;
        last_refclk_rise = 0;
    end

    always @(posedge REFCLK)
        last_refclk_rise = $time;

    // Match the documented asynchronous-assert/synchronous-release contract.
    // This makes open-source CI reject a cfg_clk-domain reset release.
    always @(negedge RST) begin
        if ($time != last_refclk_rise)
            $fatal(1, "IDELAYCTRL.RST deasserted away from REFCLK");
    end

    always @(posedge REFCLK or posedge RST) begin
        if (RST) begin
            RDY          <= 1'b0;
            refclk_count <= 0;
        end else if (!RDY) begin
            if (refclk_count == 15)
                RDY <= 1'b1;
            else
                refclk_count <= refclk_count + 1;
        end
    end
endmodule

module ODELAYE3 #(
    parameter CASCADE           = "NONE",
    parameter DELAY_FORMAT      = "TIME",
    parameter DELAY_TYPE        = "FIXED",
    parameter integer DELAY_VALUE = 0,
    parameter IS_CLK_INVERTED   = 1'b0,
    parameter IS_RST_INVERTED   = 1'b0,
    parameter real REFCLK_FREQUENCY = 300.0,
    parameter SIM_DEVICE        = "ULTRASCALE",
    parameter UPDATE_MODE       = "ASYNC"
) (
    output wire       CASC_OUT,
    output reg  [8:0] CNTVALUEOUT,
    output reg        DATAOUT,
    input  wire       CASC_IN,
    input  wire       CASC_RETURN,
    input  wire       CE,
    input  wire       CLK,
    input  wire [8:0] CNTVALUEIN,
    input  wire       EN_VTC,
    input  wire       INC,
    input  wire       LOAD,
    input  wire       ODATAIN,
    input  wire       RST
);
    localparam integer TAP_PS = 5;
    localparam integer INITIAL_TAPS = DELAY_VALUE / TAP_PS;

    wire clk_int;
    wire rst_int;
    wire path_in;
    integer delay_ps;

    assign clk_int  = CLK ^ IS_CLK_INVERTED;
    assign rst_int  = RST ^ IS_RST_INVERTED;
    assign CASC_OUT = (CASCADE == "MASTER") ? ODATAIN : CASC_IN;
    assign path_in  = (CASCADE == "SLAVE_END") ? CASC_IN :
                      (CASCADE == "NONE")      ? ODATAIN : CASC_RETURN;

    always @* delay_ps = CNTVALUEOUT * TAP_PS;

    initial begin
        // Vendor models keep startup state unknown until a valid primitive
        // reset/global-startup sequence initializes the delay counter.
        CNTVALUEOUT = 9'bx;
        DATAOUT     = 1'bx;
    end

    always @(posedge clk_int or posedge rst_int) begin
        if (rst_int)
            CNTVALUEOUT <= INITIAL_TAPS;
        else if (LOAD)
            CNTVALUEOUT <= CNTVALUEIN;
        else if (CE)
            CNTVALUEOUT <= INC ? CNTVALUEOUT + 9'd1
                               : CNTVALUEOUT - 9'd1;
    end

    always @(path_in)
        DATAOUT <= #(delay_ps) path_in;
endmodule

module IDELAYE3 #(
    parameter CASCADE           = "NONE",
    parameter DELAY_FORMAT      = "TIME",
    parameter DELAY_SRC         = "DATAIN",
    parameter DELAY_TYPE        = "FIXED",
    parameter integer DELAY_VALUE = 0,
    parameter IS_CLK_INVERTED   = 1'b0,
    parameter IS_RST_INVERTED   = 1'b0,
    parameter real REFCLK_FREQUENCY = 300.0,
    parameter SIM_DEVICE        = "ULTRASCALE",
    parameter UPDATE_MODE       = "ASYNC"
) (
    output wire       CASC_OUT,
    output reg  [8:0] CNTVALUEOUT,
    output reg        DATAOUT,
    input  wire       CASC_IN,
    input  wire       CASC_RETURN,
    input  wire       CE,
    input  wire       CLK,
    input  wire [8:0] CNTVALUEIN,
    input  wire       DATAIN,
    input  wire       EN_VTC,
    input  wire       IDATAIN,
    input  wire       INC,
    input  wire       LOAD,
    input  wire       RST
);
    localparam integer TAP_PS = 5;
    localparam integer ALIGN_TAPS = 32;
    localparam integer INITIAL_TAPS = ALIGN_TAPS + (DELAY_VALUE / TAP_PS);

    wire clk_int;
    wire rst_int;
    wire path_in;
    integer delay_ps;

    assign clk_int  = CLK ^ IS_CLK_INVERTED;
    assign rst_int  = RST ^ IS_RST_INVERTED;
    // An IDELAY master launches its selected input onto the dedicated cascade;
    // middle/end stages only forward the incoming cascade signal.
    assign CASC_OUT = (CASCADE == "MASTER")
                    ? ((DELAY_SRC == "IDATAIN") ? IDATAIN : DATAIN)
                    : CASC_IN;
    assign path_in  = (CASCADE == "SLAVE_END") ? CASC_IN :
                      (CASCADE == "NONE")      ? DATAIN : CASC_RETURN;

    always @* begin
        if (CNTVALUEOUT > ALIGN_TAPS)
            delay_ps = (CNTVALUEOUT - ALIGN_TAPS) * TAP_PS;
        else
            delay_ps = 0;
    end

    initial begin
        CNTVALUEOUT = 9'bx;
        DATAOUT     = 1'bx;
    end

    always @(posedge clk_int or posedge rst_int) begin
        if (rst_int)
            CNTVALUEOUT <= INITIAL_TAPS;
        else if (LOAD)
            CNTVALUEOUT <= CNTVALUEIN;
        else if (CE)
            CNTVALUEOUT <= INC ? CNTVALUEOUT + 9'd1
                               : CNTVALUEOUT - 9'd1;
    end

    always @(path_in)
        DATAOUT <= #(delay_ps) path_in;
endmodule
