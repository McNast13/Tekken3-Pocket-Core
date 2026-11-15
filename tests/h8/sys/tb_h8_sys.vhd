-- H8 system test: the core's H8 CPU (pocket/core/s12/h8_cpu.vhd) and peripherals (h8_periph.vhd) run Tekken 3's sound
-- program from reset, against MAME's recording of the same boot (tools/mame/h8_shared.lua, tests/h8/ref):
--   - the main CPU's writes to the shared RAM are played back at the frames MAME made them;
--   - the C352's registers are modelled as MAME's c352 does: they hold what the H8 writes, and a write to 0x280404
--     runs the key-ons (KEYON -> BUSY) and key-offs (BUSY and KEYOFF cleared); a sample playing to its end (which
--     needs the wave data) clears BUSY and sets KEYOFF at the frame MAME's H8 saw it (c352_ends.log, c352_ends.py);
--   - vblank (60 Hz, 564,480 clocks of 33.8688 MHz) drives IRQ1, ADTRG and port B bit 7, as on System 12;
--   - every C352 write is logged (frame, address, value, byte lanes) to OUT, for tests/h8/sys/compare.py.
-- Inputs idle (0x300000-3 read 0xFF00), DSW 0xFF, no JVS, no RTC (SCI1 receives 1s), analog inputs 0.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_h8_sys is
   generic (REF : string := "../ref"; OUTF : string := "c352_sim.log"; FRAMES : integer := 120);
end entity;

architecture tb of tb_h8_sys is
   constant T  : integer := 564480;        -- clocks per frame
   constant VB : integer := 36000;         -- vblank length (about 17 lines)
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal done : boolean := false;
   signal phi_ce : std_logic := '0';

   signal bus_addr : std_logic_vector(23 downto 0);
   signal bus_wdata, bus_rdata, mem_q, per_q : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_rd, bus_wr, bus_ack, mem_ack, per_ack, per_sel : std_logic := '0';
   signal bus_be : std_logic_vector(1 downto 0);
   signal irq, irq_ack, syscr_ue, illegal, dstart : std_logic := '0';
   signal irq_vec, irq_ack_vec : std_logic_vector(5 downto 0);
   signal ccr : std_logic_vector(7 downto 0);
   signal dpc : std_logic_vector(23 downto 0);
   signal vblank : std_logic := '0';
   signal irq_in : std_logic_vector(5 downto 0);
   signal pb_in : std_logic_vector(7 downto 0);
   signal frame : integer := 0;

   type rom_t is array (0 to 262143) of std_logic_vector(15 downto 0);
   type ram_t is array (0 to 65535 + 512) of std_logic_vector(7 downto 0);
   type c352_t is array (0 to 16383) of std_logic_vector(15 downto 0);
   shared variable rom : rom_t;
   shared variable ram : ram_t := (others => x"00");
