module SimpleMac (
    input rst, // active high and registered to tx_clk

    // MII interface
    input eth_txclk,
    output reg eth_txen,
    output reg[3:0] eth_txd,
    input eth_rxclk,
    input eth_rxdv,
    input eth_rxer,
    input[3:0] eth_rxd,
    input eth_col,
    input eth_crs,
    output eth_pcf,
    output eth_rstn,

    // Transmit interface
    input tx_clk,
    input[7:0] tx_data,
    input tx_sop,
    input tx_eop,
    input tx_err,
    output tx_rdy,
    input tx_wren,

    output tx_a_full,
    output tx_a_empty

    // Receive interface - TODO
);

    parameter ALMOST_FULL_THRESHOLD = 64;
    parameter ALMOST_EMPTY_THRESHOLD = 64;
    parameter WAIT_LEN = 24; // 24 nibbles is 12 bytes or 96 bits, the standard minimum interpacket gap

    // 2048 byte deep FIFO
    // FIFO stores 8 data bits, sop, eop, and err signals
    // single entry = {eop, sop, data}, 10 bits wide

    reg[9:0] fifo_mem[4095:0];
    reg[11:0] rd_ptr = 0;
    reg[11:0] wr_ptr = 0;
    wire[11:0] fifo_count = wr_ptr - rd_ptr;

    /* verilator lint_off WIDTH */
    assign tx_a_full = fifo_count > 2048 - ALMOST_FULL_THRESHOLD;
    assign tx_a_empty = fifo_count < ALMOST_EMPTY_THRESHOLD;
    assign tx_rdy = ~tx_a_full & ~rst_int;
    /* verilator lint_on WIDTH */

    reg[3:0] packets_ready = 0; // Number of complete packets in FIFO
    reg rst_int = 0;
    reg rst_ack = 0;

    // Write logic

    always @(posedge tx_clk) begin
        if (rst | rst_int) begin
            if (~rst_int) begin
                rst_int <= 1;
            end else if (rst_ack) begin
                rst_int <= 0;
            end
            wr_ptr <= 0;
            packets_ready <= 0;
        end else if (tx_wren & tx_rdy) begin
            fifo_mem[wr_ptr] <= {tx_eop, tx_sop, tx_data};
            wr_ptr <= wr_ptr + 1;

            if (tx_eop) begin
                packets_ready <= packets_ready + 1;
            end
        end
    end

    // Read logic

    localparam STATE_IDLE = 2'b00;
    localparam STATE_PREAMBLE = 2'b01;
    localparam STATE_DATA = 2'b10;
    localparam STATE_CRC = 2'b11;

    reg[1:0] tx_state;

    reg[7:0] rd_data; // Current data
    reg rd_sop, rd_eop; // Current sop, eop values

    reg crc_en = 0;
    reg crc_init = 0;
    wire crc_rst = crc_init | rst_int;
    wire[31:0] crc_out;

    reg[15:0] tx_counter = 0; // Position within packet, increments after every half byte
    reg[7:0] wait_counter = 0;
    reg[2:0] crc_counter = 0;

    assign eth_rstn = ~rst_int;

    CRC32 crc32 (
        .clk(eth_txclk),
        .rst(crc_rst),
        .data_in(rd_data),
        .data_valid(crc_en),
        .crc_out(crc_out)
    );

    always @(*) begin
        case (tx_state)
            // Send preamble of 55...55D
            STATE_PREAMBLE: begin
                eth_txen = 1'b1;

                if (tx_counter < 16'h00f) begin
                    eth_txd = 4'h5;
                end else begin
                    eth_txd = 4'hd;
                end
            end

            // Send packet data
            STATE_DATA: begin
                eth_txen = 1'b1;

                if (tx_counter[0]) begin
                    eth_txd = rd_data[7:4];
                end else begin
                    eth_txd = rd_data[3:0];
                end
            end

            // Send CRC
            STATE_CRC: begin
                eth_txen = 1'b1;

                eth_txd = {
                    crc_out[28-crc_counter*4],
                    crc_out[29-crc_counter*4],
                    crc_out[30-crc_counter*4],
                    crc_out[31-crc_counter*4]
                };
            end

            // Idle
            default: begin
                eth_txd = 4'b0;
                eth_txen = 1'b0;
            end
        endcase
    end

    always @(posedge eth_txclk) begin
        rd_data <= fifo_mem[rd_ptr][7:0];
        rd_sop <= fifo_mem[rd_ptr][8];
        rd_eop <= fifo_mem[rd_ptr][9];

        if (rst_int) begin
            rst_ack <= 1;
            rd_ptr <= 0;
            tx_state <= STATE_IDLE;
            tx_counter <= 0;
        end else begin
            rst_ack <= 0;
            tx_counter <= tx_counter + 1;

            case (tx_state)
                STATE_IDLE: begin
                    if (wait_counter > 0) begin
                        wait_counter <= wait_counter - 1;
                        crc_init = 1;
                    end else if (packets_ready > 0) begin
                        tx_counter <= 0;
                        crc_init = 0;

                        if (rd_sop) begin
                            tx_state <= STATE_PREAMBLE;
                        end else begin
                            rd_ptr <= rd_ptr + 1;
                            wait_counter <= 1; // This gives the fifo a cycle to work
                        end
                    end
                end

                STATE_PREAMBLE: begin
                    if (tx_counter == 16'hf) begin
                        tx_state <= STATE_DATA;
                        crc_en <= 1;
                    end
                end

                STATE_DATA: begin
                    if (tx_counter[0]) begin
                        // rd_ptr <= rd_ptr + 1; // Increment read pointer

                        crc_en <= 1; // Calculate CRC on every other cycle

                        // End transmission
                        if (rd_eop) begin
                            tx_state <= STATE_CRC;
                            crc_en <= 0;
                        end
                    end else begin
                        // This is here because the fifo takes 1 cycle to read from
                        rd_ptr <= rd_ptr + 1; // Increment read pointer

                        crc_en <= 0;
                    end
                end

                STATE_CRC: begin
                    crc_counter <= crc_counter + 1;

                    if (crc_counter == 3'h7) begin
                        tx_state <= STATE_IDLE;
                        wait_counter <= WAIT_LEN;
                    end
                end
            endcase
        end
    end

endmodule