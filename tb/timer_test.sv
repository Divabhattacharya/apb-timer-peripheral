`timescale 1ns/1ps
// Self-checking test of one apb_timer configuration.
//
//  * APB master tasks (reg_write / reg_read / apb_xfer): SETUP for one cycle,
//    then ACCESS until PREADY. Every response (PSLVERR, PRDATA) is checked.
//  * Reference model: a cycle-accurate model of the register map and timer
//    that follows the APB bus. Every cycle the DUT's COUNT, LIMIT, CONTROL,
//    STATUS and irq are compared with it.
//  * Directed tests for each feature with explicit expected values (expiry
//    timing, auto-reload period, sticky/W1C status, ...), then randomized
//    register traffic with asynchronous resets. Coverage goals are checked at
//    the end.
module timer_test #(
    parameter int          WAIT_STATES = 0,
    parameter logic [31:0] SEED        = 32'h1
) (
    output logic done,
    output int   errors
);
    localparam logic [11:0] CONTROL = 12'h000;
    localparam logic [11:0] LIMIT   = 12'h004;
    localparam logic [11:0] COUNT   = 12'h008;
    localparam logic [11:0] STATUS  = 12'h00C;

    localparam logic [31:0] EN       = 32'h1;
    localparam logic [31:0] PERIODIC = 32'h2;
    localparam logic [31:0] IRQ_EN   = 32'h4;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    logic        pclk    = 1'b0;
    logic        presetn = 1'b0;
    logic        psel    = 1'b0;
    logic        penable = 1'b0;
    logic        pwrite  = 1'b0;
    logic [11:0] paddr   = '0;
    logic [31:0] pwdata  = '0;
    logic [31:0] prdata;
    logic        pready, pslverr, irq;

    apb_timer #(.WAIT_STATES(WAIT_STATES)) dut (.*);

    always #5 pclk = ~pclk;

    int cyc = 0;
    always @(posedge pclk) cyc++;

    // ------------------------------------------------------------------
    // Deterministic PRNG (xorshift32)
    // ------------------------------------------------------------------
    logic [31:0] rng = SEED;

    function automatic logic [31:0] rand32();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    function automatic bit chance(int percent);
        return (rand32() % 100) < percent;
    endfunction

    // ------------------------------------------------------------------
    // Checker
    // ------------------------------------------------------------------
    int n_checks = 0;

    task automatic check(bit ok, string what);
        n_checks++;
        if (!ok) begin
            errors++;
            if (errors <= 10)
                $display("[WAIT_STATES=%0d] %0t FAIL %s", WAIT_STATES, $time, what);
        end
    endtask

    // ------------------------------------------------------------------
    // Reference model, driven by monitoring the APB bus
    // ------------------------------------------------------------------
    logic        m_en, m_mode, m_irq_en, m_expired;
    logic [31:0] m_limit, m_count;

    function automatic bit mapped(logic [11:0] a);
        return a inside {CONTROL, LIMIT, COUNT, STATUS};
    endfunction

    function automatic bit is_error(bit write, logic [11:0] a);
        return !mapped(a) || (write && a == COUNT);
    endfunction

    function automatic logic [31:0] model_read(logic [11:0] a);
        case (a)
            CONTROL: return {29'd0, m_irq_en, m_mode, m_en};
            LIMIT:   return m_limit;
            COUNT:   return m_count;
            STATUS:  return {31'd0, m_expired};
            default: return '0;
        endcase
    endfunction

    wire m_expire  = m_en && (m_count >= m_limit);
    wire m_irq     = m_expired && m_irq_en;
    wire m_wr      = psel && penable && pready && pwrite && !is_error(1'b1, paddr);
    wire m_wr_ctrl = m_wr && paddr == CONTROL;
    wire m_wr_lim  = m_wr && paddr == LIMIT;
    wire m_wr_stat = m_wr && paddr == STATUS;

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            m_en      <= 1'b0;
            m_mode    <= 1'b0;
            m_irq_en  <= 1'b0;
            m_expired <= 1'b0;
            m_limit   <= '0;
            m_count   <= '0;
        end else begin
            if (m_wr_ctrl && pwdata[0] && !m_en) m_count <= '0;
            else if (m_expire)                   m_count <= m_mode ? '0 : m_count;
            else if (m_en)                       m_count <= m_count + 1;

            if (m_wr_ctrl)                       {m_irq_en, m_mode, m_en} <= pwdata[2:0];
            else if (m_expire && !m_mode)        m_en <= 1'b0;

            if (m_wr_lim)                        m_limit <= pwdata;

            if (m_expire)                        m_expired <= 1'b1;
            else if (m_wr_stat && pwdata[0])     m_expired <= 1'b0;
        end
    end

    // compare the whole DUT state with the model every cycle
    always @(negedge pclk) begin
        if (presetn) begin
            check(irq === m_irq,                    "irq");
            check(dut.count_q === m_count,          "COUNT");
            check(dut.limit_q === m_limit,          "LIMIT");
            check({dut.ctrl_irq_en, dut.ctrl_mode, dut.ctrl_en} === {m_irq_en, m_mode, m_en},
                                                    "CONTROL");
            check(dut.expired_q === m_expired,      "STATUS.EXPIRED");
        end
    end

    // coverage (pre-edge values at each rising edge)
    int n_xfers, n_slverr, n_wait_cycles, n_exp_oneshot, n_exp_periodic, n_restarts;
    int n_w1c, n_set_wins, n_late_limit, n_irq_cycles, n_resets;

    always @(posedge pclk) begin
        if (presetn) begin
            n_exp_oneshot  += int'(m_expire && !m_mode);
            n_exp_periodic += int'(m_expire && m_mode);
            n_restarts     += int'(m_wr_ctrl && pwdata[0] && !m_en);
            n_w1c          += int'(m_wr_stat && pwdata[0] && m_expired && !m_expire);
            n_set_wins     += int'(m_wr_stat && pwdata[0] && m_expire);
            n_late_limit   += int'(m_en && m_count > m_limit);
            n_irq_cycles   += int'(m_irq);
            n_wait_cycles  += int'(psel && penable && !pready);
        end
    end

    // cycle numbers of every rising edge of irq
    int   irq_rises[$];
    logic irq_prev = 1'b0;
    always @(negedge pclk) begin
        if (irq && !irq_prev) irq_rises.push_back(cyc);
        irq_prev = irq;
    end

    // ------------------------------------------------------------------
    // APB master
    // ------------------------------------------------------------------
    // One transfer: SETUP for one cycle, then ACCESS until PREADY.
    // Called just after a rising edge, returns just after the completing edge.
    task automatic apb_xfer(bit write, logic [11:0] addr, logic [31:0] wdata,
                            output logic [31:0] rdata, output logic err);
        logic        ready;
        logic [31:0] expected;
        int          waits = 0;

        psel    = 1'b1;                                  // SETUP
        penable = 1'b0;
        pwrite  = write;
        paddr   = addr;
        pwdata  = write ? wdata : '0;
        @(posedge pclk); #1;

        penable = 1'b1;                                  // ACCESS
        do begin
            @(negedge pclk);
            ready    = pready;
            rdata    = prdata;
            err      = pslverr;
            expected = model_read(addr);
            waits   += int'(!ready);
            @(posedge pclk); #1;
        end while (!ready);

        psel    = 1'b0;
        penable = 1'b0;
        n_xfers++;
        n_slverr += int'(err);

        check(waits == WAIT_STATES,
              $sformatf("transfer took %0d wait states, expected %0d", waits, WAIT_STATES));
        check(err === is_error(write, addr),
              $sformatf("PSLVERR for %s of 0x%03h", write ? "write" : "read", addr));
        if (!write)
            check(rdata === (err ? 32'd0 : expected),
                  $sformatf("PRDATA for read of 0x%03h", addr));
    endtask

    task automatic reg_write(logic [11:0] addr, logic [31:0] data);
        logic [31:0] rdata;
        logic        err;
        apb_xfer(1'b1, addr, data, rdata, err);
    endtask

    task automatic reg_read(logic [11:0] addr, output logic [31:0] data);
        logic err;
        apb_xfer(1'b0, addr, '0, data, err);
    endtask

    task automatic idle(int cycles);
        repeat (cycles) begin
            @(posedge pclk); #1;
        end
    endtask

    task automatic wait_irq(int max_cycles, output int cycles);
        cycles = 0;
        while (!irq && cycles < max_cycles) begin
            @(posedge pclk); #1;
            cycles++;
        end
    endtask

    // Asynchronous reset in the middle of a cycle; returns aligned again.
    task automatic async_reset();
        #3 presetn = 1'b0;
        #1;
        check(irq === 1'b0 && dut.count_q === '0 && dut.limit_q === '0 && !dut.expired_q &&
              !dut.ctrl_en && !dut.ctrl_mode && !dut.ctrl_irq_en,
              "asynchronous reset clears every register");
        n_resets++;
        @(posedge pclk);
        #2 presetn = 1'b1;
        @(posedge pclk); #1;
    endtask

    task automatic stop_and_clear();
        reg_write(CONTROL, 32'd0);
        reg_write(STATUS, 32'd1);
    endtask

    // ------------------------------------------------------------------
    // Directed tests
    // ------------------------------------------------------------------
    task automatic test_reset_values();
        logic [11:0] regs[4] = '{CONTROL, LIMIT, COUNT, STATUS};
        logic [31:0] v;
        foreach (regs[i]) begin
            reg_read(regs[i], v);
            check(v === '0, $sformatf("reset value of 0x%03h", regs[i]));
        end
        check(irq === 1'b0, "irq low after reset");
    endtask

    task automatic test_register_access();
        logic [31:0] patterns[4] = '{32'h0000_0000, 32'hFFFF_FFFF, 32'hA5A5_A5A5, 32'h5A5A_5A5A};
        logic [31:0] v;
        foreach (patterns[i]) begin
            reg_write(LIMIT, patterns[i]);
            reg_read(LIMIT, v);
            check(v === patterns[i], "LIMIT readback");
        end
        reg_write(CONTROL, PERIODIC | IRQ_EN);
        reg_read(CONTROL, v);
        check(v === (PERIODIC | IRQ_EN), "CONTROL readback");
        reg_write(CONTROL, 32'hFFFF_FFF8);
        reg_read(CONTROL, v);
        check(v === '0, "CONTROL reserved bits read as 0");
        reg_write(STATUS, 32'd0);
        reg_read(STATUS, v);
        check(v === '0, "STATUS readback");
    endtask

    task automatic test_error_responses();
        logic [11:0] unmapped[6] = '{12'h010, 12'h0FC, 12'h800, 12'hFFC, 12'h001, 12'h006};
        logic [31:0] v;
        logic        err;
        reg_write(LIMIT, 32'd1234);
        apb_xfer(1'b1, COUNT, 32'hDEAD_BEEF, v, err);
        check(err === 1'b1, "write to read-only COUNT returns PSLVERR");
        reg_read(COUNT, v);
        check(v === '0, "COUNT unchanged by the rejected write");
        foreach (unmapped[i]) begin
            apb_xfer(1'b1, unmapped[i], 32'hFFFF_FFFF, v, err);
            check(err === 1'b1, "write to unmapped address returns PSLVERR");
            apb_xfer(1'b0, unmapped[i], '0, v, err);
            check(err === 1'b1 && v === '0, "read of unmapped address returns PSLVERR and 0");
        end
        reg_read(LIMIT, v);
        check(v === 32'd1234, "LIMIT unchanged by rejected writes");
        reg_read(CONTROL, v);
        check(v === '0, "CONTROL unchanged by rejected writes");
    endtask

    task automatic test_one_shot();
        localparam int L = 9;
        logic [31:0] v;
        int          n;
        stop_and_clear();
        reg_write(LIMIT, L);
        reg_write(CONTROL, EN | IRQ_EN);
        wait_irq(10 * L, n);
        check(n == L + 1, $sformatf("one-shot expiry after %0d cycles, expected %0d", n, L + 1));
        reg_read(CONTROL, v);
        check(v === IRQ_EN, "one-shot expiry clears EN");
        reg_read(COUNT, v);
        check(v === L, "one-shot holds COUNT at LIMIT");
        idle(3 * L);
        check(irq === 1'b1, "irq stays high until cleared");
        reg_write(STATUS, 32'd1);
        check(irq === 1'b0, "write-1-to-clear drops irq");
        idle(3 * L);
        check(irq === 1'b0, "one-shot does not fire again");
    endtask

    task automatic test_periodic();
        localparam int L = 6;
        int n, first;
        stop_and_clear();
        reg_write(LIMIT, L);
        reg_write(CONTROL, EN | PERIODIC | IRQ_EN);
        irq_rises.delete();
        wait_irq(10 * L, n);
        check(n == L + 1, $sformatf("first periodic expiry after %0d cycles, expected %0d", n, L + 1));
        repeat (5) begin
            reg_write(STATUS, 32'd1);
            wait_irq(10 * L, n);
        end
        idle(1);                                         // let the edge monitor log the last rise
        check(irq_rises.size() == 6, "six periodic expiries seen");
        first = irq_rises.pop_front();
        foreach (irq_rises[i]) begin
            check(irq_rises[i] - first == L + 1,
                  $sformatf("auto-reload period %0d, expected %0d", irq_rises[i] - first, L + 1));
            first = irq_rises[i];
        end
    endtask

    task automatic test_enable_disable();
        logic [31:0] c1, c2, c3, c4;
        stop_and_clear();
        reg_write(LIMIT, 32'd1000);
        reg_write(CONTROL, EN | PERIODIC);
        idle(20);
        reg_write(CONTROL, PERIODIC);                    // stop
        reg_read(COUNT, c1);
        idle(10);
        reg_read(COUNT, c2);
        check(c1 == c2 && c1 > 20, "COUNT freezes while stopped");
        reg_write(CONTROL, EN | PERIODIC);               // restart
        reg_read(COUNT, c3);
        check(c3 < 8, "re-enabling restarts COUNT from 0");
        idle(5);
        reg_write(CONTROL, EN | PERIODIC | IRQ_EN);      // already running: no restart
        reg_read(COUNT, c4);
        check(c4 > c3 + 5, "rewriting CONTROL while running does not restart");
    endtask

    task automatic test_irq_gating();
        logic [31:0] v;
        stop_and_clear();
        reg_write(LIMIT, 32'd3);
        reg_write(CONTROL, EN | PERIODIC);               // IRQ_EN = 0
        idle(10);
        reg_read(STATUS, v);
        check(v === 32'd1, "EXPIRED is set");
        check(irq === 1'b0, "irq masked while IRQ_EN = 0");
        reg_write(CONTROL, EN | PERIODIC | IRQ_EN);
        check(irq === 1'b1, "irq asserts as soon as IRQ_EN is set");
        reg_write(CONTROL, IRQ_EN);                      // stop, keep IRQ_EN
        reg_write(STATUS, 32'd0);
        reg_read(STATUS, v);
        check(v === 32'd1 && irq === 1'b1, "writing 0 to STATUS does not clear it");
        reg_write(STATUS, 32'd1);
        reg_read(STATUS, v);
        check(v === '0 && irq === 1'b0, "writing 1 to STATUS clears it");
    endtask

    task automatic test_set_wins();
        logic [31:0] v;
        stop_and_clear();
        reg_write(LIMIT, 32'd0);                         // expires every cycle
        reg_write(CONTROL, EN | PERIODIC | IRQ_EN);
        idle(3);
        reg_write(STATUS, 32'd1);
        reg_read(STATUS, v);
        check(v === 32'd1 && irq === 1'b1, "expiry in the same cycle as a clear wins");
        stop_and_clear();
        check(irq === 1'b0, "cleared after stopping");
    endtask

    task automatic test_limit_lowered();
        logic [31:0] v;
        int          n;
        stop_and_clear();
        reg_write(LIMIT, 32'd1000);
        reg_write(CONTROL, EN | PERIODIC | IRQ_EN);
        idle(50);
        reg_write(LIMIT, 32'd10);                        // COUNT is already past 10
        wait_irq(5, n);
        check(n == 1, "lowering LIMIT below COUNT expires on the next cycle");
        reg_read(COUNT, v);
        check(v < 32'd10, "COUNT reloaded after the immediate expiry");
        stop_and_clear();
    endtask

    // randomized register traffic, checked cycle by cycle against the model.
    // Every random value is drawn in its own statement so the stream is
    // reproducible on any simulator.
    task automatic test_random(int transfers);
        logic [11:0] mapped_regs[4] = '{CONTROL, LIMIT, COUNT, STATUS};
        logic [31:0] op, r1, r2, r3, v;
        logic        err;
        repeat (transfers) begin
            op = rand32() % 10;
            r1 = rand32();
            r2 = rand32();
            r3 = rand32();
            case (op)
                0, 1: reg_write(CONTROL, (r1 & 32'h6) | ((r2 % 100) < 75 ? EN : 32'd0));
                2, 3: reg_write(LIMIT, (r2 % 100) < 85 ? r1 % 40 : r1);
                4:    reg_write(STATUS, r1);
                5, 6: reg_read(mapped_regs[r1 % 4], v);
                7:    apb_xfer(r2[31], (r2 % 100) < 30 ? COUNT : 12'(r1 | 32'h010), r1, v, err);
                default: idle(int'(r1 % 12));
            endcase
            if (r3 % 500 == 0) async_reset();
        end
    endtask

    task automatic require(int value, string goal);
        check(value > 0, {"coverage goal not reached: ", goal});
    endtask

    initial begin
        done   = 1'b0;
        errors = 0;
        repeat (2) @(posedge pclk);
        #2 presetn = 1'b1;
        @(posedge pclk); #1;

        test_reset_values();
        test_register_access();
        test_error_responses();
        test_one_shot();
        test_periodic();
        test_enable_disable();
        test_irq_gating();
        test_set_wins();
        test_limit_lowered();
        test_random(4000);

        require(n_exp_oneshot,  "one-shot expiry");
        require(n_exp_periodic, "periodic expiry");
        require(n_restarts,     "restart from stopped");
        require(n_w1c,          "write-1-to-clear");
        require(n_set_wins,     "expiry and clear in the same cycle");
        require(n_late_limit,   "LIMIT lowered below COUNT");
        require(n_irq_cycles,   "irq asserted");
        require(n_slverr,       "PSLVERR response");
        require(n_resets,       "reset during random traffic");
        if (WAIT_STATES > 0) require(n_wait_cycles, "wait states");

        $display("[WAIT_STATES=%0d] %6d cycles  %5d APB transfers  %4d PSLVERR  %5d wait cycles  %4d one-shot / %5d periodic expiries  %3d W1C  %3d set-wins  %2d resets  %7d checks  %0d errors",
                 WAIT_STATES, cyc, n_xfers, n_slverr, n_wait_cycles, n_exp_oneshot, n_exp_periodic,
                 n_w1c, n_set_wins, n_resets, n_checks, errors);
        done = 1'b1;
    end
endmodule
