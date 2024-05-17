////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	sdfrontend.v
// {{{
// Project:	SDIO SD-Card controller
//
// Purpose:	This is the "front-end" for the SDIO controller.  It's designed
//		to support all modes up to HS400 if OPT_SERDES is enabled,
//	or just the backwards compatibility modes (up to 50MHz) if not.
//
// Status:
//	OPT_DDR=0	(Without IDDR and ODDR hardware elements)
//		Verified in H/W for 1, 4, and 8b.  (Not yet for DDR)
//		No support for data strobe.
//	OPT_DDR=1	(With IDDR/ODDR hardware elements, but no SERDES)
//		Verified in H/W for 1 and 4b.  (Not yet for DDR, not yet for 8b)
//		No support for data strobe.
//	OPT_SERDES=1
//		NOT YET VERIFIED IN H/W
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2023-2024, Gisselquist Technology, LLC
// {{{
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
// }}}
// License:	GPL, v3, as defined and found on www.gnu.org,
// {{{
//		http://www.gnu.org/licenses/gpl.html
//
////////////////////////////////////////////////////////////////////////////////
//
`timescale		1ns / 1ps
`default_nettype	none
// }}}
module	sdfrontend #(
		// {{{
		parameter [0:0]	OPT_SERDES = 1'b0,
		parameter [0:0]	OPT_DDR = 1'b0,
		parameter [0:0]	OPT_DS = OPT_SERDES,
		parameter [0:0]	OPT_COLLISION = 1'b0,
		parameter	NUMIO = 8
		// }}}
	) (
		// {{{
		input	wire		i_clk, i_hsclk,
		// Configuration
		input	wire		i_reset,
		input	wire		i_cfg_ddr,
		input	wire		i_cfg_ds, i_cfg_dscmd,
		input	wire	[4:0]	i_sample_shift,
		// Control signals
		// Tx path
		// {{{
		// MSB "first" incoming data.
		input	wire	[7:0]	i_sdclk,
		// Verilator lint_off SYNCASYNCNET
		input	wire		i_cmd_en,
		// Verilator lint_on  SYNCASYNCNET
		input	wire		i_pp_cmd,	// Push/pull cmd lines
		input	wire	[1:0]	i_cmd_data,
		//
		input	wire		i_data_en, i_rx_en,
		input	wire		i_pp_data,	// Push/pull data lines
		input	wire	[31:0]	i_tx_data,
		// }}}
		output	wire		o_data_busy,
		// Synchronous Rx path
		// {{{
		output	wire	[1:0]	o_cmd_strb,
		output	wire	[1:0]	o_cmd_data,
		output	wire		o_cmd_collision,
		//
		output	wire	[1:0]	o_rx_strb,
		output	wire	[15:0]	o_rx_data,
		// }}}
		// Async Rx path
		// {{{
		output	wire		MAC_VALID,
		output	wire	[1:0]	MAC_DATA,
		output	wire		MAD_VALID,
		output	wire	[31:0]	MAD_DATA,
		// output	wire		MAD_LAST,
		// }}}
		// I/O ports
		// {{{
		output	wire			o_ck,
		input	wire			i_ds,
		//
`ifdef	VERILATOR
		output	wire			io_cmd_tristate,
		output	wire			o_cmd,
		input	wire			i_cmd,
		//
		output	wire	[NUMIO-1:0]	io_dat_tristate,
		output	wire	[NUMIO-1:0]	o_dat,
		input	wire	[NUMIO-1:0]	i_dat,
`else
		inout	wire			io_cmd,
		inout	wire	[NUMIO-1:0]	io_dat,
`endif
		// }}}
		output	wire	[31:0]	o_debug
		// }}}
	);

	// Local declarations
	// {{{
	genvar		gk;
	reg		dat0_busy, wait_for_busy;
	wire		raw_cmd;
	wire	[NUMIO-1:0]	raw_iodat;
	wire		w_cmd_collision;
`ifndef	VERILATOR
	wire			io_cmd_tristate, i_cmd, o_cmd;
	wire	[NUMIO-1:0]	io_dat_tristate, i_dat, o_dat;
`endif
	// }}}
	generate if (!OPT_SERDES && !OPT_DDR)
	begin : GEN_NO_SERDES
		// {{{
		// This is sort of the "No-PHY" option.  Maximum speed, when
		// using this option, is the incoming clock speed/2.  Without
		// SERDES support, there's no support for the DS (data strobe)
		// pin either.  Think of this as a compatibility mode.
		//
		// Fastest clock supported = incoming clock speed / 2.  That's
		// also the fastest clock supported *if you get lucky*.  It's
		// possible that there won't be enough sub-clock resolution
		// to land close enough to the middle of the eye at this
		// frequency.
		//
		wire		next_pedge, next_dedge;
		reg		resp_started, last_ck;
		reg	[1:0]	io_started;
		reg		r_cmd_data, r_cmd_strb, r_rx_strb;
		reg	[7:0]	r_rx_data;
		reg	[1:0]	ck_sreg, pck_sreg, ck_psreg;
		reg		sample_ck, cmd_sample_ck, sample_pck;

		assign	o_ck = i_sdclk[7];

		assign	io_cmd_tristate = (OPT_COLLISION && o_cmd_collision)
				|| !(i_cmd_en && (i_pp_cmd || !i_cmd_data[1]));
		assign	o_cmd = i_cmd_data[1];
		assign	raw_cmd = i_cmd;

		// assign	io_cmd = (io_cmd_tristate) ? i_cmd : o_cmd;


		assign	o_dat = i_tx_data[24 +: NUMIO];

		for(gk=0; gk<NUMIO; gk=gk+1)
		begin : FOREACH_IO
			assign	io_dat_tristate[gk] = !(i_data_en
					&& (i_pp_data || !i_tx_data[24+gk]));
		end

		// assign	io_dat = (o_dat & ~io_dat_tristate)
		//		| (i_dat & io_dat_tristate);

		assign	next_pedge = !last_ck && o_ck;
		assign	next_dedge = next_pedge || (i_cfg_ddr
					&& last_ck && !o_ck);

		assign	w_cmd_collision = OPT_COLLISION && io_cmd_tristate
				&& i_cmd_en && !i_cmd && next_pedge;
					// && !i_pp_cmd;

		if (OPT_COLLISION)
		begin : GEN_COLLISION
			reg	r_collision;

			always @(posedge i_clk)
			if (i_reset || !i_cmd_en)
				r_collision <= 1'b0;
			else if (w_cmd_collision)
				r_collision <= 1'b1;

			assign	o_cmd_collision = r_collision;
		end else begin : NO_COLLISION
			assign	o_cmd_collision = 1'b0;
		end

		initial	last_ck = 1'b0;
		always @(posedge i_clk)
			last_ck <= o_ck;

		// sample_ck
		// {{{
		initial	ck_sreg = 0;
		always @(posedge i_clk)
		if (i_reset || i_data_en)
			ck_sreg <= 0;
		else
			ck_sreg <= { ck_sreg[0], next_dedge };

		initial	sample_ck = 0;
		always @(*)
		if (i_data_en)
			sample_ck = 0;
		else
			// Verilator lint_off WIDTH
			sample_ck = { ck_sreg[1:0], next_dedge } >> i_sample_shift[4:3];
			// Verilator lint_on  WIDTH
		// }}}

		// sample_pck
		// {{{
		initial	ck_sreg = 0;
		always @(posedge i_clk)
		if (i_reset || i_data_en)
			ck_psreg <= 0;
		else
			ck_psreg <= { ck_sreg[0], next_pedge };

		initial	sample_ck = 0;
		always @(*)
		if (i_data_en)
			sample_pck = 0;
		else
			// Verilator lint_off WIDTH
			sample_pck = { ck_psreg[1:0],next_pedge } >> i_sample_shift[4:3];
			// Verilator lint_on  WIDTH
		// }}}

		// cmd_sample_ck: When do we sample the command line?
		// {{{
		always @(posedge i_clk)
		if (i_reset || i_cmd_en || i_cfg_dscmd)
			pck_sreg <= 0;
		else
			pck_sreg <= { pck_sreg[0], next_pedge };

		always @(*)
		if (i_cmd_en)
			cmd_sample_ck = 0;
		else
			// Verilator lint_off WIDTH
			cmd_sample_ck = { pck_sreg[1:0], next_pedge } >> i_sample_shift[4:3];
			// Verilator lint_on  WIDTH
		// }}}

		assign	raw_iodat = i_dat;

		always @(posedge i_clk)
		if (i_reset || i_cmd_en || i_cfg_dscmd)
			resp_started <= 1'b0;
		else if (!i_cmd && cmd_sample_ck)
			resp_started <= 1'b1;

		always @(posedge i_clk)
		if (i_reset || i_data_en || !i_rx_en || i_cfg_ds)
			io_started <= 2'b0;
		else if (i_cfg_ddr && io_started[0] && sample_ck)
			io_started <= 2'b11;
		else if (!i_dat[0] && sample_pck)
			io_started <= (i_cfg_ddr) ? 2'b01 : 2'b11;

		// dat0_busy, wait_for_busy
		// {{{
		initial	{ dat0_busy, wait_for_busy } = 2'b01;
		always @(posedge i_clk)
		if (i_reset || i_cmd_en || i_data_en)
		begin
			dat0_busy <= 1'b0;
			wait_for_busy <= 1'b1;
		end else if (wait_for_busy && !i_dat[0])
		begin
			dat0_busy <= 1'b1;
			wait_for_busy <= 1'b0;
		end else if (!wait_for_busy && i_dat[0])
			dat0_busy <= 1'b0;

		assign	o_data_busy = dat0_busy;
		// }}}

		always @(posedge i_clk)
		begin
			if (i_cmd_en || !cmd_sample_ck || i_cfg_dscmd)
				r_cmd_strb <= 1'b0;
			else if (!i_cmd || resp_started)
				r_cmd_strb <= 1'b1;
			else
				r_cmd_strb <= 1'b0;

			if (i_data_en || sample_ck == 0 || i_cfg_ds)
				r_rx_strb <= 1'b0;
			else if (io_started[1])
				r_rx_strb <= 1'b1;
			else
				r_rx_strb <= 1'b0;

			if (cmd_sample_ck)
				r_cmd_data <= i_cmd;
			if (sample_ck)
			begin
				r_rx_data <= 0;
				r_rx_data[NUMIO-1:0] <= i_dat;
			end
		end

		assign	o_cmd_strb = { r_cmd_strb, 1'b0 };
		assign	o_cmd_data = { r_cmd_data, 1'b0 };
		assign	o_rx_strb  = { r_rx_strb, 1'b0 };
		assign	o_rx_data  = { r_rx_data, 8'h0 };

		reg	[7:0]	w_out;
		always @(*)
		begin
			w_out = 0;
			w_out[NUMIO-1:0] = i_dat;
		end

		assign	o_debug = {
				i_cmd_en || i_data_en,
				5'h0,
				i_sdclk[7], 1'b0,
				i_cmd_en, i_cmd_data[1], i_cmd,
					(io_cmd_tristate) ? i_cmd: o_cmd,//w_cmd
					r_cmd_strb, r_cmd_data,		// 2b
				i_data_en, r_rx_strb, r_rx_data,	// 10b
				//
				((i_data_en) ? i_tx_data[31:24] : w_out) // 8b
				};

		// Keep Verilator happy
		// {{{
		// Verilator coverage_off
		// Verilator lint_off UNUSED
		wire	unused_no_serdes;
		assign	unused_no_serdes = &{ 1'b0,
				i_cfg_ds, i_ds,
				i_sdclk[6:0], i_tx_data[23:0],
				i_cmd_data[0], i_hsclk,i_sample_shift
				};
		// Verilator lint_on  UNUSED
		// Verilator coverage_on
		// }}}
		// }}}
	end else if (!OPT_SERDES && OPT_DDR)
	begin : GEN_IODDR_IO
		// {{{
		// Notes:
		// {{{
		// The idea is, if we only have DDR elements and no SERDES
		// elements, can we do better than with just IOs?
		//
		// The answer is, Yes.  Even though we aren't going to run at
		// 2x the clock speed w/o OPT_SERDES, we can output a DDR clk,
		// and we can also access sub-sample timing via IDDR elements.
		// Even in DDR mode, however, there will be no possibility of
		// two outputs per clock.
		//
		// Fastest clock supported = incoming clock speed
		//	Practically, you won't be likely to achieve this unless
		//	you get really lucky, but it is technically the fastest
		//	speed this version supports.
		// A more realistic speed will be the incoming clock speed / 2,
		//	and done with more reliability than the non-DDR mode.
		// }}}

		// Local declarations
		// {{{
		wire	[1:0]	w_cmd;
		wire		pre_dat	[15:0];
		reg	[15:0]	w_dat;
		wire	[1:0]	next_pedge, next_dedge;

		reg	[5:0]	ck_sreg, pck_sreg, ck_psreg;
		reg	[1:0]	sample_ck, cmd_sample_ck, sample_pck;
		reg		resp_started, last_ck, r_last_cmd_enabled,
				r_cmd_strb, r_cmd_data, r_rx_strb;
		wire	[1:0]	my_cmd_data;
		reg	[1:0]	io_started;
		reg	[7:0]	r_rx_data;
		reg	[1:0]	busy_delay;
		// Verilator lint_off UNUSED
		wire		io_clk_tristate, ign_clk;
		assign		ign_clk = o_ck;
		// Verilator lint_on  UNUSED
		// }}}

		// Clock
		// {{{
		xsdddr #(.OPT_BIDIR(1'b0))
		u_clk_oddr(
			.i_clk(i_clk), .i_en(1'b1),
			.i_data({ i_sdclk[7], i_sdclk[3] }),
			.io_pin_tristate(io_clk_tristate),
			.o_pin(o_ck),
			.i_pin(ign_clk),
			// Verilator lint_off PINCONNECTEMPTY
			.o_mine(),
			.o_wide()
			// Verilator lint_on  PINCONNECTEMPTY
		);
		// }}}

		// CMD
		// {{{
		always @(posedge i_clk)
			r_last_cmd_enabled <= i_cmd_en && i_pp_cmd;

		xsdddr #(.OPT_BIDIR(1'b1))
		u_cmd_ddr(
			.i_clk(i_clk),
			.i_en(i_reset || r_last_cmd_enabled
				|| (!o_cmd_collision && i_cmd_en
					&& (i_pp_cmd || !i_cmd_data[1]))),
			.i_data({(2){ i_reset || i_cmd_data[1] }}),
			.io_pin_tristate(io_cmd_tristate),
			.o_pin(o_cmd),
			.i_pin(i_cmd),
			.o_mine(my_cmd_data),
			.o_wide(w_cmd)
		);

		assign	raw_cmd = i_cmd;

		assign	w_cmd_collision = OPT_COLLISION && i_cmd_en && !i_pp_cmd
				&& |(my_cmd_data & ~w_cmd);

		if (OPT_COLLISION)
		begin : GEN_COLLISION
			reg	r_collision;

			always @(posedge i_clk)
			if (i_reset || !i_cmd_en || i_pp_cmd)
				r_collision <= 1'b0;
			else if (w_cmd_collision)
				r_collision <= 1'b1;

			assign	o_cmd_collision = r_collision;
		end else begin : NO_COLLISION
			assign	o_cmd_collision = 1'b0;
		end
		// }}}

		// DATA
		// {{{
		for(gk=0; gk<NUMIO; gk=gk+1)
		begin : DRIVE_DDR_IO
			wire	enable;

			assign	enable = i_reset || (i_data_en && (i_pp_data
						|| !i_tx_data[24+gk]));
			xsdddr #(.OPT_BIDIR(1'b1))
			u_dat_ddr(
				.i_clk(i_clk),
				.i_en(enable),
				.i_data({(2){ i_reset || i_tx_data[24+gk] }}),
				.io_pin_tristate(io_dat_tristate[gk]),
				.o_pin(o_dat[gk]),
				.i_pin(i_dat[gk]),
				// Verilator lint_off PINCONNECTEMPTY
				.o_mine(),
				// Verilator lint_on  PINCONNECTEMPTY
				.o_wide({ pre_dat[gk+8], pre_dat[gk] })
			);

			assign	raw_iodat[gk] = i_dat[gk];

		end for(gk=NUMIO; gk<8; gk=gk+1)
		begin : NO_DDR_IO
			assign	{ pre_dat[8+gk], pre_dat[gk] } = 2'b00;
		end


		integer	ipre;
		always @(*)
		begin
			for(ipre=0; ipre<16; ipre=ipre+1)
				w_dat[ipre] = pre_dat[ipre];
		end
		// }}}

		assign	next_pedge = { !last_ck && i_sdclk[7],
				!i_sdclk[7] && i_sdclk[3] };
		assign	next_dedge = next_pedge | (!i_cfg_ddr ? 2'b00
			: {last_ck && !i_sdclk[7], i_sdclk[7] && !i_sdclk[3]});

		// sample_ck
		// {{{
		initial	ck_sreg = 0;
		always @(posedge i_clk)
		if (i_data_en || i_cfg_ds)
			ck_sreg <= 0;
		else
			ck_sreg <= { ck_sreg[3:0], next_dedge };

		initial	sample_ck = 0;
		always @(*)
		if (i_data_en || !i_rx_en || i_cfg_ds)
			sample_ck = 0;
		else
			// Verilator lint_off WIDTH
			sample_ck = { ck_sreg[5:0], next_dedge } >> i_sample_shift[4:2];
			// Verilator lint_on  WIDTH
		// }}}

		// sample_pck -- positive edge data sampl clock
		// {{{
		initial	ck_sreg = 0;
		always @(posedge i_clk)
		if (i_data_en || i_cfg_ds)
			ck_psreg <= 0;
		else
			ck_psreg <= { ck_psreg[3:0], next_pedge };

		initial	sample_ck = 0;
		always @(*)
		if (i_data_en || !i_rx_en || i_cfg_ds)
			sample_pck = 0;
		else
			// Verilator lint_off WIDTH
			sample_pck = { ck_psreg[5:0], next_pedge } >> i_sample_shift[4:2];
			// Verilator lint_on  WIDTH
		// }}}

		// cmd_sample_ck: When do we sample the command line?
		// {{{
		always @(posedge i_clk)
		if (i_reset || i_cmd_en || r_last_cmd_enabled || i_cfg_dscmd)
			pck_sreg <= 0;
		else
			pck_sreg <= { pck_sreg[3:0], next_pedge };

		always @(*)
		if (i_cmd_en || r_last_cmd_enabled || i_cfg_dscmd)
			cmd_sample_ck = 0;
		else
			// Verilator lint_off WIDTH
			cmd_sample_ck = { pck_sreg[5:0], next_pedge } >> i_sample_shift[4:2];
			// Verilator lint_on  WIDTH
		// }}}

		always @(posedge i_clk)
		if (i_reset || i_cmd_en || r_last_cmd_enabled || i_cfg_dscmd)
			resp_started <= 1'b0;
		else if ((cmd_sample_ck != 0) && (cmd_sample_ck & w_cmd)==0)
			resp_started <= 1'b1;

		always @(posedge i_clk)
		if (i_reset || i_data_en || !i_rx_en || i_cfg_ds)
			io_started <= 2'b0;
		else if (sample_pck != 0
				&& ((sample_pck & { w_dat[8], w_dat[0] }) == 0))
		begin
			io_started[0] <= 1'b1;
			if (!i_cfg_ddr)
				io_started[1] <= 1'b1;
			else if (sample_pck[1] && sample_ck[0])
				io_started[1] <= 1'b1;
		end else if (io_started == 2'b01 && sample_ck != 0)
			io_started <= 2'b11;

		// dat0_busy, wait_for_busy, busy_delay
		// {{{
		initial	{ dat0_busy, wait_for_busy } = 2'b01;
		always @(posedge i_clk)
		if (i_cmd_en || i_data_en)
		begin
			dat0_busy <= 1'b0;
			wait_for_busy <= 1'b1;
			busy_delay <= -1;
		end else if (busy_delay != 0)
		begin
			dat0_busy <= 1'b0;
			wait_for_busy <= 1'b1;
			busy_delay <= busy_delay - 1;
		end else if (wait_for_busy && (cmd_sample_ck != 0)
				&& (cmd_sample_ck & {w_dat[8],w_dat[0]})==2'b0)
		begin
			dat0_busy <= 1'b1;
			wait_for_busy <= 1'b0;
		end else if (!wait_for_busy && (cmd_sample_ck != 0)
				&& (cmd_sample_ck & {w_dat[8],w_dat[0]})!=2'b0)
			dat0_busy <= 1'b0;

		assign	o_data_busy = dat0_busy;
		// }}}

		initial	last_ck = 1'b0;
		always @(posedge i_clk)
		begin
			last_ck <= i_sdclk[3];

			// The command response
			// {{{
			if (i_reset || i_cmd_en || cmd_sample_ck == 0 || i_cfg_dscmd)
			begin
				r_cmd_strb <= 1'b0;
				// r_cmd_data <= r_cmd_data;
			end else if (resp_started)
			begin
				r_cmd_strb <= 1'b1;
				r_cmd_data <= |(cmd_sample_ck & w_cmd);
			end else if ((cmd_sample_ck[1] && !w_cmd[1])
					||(cmd_sample_ck[0] && !w_cmd[0]))
			begin
				r_cmd_strb <= 1'b1;
				r_cmd_data <= 1'b0;
			end else
				r_cmd_strb <= 1'b0;
			// }}}

			// The data response
			// {{{
			if (i_data_en || sample_ck == 0 || i_cfg_ds)
				r_rx_strb <= 1'b0;
			else if (io_started[1])
				r_rx_strb <= 1'b1;
			else
				r_rx_strb <= 1'b0;
			// }}}

			if (sample_ck[1])
				r_rx_data <= w_dat[15:8];
			else
				r_rx_data <= w_dat[7:0];
		end

		assign	o_cmd_strb = { r_cmd_strb, 1'b0 };
		assign	o_cmd_data = { r_cmd_data, 1'b0 };
		assign	o_rx_strb  = { r_rx_strb, 1'b0 };
		assign	o_rx_data  = { r_rx_data, 8'h0 };

		reg	[7:0]	w_out;
		always @(*)
		begin
			w_out = 0;
			w_out[NUMIO-1:0] = w_dat[8 +: NUMIO]& w_dat[0 +: NUMIO];
		end

		assign	o_debug = {
				i_cmd_en || i_data_en, 2'h0, i_rx_en,
				sample_ck, i_sdclk[7], i_sdclk[3],
				i_cmd_en, i_cmd_data[1:0],
					(&w_cmd), r_cmd_strb, r_cmd_data,
				i_data_en, r_rx_strb, r_rx_data,
				//
				((i_data_en) ? i_tx_data[31:24] : w_out)
				};


		// Keep Verilator happy
		// {{{
		// Verilator coverage_off
		// Verilator lint_off UNUSED
		wire	unused_ddr;
		assign	unused_ddr = &{ 1'b0, i_hsclk,
				i_cfg_ds, i_ds, i_tx_data[23:0],
				i_sdclk[6:4], i_sdclk[2:0],
				i_sample_shift[1:0] };
		// Verilator lint_on  UNUSED
		// Verilator coverage_on
		// }}}
		// }}}
	end else begin : GEN_WIDE_IO
		// {{{
		// Generic PHY handler, designed to support up to HS400.
		// Outputs 4 data periods per incoming clock, and 8 clock values
		// per incoming clock--hence the outgoing clock may have a
		// 90 degree shift from the data.  When dealing with non-DS
		// data, the clock edge is detected on output, and a sample
		// controller decides when to sample it on input.
		//
		// Fastest clock supported = incoming clock speed * 2

		// Local declarations
		// {{{
		reg		r_last_cmd_enabled, r_last_enabled;
		reg	[1:0]	w_cmd_data;
		reg	[15:0]	r_rx_data;
		wire	[15:0]	w_rx_data;
		reg		last_ck;
		wire	[7:0]	next_ck_sreg, next_ck_psreg;
		reg	[23:0]	ck_sreg, ck_psreg;
		wire	[7:0]	next_pedge, next_nedge, wide_cmd_data,
				my_cmd_data;
		reg	[7:0]	sample_ck, sample_pck;
		reg	[1:0]	r_cmd_data;
		reg		busy_strb, busy_data;
		reg	[1:0]	r_rx_strb;
		reg	[1:0]	start_io;
		reg	[1:0]	io_started;
		reg		resp_started;
		reg	[1:0]	r_cmd_strb;
		reg	[23:0]	pck_sreg;
		reg	[7:0]	cmd_sample_ck;
		wire		busy_pin;
		reg	[1:0]	busy_delay;
		// }}}

		// Clock
		// {{{
		// Verilator lint_off UNUSED
		wire		io_clk_tristate, ign_clk_raw;
		wire	[7:0]	ign_clk_mine, ign_clk_wide;
		// Verilator lint_on  UNUSED

		xsdserdes8x #(.OPT_BIDIR(1'b0))
		u_clk_oserdes(
			.i_clk(i_clk),
			.i_hsclk(i_hsclk),
			.i_en(1'b1),
			.i_data(i_sdclk),
			.io_tristate(io_clk_tristate),
			.o_pin(o_ck),
			.i_pin(1'b0),
			// Verilator lint_off PINCONNECTEMPTY
			.o_raw(ign_clk_raw), .o_mine(ign_clk_mine),
			.o_wide(ign_clk_wide)
			// Verilator lint_on  PINCONNECTEMPTY
		);
		// }}}

		assign	next_pedge = { ~{last_ck, i_sdclk[7:1] } &  i_sdclk[7:0] };
		assign	next_nedge = i_cfg_ddr ? {  {last_ck, i_sdclk[7:1] } & ~i_sdclk[7:0] } : 8'h0;

		assign	next_ck_sreg = (i_data_en) ? 8'h0
				: { next_pedge | next_nedge };
		assign	next_ck_psreg = (i_data_en) ? 8'h0 : next_pedge;

		initial	last_ck = 0;
		always @(posedge i_clk)
			last_ck <= i_sdclk[0];

		// sample_ck
		// {{{
		// We use this for busy detection, as well as reception
		always @(posedge i_clk)
		if (i_reset || i_data_en
				|| (!wait_for_busy && (!i_rx_en || i_cfg_ds)))
			ck_sreg <= 0;
		else
			ck_sreg <= { ck_sreg[15:0], next_ck_sreg };

		initial	sample_ck = 0;
		always @(posedge i_clk)
		if (i_reset || i_data_en
				|| (!wait_for_busy && (!i_rx_en || i_cfg_ds)))
			sample_ck <= 0;
		else
			// Verilator lint_off WIDTH
			sample_ck <= { ck_sreg[23:0], next_ck_sreg } >> i_sample_shift;
			// Verilator lint_on  WIDTH
		// }}}

		// sample_pck
		// {{{
		always @(posedge i_clk)
		if (i_reset || !i_rx_en || i_data_en || i_cfg_ds)
			ck_psreg <= 0;
		else
			ck_psreg <= { ck_psreg[15:0], next_ck_psreg };

		initial	sample_pck = 0;
		always @(posedge i_clk)
		if (i_reset || !i_rx_en || i_data_en || i_cfg_ds)
			sample_pck <= 0;
		else
			// Verilator lint_off WIDTH
			sample_pck <= { ck_psreg[23:0], next_ck_psreg } >> i_sample_shift;
			// Verilator lint_on  WIDTH
		// }}}

		always @(posedge i_clk)
			r_last_enabled <= i_data_en && i_pp_data;

		for(gk=0; gk<NUMIO; gk=gk+1)
		begin : GEN_WIDE_DATIO
			// {{{
			wire		out_en;
			reg	[7:0]	out_pin;
			wire	[7:0]	in_pin;
			integer		ik;
			reg	[1:0]	lcl_data;

			always @(*)
			for(ik=0; ik<4; ik=ik+1)
				out_pin[ik*2 +: 2] = {(2){i_tx_data[ik*8+gk]}};

			assign	out_en=(i_data_en &&(i_pp_data || !out_pin[3]))
					|| r_last_enabled;

			xsdserdes8x #(
				.OPT_BIDIR(1'b1)
			) io_serdes(
				.i_clk(i_clk),
				.i_hsclk(i_hsclk),
				.i_en(out_en),
				.i_data(out_pin),
				.io_tristate(io_dat_tristate[gk]),
				.o_pin(o_dat[gk]),
				.i_pin(i_dat[gk]),
				// Verilator lint_off PINCONNECTEMPTY
				.o_mine(),
				// Verilator lint_on  PINCONNECTEMPTY
				.o_raw(raw_iodat[gk]), .o_wide(in_pin)
			);

			if (gk == 0)
			begin : GEN_START_SIGNAL
				always @(*)
				begin
					start_io[1] = (|sample_pck[7:4])
						&&(0 == (sample_pck[7:4]&in_pin[7:4]));
					start_io[0] = (|sample_pck[3:0])
						&&(0 == (sample_pck[3:0]&in_pin[3:0]));
				end

				assign	busy_pin = !in_pin[0];
			end

			always @(*)
			begin
				lcl_data[1] = |(sample_ck[7:4]&in_pin[7:4]);
				lcl_data[0] = |(sample_ck[3:0]&in_pin[3:0]);
			end

			assign	w_rx_data[8+gk] = lcl_data[1];
			assign	w_rx_data[  gk] = lcl_data[0];
			// }}}
		end

		for(gk=NUMIO; gk<8; gk=gk+1)
		begin : NULL_DATIO
			// {{{
			assign	w_rx_data[8+gk] = 1'b1;
			assign	w_rx_data[  gk] = 1'b1;

			// Keep Verilator happy
			// {{{
			// Verilator coverage_off
			// Verilator lint_off UNUSED
			wire	unused_outputs;
			assign	unused_outputs = &{ 1'b0 }; // , out_pin };
			// Verilator lint_on  UNUSED
			// Verilator coverage_on
			// }}}
			// }}}
		end

		// o_rx_strb, o_rx_data
		// {{{
		always @(posedge i_clk)
		if (i_reset || i_data_en || !i_rx_en || i_cfg_ds)
			io_started <= 2'b0;
		else if (!io_started[1])
		begin
			if (start_io[1] && (|sample_ck[3:0]))
				io_started <= 2'b11;
			else if (io_started[0])
				io_started[1] <= |sample_ck;
			else begin // if (!io_started[0] && start_io[0])
				io_started[0] <= |start_io;
				if (!i_cfg_ddr)
					io_started[1] <= |start_io;
			end
		end

		always @(posedge i_clk)
		if (i_reset || i_cfg_ds || !i_rx_en || i_data_en)
			r_rx_strb <= 2'b0;
		else if (sample_ck == 0)
			r_rx_strb <= 2'b0;
		else if (io_started == 0
				&& (|sample_pck[7:4]) && (|sample_pck[3:0])
				&& start_io[1])
		begin
			r_rx_strb <= 2'b10;
		end else if (io_started[1])
		begin
			r_rx_strb[1] <= (|sample_ck);
			r_rx_strb[0] <= (|sample_ck[7:4]) && (|sample_ck[3:0]);
		end else if (io_started[0]&& (|sample_ck[7:4]))
		begin
			r_rx_strb[1] <= (|sample_ck[3:0]);
			r_rx_strb[0] <= 1'b0;
		end else
			r_rx_strb <= 2'b0;

		always @(posedge i_clk)
		if (i_reset || i_cfg_ds)
			r_rx_data <= 16'h0;
		else begin
			if (io_started[1])
				r_rx_data[15:8] <= w_rx_data[15:8];
			else
				r_rx_data[15:8] <= w_rx_data[ 7:0];

			r_rx_data[7:0] <= w_rx_data[7:0];
		end

		assign	o_rx_strb = r_rx_strb;
		assign	o_rx_data = r_rx_data;
		// }}}

		// busy_strb, busy_data
		// {{{
		always @(*)
		begin
			busy_strb = (|sample_ck);
			if (|sample_ck[3:0] && !w_rx_data[0])
				busy_data = 1'b0;
			else if (|sample_ck[7:4] && !w_rx_data[8])
				busy_data = 1'b0;
			else
				busy_data = 1'b1;
		end
		// }}}

		// o_data_busy, dat0_busy, wait_for_busy, busy_delay
		// {{{
		initial	{ dat0_busy, wait_for_busy } = 2'b01;
		always @(posedge i_clk)
		if (i_cmd_en || i_data_en)
		begin
			dat0_busy <= 1'b0;
			wait_for_busy <= 1'b1;
			busy_delay <= -1;
		end else if (busy_delay != 0)
		begin
			dat0_busy <= 1'b0;
			wait_for_busy <= 1'b1;
			busy_delay <= busy_delay - 1;
		end else if (wait_for_busy)
		begin
			if (busy_pin)
			begin
				// Once busy is activated, we stop waiting for
				// it, mark ourselves as busy, and then follow
				// the pin for our busy indicators.
				dat0_busy <= 1'b1;
				wait_for_busy <= 1'b0;
			end
		end else if (!wait_for_busy && !busy_pin)
			// Once busy is released, we don't become busy again
			// until we reset
			dat0_busy <= 1'b0;

		assign	o_data_busy = dat0_busy;
		// }}}

		////////////////////////////////////////////////////////////////
		//
		// CMD
		// {{{
		always @(posedge i_clk)
		if (i_reset || i_cfg_dscmd || i_cmd_en)
			pck_sreg <= 0;
		else
			pck_sreg <= { pck_sreg[15:0], next_pedge };

		always @(posedge i_clk)
		if (i_reset || i_cfg_dscmd || i_cmd_en || r_last_cmd_enabled)
			cmd_sample_ck <= 0;
		else
			// Verilator lint_off WIDTH
			cmd_sample_ck <= { pck_sreg[23:0], next_pedge } >> i_sample_shift;
			// Verilator lint_on  WIDTH

		always @(posedge i_clk)
			r_last_cmd_enabled <= i_cmd_en && i_pp_cmd;

		xsdserdes8x #(
			.OPT_BIDIR(1'b1)
		) cmd_serdes(
			.i_clk(i_clk),
			.i_hsclk(i_hsclk),
			.i_en(r_last_cmd_enabled
				||(!w_cmd_collision && !o_cmd_collision
					&& i_cmd_en
					&& (i_pp_cmd || !i_cmd_data[1]))),
			.i_data({ {(4){i_cmd_data[1]}}, {(4){i_cmd_data[0]}} }),
			.io_tristate(io_cmd_tristate),
			.o_pin(o_cmd),
			.i_pin(i_cmd),
			.o_mine(my_cmd_data),
			.o_raw(raw_cmd), .o_wide(wide_cmd_data)
		);

		assign	w_cmd_collision = OPT_COLLISION && i_cmd_en
					&& !i_pp_cmd && !i_cfg_dscmd
					&& |(my_cmd_data & ~wide_cmd_data);

		if (OPT_COLLISION)
		begin : GEN_COLLISION
			reg	r_collision;

			always @(posedge i_clk)
			if (i_reset || !i_cmd_en || i_pp_cmd || i_cfg_dscmd)
				r_collision <= 1'b0;
			else if (w_cmd_collision)
				r_collision <= 1'b1;

			assign	o_cmd_collision = r_collision;
		end else begin : NO_COLLISION
			assign	o_cmd_collision = 1'b0;
		end

		// resp_started
		// {{{
		always @(posedge i_clk)
		if (i_reset || i_cmd_en || i_cfg_dscmd)
			resp_started <= 1'b0;
		else if (((|cmd_sample_ck[7:4])&&((cmd_sample_ck[7:4] & wide_cmd_data[7:4])==0))
			||((|cmd_sample_ck[3:0])&&((cmd_sample_ck[3:0] & wide_cmd_data[3:0])==0)))
			resp_started <= 1'b1;
		// }}}

		// o_cmd_strb
		// {{{
		always @(posedge i_clk)
		if (i_reset || i_cmd_en || i_cfg_dscmd)
			r_cmd_strb <= 2'b00;
		else if (resp_started)
		begin
			r_cmd_strb[1] <= (|cmd_sample_ck);
			r_cmd_strb[0] <= (|cmd_sample_ck[7:4])
						&&(|cmd_sample_ck[3:0]);
		end else begin
			r_cmd_strb[1] <= (((|cmd_sample_ck[7:4])&&((cmd_sample_ck[7:4] & wide_cmd_data[7:4])==0))
				||((|cmd_sample_ck[3:0])&&((cmd_sample_ck[3:0] & wide_cmd_data[3:0])==0)));
			r_cmd_strb[0] <= (|cmd_sample_ck[7:4])
				&& ((cmd_sample_ck[7:4] & wide_cmd_data[7:4])==0)
				&& (|cmd_sample_ck[3:0]);
		end

		assign	o_cmd_strb = r_cmd_strb;
		// }}}

		// o_cmd_data
		// {{{
		always @(*)
		begin
			if (resp_started)
			begin
				if (|cmd_sample_ck[7:4])
					w_cmd_data[1] = |(cmd_sample_ck[7:4] & wide_cmd_data[7:4]);
				else
					w_cmd_data[1] = |(cmd_sample_ck[3:0] & wide_cmd_data[3:0]);
			end else begin // if (!resp_started)
				w_cmd_data[1] = 1'b0;
			end

			w_cmd_data[0] = |(cmd_sample_ck[3:0]
						& wide_cmd_data[3:0]);
		end

		always @(posedge i_clk)
			r_cmd_data <= w_cmd_data;

		assign	o_cmd_data = r_cmd_data;
		// }}}

		// }}}
		assign	o_debug = 32'h0;

		// Keep Verilator happy
		// {{{
		// Verilator lint_off UNUSED
		wire	unused_serdes;
		assign	unused_serdes = &{ 1'b0, ign_clk_mine,
				ign_clk_raw, ign_clk_wide,
				w_rx_data[15:9], w_rx_data[7:1] };
		// Verilator lint_on  UNUSED
		// }}}
		// }}}
	end endgenerate
	////////////////////////////////////////////////////////////////////////
	//
	// Datastrobe support
	// {{{
	////////////////////////////////////////////////////////////////////////
	//

	generate if (OPT_DS && NUMIO == 8)
	begin : GEN_DATASTROBE
		// Notes
		// {{{
		// This *SHOULD* work with OPT_DDR.  However, I have no evidence
		// that the IDDR element can be bypassed, which would be
		// required by the logic below.  If it cannot be bypassed,
		// this logic then makes no sense.
		//
		// Also: The DS (data strobe) needs to be delayed by a quarter
		// clock before entering this module.  Since the clock frequency
		// isn't fully known until run time, it should instead be
		// delayed by a quarter of the maximum clock period that will
		// be used.
		//
		// When working with DS based outputs, an asynchronous FIFO is
		// used to clock incoming data.  Further, when using the
		// asynchronous FIFO, the start of any incoming data is quietly
		// stripped off, guaranteeing that all data will be aligned on
		// the left/MSB sample.
		// }}}

		// Local declarations
		// {{{
		wire	afifo_reset_n;
		wire	cmd_ds_en;
		reg		af_started_p, af_started_n, acmd_started;
		reg		af_count_p, af_count_n, acmd_count;
		wire	[3:0]	ign_afifo_full, afifo_empty;
		wire	[31:0]	af_data;
		wire	[1:0]	acmd_empty, ign_acmd_full;
		wire	[1:0]	af_cmd;
		// }}}

		assign	afifo_reset_n = i_cfg_ds && !i_data_en && i_rx_en;
		assign	cmd_ds_en = i_cfg_dscmd && !i_cmd_en;

		// Async command port
		// {{{
		// The rule here is that only the positive edges of the
		// data strobe will qualify the CMD pin;
		always @(posedge i_ds or negedge cmd_ds_en)
		if (!cmd_ds_en)
			acmd_started <= 0;
		else if (!raw_cmd)
			acmd_started <= 1;

		always @(posedge i_ds or negedge cmd_ds_en)
		if (!cmd_ds_en)
			acmd_count <= 0;
		else if (acmd_started || !raw_cmd)
			acmd_count <= acmd_count + 1;

		afifo #(
			.LGFIFO(4), .WIDTH(1), .WRITE_ON_POSEDGE(1'b1)
		) u_pcmd_fifo_0 (
			// {{{
			.i_wclk(i_ds), .i_wr_reset_n(cmd_ds_en),
			.i_wr((acmd_started || !raw_cmd)&& acmd_count == 1'b0),
				.i_wr_data(raw_cmd),
			.o_wr_full(ign_acmd_full[0]),
			//
			.i_rclk(i_clk), .i_rd_reset_n(cmd_ds_en),
			.i_rd(acmd_empty == 2'b0), .o_rd_data(af_cmd[1]),
			.o_rd_empty(acmd_empty[0])
			// }}}
		);

		afifo #(
			.LGFIFO(4), .WIDTH(1), .WRITE_ON_POSEDGE(1'b1)
		) u_pcmd_fifo_1 (
			// {{{
			.i_wclk(i_ds), .i_wr_reset_n(cmd_ds_en),
			.i_wr(acmd_count), .i_wr_data(raw_cmd),
			.o_wr_full(ign_acmd_full[1]),
			//
			.i_rclk(i_clk), .i_rd_reset_n(cmd_ds_en),
			.i_rd(acmd_empty == 2'b0), .o_rd_data(af_cmd[0]),
			.o_rd_empty(acmd_empty[1])
			// }}}
		);

		assign	MAC_VALID = (acmd_empty == 2'h0);
		assign	MAC_DATA  = af_cmd;
		// }}}

		// af_started_*, af_count_*
		// {{{
		always @(posedge i_ds or negedge afifo_reset_n)
		if (!afifo_reset_n)
			af_started_p <= 0;
		else if (raw_iodat[0] == 0)
			af_started_p <= 1;

		always @(posedge i_ds or negedge afifo_reset_n)
		if (!afifo_reset_n)
			af_count_p <= 0;
		else if (af_started_p)
			af_count_p <= af_count_p + 1;

		always @(negedge i_ds or negedge afifo_reset_n)
		if (!afifo_reset_n)
			af_started_n <= 0;
		else if (af_started_p)
			af_started_n <= 1;

		always @(negedge i_ds or negedge afifo_reset_n)
		if (!afifo_reset_n)
			af_count_n <= 0;
		else if (af_started_n)
			af_count_n <= af_count_n + 1;
		// }}}


		afifo #(
			.LGFIFO(4), .WIDTH(NUMIO), .WRITE_ON_POSEDGE(1'b1)
		) u_pedge_fifo_0 (
			// {{{
			.i_wclk(i_ds), .i_wr_reset_n(afifo_reset_n),
			.i_wr(af_started_p && af_count_p == 1'b0),
				.i_wr_data(raw_iodat),
			.o_wr_full(ign_afifo_full[0]),
			//
			.i_rclk(i_clk), .i_rd_reset_n(afifo_reset_n),
			.i_rd(MAD_VALID), .o_rd_data(af_data[24 +: NUMIO]),
			.o_rd_empty(afifo_empty[0])
			// }}}
		);

		afifo #(
			.LGFIFO(4), .WIDTH(NUMIO), .WRITE_ON_POSEDGE(1'b0)
		) u_nedge_fifo_1 (
			// {{{
			.i_wclk(i_ds), .i_wr_reset_n(afifo_reset_n),
			.i_wr(af_started_n && af_count_n == 1'b0),
				.i_wr_data(raw_iodat),
			.o_wr_full(ign_afifo_full[1]),
			//
			.i_rclk(i_clk), .i_rd_reset_n(afifo_reset_n),
			.i_rd(MAD_VALID), .o_rd_data(af_data[16 +: NUMIO]),
			.o_rd_empty(afifo_empty[1])
			// }}}
		);

		afifo #(
			.LGFIFO(4), .WIDTH(NUMIO), .WRITE_ON_POSEDGE(1'b1)
		) u_pedge_fifo_2 (
			// {{{
			.i_wclk(i_ds), .i_wr_reset_n(afifo_reset_n),
			.i_wr(af_count_p == 1'b1),
				.i_wr_data(raw_iodat),
			.o_wr_full(ign_afifo_full[2]),
			//
			.i_rclk(i_clk), .i_rd_reset_n(afifo_reset_n),
			.i_rd(MAD_VALID), .o_rd_data(af_data[8 +: NUMIO]),
			.o_rd_empty(afifo_empty[2])
			// }}}
		);

		afifo #(
			.LGFIFO(4), .WIDTH(NUMIO), .WRITE_ON_POSEDGE(1'b0)
		) u_nedge_fifo_3 (
			// {{{
			.i_wclk(i_ds), .i_wr_reset_n(afifo_reset_n),
			.i_wr(af_count_n == 1'b1),
				.i_wr_data(raw_iodat),
			.o_wr_full(ign_afifo_full[3]),
			//
			.i_rclk(i_clk), .i_rd_reset_n(afifo_reset_n),
			.i_rd(MAD_VALID), .o_rd_data(af_data[0 +: NUMIO]),
			.o_rd_empty(afifo_empty[3])
			// }}}
		);

		for(gk=NUMIO; gk<8; gk=gk+1)
		begin : ASSIGN_UNUSED_DATA
			// {{{
			// Technically, the data strobe is only permitted
			// if/when we are using all 8 IOs.  Still, there's no
			// reason why we can't build the front end to use
			// however many IOs we have.  Of course ... the rest
			// of the design assumes 8 IOs whenever the ASYNC
			// interface is active, so ... defining these here
			// doesn't mean these will work with the rest of the
			// design.
			//
			assign	af_data[     gk] = 1'b0;
			assign	af_data[ 8 + gk] = 1'b0;
			assign	af_data[16 + gk] = 1'b0;
			assign	af_data[24 + gk] = 1'b0;
			// }}}
		end

		assign	MAD_VALID = (afifo_empty == 4'h0); // af_flush && !afifo_empty[0]
		assign	MAD_DATA  = af_data;

		// Keep Verilator happy
		// {{{
		// Verilator lint_off UNUSED
		wire	unused_ds;
		assign	unused_ds = &{ 1'b0,
				ign_afifo_full, ign_acmd_full
				};
		// Verilator lint_on  UNUSED
		// }}}
	end else begin : NO_DATASTROBE
		assign	MAC_VALID = 1'b0;
		assign	MAC_DATA  = 2'b0;
		assign	MAD_VALID = 1'b0;
		assign	MAD_DATA  = 32'h0;

		// Keep Verilator happy
		// {{{
		// Verilator lint_off UNUSED
		wire	unused_ds;
		assign	unused_ds = &{ 1'b0, raw_cmd, raw_iodat,
				i_cfg_ds, i_cfg_dscmd
				};
		// Verilator lint_on  UNUSED
		// }}}
	end endgenerate

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// IO buffers --- if not using Verilator
	// {{{
`ifndef	VERILATOR

	IOBUF
	u_cmdbuf( .T(io_cmd_tristate), .I(o_cmd), .IO(io_cmd), .O(i_cmd));

	generate for(gk=0; gk<NUMIO; gk=gk+1)
	begin : GEN_IOBUF
		IOBUF
		u_datbuf(
			.T(io_dat_tristate[gk]),
			.I(o_dat[gk]),
			.IO(io_dat[gk]),
			.O(i_dat[gk])
		);
	end endgenerate
`endif
	// }}}
endmodule
