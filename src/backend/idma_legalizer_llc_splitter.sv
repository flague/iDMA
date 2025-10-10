// Copyright 2025 Politecnico di Torino and EPFL.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: idma_legalizer_llc_splitter.sv
// Author: Flavia Guella
// Date: 11/09/2025
// Description: Legalizer module implementing a LLC splitter.
// Transactions from the DMA with both src and dst in AXI LLC must be split
// so that the DMA (and downstream fifos) are available to keep all received data
// without stalling the pipeline of the LLC, eventually causing a deadlock.
// This module dinamically splits the incoming requests based on the number of
// available slots in the LLC path, which is updated based on the wvalid received
// from the write channel.
// It does not support max_llen_i as the page splitter will take care of that constraint.
// And in a real system with a LLC we assume the two are coupled

// The constraint on max_llen can be easily integrated if needed together with
// the MinAvailSlots static one.

module idma_legalizer_llc_splitter #(
  /// Max number of rvalid that can be in flight, while no wvalid is received
  /// This should correspond to the size of the READ FIFOs in between the DMA and LLC path 
  parameter int unsigned MaxReadInFlight = 32'd16, // In elements of DataType
  /// Minimum length of a burst request that can be sent
  parameter int unsigned MinAvailSlots  = 32'd2, // In elements of DataType
  /// Data Type of the burst transfers used by the DMA
  parameter int unsigned DataType       = 8, // in bytes
  /// Type of the byte length signal
  /// As max burst is 256, theoric max is 256*DataType
  parameter type llc_len_t = logic[31:0],
  // Type representing max transfer length in byte
  parameter type tf_len_t  = logic[31:0],
  localparam int unsigned LogDataType = $clog2(DataType)
) (
  input  logic clk_i,
  input  logic rst_ni,
  
  // Incoming 1D request accepted
  // ----------------------------
  input  logic req_accepted_i,
  
  // Enable splitting
  // ----------------
  input  logic splitter_en_i,
  // Current transfer length in bytes
  // --------------------------------
  input  logic [7:0] words_transfer_i, //max burst size is 257
  input  logic transfer_valid_i,
  
  // Remaining bytes to be transferred
  // ---------------------------------
  input  tf_len_t rem_bytes_i,

  // Wvalid from the write channel
  // -----------------------------
  input  logic wvalid_i,
  
  // Current available bytes
  // -----------------------
  output llc_len_t num_bytes_to_llc_o,

  // Valid/Ready to/from downstream
  // ------------------------------
  output logic req_valid_o
);

//-----------------
// Internal signals
//-----------------

// FSM States
// -----------
typedef enum logic [1:0] {
  RESET     = 2'd0,
  IDLE      = 2'd1,
  UPD_SLOTS = 2'd2,
 // WAIT_LAST = 2'd3
} state_t;

state_t curr_state, next_state;

// Words trackers
// --------------
llc_len_t curr_avail_words, next_avail_words, upd_avail_words;

//--------------
// State machine
//--------------

always_comb begin : proc_fsm
  next_state = curr_state; // default
  case (curr_state)
    RESET: begin
      next_state = IDLE;
    end

    IDLE: begin
      if (req_accepted_i && splitter_en_i) begin
        next_state = UPD_SLOTS;
      end
    end
    UPD_SLOTS: begin
      if (splitter_en_i) // should be disabled only when all burst have been sent (check)
        next_state = UPD_SLOTS; // stay in this state until the end of the split transfers
      else 
        next_state = IDLE; // if not splitting, go back to IDLE after one iteration
    end
    //WAIT_LAST: begin
    //  if (req_accepted_i && splitter_en_i) begin
    //    next_state = UPD_SLOTS; // new request to split
    //  end else if (req_accepted_i && !splitter_en_i) begin
    //    next_state = IDLE; // new request but no splitting needed
    //  end else if (curr_avail_words == MaxReadInFlight)begin
    //    next_state = IDLE; // back to idle
    //  end
    //end
    default: begin
      next_state = IDLE;
    end
  endcase
end

//---------------
// Internal logic
//---------------

