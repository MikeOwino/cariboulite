module smi_ctrl
(
    input               i_rst_b,
    input               i_sys_clk,        // FPGA Clock
    input 				i_fast_clk,

    input [4:0]         i_ioc,
    input [7:0]         i_data_in,
    output reg [7:0]    o_data_out,
    input               i_cs,
    input               i_fetch_cmd,
    input               i_load_cmd,

    // FIFO INTERFACE
    output              o_rx_fifo_pull,
    input [31:0]        i_rx_fifo_pulled_data,
    input               i_rx_fifo_empty,
    
    output              o_tx_fifo_push,
    output reg [31:0]   o_tx_fifo_pushed_data,
    input               i_tx_fifo_full,
    output              o_tx_fifo_clock,

    // SMI INTERFACE
    input               i_smi_soe_se,
    input               i_smi_swe_srw,
    output reg [7:0]    o_smi_data_out,
    input [7:0]         i_smi_data_in,
    output              o_smi_read_req,
    output              o_smi_write_req,
    input               i_smi_test,
    output              o_channel,

    // TX CONDITIONAL
    output reg          o_cond_tx,
    // Errors
    output reg          o_address_error);

    // ---------------------------------

    // MODULE SPECIFIC IOC LIST
    // ---------------------------------
    localparam
        ioc_module_version  = 5'b00000,     // read only
        ioc_fifo_status     = 5'b00001,     // read-only
        ioc_channel_select  = 5'b00010;

    // ---------------------------------
    // MODULE SPECIFIC PARAMS
    // ---------------------------------
    localparam
        module_version  = 8'b00000001;

    // ---------------------------------------
    // MODULE CONTROL
    // ---------------------------------------
    assign o_channel = r_channel;
    always @(posedge i_sys_clk or negedge i_rst_b)
    begin
        if (i_rst_b == 1'b0) begin
            o_address_error <= 1'b0;
        end else begin
            if (i_cs == 1'b1) begin
                //=============================================
                // READ OPERATIONS
                //=============================================
                if (i_fetch_cmd == 1'b1) begin
                    case (i_ioc)
                        //----------------------------------------------
                        ioc_module_version: o_data_out <= module_version; // Module Version

                        //----------------------------------------------
                        ioc_fifo_status: begin
                            o_data_out[0] <= i_rx_fifo_empty;
                            o_data_out[1] <= i_tx_fifo_full;
                            o_data_out[2] <= r_channel;
                            o_data_out[3] <= i_smi_test;
                            o_data_out[7:4] <= 4'b0000;
                        end
                    endcase
                end
                //=============================================
                // WRITE OPERATIONS
                //=============================================
                else if (i_load_cmd == 1'b1) begin
                    case (i_ioc)
                        //----------------------------------------------
                        ioc_channel_select: begin
                            r_channel <= i_data_in[0];
                        end
                    endcase
                end
            end
        end
    end


    // ---------------------------------------
    // RX SIDE
    // ---------------------------------------
    reg [4:0] int_cnt_rx;
    reg [7:0] r_smi_test_count;
    reg r_fifo_pull;
    reg r_fifo_pull_1;
    wire w_fifo_pull_trigger;
    reg r_channel;
    reg [31:0] r_fifo_pulled_data;

    wire soe_and_reset;
    assign soe_and_reset = i_rst_b & i_smi_soe_se;
    assign o_smi_read_req = (!i_rx_fifo_empty) || i_smi_test;
    assign o_rx_fifo_pull = !r_fifo_pull_1 && r_fifo_pull && !i_rx_fifo_empty;

    always @(negedge soe_and_reset)
    begin
        if (i_rst_b == 1'b0) begin
            int_cnt_rx <= 5'd0;
            r_smi_test_count <= 8'h56;
            r_fifo_pulled_data <= 32'h00000000;
        end else begin
            // trigger the fifo pulling on the second byte
            w_fifo_pull_trigger <= (int_cnt_rx == 5'd8) && !i_smi_test;

            if ( i_smi_test ) begin
                if (r_smi_test_count == 0) begin
                    r_smi_test_count <= 8'h56;
                end else begin
                    o_smi_data_out <= r_smi_test_count;
                    r_smi_test_count <= {((r_smi_test_count[2] ^ r_smi_test_count[3]) & 1'b1), r_smi_test_count[7:1]};
                end
            end else begin
                int_cnt_rx <= int_cnt_rx + 8;
                o_smi_data_out <= r_fifo_pulled_data[int_cnt_rx+7:int_cnt_rx];
                
                // update the internal register as soon as we reach the fourth byte
                if (int_cnt_rx == 5'd24) begin
                    r_fifo_pulled_data <= i_rx_fifo_pulled_data;
                end
            end

        end
    end

    always @(posedge i_sys_clk)
    begin
        if (i_rst_b == 1'b0) begin
            r_fifo_pull <= 1'b0;
            r_fifo_pull_1 <= 1'b0;
        end else begin
            r_fifo_pull <= w_fifo_pull_trigger;
            r_fifo_pull_1 <= r_fifo_pull;
        end
    end

    // -----------------------------------------
    // TX SIDE
    // -----------------------------------------
    localparam
        tx_state_first  = 2'b00,
        tx_state_second = 2'b01,
        tx_state_third  = 2'b10,
        tx_state_fourth = 2'b11;

    reg [4:0] int_cnt_tx;
    reg [31:0] r_fifo_pushed_data;
    reg [1:0] tx_reg_state;
    reg modem_tx_ctrl;
    reg cond_tx_ctrl;
    reg r_fifo_push;
    reg r_fifo_push_1;
    wire w_fifo_push_trigger;
    assign o_smi_write_req = !i_tx_fifo_full;
    assign o_tx_fifo_push = !r_fifo_push_1 && r_fifo_push && !i_tx_fifo_full;
    assign swe_and_reset = i_rst_b & i_smi_swe_srw;
    assign o_tx_fifo_clock = i_sys_clk;

    always @(negedge swe_and_reset)
    begin
        if (i_rst_b == 1'b0) begin
            tx_reg_state <= tx_state_first;
            w_fifo_push_trigger <= 1'b0;
            r_fifo_pushed_data <= 32'h00000000;
            modem_tx_ctrl <= 1'b0;
            cond_tx_ctrl <= 1'b0;
            //cnt <= 0;
        end else begin
            case (tx_reg_state)
                //----------------------------------------------
                tx_state_first: 
                begin
                    if (i_smi_data_in[7] == 1'b1) begin
                        r_fifo_pushed_data[31:30] <= 2'b10;
                        modem_tx_ctrl <= i_smi_data_in[6];
                        cond_tx_ctrl <= i_smi_data_in[5];
                        r_fifo_pushed_data[29:25] <= i_smi_data_in[4:0];
                        tx_reg_state <= tx_state_second;
                        w_fifo_push_trigger <= 1'b0;
                    end else begin
                        // if from some reason we are in the first byte stage and we got
                        // a byte without '1' on its MSB, that means that we are not synced
                        // so push a "sync" word into the modem.
                        cond_tx_ctrl <= 1'b0;
                        modem_tx_ctrl <= 1'b0;
                        o_tx_fifo_pushed_data <= 32'h00000000;
                        w_fifo_push_trigger <= 1'b1;
                    end
                end
                //----------------------------------------------
                tx_state_second: 
                begin
                    if (i_smi_data_in[7] == 1'b0) begin
                        r_fifo_pushed_data[24:18] <= i_smi_data_in[6:0];
                        tx_reg_state <= tx_state_third;
                    end else begin
                        tx_reg_state <= tx_state_first;
                    end
                    w_fifo_push_trigger <= 1'b0;
                end
                //----------------------------------------------
                tx_state_third: 
                begin
                    if (i_smi_data_in[7] == 1'b0) begin
                        r_fifo_pushed_data[17] <= i_smi_data_in[6];
                        r_fifo_pushed_data[16] <= modem_tx_ctrl;
                        r_fifo_pushed_data[15:14] <= 2'b01;
                        r_fifo_pushed_data[13:8] <= i_smi_data_in[5:0];
                        tx_reg_state <= tx_state_fourth;
                    end else begin
                        tx_reg_state <= tx_state_first;
                    end
                    w_fifo_push_trigger <= 1'b0;
                end
                //----------------------------------------------
                tx_state_fourth: 
                begin
                    if (i_smi_data_in[7] == 1'b0) begin
                        o_tx_fifo_pushed_data <= {r_fifo_pushed_data[31:8], i_smi_data_in[6:0], 1'b0};
                        //o_tx_fifo_pushed_data <= {2'b10, cnt, 1'b1, 2'b01, 13'h3F, 1'b0};
                        //o_tx_fifo_pushed_data <= {cnt, cnt, 6'b111111};
                        //cnt <= cnt + 1024;
                        w_fifo_push_trigger <= 1'b1;
                        o_cond_tx <= cond_tx_ctrl;
                    end else begin
                        o_tx_fifo_pushed_data <= 32'h00000000;
                        w_fifo_push_trigger <= 1'b0;
                    end
                    tx_reg_state <= tx_state_first;
                end
            endcase
        end
    end
    
    always @(posedge i_sys_clk)
    begin
        if (i_rst_b == 1'b0) begin
            r_fifo_push <= 1'b0;
            r_fifo_push_1 <= 1'b0;
        end else begin
            r_fifo_push <= w_fifo_push_trigger;
            r_fifo_push_1 <= r_fifo_push;
        end
    end

endmodule // smi_ctrl