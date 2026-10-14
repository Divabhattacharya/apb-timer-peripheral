`timescale 1ns/1ps
// Programmable timer peripheral with an AMBA APB (APB3) slave interface.
//
// Register map (32-bit registers, byte addresses):
//   0x00  CONTROL  RW   [0] EN      run; writing 1 while stopped restarts COUNT at 0
//                       [1] MODE    0 = one-shot, 1 = periodic (auto-reload)
//                       [2] IRQ_EN  interrupt enable
//   0x04  LIMIT    RW   expiry value
//   0x08  COUNT    RO   current count
//   0x0C  STATUS   W1C  [0] EXPIRED  sticky expiry flag, write 1 to clear
//
// Timer: while EN = 1 the counter steps 0, 1, ..., LIMIT and expires on the
// next cycle, so it expires every LIMIT + 1 cycles. On expiry EXPIRED is set;
// periodic mode reloads COUNT to 0 and keeps running, one-shot mode clears EN
// and holds COUNT. irq = EXPIRED & IRQ_EN. Expiry is COUNT >= LIMIT, so
// lowering LIMIT below COUNT expires immediately instead of wrapping 2^32.
// If an expiry and a STATUS clear land in the same cycle, the expiry wins.
//
// APB: every access takes WAIT_STATES extra cycles (PREADY low). PSLVERR is
// returned for unmapped addresses and for writes to COUNT; such writes have no
// effect and unmapped reads return 0.
module apb_timer #(
    parameter int WAIT_STATES = 0
) (
    input  logic        pclk,
    input  logic        presetn,
    // APB slave
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,
    // interrupt
    output logic        irq
);
    localparam logic [11:0] ADDR_CONTROL = 12'h000;
    localparam logic [11:0] ADDR_LIMIT   = 12'h004;
    localparam logic [11:0] ADDR_COUNT   = 12'h008;
    localparam logic [11:0] ADDR_STATUS  = 12'h00C;

    logic        ctrl_en, ctrl_mode, ctrl_irq_en;
    logic [31:0] limit_q, count_q;
    logic        expired_q;

    // ------------------------------------------------------------------
    // APB access handling
    // SETUP:  psel & !penable (one cycle)
    // ACCESS: psel &  penable, completes on the cycle pready is high
    // ------------------------------------------------------------------
    logic access, xfer;
    assign access = psel && penable;
    assign xfer   = access && pready;

    generate
        if (WAIT_STATES == 0) begin : g_no_wait
            assign pready = 1'b1;
        end else begin : g_wait
            localparam int WW = $clog2(WAIT_STATES + 1);
            logic [WW-1:0] wait_q;
            always_ff @(posedge pclk or negedge presetn) begin
                if (!presetn)               wait_q <= '0;
                else if (access && !pready) wait_q <= wait_q + 1'b1;
                else                        wait_q <= '0;
            end
            assign pready = (wait_q == WW'(WAIT_STATES));
        end
    endgenerate

    // address decode
    logic addr_ok;
    always_comb begin
        case (paddr)
            ADDR_CONTROL, ADDR_LIMIT, ADDR_COUNT, ADDR_STATUS: addr_ok = 1'b1;
            default:                                           addr_ok = 1'b0;
        endcase
    end

    assign pslverr = xfer && (!addr_ok || (pwrite && paddr == ADDR_COUNT));

    logic wr_control, wr_limit, wr_status;
    assign wr_control = xfer && pwrite && paddr == ADDR_CONTROL;
    assign wr_limit   = xfer && pwrite && paddr == ADDR_LIMIT;
    assign wr_status  = xfer && pwrite && paddr == ADDR_STATUS;

    // register readback
    always_comb begin
        prdata = '0;
        if (access && !pwrite) begin
            case (paddr)
                ADDR_CONTROL: prdata = {29'd0, ctrl_irq_en, ctrl_mode, ctrl_en};
                ADDR_LIMIT:   prdata = limit_q;
                ADDR_COUNT:   prdata = count_q;
                ADDR_STATUS:  prdata = {31'd0, expired_q};
                default:      prdata = '0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Timer
    // ------------------------------------------------------------------
    logic expire;
    assign expire = ctrl_en && (count_q >= limit_q);

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl_en     <= 1'b0;
            ctrl_mode   <= 1'b0;
            ctrl_irq_en <= 1'b0;
            limit_q     <= '0;
            count_q     <= '0;
            expired_q   <= 1'b0;
        end else begin
            // COUNT
            if (wr_control && pwdata[0] && !ctrl_en)
                count_q <= '0;                          // start: count from 0
            else if (expire)
                count_q <= ctrl_mode ? '0 : count_q;    // periodic reloads, one-shot holds
            else if (ctrl_en)
                count_q <= count_q + 1'b1;

            // CONTROL
            if (wr_control) begin
                ctrl_en     <= pwdata[0];
                ctrl_mode   <= pwdata[1];
                ctrl_irq_en <= pwdata[2];
            end else if (expire && !ctrl_mode) begin
                ctrl_en     <= 1'b0;                    // one-shot finished
            end

            // LIMIT
            if (wr_limit)
                limit_q <= pwdata;

            // STATUS: set on expiry, write 1 to clear
            if (expire)
                expired_q <= 1'b1;
            else if (wr_status && pwdata[0])
                expired_q <= 1'b0;
        end
    end

    assign irq = expired_q && ctrl_irq_en;
endmodule