always_comb begin : internal_logic
  next_avail_words = curr_avail_words; // default
  upd_avail_words  = curr_avail_words; // default
  case (curr_state)
    RESET: ;
    IDLE: begin
      upd_avail_words = MaxReadInFlight;
      if (splitter_en_i && req_accepted_i && transfer_valid_i) begin // added the first two NOW
          next_avail_words = MaxReadInFlight - words_transfer_i - 1;
      end else begin
        next_avail_words = MaxReadInFlight; // reset to all availables
      end
    end
    UPD_SLOTS: begin
      upd_avail_words = curr_avail_words + wvalid_i;
      // if rem_bytes are unaligned, they could require a +1 word transfer
      if (upd_avail_words < MinAvailSlots && upd_avail_words <= ((rem_bytes_i >> LogDataType) + 1)) begin
        next_avail_words = upd_avail_words;
      end else begin
        if (transfer_valid_i) begin
          next_avail_words = upd_avail_words - words_transfer_i - 1;
        end else begin
          next_avail_words = upd_avail_words; // offer the currently available words
        end
      end
    end
    //WAIT_LAST: begin
    //  // wait until all the read data have been written to the LLC
    //  upd_avail_words  = curr_avail_words + wvalid_i;
    //  if (upd_avail_words < MinAvailSlots && upd_avail_words <= ((rem_bytes_i >> LogDataType) + 1)) begin
    //    next_avail_words = upd_avail_words;
    // As it is will cause an error in case of splitter_en_i == 0 and transfer_valid_i == 1
    // next_avail_words becomes a negative value, so must check this condition here, in case
    //  end else begin
    //    if (transfer_valid_i) begin
    //      next_avail_words = upd_avail_words - words_transfer_i - 1;
    //    end else begin
    //      next_avail_words = upd_avail_words; // offer the currently available words
    //    end
    //  end
    //end
    default : ;
  endcase
end


//-------------
// Output logic
//-------------
always_comb begin : output_logic
  num_bytes_to_llc_o = (MaxReadInFlight-1) << LogDataType; // default
  req_valid_o = 1'b0; // default
  case (curr_state)
    RESET: ;
    IDLE: begin
      req_valid_o = 1'b1;
      //if (req_accepted_i && splitter_en_i) begin
      //  num_bytes_to_llc_o = (MaxReadInFlight-1) << LogDataType; // offer the currently available bytes
      //end
    end
    UPD_SLOTS: begin
      // Do not forward any request until there are enough available bytes
      if (upd_avail_words < MinAvailSlots && upd_avail_words <= ((rem_bytes_i >> LogDataType) + 1)) begin
        num_bytes_to_llc_o = '0;
        req_valid_o = 1'b0;
      end else begin
        req_valid_o = 1'b1;
        //if ((upd_avail_words-1) == 0) // should never happen due to the +1 in the rem_bytes check
        //  num_bytes_to_llc_o = DataType; // offer at least one data type
        //else
        num_bytes_to_llc_o = (upd_avail_words-1) << LogDataType; // offer the currently available bytes
      end
    end
    //WAIT_LAST: begin
    //  if (req_accepted_i && !splitter_en_i) begin
    //    req_valid_o = 1'b1; // new request but no splitting needed
    //  end else if (req_accepted_i && splitter_en_i) begin
    //    if (upd_avail_words < MinAvailSlots && upd_avail_words <= ((rem_bytes_i >> LogDataType) + 1)) begin
    //      num_bytes_to_llc_o = '0;
    //      req_valid_o = 1'b0;
    //    end else begin
    //      req_valid_o = 1'b1;
    //      num_bytes_to_llc_o = (upd_avail_words-1) << LogDataType; // offer the currently available bytes
    //    end
    //  end
    //end
    default : ;
  endcase
end



//----
// FFs
//----

// State FF
always_ff @(posedge clk_i or negedge rst_ni) begin : ff_state
  if (!rst_ni) begin
    curr_state <= RESET;
  end else begin
    curr_state <= next_state;
  end
end

// FF for available bytes
always_ff @(posedge clk_i or negedge rst_ni) begin : ff_avail_words
  if (!rst_ni) begin
    curr_avail_words <= MaxReadInFlight;
  end else begin
    curr_avail_words <= next_avail_words;
  end
end


endmodule
