`timescale 1ns/1ps

module tb_ku115_delay_chain;
    reg        clk80_in;
    reg        refclk300_in;
    reg        rst;
    reg  [1:0] sel;

    wire       ddr_clk_p;
    wire       ddr_clk_n;
    wire       delay_ready;
    wire       update_busy;
    wire       idelayctrl_ready;
    wire [1:0] sel_active;
    wire       cal_error;

    realtime last_clk80_rise;

    ku115_delay_chain_top dut (
        .clk80_in          (clk80_in),
        .refclk300_in      (refclk300_in),
        .rst               (rst),
        .sel               (sel),
        .ddr_clk_p         (ddr_clk_p),
        .ddr_clk_n         (ddr_clk_n),
        .delay_ready       (delay_ready),
        .update_busy       (update_busy),
        .idelayctrl_ready  (idelayctrl_ready),
        .sel_active        (sel_active),
        .cal_error         (cal_error)
    );

    initial begin
        clk80_in = 1'b0;
        forever #6.250 clk80_in = ~clk80_in;
    end

    initial begin
        refclk300_in = 1'b0;
        forever #1.667 refclk300_in = ~refclk300_in;
    end

    always @(posedge clk80_in)
        last_clk80_rise = $realtime;

    always @* begin
        if (ddr_clk_n !== ~ddr_clk_p)
            $fatal(1, "Differential outputs are not complementary");
        if (update_busy !== ~delay_ready)
            $fatal(1, "update_busy must be the inverse of delay_ready");
    end

    task automatic wait_initial_ready;
        begin
            fork : initial_ready_or_timeout
                begin
                    @(posedge delay_ready);
                end
                begin
                    #20000;
                    $fatal(1, "Timeout waiting for initial delay calibration");
                end
            join_any
            disable initial_ready_or_timeout;

            if (!idelayctrl_ready)
                $fatal(1, "delay_ready asserted before IDELAYCTRL.RDY");
            if (cal_error)
                $fatal(1, "Calibration entered ST_ERROR");
            if (sel_active !== 2'b00)
                $fatal(1, "Initial sel_active is %b, expected 00", sel_active);
        end
    endtask

    task automatic check_forwarded_clock;
        input [1:0] expected_sel;
        input realtime expected_delay_ns;
        realtime edge_1;
        realtime edge_2;
        realtime measured_delay;
        realtime measured_period;
        realtime delta;
        begin
            // Flush any edge launched while the delay was being updated.
            repeat (2) @(posedge ddr_clk_p);

            @(posedge ddr_clk_p);
            edge_1         = $realtime;
            measured_delay = edge_1 - last_clk80_rise;

            @(posedge ddr_clk_p);
            edge_2          = $realtime;
            measured_period = edge_2 - edge_1;

            if (sel_active !== expected_sel)
                $fatal(1, "sel_active=%b, expected %b",
                       sel_active, expected_sel);
            if (cal_error)
                $fatal(1, "cal_error asserted for SEL=%b", expected_sel);

            delta = measured_period - 12.500;
            if ((delta > 0.003) || (delta < -0.003))
                $fatal(1, "Forwarded-clock period %.3f ns, expected 12.500 ns",
                       measured_period);

`ifdef OPEN_SOURCE_SIM
            // The lightweight CI model uses a deterministic 5 ps/tap. XSim
            // and post-route SDF are checked separately because their fixed
            // insertion and routing delays are device/placement dependent.
            delta = measured_delay - expected_delay_ns;
            if ((delta > 0.003) || (delta < -0.003))
                $fatal(1,
                       "SEL=%b delay %.3f ns, expected behavioral %.3f ns",
                       expected_sel, measured_delay, expected_delay_ns);
`endif
        end
    endtask

    task automatic select_and_wait;
        input [1:0] requested_sel;
        realtime low_started;
        realtime low_finished;
        realtime low_time;
        begin
            @(negedge clk80_in);
            sel = requested_sel;

            fork : ready_low_or_timeout
                begin
                    @(negedge delay_ready);
                    low_started = $realtime;
                end
                begin
                    #1000;
                    $fatal(1, "delay_ready did not fall for SEL=%b",
                           requested_sel);
                end
            join_any
            disable ready_low_or_timeout;

            fork : ready_high_or_timeout
                begin
                    @(posedge delay_ready);
                    low_finished = $realtime;
                end
                begin
                    #4000;
                    $fatal(1, "delay_ready did not recover for SEL=%b",
                           requested_sel);
                end
            join_any
            disable ready_high_or_timeout;

            low_time = low_finished - low_started;
            if (low_time > 3800.0)
                $fatal(1,
                       "delay_ready low for %.3f ns; exceeds 3.8 us budget",
                       low_time);
            if (sel_active !== requested_sel)
                $fatal(1, "SEL=%b completed with sel_active=%b",
                       requested_sel, sel_active);
        end
    endtask

    initial begin
        rst = 1'b1;
        sel = 2'b00;
        last_clk80_rise = 0.0;

        repeat (8) @(posedge clk80_in);
        @(negedge clk80_in);
        rst = 1'b0;

        wait_initial_ready();
        check_forwarded_clock(2'b00, 1.260);

        select_and_wait(2'b01);
        check_forwarded_clock(2'b01, 2.500);

        select_and_wait(2'b10);
        check_forwarded_clock(2'b10, 3.760);

        select_and_wait(2'b11);
        check_forwarded_clock(2'b11, 4.000);

        select_and_wait(2'b00);
        check_forwarded_clock(2'b00, 1.260);

        $display("TEST PASSED: reset, calibration, all SEL transitions,");
        $display("delay_ready timing, forwarded-clock period and delay.");
        $finish;
    end
endmodule
