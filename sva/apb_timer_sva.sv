`timescale 1ns/1ps
// Concurrent assertions for apb_timer, attached with `bind`.
// The protocol group checks the APB master driving the bus (so a broken
// testbench cannot produce a false pass); the other groups check the slave
// response and the timer behaviour.
module apb_timer_sva (
    input logic        pclk,
    input logic        presetn,
    input logic        psel,
    input logic        penable,
    input logic        pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata,
    input logic [31:0] prdata,
    input logic        pready,
    input logic        pslverr,
    input logic        irq,
    input logic        ctrl_en,
    input logic        ctrl_mode,
    input logic        ctrl_irq_en,
    input logic        expired_q,
    input logic [31:0] count_q,
    input logic        expire,
    input logic        wr_control,
    input logic        wr_status
);
    // ---------------- APB protocol ----------------
    a_penable_needs_psel: assert property (@(posedge pclk) disable iff (!presetn)
        penable |-> psel)
        else $error("PENABLE without PSEL");

    a_setup_then_access: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && !penable) |=> (psel && penable))
        else $error("SETUP phase not followed by ACCESS");

    a_access_after_setup: assert property (@(posedge pclk) disable iff (!presetn)
        $rose(penable) |-> $past(psel && !penable))
        else $error("ACCESS phase without SETUP");

    a_stable_while_waiting: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && penable && !pready) |=>
            (psel && penable && $stable(paddr) && $stable(pwrite) && $stable(pwdata)))
        else $error("bus changed during a wait state");

    // ---------------- slave response ----------------
    a_slverr_on_completion: assert property (@(posedge pclk) disable iff (!presetn)
        pslverr |-> (psel && penable && pready))
        else $error("PSLVERR outside the completing ACCESS cycle");

    a_prdata_quiet: assert property (@(posedge pclk) disable iff (!presetn)
        !(psel && penable && !pwrite) |-> prdata == '0)
        else $error("PRDATA driven outside a read ACCESS");

    // ---------------- timer ----------------
    a_irq: assert property (@(posedge pclk) disable iff (!presetn)
        irq == (expired_q && ctrl_irq_en))
        else $error("irq != EXPIRED & IRQ_EN");

    a_expire_sets_status: assert property (@(posedge pclk) disable iff (!presetn)
        expire |=> expired_q)
        else $error("expiry did not set EXPIRED");

    a_status_sticky: assert property (@(posedge pclk) disable iff (!presetn)
        (expired_q && !(wr_status && pwdata[0])) |=> expired_q)
        else $error("EXPIRED cleared without a write-1-to-clear");

    a_count_steps: assert property (@(posedge pclk) disable iff (!presetn)
        (ctrl_en && !expire) |=> count_q == $past(count_q) + 1)
        else $error("COUNT did not advance");

    a_count_holds: assert property (@(posedge pclk) disable iff (!presetn)
        (!ctrl_en && !(wr_control && pwdata[0])) |=> count_q == $past(count_q))
        else $error("COUNT changed while stopped");

    a_periodic_reload: assert property (@(posedge pclk) disable iff (!presetn)
        (expire && ctrl_mode) |=> count_q == '0)
        else $error("periodic mode did not reload COUNT");

    a_oneshot_stops: assert property (@(posedge pclk) disable iff (!presetn)
        (expire && !ctrl_mode && !wr_control) |=> (!ctrl_en && count_q == $past(count_q)))
        else $error("one-shot mode did not stop");
endmodule

bind apb_timer apb_timer_sva u_sva (.*);
