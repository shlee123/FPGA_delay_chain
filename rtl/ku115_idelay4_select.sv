`timescale 1ns/1ps

//------------------------------------------------------------------------------
// Four-element programmable input-delay cascade for Kintex UltraScale.
//
// This is the input-side counterpart of ku115_odelay4_select.  An input-port
// signal is presented to the IDELAYE3 master through an IBUF and returns to
// fabric through the dedicated component-mode cascade:
//
//   IDELAYE3 (MASTER)
//     -> ODELAYE3 (SLAVE_MIDDLE)
//     -> IDELAYE3 (SLAVE_MIDDLE)
//     -> ODELAYE3 (SLAVE_END)
//
// SEL mapping (programmed delay; fixed IOB/cascade insertion delay is extra):
//   2'b00 : 4 x  312.5 ps = 1.25 ns
//   2'b01 : 4 x  625.0 ps = 2.50 ns
//   2'b10 : 4 x  937.5 ps = 3.75 ns
//   2'b11 : 4 x 1250.0 ps = 5.00 ns
//
// The physical cascade topology is fixed.  SEL changes the VAR_LOAD tap
// values of all four elements; it never changes the cascade depth.
//------------------------------------------------------------------------------

module ku115_idelay4_select (
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

    function automatic [8:0] step_by_8;
        input [8:0] current;
        input [8:0] target;
        begin
            if (current < target)
                step_by_8 = (({1'b0, current} + 10'd8) < {1'b0, target})
                          ? current + 9'd8 : target;
            else if (current > target)
                step_by_8 = ({1'b0, current} > ({1'b0, target} + 10'd8))
                          ? current - 9'd8 : target;
            else
                step_by_8 = current;
        end
    endfunction

    // NUM=1/2/3/4 scales the calibrated 1250-ps span to the selected delay.
    function automatic [8:0] scale_span_4;
        input [8:0] span;
        input [2:0] num;
        reg   [11:0] product;
        begin
            product      = (span * num) + 12'd2;
            scale_span_4 = product >> 2;
        end
    endfunction

    function automatic [2:0] sel_numerator;
        input [1:0] sel_i;
        begin
            case (sel_i)
                2'b00: sel_numerator = 3'd1;
                2'b01: sel_numerator = 3'd2;
                2'b10: sel_numerator = 3'd3;
                default: sel_numerator = 3'd4;
            endcase
        end
    endfunction

    function automatic [8:0] sat_add_9;
        input [8:0] a;
        input [8:0] b;
        reg   [9:0] sum;
        begin
            sum       = {1'b0, a} + {1'b0, b};
            sat_add_9 = sum[9] ? 9'h1ff : sum[8:0];
        end
    endfunction

    function automatic add_overflows_9;
        input [8:0] a;
        input [8:0] b;
        reg   [9:0] sum;
        begin
            sum             = {1'b0, a} + {1'b0, b};
            add_overflows_9 = sum[9];
        end
    endfunction

    // Synchronize the multibit request and IDELAYCTRL status into cfg_clk.
    // A source asynchronous to cfg_clk must keep SEL stable until ready=1.
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
    reg [2:0] numerator;

    reg [8:0] cnt_in_0, cnt_in_1, cnt_in_2, cnt_in_3;
    wire [8:0] cnt_out_0, cnt_out_1, cnt_out_2, cnt_out_3;
    reg [8:0] cur_0, cur_1, cur_2, cur_3;
    reg [8:0] target_0, target_1, target_2, target_3;

    // In the input topology, stages 0/2 are IDELAYE3 and stages 1/3 are
    // ODELAYE3.  IDELAY's zero point contains Align_Delay; calibrating its
    // 1250-ps span against stage 0 removes it before later VAR_LOAD writes.
    reg [8:0] idelay_align;
    reg [8:0] odelay_zero;
    reg [8:0] idelay_span_1250;
    reg [8:0] odelay_span_1250;

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
            numerator           <= 3'd1;
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
            idelay_align        <= 9'd0;
            odelay_zero         <= 9'd0;
            idelay_span_1250    <= 9'd0;
            odelay_span_1250    <= 9'd0;
        end else begin
            load_all <= 1'b0;

            // Loss of calibration invalidates TIME-mode counter values.
            if (!rdy_sync && (state >= ST_CAPTURE) && (state != ST_ERROR)) begin
                delay_rst      <= 1'b1;
                idelayctrl_rst <= 1'b1;
                en_vtc         <= 1'b1;
                delay_ready    <= 1'b0;
                state          <= ST_RESET;
            end else case (state)
                ST_RESET: begin
                    // Release delay lines before their IDELAYCTRL.
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
                    end else
                        wait_count <= wait_count + 7'd1;
                end
                ST_WAIT_RDY: begin
                    if (rdy_sync) begin
                        wait_count <= 7'd0;
                        state      <= ST_WAIT_64;
                    end
                end
                ST_WAIT_64: begin
                    if (!rdy_sync)
                        state <= ST_WAIT_RDY;
                    else if (wait_count == 7'd63)
                        state <= ST_CAPTURE;
                    else
                        wait_count <= wait_count + 7'd1;
                end
                ST_CAPTURE: begin
                    // Start with 0/0/1250/1250 ps and determine the two
                    // calibrated 1250-ps counter spans.
                    if ((cnt_out_2 <= cnt_out_0) ||
                        (cnt_out_3 <= cnt_out_1)) begin
                        cal_error   <= 1'b1;
                        delay_ready <= 1'b0;
                        state       <= ST_ERROR;
                    end else begin
                        idelay_align     <= cnt_out_0;
                        odelay_zero      <= cnt_out_1;
                        idelay_span_1250 <= cnt_out_2 - cnt_out_0;
                        odelay_span_1250 <= cnt_out_3 - cnt_out_1;
                        cur_0            <= cnt_out_0;
                        cur_1            <= cnt_out_1;
                        cur_2            <= cnt_out_2;
                        cur_3            <= cnt_out_3;
                        sel_work         <= sel_sync;
                        numerator        <= sel_numerator(sel_sync);
                        en_vtc           <= 1'b0;
                        wait_count       <= 7'd0;
                        state            <= ST_QUIESCE;
                    end
                end
                ST_QUIESCE: begin
                    // TIME-mode changes require EN_VTC=0 for >=10 cycles.
                    delay_ready <= 1'b0;
                    if (wait_count == 7'd9) begin
                        if (add_overflows_9(
                                idelay_align,
                                scale_span_4(idelay_span_1250, numerator)) ||
                            add_overflows_9(
                                odelay_zero,
                                scale_span_4(odelay_span_1250, numerator))) begin
                            cal_error <= 1'b1;
                            state     <= ST_ERROR;
                        end else begin
                            target_0 <= sat_add_9(idelay_align,
                                scale_span_4(idelay_span_1250, numerator));
                            target_1 <= sat_add_9(odelay_zero,
                                scale_span_4(odelay_span_1250, numerator));
                            target_2 <= sat_add_9(idelay_align,
                                scale_span_4(idelay_span_1250, numerator));
                            target_3 <= sat_add_9(odelay_zero,
                                scale_span_4(odelay_span_1250, numerator));
                            wait_count <= 7'd0;
                            state      <= ST_SET_VALUE;
                        end
                    end else
                        wait_count <= wait_count + 7'd1;
                end
                ST_SET_VALUE: begin
                    cnt_in_0 <= step_by_8(cur_0, target_0);
                    cnt_in_1 <= step_by_8(cur_1, target_1);
                    cnt_in_2 <= step_by_8(cur_2, target_2);
                    cnt_in_3 <= step_by_8(cur_3, target_3);
                    state    <= ST_LOAD;
                end
                ST_LOAD: begin
                    load_all   <= 1'b1;
                    cur_0      <= cnt_in_0;
                    cur_1      <= cnt_in_1;
                    cur_2      <= cnt_in_2;
                    cur_3      <= cnt_in_3;
                    wait_count <= 7'd0;
                    state      <= ST_WAIT_5;
                end
                ST_WAIT_5: begin
                    if (wait_count == 7'd4) begin
                        wait_count <= 7'd0;
                        state      <= ST_CHECK;
                    end else
                        wait_count <= wait_count + 7'd1;
                end
                ST_CHECK: begin
                    if (targets_reached) begin
                        wait_count <= 7'd0;
                        state      <= ST_WAIT_10;
                    end else
                        state <= ST_SET_VALUE;
                end
                ST_WAIT_10: begin
                    if (wait_count == 7'd9) begin
                        en_vtc      <= 1'b1;
                        sel_active  <= sel_work;
                        delay_ready <= 1'b1;
                        state       <= ST_READY;
                    end else
                        wait_count <= wait_count + 7'd1;
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
                ST_ERROR: delay_ready <= 1'b0;
                default:  state <= ST_ERROR;
            endcase
        end
    end

    // One IDELAYCTRL is required for the I/O bank containing this cascade.
    IDELAYCTRL #(
        .SIM_DEVICE("ULTRASCALE")
    ) u_idelayctrl (
        .RDY    (idelayctrl_rdy_raw),
        .REFCLK (refclk_300),
        .RST    (idelayctrl_rst)
    );

    // Dedicated component-mode cascade.  CASC_OUT carries the signal forward
    // to the SLAVE_END; DATAOUT returns it through every programmed element.
    wire casc_0_to_1, casc_1_to_2, casc_2_to_3;
    wire return_1_to_0, return_2_to_1, return_3_to_2;
    wire unused_casc_out_3;

    IDELAYE3 #(
        .CASCADE("MASTER"), .DELAY_FORMAT("TIME"),
        .DELAY_SRC("IDATAIN"), .DELAY_TYPE("VAR_LOAD"),
        .DELAY_VALUE(0), .IS_CLK_INVERTED(1'b0),
        .IS_RST_INVERTED(1'b0), .REFCLK_FREQUENCY(300.0),
        .SIM_DEVICE("ULTRASCALE"), .UPDATE_MODE("ASYNC")
    ) u_dly0_idelay_master (
        .CASC_OUT(casc_0_to_1), .CNTVALUEOUT(cnt_out_0), .DATAOUT(data_out),
        .CASC_IN(1'b0), .CASC_RETURN(return_1_to_0), .CE(1'b0),
        .CLK(cfg_clk), .CNTVALUEIN(cnt_in_0), .DATAIN(1'b0),
        .EN_VTC(en_vtc), .IDATAIN(data_in), .INC(1'b0), .LOAD(load_all),
        .RST(delay_rst)
    );

    ODELAYE3 #(
        .CASCADE("SLAVE_MIDDLE"), .DELAY_FORMAT("TIME"),
        .DELAY_TYPE("VAR_LOAD"), .DELAY_VALUE(0),
        .IS_CLK_INVERTED(1'b0), .IS_RST_INVERTED(1'b0),
        .REFCLK_FREQUENCY(300.0), .SIM_DEVICE("ULTRASCALE"),
        .UPDATE_MODE("ASYNC")
    ) u_dly1_odelay_middle (
        .CASC_OUT(casc_1_to_2), .CNTVALUEOUT(cnt_out_1),
        .DATAOUT(return_1_to_0), .CASC_IN(casc_0_to_1),
        .CASC_RETURN(return_2_to_1), .CE(1'b0), .CLK(cfg_clk),
        .CNTVALUEIN(cnt_in_1), .EN_VTC(en_vtc), .INC(1'b0),
        .LOAD(load_all), .ODATAIN(1'b0), .RST(delay_rst)
    );

    IDELAYE3 #(
        .CASCADE("SLAVE_MIDDLE"), .DELAY_FORMAT("TIME"),
        .DELAY_SRC("DATAIN"), .DELAY_TYPE("VAR_LOAD"),
        .DELAY_VALUE(1250), .IS_CLK_INVERTED(1'b0),
        .IS_RST_INVERTED(1'b0), .REFCLK_FREQUENCY(300.0),
        .SIM_DEVICE("ULTRASCALE"), .UPDATE_MODE("ASYNC")
    ) u_dly2_idelay_middle (
        .CASC_OUT(casc_2_to_3), .CNTVALUEOUT(cnt_out_2),
        .DATAOUT(return_2_to_1), .CASC_IN(casc_1_to_2),
        .CASC_RETURN(return_3_to_2), .CE(1'b0), .CLK(cfg_clk),
        .CNTVALUEIN(cnt_in_2), .DATAIN(1'b0), .EN_VTC(en_vtc),
        .IDATAIN(1'b0), .INC(1'b0), .LOAD(load_all), .RST(delay_rst)
    );

    ODELAYE3 #(
        .CASCADE("SLAVE_END"), .DELAY_FORMAT("TIME"),
        .DELAY_TYPE("VAR_LOAD"), .DELAY_VALUE(1250),
        .IS_CLK_INVERTED(1'b0), .IS_RST_INVERTED(1'b0),
        .REFCLK_FREQUENCY(300.0), .SIM_DEVICE("ULTRASCALE"),
        .UPDATE_MODE("ASYNC")
    ) u_dly3_odelay_end (
        .CASC_OUT(unused_casc_out_3), .CNTVALUEOUT(cnt_out_3),
        .DATAOUT(return_3_to_2), .CASC_IN(casc_2_to_3),
        .CASC_RETURN(1'b0), .CE(1'b0), .CLK(cfg_clk),
        .CNTVALUEIN(cnt_in_3), .EN_VTC(en_vtc), .INC(1'b0),
        .LOAD(load_all), .ODATAIN(1'b0), .RST(delay_rst)
    );

endmodule
