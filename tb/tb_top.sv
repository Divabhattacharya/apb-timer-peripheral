`timescale 1ns/1ps
// Runs the timer test on two configurations in parallel:
// zero-wait-state APB and two wait states per access.
module tb_top;
    logic done_a, done_b;
    int   err_a, err_b;

    timer_test #(.WAIT_STATES(0), .SEED(32'h0000_A5B1)) cfg_a (.done(done_a), .errors(err_a));
    timer_test #(.WAIT_STATES(2), .SEED(32'h0BAD_F00D)) cfg_b (.done(done_b), .errors(err_b));

    initial begin
`ifdef DUMP
        $dumpfile("apb_timer.vcd");
        $dumpvars(0, tb_top);
`endif
        wait (done_a && done_b);
        $display("--------------------------------------------------");
        if (err_a + err_b == 0) $display("ALL TESTS PASSED");
        else                    $display("TESTS FAILED (%0d errors)", err_a + err_b);
        $finish;
    end

    initial begin
        #10ms;
        $display("TIMEOUT");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