begin
   clk <= not clk after 5 ns when not done;

   cpu : entity work.h8_cpu
      port map (clk => clk, ce => '1', reset => reset, bus_addr => bus_addr, bus_wdata => bus_wdata, bus_rdata => bus_rdata,
                bus_rd => bus_rd, bus_wr => bus_wr, bus_be => bus_be, bus_ack => bus_ack, irq => irq, irq_vec => irq_vec,
                irq_ack => irq_ack, irq_ack_vec => irq_ack_vec, syscr_ue => syscr_ue, ccr_o => ccr,
                dbg_start => dstart, dbg_pc => dpc, dbg_illegal => illegal);

   per_sel <= '1' when unsigned(bus_addr) >= 16#FFFF1C# else '0';
   irq_in <= "0000" & vblank & '0';
   pb_in <= vblank & "1111111";
   per : entity work.h8_periph
      port map (clk => clk, reset => reset, phi_ce => phi_ce,
                sel => per_sel, rd => bus_rd, wr => bus_wr, a8 => bus_addr(7 downto 0), be => bus_be, wdata => bus_wdata,
                rdata => per_q, ack => per_ack,
                ccr => ccr, irq => irq, irq_vec => irq_vec, irq_ack => irq_ack, irq_ack_vec => irq_ack_vec,
                syscr_ue => syscr_ue,
                irq_in => irq_in, adtrg => vblank, adc_in => (others => '0'),
                p4_in => x"FF", p6_in => x"FF", p7_in => x"FF", p8_in => x"EF", p9_in => x"FF", pa_in => x"FF", pb_in => pb_in,
                sci1_rxd => '1');
   bus_ack <= per_ack or mem_ack;
   bus_rdata <= per_q when per_sel = '1' else mem_q;

   -- memory, C352, inputs; the frame clock and the main CPU's shared RAM writes
   mem : process (clk)
      file mf, rf, logf : text;
      variable l, ol : line;
      variable opened : boolean := false;
      variable cyc : integer := 0;
      variable fr : integer := 0;
      variable a : unsigned(23 downto 0);
      variable i : integer;
      variable c352 : c352_t := (others => x"0000");               -- word offsets: 0-0xFF voices, 0x200 control
      variable off : integer;
      -- the next main CPU write and the next C352 read value, read ahead
      variable m_f : integer := -1;
      variable m_a : std_logic_vector(23 downto 0);
      variable m_v, m_m : std_logic_vector(15 downto 0);
      variable r_f : integer := -1;                               -- the next sample end: frame, voice
      variable r_n : integer;
      variable nw, nunm : integer := 0;
      variable w8 : std_logic_vector(7 downto 0);
      procedure next_main is
      begin
         if endfile(mf) then m_f := integer'high;
         else readline(mf, l); read(l, m_f); hread(l, m_a); hread(l, m_v); hread(l, m_m); end if;
      end procedure;
      procedure next_end is
      begin
         if endfile(rf) then r_f := integer'high;
         else readline(rf, l); read(l, r_f); read(l, r_n); end if;
      end procedure;
   begin
      if rising_edge(clk) then
         if not opened then
            file_open(mf, REF & "/main_shared.log", read_mode);
            file_open(logf, OUTF, write_mode);
            file_open(rf, REF & "/c352_ends.log", read_mode);
            next_main; next_end;
            opened := true;
         end if;
         phi_ce <= not phi_ce;

         -- frames: vblank starts each frame (MAME counts a frame done there); the main CPU's writes of frame f are
         -- played in its middle, and the sample ends MAME's H8 saw in frame f happen at its start
         if reset = '0' then
            cyc := cyc + 1;
            if cyc = T then
               cyc := 0; fr := fr + 1; frame <= fr;
               if fr >= FRAMES then done <= true; end if;
            end if;
            if fr >= 1 and cyc < VB then vblank <= '1'; else vblank <= '0'; end if;
            while r_f <= fr loop
               i := 8 * r_n + 3;
               if c352(i)(15) = '1' then c352(i)(15) := '0'; c352(i)(13) := '1'; end if;
               next_end;
            end loop;
            if cyc = T / 2 then
               while m_f <= fr loop
                  i := to_integer(unsigned(m_a(15 downto 0)));
                  if m_m(15 downto 8) /= x"00" then ram(i) := m_v(15 downto 8); end if;
                  if m_m(7 downto 0) /= x"00" then ram(i + 1) := m_v(7 downto 0); end if;
                  next_main;
               end loop;
            end if;
         end if;

         mem_ack <= '0';
         if (bus_rd = '1' or bus_wr = '1') and mem_ack = '0' and per_sel = '0' then
            mem_ack <= '1';
            a := unsigned(bus_addr);
            if bus_rd = '1' then
               if a < 16#080000# then
                  mem_q <= rom(to_integer(a(18 downto 1)));
               elsif a <= 16#08FFFF# then
                  i := to_integer(a(15 downto 1) & '0'); mem_q <= ram(i) & ram(i + 1);
               elsif a >= 16#280000# and a <= 16#287FFF# then
                  off := to_integer(a(14 downto 1));
                  if off < 16#100# or off = 16#200# then mem_q <= c352(off); else mem_q <= x"0000"; end if;
               elsif a >= 16#300000# and a <= 16#300003# then
                  mem_q <= x"FF00";
               elsif a >= 16#FFFD10# and a <= 16#FFFF0F# then
                  i := 65536 + to_integer(a - 16#FFFD10#); i := i - (i mod 2); mem_q <= ram(i) & ram(i + 1);
               else
                  mem_q <= x"0000";
                  if nunm < 20 then report "unmapped read " & to_hstring(bus_addr) & " PC " & to_hstring(dpc); end if;
                  nunm := nunm + 1;
               end if;
            else
               i := -1;
               if a >= 16#080000# and a <= 16#08FFFF# then i := to_integer(a(15 downto 0));
               elsif a >= 16#FFFD10# and a <= 16#FFFF0F# then i := 65536 + to_integer(a - 16#FFFD10#);
               elsif a >= 16#280000# and a <= 16#287FFF# then
                  -- a C352 write: frame, word address, value, lanes
                  write(ol, integer'image(fr) & " " & to_hstring(std_logic_vector(a(23 downto 1)) & '0') & " " &
                            to_hstring(bus_wdata) & " " & to_hstring(bus_be));
                  writeline(logf, ol);
                  nw := nw + 1;
                  off := to_integer(a(14 downto 1));
                  if off < 16#100# or off = 16#200# then
                     if bus_be(1) = '1' then c352(off)(15 downto 8) := bus_wdata(15 downto 8); end if;
                     if bus_be(0) = '1' then c352(off)(7 downto 0) := bus_wdata(7 downto 0); end if;
                  elsif off = 16#202# and bus_be = "11" then          -- run the key-ons and key-offs
                     for v in 0 to 31 loop
                        if c352(8 * v + 3)(14) = '1' then
                           c352(8 * v + 3)(15) := '1'; c352(8 * v + 3)(14) := '0'; c352(8 * v + 3)(11) := '0';
                        end if;
                        if c352(8 * v + 3)(13) = '1' then
                           c352(8 * v + 3)(15) := '0'; c352(8 * v + 3)(13) := '0';
                        end if;
                     end loop;
                  end if;
               end if;
               if i >= 0 then
                  if bus_be = "11" then
                     ram(i - (i mod 2)) := bus_wdata(15 downto 8); ram(i - (i mod 2) + 1) := bus_wdata(7 downto 0);
                  elsif bus_be = "10" then ram(i) := bus_wdata(15 downto 8);
                  else ram(i) := bus_wdata(7 downto 0); end if;
               end if;
            end if;
         end if;
         if done then
            report "tb_h8_sys: " & integer'image(fr) & " frames, " & integer'image(nw) & " C352 writes, " &
                   integer'image(nunm) & " unmapped reads";
         end if;
      end if;
   end process;

   main : process
      file f : text;
      variable l : line;
      variable w16 : std_logic_vector(15 downto 0);
   begin
      file_open(f, REF & "/rom.hex", read_mode);
      for i in 0 to 262143 loop readline(f, l); hread(l, w16); rom(i) := w16; end loop;
      file_close(f);
      wait until rising_edge(clk); wait until rising_edge(clk);
      reset <= '0';
      loop
         wait until rising_edge(clk);
         assert illegal = '0' report "opcode not implemented at " & to_hstring(dpc) severity failure;
         exit when done;
      end loop;
      wait;
   end process;
end architecture;
