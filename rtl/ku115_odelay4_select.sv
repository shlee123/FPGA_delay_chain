`timescale 1ns/1ps

//------------------------------------------------------------------------------
// Four-element programmable output-delay cascade for Kintex UltraScale.
//
// Target device:
//   xcku115-flvb1760-1-c
//
// Legal UltraScale component-mode cascade:
//   ODELAYE3 (MASTER)
//     -> IDELAYE3 (SLAVE_MIDDLE)
//     -> ODELAYE3 (SLAVE_MIDDLE)
//     -> IDELAYE3 (SLAVE_END)
//
// SEL mapping (programmed delay; fixed cascade insertion delay is additional):
//   2'b00 : 4 x  312.5 ps = 1.25 ns
//   2'b01 : 4 x  625.0 ps = 2.50 ns
//   2'b10 : 4 x  937.5 ps = 3.75 ns
//   2'b11 : 4 x 1000.0 ps = 4.00 ns
//
// IMPORTANT:
// 1. UltraScale cannot directly cascade four ODELAYE3 primitives.  The
//    dedicated cascade route alternates ODELAYE3 and IDELAYE3 as shown above.
// 2. SEL does not mux physical delay stages.  It reloads the tap count of all
//    four elements in the fixed cascade.
// 3. delay_ready is Low while the delay is being changed.  If data_in is a
//    clock, the receiver must ignore/gate that clock while delay_ready is Low.
// 4. This example changes each delay by no more than eight taps per LOAD and
//    waits five cfg_clk cycles between updates, as recommended by UG571.
// 5. refclk_300 and cfg_clk must be stable before rst is deasserted.
// 6. If the bank contains other IDELAYCTRL/BITSLICE_CONTROL instances, their
//    resets must be coordinated at the bank level.
//------------------------------------------------------------------------------

module ku115_odelay4_select (
    input  wire       data_in,
    input  wire       cfg_clk,
    input  wire       refclk_300,
    input  wire       rst,
    input  wire [1:0] sel,

    output wire       data_out,
    output reg        delay_ready,
    output wire       update_busy,
    output wire       idelayctrl_ready,
    output reg  [1:0] sel_active,
    output reg        cal_error
);

    //--------------------------------------------------------------------------
    // Utility functions
    //--------------------------------------------------------------------------

    // Move from current tap count toward target by at most eight taps.
    function automatic [8:0] step_by_8;
        input [8:0] current;
        input [8:0] target;
        reg   [9:0] current_plus_8;
        reg   [9:0] target_plus_8;
        begin
            current_plus_8 = {1'b0, current} + 10'd8;
            target_plus_8  = {1'b0, target}  + 10'd8;
            if (current < target)
                step_by_8 = (current_plus_8 < {1'b0, target})
                          ? current_plus_8[8:0] : target;
            else if (current > target)
                step_by_8 = ({1'b0, current} > target_plus_8)
                          ? current - 9'd8 : target;
            else
                step_by_8 = current;
        end
    endfunction

    // Scale a calibrated 1000-ps tap span by NUM/16 with rounding.
    // NUM = 5, 10, 15, 16 gives 312.5, 625, 937.5, 1000 ps.
    function automatic [8:0] scale_span_16;
        input [8:0] span;
        input [4:0] num;
        reg   [14:0] product;
        begin
            product       = (span * num) + 15'd8;
            scale_span_16 = product >> 4;
        end
    endfunction

    function automatic [4:0] sel_numerator;
        input [1:0] sel_i;
        begin
            case (sel_i)
                2'b00: sel_numerator = 5'd5;
                2'b01: sel_numerator = 5'd10;
                2'b10: sel_numerator = 5'd15;
                default: sel_numerator = 5'd16;
            endcase
        end
    endfunction

    // Saturating 9-bit addition.
    function automatic [8:0] sat_add_9;
        input [8:0] a;
        input [8:0] b;
        reg   [9:0] sum;
        begin
            sum       = {1'b0, a} + {1'b0, b};
            sat_add_9 = sum[9] ? 9'h1ff : sum[8:0];
        end
    endfunction

    //--------------------------------------------------------------------------
    // SEL and IDELAYCTRL.RDY synchronization into cfg_clk domain
    //--------------------------------------------------------------------------

    (* ASYNC_REG = "TRUE" *) reg [1:0] sel_meta;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sel_sync;
    (* ASYNC_REG = "TRUE" *) reg       rdy_meta;
    (* ASYNC_REG = "TRUE" *) reg       rdy_sync;

    wire idelayctrl_rdy_raw;

    always @(posedge cfg_clk or posedge rst) begin
        if (rst) begin
            sel_meta <= 2'b00;
            sel_sync <= 2'b00;
            rdy_meta <= 1'b0;
            rdy_sync <= 1'b0;
        end else begin
            sel_meta <= sel;
            sel_sync <= sel_meta;
            rdy_meta <= idelayctrl_rdy_raw;
            rdy_sync <= rdy_meta;
        end
    end

    assign idelayctrl_ready = rdy_sync;
    assign update_busy      = ~delay_ready;

    //--------------------------------------------------------------------------
    // Reset, calibration and tap-update controller
    //--------------------------------------------------------------------------

    localparam [3:0] ST_RESET       = 4'd0;
    localparam [3:0] ST_RELEASE_DLY = 4'd1;
    localparam [3:0] ST_WAIT_RDY    = 4'd2;
    localparam [3:0] ST_WAIT_64     = 4'd3;
    localparam [3:0] ST_CAPTURE     = 4'd4;
    localparam [3:0] ST_QUIESCE     = 4'd5;
    localparam [3:0] ST_SET_VALUE   = 4'd6;
    localparam [3:0] ST_LOAD        = 4'd7;
    localparam [3:0] ST_WAIT_5      = 4'd8;
    localparam [3:0] ST_CHECK       = 4'd9;
    localparam [3:0] ST_WAIT_10     = 4'd10;
    localparam [3:0] ST_READY       = 4'd11;
    localparam [3:0] ST_ERROR       = 4'd12;

    reg [3:0] state;
    reg [6:0] wait_count;

    reg       delay_rst;
    reg       idelayctrl_rst;
    reg       en_vtc;
    reg       load_all;

    reg [1:0] sel_work;
    reg [4:0] numerator;

    reg [8:0] cnt_in_0;
    reg [8:0] cnt_in_1;
    reg [8:0] cnt_in_2;
    reg [8:0] cnt_in_3;

    wire [8:0] cnt_out_0;
    wire [8:0] cnt_out_1;
    wire [8:0] cnt_out_2;
    wire [8:0] cnt_out_3;

    reg [8:0] cur_0;
    reg [8:0] cur_1;
    reg [8:0] cur_2;
    reg [8:0] cur_3;

    reg [8:0] target_0;
    reg [8:0] target_1;
    reg [8:0] target_2;
    reg [8:0] target_3;

    reg [8:0] odelay_zero;
    reg [8:0] idelay_align;
    reg [8:0] odelay_span_1000;
    reg [8:0] idelay_span_1000;

    wire targets_reached;
    assign targets_reached = (cur_0 == target_0) &&
                             (cur_1 == target_1) &&
                             (cur_2 == target_2) &&
                             (cur_3 == target_3);

    always @(posedge cfg_clk or posedge rst) begin
        if (rst) begin
            state               <= ST_RESET;
            wait_count          <= 7'd0;
            delay_rst           <= 1'b1;
            idelayctrl_rst      <= 1'b1;
            en_vtc              <= 1'b1;
            load_all            <= 1'b0;
            delay_ready         <= 1'b0;
            cal_error           <= 1'b0;
            sel_active          <= 2'b00;
            sel_work            <= 2'b00;
            numerator           <= 5'd5;
            cnt_in_0            <= 9'd0;
            cnt_in_1            <= 9'd0;
            cnt_in_2            <= 9'd0;
            cnt_in_3            <= 9'd0;
            cur_0               <= 9'd0;
            cur_1               <= 9'd0;
            cur_2               <= 9'd0;
            cur_3               <= 9'd0;
            target_0            <= 9'd0;
            target_1            <= 9'd0;
            target_2            <= 9'd0;
            target_3            <= 9'd0;
            odelay_zero         <= 9'd0;
            idelay_align        <= 9'd0;
            odelay_span_1000    <= 9'd0;
            idelay_span_1000    <= 9'd0;
        end else begin
            load_all <= 1'b0;

            // RDY loss invalidates TIME-mode calibration. Restart the complete
            // component-mode reset/calibration sequence from any active state.
            if (!rdy_sync &&
                (state >= ST_CAPTURE) &&
                (state != ST_ERROR)) begin
                delay_rst      <= 1'b1;
                idelayctrl_rst <= 1'b1;
                en_vtc         <= 1'b1;
                delay_ready    <= 1'b0;
                state          <= ST_RESET;
            end else case (state)
                ST_RESET: begin
                    // Release delay elements before IDELAYCTRL, per UG571.
                    delay_rst  <= 1'b0;
                    en_vtc     <= 1'b1;
                    wait_count <= 7'd0;
                    state      <= ST_RELEASE_DLY;
                end

                ST_RELEASE_DLY: begin
                    if (wait_count == 7'd3) begin
                        idelayctrl_rst <= 1'b0;
                        wait_count     <= 7'd0;
                        state          <= ST_WAIT_RDY;
                    end else begin
                        wait_count <= wait_count + 7'd1;
                    end
                end

                ST_WAIT_RDY: begin
                    if (rdy_sync) begin
                        wait_count <= 7'd0;
                        state      <= ST_WAIT_64;
                    end
                end

                ST_WAIT_64: begin
                    if (!rdy_sync) begin
                        state <= ST_WAIT_RDY;
                    end else if (wait_count == 7'd63) begin
                        state <= ST_CAPTURE;
                    end else begin
                        wait_count <= wait_count + 7'd1;
                    end
                end

                ST_CAPTURE: begin
                    // Initial programmed values:
                    //   stage 0/1 = 0 ps
                    //   stage 2/3 = 1000 ps
                    // Their differences establish nominal taps per 1000 ps;
                    // the IDELAY subtraction also removes Align_Delay.
                    if ((cnt_out_2 <= cnt_out_0) ||
                        (cnt_out_3 <= cnt_out_1)) begin
                        cal_error   <= 1'b1;
                        delay_ready <= 1'b0;
                        state       <= ST_ERROR;
                    end else begin
                        odelay_zero      <= cnt_out_0;
                        idelay_align     <= cnt_out_1;
                        odelay_span_1000 <= cnt_out_2 - cnt_out_0;
                        idelay_span_1000 <= cnt_out_3 - cnt_out_1;

                        cur_0 <= cnt_out_0;
                        cur_1 <= cnt_out_1;
                        cur_2 <= cnt_out_2;
                        cur_3 <= cnt_out_3;

                        sel_work   <= sel_sync;
                        numerator  <= sel_numerator(sel_sync);
                        en_vtc     <= 1'b0;
                        wait_count <= 7'd0;
                        state      <= ST_QUIESCE;
                    end
                end

                ST_QUIESCE: begin
                    // EN_VTC must be Low for at least 10 cfg_clk cycles before
                    // modifying a TIME-mode delay line.
                    delay_ready <= 1'b0;
                    if (wait_count == 7'd9) begin
                        target_0 <= sat_add_9(
                            odelay_zero,
                            scale_span_16(odelay_span_1000, numerator));
                        target_1 <= sat_add_9(
                            idelay_align,
                            scale_span_16(idelay_span_1000, numerator));
                        target_2 <= sat_add_9(
                            odelay_zero,
                            scale_span_16(odelay_span_1000, numerator));
                        target_3 <= sat_add_9(
                            idelay_align,
                            scale_span_16(idelay_span_1000, numerator));
                        wait_count <= 7'd0;
                        state      <= ST_SET_VALUE;
                    end else begin
                        wait_count <= wait_count + 7'd1;
                    end
                end

                ST_SET_VALUE: begin
                    // Present the next values for one full cfg_clk cycle
                    // before asserting LOAD.
                    cnt_in_0 <= step_by_8(cur_0, target_0);
                    cnt_in_1 <= step_by_8(cur_1, target_1);
                    cnt_in_2 <= step_by_8(cur_2, target_2);
                    cnt_in_3 <= step_by_8(cur_3, target_3);
                    state    <= ST_LOAD;
                end

                ST_LOAD: begin
                    load_all <= 1'b1;
                    cur_0    <= cnt_in_0;
                    cur_1    <= cnt_in_1;
                    cur_2    <= cnt_in_2;
                    cur_3    <= cnt_in_3;
                    wait_count <= 7'd0;
                    state      <= ST_WAIT_5;
                end

                ST_WAIT_5: begin
                    if (wait_count == 7'd4) begin
                        wait_count <= 7'd0;
                        state      <= ST_CHECK;
                    end else begin
                        wait_count <= wait_count + 7'd1;
                    end
                end

                ST_CHECK: begin
                    if (targets_reached) begin
                        wait_count <= 7'd0;
                        state      <= ST_WAIT_10;
                    end else begin
                        state <= ST_SET_VALUE;
                    end
                end

                ST_WAIT_10: begin
                    if (wait_count == 7'd9) begin
                        en_vtc      <= 1'b1;
                        sel_active  <= sel_work;
                        delay_ready <= 1'b1;
                        state       <= ST_READY;
                    end else begin
                        wait_count <= wait_count + 7'd1;
                    end
                end

                ST_READY: begin
                    if (sel_sync != sel_active) begin
                        sel_work    <= sel_sync;
                        numerator   <= sel_numerator(sel_sync);
                        en_vtc      <= 1'b0;
                        delay_ready <= 1'b0;
                        wait_count  <= 7'd0;
                        state       <= ST_QUIESCE;
                    end
                end

                ST_ERROR: begin
                    delay_ready <= 1'b0;
                end

                default: state <= ST_ERROR;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // One IDELAYCTRL for the nibble containing this cascade
    //--------------------------------------------------------------------------

    IDELAYCTRL #(
        .SIM_DEVICE("ULTRASCALE")
    ) u_idelayctrl (
        .RDY    (idelayctrl_rdy_raw),
        .REFCLK (refclk_300),
        .RST    (idelayctrl_rst)
    );

    //--------------------------------------------------------------------------
    // Four-element dedicated cascade
    //
    // Forward path:
    //   u_dly0.CASC_OUT -> u_dly1.CASC_IN
    //   u_dly1.CASC_OUT -> u_dly2.CASC_IN
    //   u_dly2.CASC_OUT -> u_dly3.CASC_IN
    //
    // Return path:
    //   u_dly3.DATAOUT -> u_dly2.CASC_RETURN
    //   u_dly2.DATAOUT -> u_dly1.CASC_RETURN
    //   u_dly1.DATAOUT -> u_dly0.CASC_RETURN
    //
    // The final output is u_dly0.DATAOUT.
    //--------------------------------------------------------------------------

    wire casc_0_to_1;
    wire casc_1_to_2;
    wire casc_2_to_3;
    wire return_1_to_0;
    wire return_2_to_1;
    wire return_3_to_2;
    wire unused_casc_out_3;

    // Stage 0: output-pin ODELAY, cascade master, initial calibration point 0 ps.
    ODELAYE3 #(
        .CASCADE          ("MASTER"),
        .DELAY_FORMAT     ("TIME"),
        .DELAY_TYPE       ("VAR_LOAD"),
        .DELAY_VALUE      (0),
        .IS_CLK_INVERTED  (1'b0),
        .IS_RST_INVERTED  (1'b0),
        .REFCLK_FREQUENCY (300.0),
        .SIM_DEVICE       ("ULTRASCALE"),
        .UPDATE_MODE      ("ASYNC")
    ) u_dly0_odelay_master (
        .CASC_OUT     (casc_0_to_1),
        .CNTVALUEOUT  (cnt_out_0),
        .DATAOUT      (data_out),
        .CASC_IN      (1'b0),
        .CASC_RETURN  (return_1_to_0),
        .CE           (1'b0),
        .CLK          (cfg_clk),
        .CNTVALUEIN   (cnt_in_0),
        .EN_VTC       (en_vtc),
        .INC          (1'b0),
        .LOAD         (load_all),
        .ODATAIN      (data_in),
        .RST          (delay_rst)
    );

    // Stage 1: first slave, initial calibration point 0 ps.
    IDELAYE3 #(
        .CASCADE          ("SLAVE_MIDDLE"),
        .DELAY_FORMAT     ("TIME"),
        .DELAY_SRC        ("DATAIN"),
        .DELAY_TYPE       ("VAR_LOAD"),
        .DELAY_VALUE      (0),
        .IS_CLK_INVERTED  (1'b0),
        .IS_RST_INVERTED  (1'b0),
        .REFCLK_FREQUENCY (300.0),
        .SIM_DEVICE       ("ULTRASCALE"),
        .UPDATE_MODE      ("ASYNC")
    ) u_dly1_idelay_middle (
        .CASC_OUT     (casc_1_to_2),
        .CNTVALUEOUT  (cnt_out_1),
        .DATAOUT      (return_1_to_0),
        .CASC_IN      (casc_0_to_1),
        .CASC_RETURN  (return_2_to_1),
        .CE           (1'b0),
        .CLK          (cfg_clk),
        .CNTVALUEIN   (cnt_in_1),
        .DATAIN       (1'b0),
        .EN_VTC       (en_vtc),
        .IDATAIN      (1'b0),
        .INC          (1'b0),
        .LOAD         (load_all),
        .RST          (delay_rst)
    );

    // Stage 2: second slave, initial calibration point 1000 ps.
    ODELAYE3 #(
        .CASCADE          ("SLAVE_MIDDLE"),
        .DELAY_FORMAT     ("TIME"),
        .DELAY_TYPE       ("VAR_LOAD"),
        .DELAY_VALUE      (1000),
        .IS_CLK_INVERTED  (1'b0),
        .IS_RST_INVERTED  (1'b0),
        .REFCLK_FREQUENCY (300.0),
        .SIM_DEVICE       ("ULTRASCALE"),
        .UPDATE_MODE      ("ASYNC")
    ) u_dly2_odelay_middle (
        .CASC_OUT     (casc_2_to_3),
        .CNTVALUEOUT  (cnt_out_2),
        .DATAOUT      (return_2_to_1),
        .CASC_IN      (casc_1_to_2),
        .CASC_RETURN  (return_3_to_2),
        .CE           (1'b0),
        .CLK          (cfg_clk),
        .CNTVALUEIN   (cnt_in_2),
        .EN_VTC       (en_vtc),
        .INC          (1'b0),
        .LOAD         (load_all),
        .ODATAIN      (1'b0),
        .RST          (delay_rst)
    );

    // Stage 3: final slave, initial calibration point 1000 ps.
    IDELAYE3 #(
        .CASCADE          ("SLAVE_END"),
        .DELAY_FORMAT     ("TIME"),
        .DELAY_SRC        ("DATAIN"),
        .DELAY_TYPE       ("VAR_LOAD"),
        .DELAY_VALUE      (1000),
        .IS_CLK_INVERTED  (1'b0),
        .IS_RST_INVERTED  (1'b0),
        .REFCLK_FREQUENCY (300.0),
        .SIM_DEVICE       ("ULTRASCALE"),
        .UPDATE_MODE      ("ASYNC")
    ) u_dly3_idelay_end (
        .CASC_OUT     (unused_casc_out_3),
        .CNTVALUEOUT  (cnt_out_3),
        .DATAOUT      (return_3_to_2),
        .CASC_IN      (casc_2_to_3),
        .CASC_RETURN  (1'b0),
        .CE           (1'b0),
        .CLK          (cfg_clk),
        .CNTVALUEIN   (cnt_in_3),
        .DATAIN       (1'b0),
        .EN_VTC       (en_vtc),
        .IDATAIN      (1'b0),
        .INC          (1'b0),
        .LOAD         (load_all),
        .RST          (delay_rst)
    );

endmodule
