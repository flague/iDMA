// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "idma/guard.svh"
`include "common_cells/registers.svh"
<%
 streaming_accel = False
 llc_coh = False
%>
% for protocol in used_protocols:
%   if streaming_accelerator[protocol] == 'true' and 'axi' in used_read_protocols and 'axi' in used_write_protocols and one_write_port:
<%
       streaming_accel = True
%>
%   endif
%   if llc_coherence[protocol] == 'true' and 'axi' in used_read_protocols and 'axi' in used_write_protocols:
<%
       llc_coh = True
%>
% endif
% endfor

/// Implementing the transport layer in the iDMA backend.
module idma_transport_layer_${name_uniqueifier} #(
    /// Number of transaction that can be in-flight concurrently
    parameter int unsigned NumAxInFlight = 32'd2,
    /// Data width
    parameter int unsigned DataWidth = 32'd16,
    /// The depth of the internal reorder buffer:
    /// - '2': minimal possible configuration
    /// - '3': efficiently handle misaligned transfers (recommended)
    parameter int unsigned BufferDepth = 32'd3,
    /// Mask invalid data on the manager interface
    parameter bit MaskInvalidData = 1'b1,
    /// Print the info of the FIFO configuration
    parameter bit PrintFifoInfo = 1'b0,
    /// `r_dp_req_t` type:
    parameter type r_dp_req_t = logic,
    /// `w_dp_req_t` type:
    parameter type w_dp_req_t = logic,
    /// `r_dp_rsp_t` type:
    parameter type r_dp_rsp_t = logic,
    /// `w_dp_rsp_t` type:
    parameter type w_dp_rsp_t = logic,
    /// Write Meta channel type
    parameter type write_meta_channel_t = logic,
% if not one_write_port:
    parameter type write_meta_channel_tagged_t = logic,
% endif
    /// Read Meta channel type
    parameter type read_meta_channel_t = logic\
% if not one_read_port:
,
    parameter type read_meta_channel_tagged_t = logic\
% endif
% for protocol in used_protocols:
,
    % if llc_coherence[protocol] == 'true' and 'axi' in used_read_protocols and 'axi' in used_write_protocols:
    /// Disable LLC legalizer through this flag
    parameter bit LLC_Legalizer             = 1'b1,
    % endif
    % if streaming_accelerator[protocol] == 'true' and 'axi' in used_read_protocols and 'axi' in used_write_protocols:
    parameter bit StreamingAccelerator    = 1'b1,
    parameter type stream_acc_t        = logic,
    parameter int unsigned NumRStreamAcc   = 32'd1,
    parameter int unsigned NumWStreamAcc   = 32'd1,
    /// Widening accelerator enabled
    parameter bit WideningUnit     = 1'b1,
    parameter bit NarrowingUnit    = 1'b1,
    parameter int unsigned WideningDataWidth    = 32'd32,
    parameter int unsigned NarrowingDataWidth   = 32'd32,
    /// Widening max 1D transfer width (log2(VPU line size))
    parameter int unsigned WideningMax1DTxWidth = 32'd10,
    parameter int unsigned NarrowingMax1DTxWidth = 32'd10,
    % endif
    /// ${database[protocol]['full_name']} Request and Response channel type
    % if database[protocol]['read_slave'] == 'true':
        % if (protocol in used_read_protocols) and (protocol in used_write_protocols):
    parameter type ${protocol}_read_req_t = logic,
    parameter type ${protocol}_read_rsp_t = logic,

    parameter type ${protocol}_write_req_t = logic,
    parameter type ${protocol}_write_rsp_t = logic\
        % elif protocol in used_read_protocols:
    parameter type ${protocol}_read_req_t = logic,
    parameter type ${protocol}_read_rsp_t = logic\
        % elif protocol in used_write_protocols:
    parameter type ${protocol}_write_req_t = logic,
    parameter type ${protocol}_write_rsp_t = logic\
        % endif
    % else:
    parameter type ${protocol}_req_t = logic,
    parameter type ${protocol}_rsp_t = logic\
    % endif
% endfor

)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,
    /// Testmode in
    input  logic testmode_i,
% for protocol in used_read_protocols:

    /// ${database[protocol]['full_name']} read request
% if database[protocol]['passive_req'] == 'true':
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${protocol}_read_req_i,
% else:
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${protocol}_read_req_o,
% endif
    /// ${database[protocol]['full_name']} read response
% if database[protocol]['passive_req'] == 'true':
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${protocol}_read_rsp_o,
% else:
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${protocol}_read_rsp_i,
% endif
% endfor
% for protocol in used_write_protocols:

    /// ${database[protocol]['full_name']} write request
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_req_t ${protocol}_write_req_o,
    /// ${database[protocol]['full_name']} write response
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_rsp_t ${protocol}_write_rsp_i,
% endfor

    /// Read datapath request
    input  r_dp_req_t r_dp_req_i,
    /// Read datapath request valid
    input  logic r_dp_valid_i,
    /// Read datapath request ready
    output logic r_dp_ready_o,

    /// Read datapath response
    output r_dp_rsp_t r_dp_rsp_o,
    /// Read datapath response valid
    output logic r_dp_valid_o,
    /// Read datapath response valid
    input  logic r_dp_ready_i,

    /// Write datapath request
    input  w_dp_req_t w_dp_req_i,
    /// Write datapath request valid
    input  logic w_dp_valid_i,
    /// Write datapath request ready
    output logic w_dp_ready_o,

    /// Write datapath response
    output w_dp_rsp_t w_dp_rsp_o,
    /// Write datapath response valid
    output logic w_dp_valid_o,
    /// Write datapath response valid
    input  logic w_dp_ready_i,

    /// Read meta request
% if not one_read_port:
    input  read_meta_channel_tagged_t ar_req_i,
% else:
    input  read_meta_channel_t ar_req_i,
% endif
    /// Read meta request valid
    input  logic ar_valid_i,
    /// Read meta request ready
    output logic ar_ready_o,

    /// Write meta request
% if not one_write_port:
    input  write_meta_channel_tagged_t aw_req_i,
% else:
    input  write_meta_channel_t aw_req_i,
% endif
    /// Write meta request valid
    input  logic aw_valid_i,
    /// Write meta request ready
    output logic aw_ready_o,

    
%  if llc_coh:
    /// Write valid sent to downstream goes back
    /// This is used to throttle the read requests in case of LLC to LLC transfers
    output logic wvalid_o,
%  endif
% if streaming_accel:
    /// Widening configuration valid
    input  stream_acc_t widening_req_i,
    input  stream_acc_t narrowing_req_i,
%  endif
    /// Datapath poison signal
    input  logic dp_poison_i,

    /// Response channel valid and ready
    output logic r_chan_ready_o,
    output logic r_chan_valid_o,

    /// Read part of the datapath is busy
    output logic r_dp_busy_o,
    /// Write part of the datapath is busy
    output logic w_dp_busy_o,
    /// Buffer is busy
    output logic buffer_busy_o
);

    /// Stobe width
    localparam int unsigned StrbWidth   = DataWidth / 8;

    /// Data type
    typedef logic [DataWidth-1:0] data_t;
    /// Offset type
    typedef logic [StrbWidth-1:0] strb_t;
    /// Byte type
    typedef logic [7:0] byte_t;

    // inbound control signals to the read buffer: controlled by the read process
    strb_t\
% if not one_read_port:
    % for p in used_read_protocols:
 ${p}_buffer_in_valid,\
    % endfor
% endif
 buffer_in_valid;

    strb_t buffer_in_ready;
    // outbound control signals of the buffer: controlled by the write process
    strb_t buffer_out_valid, buffer_out_valid_shifted;
    strb_t\
% if not one_write_port:
    % for p in used_write_protocols:
 ${p}_buffer_out_ready,\
    % endfor
% endif

        buffer_out_ready, buffer_out_ready_shifted;

    // shifted data flowing into the buffer
    byte_t [2*StrbWidth-1:0] buffer_in_tmp;
    byte_t [StrbWidth-1:0]\
% if not one_read_port:
    % for p in used_read_protocols:
 ${p}_buffer_in,\
    % endfor
% endif

        buffer_in, buffer_in_shifted;
    // aligned and coalesced data leaving the buffer
    byte_t [2*StrbWidth-1:0] buffer_out_tmp;
    byte_t [StrbWidth-1:0] buffer_out, buffer_out_shifted;
% if not one_read_port:

    // Read multiplexed signals
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_chan_valid\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_chan_ready\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_dp_valid\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_dp_ready\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    r_dp_rsp_t\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_dp_rsp\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor

    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_ar_ready\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
% endif
% if not one_write_port:

    // Write multiplexed signals
    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_rsp_valid\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_rsp_ready\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_ready\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    w_dp_rsp_t\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_rsp\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor

    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_aw_ready\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
% endif
% if not one_write_port:
    logic w_dp_req_valid, w_dp_req_ready;
    logic w_dp_rsp_mux_valid, w_dp_rsp_mux_ready;
    logic w_dp_rsp_valid, w_dp_rsp_ready;
    w_dp_rsp_t w_dp_rsp_mux;

    // Write Response FIFO signals
    logic w_resp_fifo_in_valid, w_resp_fifo_in_ready;
    idma_pkg::protocol_e w_resp_fifo_out_protocol;
    logic w_resp_fifo_out_valid, w_resp_fifo_out_ready;
% endif



%  if streaming_accel:
    
    
    // Signals
    // Intermediate signals axi_read_unit
    r_dp_req_t r_dp_req_acc_ru;
    logic r_dp_req_valid_acc_ru;
    logic r_dp_req_ready_acc_ru;

    r_dp_rsp_t r_dp_rsp_acc_ru;
    logic r_dp_rsp_valid_acc_ru;
    logic r_dp_rsp_ready_acc_ru;

    read_meta_channel_t ar_req_acc_ru;
    logic ar_req_valid_acc_ru;
    logic ar_req_ready_acc_ru;


    // output buffer
    byte_t [StrbWidth-1:0]    r_buffer_out_acc_df;
    strb_t                    r_buffer_out_valid_acc_df;
    strb_t                    r_buffer_out_ready_acc_df;

    //--------------------------------------
    // Read accelerator interface
    // -------------------------------------

    if(StreamingAccelerator && NumRStreamAcc > 0) begin : gen_r_stream_acc
    
    // Input dp --> accelerators
    logic [NumRStreamAcc:0]     r_dp_in_req_valid_acc;
    logic [NumRStreamAcc:0]     r_dp_in_req_ready_acc;
    // Accelerator --> read dp
    r_dp_rsp_t [NumRStreamAcc:0]    r_dp_out_rsp_acc;
    logic [NumRStreamAcc:0]         r_dp_out_rsp_valid_acc;
    logic [NumRStreamAcc:0]         r_dp_out_rsp_ready_acc;
    // Input ar req --> accelerators
    logic [NumRStreamAcc:0]     ar_in_valid_acc;
    logic [NumRStreamAcc:0]     ar_in_ready_acc;
    // Accelerator --> read ar req
    read_meta_channel_t [NumRStreamAcc:0]    ar_out_req_acc;
    logic [NumRStreamAcc:0]         ar_out_valid_acc;
    logic [NumRStreamAcc:0]         ar_out_ready_acc;

    // Output dp from accelerators --> read dp
    r_dp_req_t[NumRStreamAcc:0]     r_dp_out_req_acc;
    logic [NumRStreamAcc:0]         r_dp_out_req_valid_acc;
    logic [NumRStreamAcc:0]         r_dp_out_req_ready_acc;

    // resp ru acc
    logic [NumRStreamAcc:0]         r_dp_in_rsp_valid_acc;
    logic [NumRStreamAcc:0]         r_dp_in_rsp_ready_acc;

    // input buffer
    strb_t [NumRStreamAcc:0]       buffer_in_valid_acc;
    strb_t [NumRStreamAcc:0]       buffer_in_ready_acc;
    
    
    // Acc to dataflow element
    byte_t [NumRStreamAcc:0][StrbWidth-1:0]    r_buffer_out_acc;
    strb_t [NumRStreamAcc:0]                   r_buffer_out_valid_acc;
    strb_t [NumRStreamAcc:0]                   r_buffer_out_ready_acc;


    // Demux input signals
    // -------------------    
    always_comb begin : r_acc_demux
        for (int unsigned i = 0; i <= NumRStreamAcc; i++) begin : rendered_stream_acc_ports
            r_dp_in_req_valid_acc[i] = (r_dp_req_i.stream_acc_id == (i)) ? r_dp_valid_i : 1'b0;
            ar_in_valid_acc[i]       = (r_dp_req_i.stream_acc_id == (i)) ? ar_valid_i  : 1'b0;
            r_dp_out_rsp_ready_acc[i] = (r_dp_req_i.stream_acc_id == (i)) ? r_dp_ready_i : 1'b0;
            // read unit acc
            r_dp_out_req_ready_acc[i]= (r_dp_req_i.stream_acc_id == (i)) ? r_dp_req_ready_acc_ru : 1'b0;
            ar_out_ready_acc[i]      = (r_dp_req_i.stream_acc_id == (i)) ? ar_req_ready_acc_ru : 1'b0;
            // r dp rsp
            r_dp_in_rsp_valid_acc[i] = (r_dp_req_i.stream_acc_id == (i)) ? r_dp_rsp_valid_acc_ru : 1'b0;
            // buffer in
            buffer_in_valid_acc[i]   = (r_dp_req_i.stream_acc_id == (i)) ? buffer_in_valid : '0;
            r_buffer_out_ready_acc[i] = (r_dp_req_i.stream_acc_id == (i)) ? r_buffer_out_ready_acc_df : '0;
        end    
    
    end
    
    // Mux output signals
    // ------------------
    assign r_dp_ready_o = r_dp_in_req_ready_acc[r_dp_req_i.stream_acc_id];
    assign ar_ready_o   = ar_in_ready_acc[r_dp_req_i.stream_acc_id];
    assign r_dp_rsp_o   = r_dp_out_rsp_acc[r_dp_req_i.stream_acc_id];
    assign r_dp_valid_o = r_dp_out_rsp_valid_acc[r_dp_req_i.stream_acc_id];
    // Req from accelerators to read unit
    assign r_dp_req_acc_ru       = r_dp_out_req_acc[r_dp_req_i.stream_acc_id];
    assign r_dp_req_valid_acc_ru = r_dp_out_req_valid_acc[r_dp_req_i.stream_acc_id];
    assign ar_req_acc_ru         = ar_out_req_acc[r_dp_req_i.stream_acc_id];
    assign ar_req_valid_acc_ru   = ar_out_valid_acc[r_dp_req_i.stream_acc_id];
    // Rdp resp
    assign r_dp_rsp_ready_acc_ru = r_dp_in_rsp_ready_acc[r_dp_req_i.stream_acc_id];
    // Buffer in
    assign buffer_in_ready      = buffer_in_ready_acc[r_dp_req_i.stream_acc_id];
    // Buffer out
    assign r_buffer_out_acc_df          = r_buffer_out_acc[r_dp_req_i.stream_acc_id];
    assign r_buffer_out_valid_acc_df    = r_buffer_out_valid_acc[r_dp_req_i.stream_acc_id];

    if (NarrowingUnit) begin : gen_narrow_unit
        narrowing_wrap #(
            .BusDataWidth     ( DataWidth       ),
            .WidenedDataWidth ( WideningDataWidth  ),
            .Max1DTxWidth     ( WideningMax1DTxWidth ),
            .byte_t           ( byte_t          ),
            .data_t           ( data_t          ),
            .strb_t           ( strb_t          ),
            .r_dp_req_t       ( r_dp_req_t      ),
            .r_dp_rsp_t       ( r_dp_rsp_t      ),
            .ar_chan_t        ( read_meta_channel_t ),
            .stream_acc_t     (stream_acc_t    )
        ) i_narrowing_wrap (
            .clk_i             (clk_i),
            .rst_ni            (rst_ni),
            .narrowing_req_i   (narrowing_req_i),
            .r_dp_req_i        (r_dp_req_i),
            .r_dp_req_valid_i  (r_dp_in_req_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_req_ready_o  (r_dp_in_req_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_req_o        (r_dp_out_req_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_req_valid_o  (r_dp_out_req_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_req_ready_i  (r_dp_out_req_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_rsp_i        (r_dp_rsp_acc_ru),
            .r_dp_rsp_valid_i  (r_dp_in_rsp_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_rsp_ready_o  (r_dp_in_rsp_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_rsp_o        (r_dp_out_rsp_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_rsp_valid_o  (r_dp_out_rsp_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .r_dp_rsp_ready_i  (r_dp_out_rsp_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .ar_req_i          (ar_req_i),
            .ar_valid_i        (ar_in_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .ar_ready_o        (ar_in_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .ar_req_o          (ar_out_req_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .ar_valid_o        (ar_out_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .ar_ready_i        (ar_out_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            // Input buffer interface
            .buffer_in_i      (buffer_in   ),
            .buffer_in_valid_i(buffer_in_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .buffer_in_ready_o(buffer_in_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]),  // TODO: careful to this signal
            .buffer_out_o     (r_buffer_out_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .buffer_out_valid_o (r_buffer_out_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]),
            .buffer_out_ready_i (r_buffer_out_ready_acc[stream_acc_pkg::NARROWING_ACC_ID])
        );
    
    end else begin: gen_no_narrow_unit
        // Index 0 is for normal DMA transfer
        // TODO: normal req
        // No widening unit, directly connect signals
        // TODO: fix not like that probably if the acc is not there
        // all its valid should be 0 not forwarded
            // Tie off widening accelerator signals
            assign r_dp_out_req_acc[stream_acc_pkg::NARROWING_ACC_ID]       = '0;
            assign r_dp_out_req_valid_acc[stream_acc_pkg::NARROWING_ACC_ID] = 1'b0;
            assign r_dp_in_req_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]  = 1'b0;
            assign r_dp_in_rsp_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]  = 1'b0;
            assign r_dp_out_rsp_acc[stream_acc_pkg::NARROWING_ACC_ID]       = '0;
            assign r_dp_out_rsp_valid_acc[stream_acc_pkg::NARROWING_ACC_ID] = 1'b0;
            assign ar_out_req_acc[stream_acc_pkg::NARROWING_ACC_ID]         = '0;
            assign ar_out_valid_acc[stream_acc_pkg::NARROWING_ACC_ID]       = 1'b0;
            assign ar_in_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]        = 1'b0;
            assign r_buffer_out_acc[stream_acc_pkg::NARROWING_ACC_ID]       = '0;
            assign r_buffer_out_valid_acc[stream_acc_pkg::NARROWING_ACC_ID] = '0;
            assign buffer_in_ready_acc[stream_acc_pkg::NARROWING_ACC_ID]    = '0;
    end
        // Index 0 is fixed to forwarding
        assign r_dp_out_req_acc[0]        = r_dp_req_i;
        assign r_dp_out_req_valid_acc[0]  = r_dp_valid_i;
        assign r_dp_in_req_ready_acc[0]   = r_dp_out_req_ready_acc[0];
        assign r_dp_in_rsp_ready_acc[0]   = r_dp_out_rsp_ready_acc[0];
        assign r_dp_out_rsp_acc[0]        = r_dp_rsp_acc_ru;
        assign r_dp_out_rsp_valid_acc[0]  = r_dp_in_rsp_valid_acc[0];
        assign ar_out_req_acc[0]          = ar_req_i;
        assign ar_out_valid_acc[0]        = ar_in_valid_acc[0];
        assign ar_in_ready_acc[0]         = ar_out_ready_acc[0];
        assign buffer_in_ready_acc[0]     = r_buffer_out_ready_acc[0];
        assign r_buffer_out_acc[0]        = buffer_in;
        assign r_buffer_out_valid_acc[0]    = buffer_in_valid_acc[0];
    
    
    
    end else begin : gen_no_r_stream_acc
            // connect to 0 all acc_wu signals
        assign r_dp_req_acc_ru           = r_dp_req_i;
        assign r_dp_req_valid_acc_ru     = r_dp_valid_i;
        assign r_dp_ready_o              = r_dp_req_ready_acc_ru;
        assign ar_req_acc_ru             = ar_req_i;
        assign ar_req_valid_acc_ru       = ar_valid_i;
        assign ar_ready_o                = ar_req_ready_acc_ru;
        assign r_buffer_out_acc_df       = buffer_in;
        assign r_buffer_out_valid_acc_df = buffer_in_valid;
        assign buffer_in_ready           = r_buffer_out_ready_acc_df;
        assign r_dp_rsp_o                = r_dp_rsp_acc_ru;
        assign r_dp_valid_o              = r_dp_rsp_valid_acc_ru;
        assign r_dp_rsp_ready_acc_ru     = r_dp_ready_i;
    end


%endif




    //--------------------------------------
    // Read Ports
    //--------------------------------------

% for read_port in used_read_protocols:
% if one_read_port and one_write_port:
%  if streaming_accel:
${rendered_stream_acc_read_ports[read_port]}
% else:
${rendered_read_ports[read_port]}
% endif
% else:
${rendered_read_ports[read_port]}
% endif
% endfor
% if not one_read_port:
    //--------------------------------------
    // Read Multiplexers
    //--------------------------------------

    always_comb begin : gen_read_meta_channel_multiplexer
        case(ar_req_i.src_protocol)
% for rp in used_read_protocols:
        idma_pkg::${database[rp]['protocol_enum']}: ar_ready_o = ${rp}_ar_ready;
% endfor
        default:       ar_ready_o = 1'b0;
        endcase
    end

    always_comb begin : gen_read_multiplexer
        if (r_dp_valid_i) begin
            case(r_dp_req_i.src_protocol)
% for rp in used_read_protocols:
            idma_pkg::${database[rp]['protocol_enum']}: begin
                r_chan_valid_o  = ${rp}_r_chan_valid;
                r_chan_ready_o  = ${rp}_r_chan_ready;

                r_dp_ready_o    = ${rp}_r_dp_ready;
                r_dp_rsp_o      = ${rp}_r_dp_rsp;
                r_dp_valid_o    = ${rp}_r_dp_valid;

                buffer_in       = ${rp}_buffer_in;
                buffer_in_valid = ${rp}_buffer_in_valid;
            end
% endfor
            default: begin
                r_chan_valid_o  = 1'b0;
                r_chan_ready_o  = 1'b0;

                r_dp_ready_o    = 1'b0;
                r_dp_rsp_o      = '0;
                r_dp_valid_o    = 1'b0;

                buffer_in       = '0;
                buffer_in_valid = '0;
            end
            endcase
        end else begin
            r_chan_valid_o  = 1'b0;
            r_chan_ready_o  = 1'b0;

            r_dp_ready_o    = 1'b0;
            r_dp_rsp_o      = '0;
            r_dp_valid_o    = 1'b0;

            buffer_in       = '0;
            buffer_in_valid = '0;
        end
    end

% endif
    //--------------------------------------
    // Read Barrel shifter
    //--------------------------------------
% if accel_condition:
    assign buffer_in_tmp = {r_buffer_out_acc_df, r_buffer_out_acc_df} >> (r_dp_req_i.shift * 8);
    assign buffer_in_shifted = buffer_in_tmp[$bits(buffer_in_shifted)/8-1:0];
% else:
    assign buffer_in_tmp = {buffer_in, buffer_in} >> (r_dp_req_i.shift * 8);
    assign buffer_in_shifted = buffer_in_tmp[$bits(buffer_in_shifted)/8-1:0];
%endif
    //--------------------------------------
    // Buffer
    //--------------------------------------

    idma_dataflow_element #(
        .BufferDepth   ( BufferDepth   ),
        .StrbWidth     ( StrbWidth     ),
        .PrintFifoInfo ( PrintFifoInfo ),
        .strb_t        ( strb_t        ),
        .byte_t        ( byte_t        )
    ) i_dataflow_element (
        .clk_i       ( clk_i                    ),
        .rst_ni      ( rst_ni                   ),
        .testmode_i  ( testmode_i               ),
        .data_i      ( buffer_in_shifted        ),
        %  if accel_condition:
        .valid_i     ( r_buffer_out_valid_acc_df  ),
        .ready_o     ( r_buffer_out_ready_acc_df  ),
        %  else:
        .valid_i     ( buffer_in_valid          ),
        .ready_o     ( buffer_in_ready          ),
        % endif
        .data_o      ( buffer_out               ),
        .valid_o     ( buffer_out_valid         ),
        .ready_i     ( buffer_out_ready_shifted )
    );
    //--------------------------------------
    // Write Barrel shifter
    //--------------------------------------

    assign buffer_out_tmp           = {buffer_out, buffer_out} >> (w_dp_req_i.shift*8);
    assign buffer_out_shifted       = buffer_out_tmp[$bits(buffer_out_shifted)/8-1:0];
    assign buffer_out_valid_shifted = strb_t'({buffer_out_valid, buffer_out_valid} >>   w_dp_req_i.shift);
    assign buffer_out_ready_shifted = strb_t'({buffer_out_ready, buffer_out_ready} >> - w_dp_req_i.shift);

%  if streaming_accel:
    w_dp_req_t w_dp_req_acc_wu;
    logic w_dp_req_valid_acc_wu;
    logic w_dp_req_ready_acc_wu;

    w_dp_rsp_t w_dp_rsp_acc_wu;
    logic w_dp_rsp_valid_acc_wu;
    logic w_dp_rsp_ready_acc_wu;
    
    write_meta_channel_t aw_req_acc_wu;
    logic aw_req_valid_acc_wu;
    logic aw_req_ready_acc_wu;

    byte_t [StrbWidth-1:0] buffer_out_acc_wu;
    strb_t buffer_out_ready_acc_wu;
    strb_t buffer_out_valid_acc_wu;

    if (StreamingAccelerator && NumWStreamAcc > 0) begin: gen_w_stream_accelerator
        // Signals
        // Accelerator <--> write unit
        // Output req from each acc
        // TODO: use 0 as the index of the normal DMA function
        w_dp_req_t [NumWStreamAcc:0] w_dp_out_req_acc;
        logic [NumWStreamAcc:0] w_dp_out_req_valid_acc;
        logic [NumWStreamAcc:0] w_dp_out_req_ready_acc;
        // Input if
        logic [NumWStreamAcc:0]     w_dp_in_req_valid_acc;
        logic [NumWStreamAcc:0]     w_dp_in_req_ready_acc;
        // From write unit to each acc
        logic [NumWStreamAcc:0]     w_dp_in_rsp_valid_acc;
        logic [NumWStreamAcc:0]     w_dp_in_rsp_ready_acc;
        // Output rsp interface, from acc
        w_dp_rsp_t [NumWStreamAcc:0]     w_dp_out_rsp_acc;
        logic [NumWStreamAcc:0]     w_dp_out_rsp_valid_acc;
        logic [NumWStreamAcc:0]     w_dp_out_rsp_ready_acc;
        

        // Input AW
        logic [NumWStreamAcc:0]     aw_valid_acc;
        logic [NumWStreamAcc:0]     aw_ready_acc;
        // AW from accelerator to write unit
        write_meta_channel_t [NumWStreamAcc:0] aw_req_acc;
        logic [NumWStreamAcc:0]     aw_req_valid_acc;
        logic [NumWStreamAcc:0]     aw_req_ready_acc;


        // input buffer to accel
        strb_t [NumWStreamAcc:0]     buffer_in_valid_acc;
        strb_t [NumWStreamAcc:0]     buffer_in_ready_acc;


        // Wvalid signal
    %  if llc_coh:
        /// Write valid sent to downstream goes back
        /// This is used to throttle the read requests in case of LLC to LLC transfers
        logic [NumWStreamAcc:0] wvalid_acc;

        // Wvalid assign
        assign wvalid_o = wvalid_acc[w_dp_req_i.stream_acc_id];

    %  endif

        byte_t [NumWStreamAcc:0] [StrbWidth-1:0] buffer_out_acc; // TODO: check width
        strb_t [NumWStreamAcc:0] buffer_out_ready_acc;
        strb_t [NumWStreamAcc:0] buffer_out_valid_acc;


        // Demux input signals
        // -------------------
        // stream_acc_id = 0 means no streaming accelerator is active (normal DMA transfer)
        always_comb begin :  w_acc_demux
            for (int unsigned i = 0; i <= NumWStreamAcc; i++) begin : gen_streaming_accelerator_ports
                // input interface
                w_dp_in_req_valid_acc[i] = (w_dp_req_i.stream_acc_id == (i)) ? w_dp_valid_i : 1'b0;
                aw_valid_acc[i]      = (w_dp_req_i.stream_acc_id == (i)) ? aw_valid_i  : 1'b0;
                // axi_write unit if
                w_dp_out_req_ready_acc[i] = (w_dp_req_i.stream_acc_id == (i)) ? w_dp_req_ready_acc_wu : 1'b0;
                w_dp_in_rsp_valid_acc[i]  = (w_dp_req_i.stream_acc_id == (i)) ? w_dp_rsp_valid_acc_wu : 1'b0;
                aw_req_ready_acc[i]   = (w_dp_req_i.stream_acc_id == (i)) ? aw_req_ready_acc_wu : 1'b0;
                // Out buffer
                buffer_out_ready_acc[i] = (w_dp_req_i.stream_acc_id == (i)) ? buffer_out_ready_acc_wu : 1'b0;
                // Output interface
                w_dp_out_rsp_ready_acc[i] = (w_dp_req_i.stream_acc_id == (i)) ? w_dp_ready_i : 1'b0;
                // Input buffer to accel
                buffer_in_valid_acc[i] = (w_dp_req_i.stream_acc_id == (i)) ? buffer_out_valid_shifted : 1'b0;
            end
        end
    
        // Mux output signals
        // ------------------
        // Input/ output interface
        assign w_dp_ready_o = w_dp_in_req_ready_acc[w_dp_req_i.stream_acc_id];
        assign aw_ready_o = aw_ready_acc[w_dp_req_i.stream_acc_id];
        assign w_dp_rsp_o = w_dp_out_rsp_acc[w_dp_req_i.stream_acc_id];
        assign w_dp_valid_o = w_dp_out_rsp_valid_acc[w_dp_req_i.stream_acc_id];


        // Out buffer to axi_write unit
        assign buffer_out_valid_acc_wu = buffer_out_valid_acc[w_dp_req_i.stream_acc_id];
        assign buffer_out_acc_wu = buffer_out_acc[w_dp_req_i.stream_acc_id];

        // Write unit
        assign w_dp_req_valid_acc_wu = w_dp_in_req_valid_acc[w_dp_req_i.stream_acc_id];
        assign w_dp_req_acc_wu = w_dp_out_req_acc[w_dp_req_i.stream_acc_id];
        assign w_dp_rsp_ready_acc_wu = w_dp_in_rsp_ready_acc[w_dp_req_i.stream_acc_id];
        // Write unit AW
        assign aw_req_acc_wu = aw_req_acc[w_dp_req_i.stream_acc_id];
        assign aw_req_valid_acc_wu = aw_req_valid_acc[w_dp_req_i.stream_acc_id];

        // In buffer to accel
        assign buffer_out_ready = buffer_in_ready_acc[w_dp_req_i.stream_acc_id];

        //---------------------
        // Widening accelerator
        //---------------------
        if (WideningUnit) begin: gen_widening_accelerator
            widening_unit #(
                .BufferDepth      ( BufferDepth     ),
                .BusDataWidth     ( DataWidth       ),
                .WidenedDataWidth ( WideningDataWidth  ),
                .Max1DTxWidth     ( WideningMax1DTxWidth ),
                %  if llc_coh:    
                .LLC_Legalizer    (LLC_Legalizer),
                % else:
                .LLC_Legalizer    (1'b0),
                % endif
                .byte_t           ( byte_t          ),
                .data_t           ( data_t          ),
                .strb_t           ( strb_t          ),
                .w_dp_req_t       ( w_dp_req_t      ),
                .w_dp_rsp_t       ( w_dp_rsp_t      ),
                .aw_chan_t        ( write_meta_channel_t ),
                .write_req_t      ( axi_req_t ),
                .write_rsp_t      ( axi_rsp_t ),
                .stream_acc_t     ( stream_acc_t )
            ) i_widening_write (
                .clk_i            (clk_i),
                .rst_ni           (rst_ni),
                .testmode_i       (testmode_i),
                //.dp_poison_i      (dp_poison_i),
                .widening_req_i    (widening_req_i     ),
                .w_dp_req_i        (w_dp_req_i),
                .w_dp_req_valid_i  (w_dp_in_req_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_req_ready_o  (w_dp_in_req_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_req_o        (w_dp_out_req_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_req_valid_o  (w_dp_out_req_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_req_ready_i  (w_dp_out_req_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_rsp_i        (w_dp_rsp_acc_wu), // TODO: check, from write unit directly
                .w_dp_rsp_valid_i  (w_dp_in_rsp_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_rsp_ready_o  (w_dp_in_rsp_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_rsp_o        (w_dp_out_rsp_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_rsp_valid_o  (w_dp_out_rsp_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .w_dp_rsp_ready_i  (w_dp_out_rsp_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .aw_req_i          (aw_req_i),
                .aw_valid_i        (aw_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .aw_ready_o        (aw_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .aw_req_o          (aw_req_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .aw_valid_o        (aw_req_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .aw_ready_i        (aw_req_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .wvalid_i          (axi_write_req_o.w_valid),
                .wready_i          (axi_write_rsp_i.w_ready),
                %  if llc_coh: 
                .wvalid_o          (wvalid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                % else:
                .wvalid_o          (),
                % endif
                // Input buffer interface
                .buffer_in_i      (buffer_out_shifted       ),
                .buffer_in_valid_i(buffer_in_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .buffer_in_ready_o(buffer_in_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]),  // TODO: careful to this signal
                .buffer_out_o     (buffer_out_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .buffer_out_valid_o (buffer_out_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]),
                .buffer_out_ready_i (buffer_out_ready_acc[stream_acc_pkg::WIDENING_ACC_ID])
            );

        end else begin: gen_no_widening_accelerator
            // Tie off widening accelerator signals
            assign w_dp_out_req_acc[stream_acc_pkg::WIDENING_ACC_ID]       = '0;
            assign w_dp_out_req_valid_acc[stream_acc_pkg::WIDENING_ACC_ID] = 1'b0;
            assign w_dp_in_req_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]  = 1'b0;
            assign w_dp_in_rsp_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]  = 1'b0;
            assign w_dp_out_rsp_acc[stream_acc_pkg::WIDENING_ACC_ID]       = '0;
            assign w_dp_out_rsp_valid_acc[stream_acc_pkg::WIDENING_ACC_ID] = 1'b0;
            assign aw_req_acc[stream_acc_pkg::WIDENING_ACC_ID]             = '0;
            assign aw_req_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]       = 1'b0;
            assign aw_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]           = 1'b0;
            //assign buffer_in_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]    = '0;
            assign buffer_out_acc[stream_acc_pkg::WIDENING_ACC_ID]         = '0;
            assign buffer_out_valid_acc[stream_acc_pkg::WIDENING_ACC_ID]   = '0;
            assign buffer_in_ready_acc[stream_acc_pkg::WIDENING_ACC_ID]   = '0;
        end
        
        // Index 0 is fixed to forwarding
        assign w_dp_out_req_acc[0]        = w_dp_req_i;
        assign w_dp_out_req_valid_acc[0]  = w_dp_valid_i;
        assign w_dp_in_req_ready_acc[0]   = w_dp_out_req_ready_acc[0];
        assign w_dp_in_rsp_ready_acc[0]   = w_dp_out_rsp_ready_acc[0];
        assign w_dp_out_rsp_acc[0]        = w_dp_rsp_acc_wu;
        assign w_dp_out_rsp_valid_acc[0]  = w_dp_in_rsp_valid_acc[0];
        assign aw_req_acc[0]              = aw_req_i;
        assign aw_req_valid_acc[0]        = aw_valid_acc[0];
        assign aw_ready_acc[0]            = aw_req_ready_acc[0];
        assign wvalid_acc[0]              = axi_write_req_o.w_valid;
        assign buffer_in_ready_acc[0]     = buffer_out_ready_acc[0];
        assign buffer_out_acc[0]          = buffer_out_shifted;
        assign buffer_out_valid_acc[0]    = buffer_in_valid_acc[0];
    
    end else begin : gen_no_streaming_acc
        // connect to 0 all acc_wu signals
        assign w_dp_req_acc_wu       = '0;
        assign w_dp_req_valid_acc_wu = 1'b0;
        assign w_dp_req_ready_acc_wu = 1'b0;
        assign aw_req_acc_wu         = '0;
        assign aw_req_valid_acc_wu   = 1'b0;
        assign aw_req_ready_acc_wu   = 1'b0;
        assign buffer_out_acc_wu     = '0;
        assign buffer_out_valid_acc_wu = '0;
        assign buffer_out_ready_acc_wu = '0;
        assign w_dp_rsp_acc_wu       = '0;
        assign w_dp_rsp_valid_acc_wu = 1'b0;
        assign w_dp_rsp_ready_acc_wu = 1'b0;
        // wvalid
        assign wvalid_o = axi_write_req_o.w_valid;
    end


%endif


% if not one_write_port:
// TODO:
// Careful: multi-port and streaming accelerator generation not supported yet
    //--------------------------------------
    // Write Request Demultiplexer
    //--------------------------------------

    // Split write request to write response fifo and write ports
    stream_fork #(
        .N_OUP ( 2 )
    ) i_write_stream_fork (
        .clk_i   ( clk_i                                    ),
        .rst_ni  ( rst_ni                                   ),
        .valid_i ( w_dp_valid_i                             ),
        .ready_o ( w_dp_ready_o                             ),
        .valid_o ( { w_resp_fifo_in_valid, w_dp_req_valid } ),
        .ready_i ( { w_resp_fifo_in_ready, w_dp_req_ready } )
    );

    // Demux write request to correct write port
    always_comb begin : gen_write_multiplexer
        case(w_dp_req_i.dst_protocol)
% for wp in used_write_protocols:
        idma_pkg::${database[wp]['protocol_enum']}: begin
            w_dp_req_ready   = ${wp}_w_dp_ready;
            buffer_out_ready = ${wp}_buffer_out_ready;
        end
% endfor
        default: begin
            w_dp_req_ready   = 1'b0;
            buffer_out_ready = '0;
        end
        endcase
    end

    // Demux write meta channel to correct write port
    always_comb begin : gen_write_meta_channel_multiplexer
        case(aw_req_i.dst_protocol)
% for wp in used_write_protocols:
        idma_pkg::${database[wp]['protocol_enum']}: aw_ready_o = ${wp}_aw_ready;
% endfor
        default:       aw_ready_o = 1'b0;
        endcase
    end

% endif
    //--------------------------------------
    // Write Ports
    //--------------------------------------

% for write_port in used_write_protocols:
%  if streaming_accel:
    if (StreamingAccelerator) begin: gen_axi_write_acc_if
    
    ${rendered_stream_acc_write_ports[write_port]}
    end else begin: gen_no_axi_write_acc_if
    // TODO: check
    ${rendered_write_ports[write_port]}
    end
% else :
${rendered_write_ports[write_port]}
% endif
% endfor

%if not one_write_port:
    //--------------------------------------
    // Write Response FIFO
    //--------------------------------------
    // Needed to be able to route the write reponses properly
    // Insert when data write happens
    // Remove when write response comes

    stream_fifo_optimal_wrap #(
        .Depth        ( NumAxInFlight        ),
        .type_t       ( idma_pkg::protocol_e ),
        .PrintInfo    ( PrintFifoInfo        )
    ) i_write_response_fifo (
        .clk_i      ( clk_i                                          ),
        .rst_ni     ( rst_ni                                         ),
        .testmode_i ( testmode_i                                     ),
        .flush_i    ( 1'b0                                           ),
        .usage_o    ( /* NOT CONNECTED */                            ),
        .data_i     ( w_dp_req_i.dst_protocol                        ),
        .valid_i    ( w_resp_fifo_in_valid && w_resp_fifo_in_ready   ),
        .ready_o    ( w_resp_fifo_in_ready                           ),
        .data_o     ( w_resp_fifo_out_protocol                       ),
        .valid_o    ( w_resp_fifo_out_valid                          ),
        .ready_i    ( w_resp_fifo_out_ready && w_resp_fifo_out_valid )
    );

    //--------------------------------------
    // Write Request Demultiplexer
    //--------------------------------------

    // Mux write port responses
    always_comb begin : gen_write_reponse_multiplexer
        w_dp_rsp_mux       = '0;
        w_dp_rsp_mux_valid = 1'b0;
% for wp in used_write_protocols:
        ${wp}_w_dp_rsp_ready = 1'b0;
% endfor
        if ( w_resp_fifo_out_valid ) begin
            case(w_resp_fifo_out_protocol)
% for wp in used_write_protocols:
            idma_pkg::${database[wp]['protocol_enum']}: begin
                w_dp_rsp_mux_valid = ${wp}_w_dp_rsp_valid;
                w_dp_rsp_mux       = ${wp}_w_dp_rsp;
                ${wp}_w_dp_rsp_ready = w_dp_rsp_mux_ready;
            end
% endfor
            default: begin
                w_dp_rsp_mux_valid = 1'b0;
                w_dp_rsp_mux       = '0;
            end
            endcase
        end
    end

    // Fall through register for the write response to be ready
    fall_through_register #(
        .T ( w_dp_rsp_t )
    ) i_write_rsp_channel_reg (
        .clk_i      ( clk_i      ),
        .rst_ni     ( rst_ni     ),
        .clr_i      ( 1'b0       ),
        .testmode_i ( testmode_i ),

        .valid_i ( w_dp_rsp_mux_valid ),
        .ready_o ( w_dp_rsp_mux_ready ),
        .data_i  ( w_dp_rsp_mux       ),

        .valid_o ( w_dp_rsp_valid ),
        .ready_i ( w_dp_rsp_ready ),
        .data_o  ( w_dp_rsp_o     )
    );

    // Join write response fifo and write port responses
    stream_join #(
        .N_INP ( 2 )
    ) i_write_stream_join (
        .inp_valid_i ( { w_resp_fifo_out_valid, w_dp_rsp_valid } ),
        .inp_ready_o ( { w_resp_fifo_out_ready, w_dp_rsp_ready } ),

        .oup_valid_o ( w_dp_valid_o ),
        .oup_ready_i ( w_dp_ready_i )
    );

% endif
    //--------------------------------------
    // Module Control
    //--------------------------------------
    assign r_dp_busy_o   = r_dp_valid_i;
    assign w_dp_busy_o   = w_dp_valid_i | w_dp_ready_o;
    assign buffer_busy_o = |buffer_out_valid;

endmodule
