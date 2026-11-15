-- H8 in the C76's place (pocket/core/s12/h8_c76.vhd, as t3_h8.apply puts it in the core): Tekken 3's H8 program runs
-- through the bridge and ROM cache against a model of the System 11 sound block's C76 bus (c76_sound.vhd):
--   0x004000-0x00BFFF shared RAM (a read is ready once its address has been out for a ce: c76_sound's ext_addr_prev
--   gate), 0x002000-0x002FFF the C352 at byte level (C76 order: low byte even; the key-on / key-off commit on a write
--   to 0x405, as c352.vhd), 0x001000-0x001007 inputs (idle 0xFF), 0x200000-0x2FFFFF the SPROG (the H8 program's first
--   256 KB, a word fetched some clocks after it is asked for, then its bytes ready, as the t3_h8 SYSTEM11.sv reader).
-- Everything else as tests/h8/sys (tb_h8_sys): MAME's main CPU shared-RAM writes played back by frame, the C352's voice
-- positions and sample ends modelled as MAME's (c352_model_pkg), vblank as c76_vblank_irq's irq0 (high 256 C76 clocks at the frame start). C352 writes are logged as H8 words
-- (the bridge's two byte cycles merged) for tests/h8/sys/compare.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.c352_model_pkg.all;

entity tb_h8_c76 is
   generic (REF : string := "../ref"; OUTF : string := "c352_sim.log"; FRAMES : integer := 120);
end entity;

architecture tb of tb_h8_c76 is
   constant T  : integer := 564480;        -- clocks per frame
   constant SPROG_LAT : integer := 9;      -- clocks from a SPROG word request to its data
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal done : boolean := false;
   signal ce : std_logic := '0';
   signal irq0 : std_logic := '0';
   signal ext_addr : std_logic_vector(23 downto 0);
   signal ext_dout, ext_din : std_logic_vector(7 downto 0);
   signal ext_rd, ext_wr, ext_ready : std_logic;
   signal ext_addr_prev : std_logic_vector(23 downto 0) := (others => '1');
   signal sp_word : integer := -1;          -- SPROG word fetched (byte address / 4)
   signal dbg_pc : std_logic_vector(23 downto 0);
   signal dbg_valid : std_logic;

   type rom_t is array (0 to 262143) of std_logic_vector(15 downto 0);
   type ram_t is array (0 to 16383) of std_logic_vector(7 downto 0);         -- shared RAM, H8 byte order
   shared variable rom : rom_t;
   shared variable ram : ram_t := (others => x"00");
   shared variable c352 : c352_regs_t := (others => x"0000");                -- word offsets 0-0xFF voices, 0x200 ctl

   function sel(a : std_logic_vector(23 downto 0); lo, hi : integer) return boolean is
   begin
      return to_integer(unsigned(a)) >= lo and to_integer(unsigned(a)) <= hi;
   end function;
begin
   clk <= not clk after 5 ns when not done;

   dut : entity work.c76(h8)
      port map (clk => clk, ce => ce, reset => reset, irq0 => irq0, irq1 => '0', irq2 => '0',
                ext_addr => ext_addr, ext_dout => ext_dout, ext_din => ext_din, ext_rd => ext_rd, ext_wr => ext_wr,
                ext_ready => ext_ready, dbg_pc => dbg_pc, dbg_valid => dbg_valid);

   -- the C76 bus, combinational like c76_sound
   process (all)
      variable i : integer;
   begin
      ext_ready <= ext_rd or ext_wr;
      ext_din <= x"00";
      if sel(ext_addr, 16#4000#, 16#BFFF#) then
         if ext_rd = '1' and ext_addr /= ext_addr_prev then ext_ready <= '0'; end if;
         i := to_integer(unsigned(ext_addr)) - 16#4000#;
         if i < 16384 then ext_din <= ram(i - 2 * (i mod 2) + 1); end if;          -- C76 odd byte = H8 even byte
      elsif sel(ext_addr, 16#2000#, 16#2FFF#) then
         i := to_integer(unsigned(ext_addr(11 downto 1)));
         if i < 1024 then
            if ext_addr(0) = '1' then ext_din <= c352(i)(15 downto 8); else ext_din <= c352(i)(7 downto 0); end if;
         end if;
      elsif sel(ext_addr, 16#1000#, 16#1007#) then
         ext_din <= x"FF";
      elsif sel(ext_addr, 16#200000#, 16#2FFFFF#) then
         if ext_rd = '1' then
            if sp_word /= to_integer(unsigned(ext_addr(19 downto 2))) then ext_ready <= '0'; end if;
            i := to_integer(unsigned(ext_addr(17 downto 1)));
            if ext_addr(0) = '0' then ext_din <= rom(i)(15 downto 8); else ext_din <= rom(i)(7 downto 0); end if;
         end if;
      end if;
   end process;

   bus_side : process (clk)
      file mf, logf : text;
      variable l, ol : line;
      variable opened : boolean := false;
      variable cyc, fr, i, off, nw, wait_sp : integer := 0;
      variable m_f : integer := -1;
      variable m_a : std_logic_vector(23 downto 0);
      variable m_v, m_m : std_logic_vector(15 downto 0);
      variable vpos : c352_pos_t := (others => (others => '0'));
      variable vcnt : c352_cnt_t := (others => (others => '0'));
      variable hi_off : integer := -1;      -- the high byte of a word write seen, waiting for its low byte
      variable hi_byte : std_logic_vector(7 downto 0);
      procedure next_main is
      begin
         if endfile(mf) then m_f := integer'high;
         else readline(mf, l); read(l, m_f); hread(l, m_a); hread(l, m_v); hread(l, m_m); end if;
      end procedure;
      procedure logw(o : integer; v : std_logic_vector(15 downto 0); be : string) is
      begin
         write(ol, integer'image(fr) & " " & to_hstring(std_logic_vector(to_unsigned(16#280000# + 2 * o, 24))) & " " &
                   to_hstring(v) & " " & be);
         writeline(logf, ol);
         nw := nw + 1;
      end procedure;
   begin
      if rising_edge(clk) then
         if not opened then
            file_open(mf, REF & "/main_shared.log", read_mode);
            file_open(logf, OUTF, write_mode);
            next_main;
            opened := true;
         end if;
         ce <= not ce;
         if ce = '1' then ext_addr_prev <= ext_addr; end if;
         -- SPROG: a word some clocks after it is asked for
         if ext_rd = '1' and sel(ext_addr, 16#200000#, 16#2FFFFF#) and
            sp_word /= to_integer(unsigned(ext_addr(19 downto 2))) then
            if wait_sp = SPROG_LAT then sp_word <= to_integer(unsigned(ext_addr(19 downto 2))); wait_sp := 0;
            else wait_sp := wait_sp + 1; end if;
         end if;
         if reset = '0' then
            cyc := cyc + 1;
            if cyc = T then
               cyc := 0; fr := fr + 1;
               if fr >= FRAMES then done <= true; end if;
            end if;
            if fr >= 1 and cyc < 512 then irq0 <= '1'; else irq0 <= '0'; end if;
            if cyc mod C352_CLKS = 0 then c352_tick(c352, vpos, vcnt); end if;
            if cyc = T / 2 then
               while m_f <= fr loop
                  i := to_integer(unsigned(m_a(13 downto 0)));
                  if m_m(15 downto 8) /= x"00" then ram(i) := m_v(15 downto 8); end if;
                  if m_m(7 downto 0) /= x"00" then ram(i + 1) := m_v(7 downto 0); end if;
                  next_main;
               end loop;
            end if;
         end if;
         -- writes, taken on a ce clock as c76_sound does
         if ce = '1' and ext_wr = '1' and ext_ready = '1' then
            if sel(ext_addr, 16#4000#, 16#BFFF#) then
               i := to_integer(unsigned(ext_addr)) - 16#4000#;
               if i < 16384 then
                  if i mod 2 = 1 then ram(i - 1) := ext_dout; else ram(i + 1) := ext_dout; end if;
               end if;
            elsif sel(ext_addr, 16#2000#, 16#2FFF#) then
               off := to_integer(unsigned(ext_addr(11 downto 0)));
               i := off / 2;
               if i < 1024 then
                  if off mod 2 = 1 then c352(i)(15 downto 8) := ext_dout; else c352(i)(7 downto 0) := ext_dout; end if;
               end if;
               if off = 16#405# then c352_keys(c352, vpos, vcnt); end if;   -- the key-on / key-off commit (c352.vhd)
               -- log as H8 words: the bridge writes the high byte (odd here) then the low byte
               if off mod 2 = 1 then
                  if hi_off >= 0 then logw(hi_off / 2, hi_byte & x"00", "2"); end if;
                  hi_off := off; hi_byte := ext_dout;
               elsif hi_off = off + 1 then
                  logw(off / 2, hi_byte & ext_dout, "3"); hi_off := -1;
               else
                  if hi_off >= 0 then logw(hi_off / 2, hi_byte & x"00", "2"); hi_off := -1; end if;
                  logw(off / 2, x"00" & ext_dout, "1");
               end if;
            end if;
         end if;
         if done then
            report "tb_h8_c76: " & integer'image(fr) & " frames, " & integer'image(nw) & " C352 writes";
         end if;
      end if;
   end process;

   -- per second: H8 ROM reads, cache line fills, C76 bus byte cycles, clocks the H8 spent outside its idle loop
   stats : process (clk)
      alias h8_rd is <<signal .tb_h8_c76.dut.bus_rd : std_logic>>;
      alias h8_ack is <<signal .tb_h8_c76.dut.bus_ack : std_logic>>;
      alias h8_addr is <<signal .tb_h8_c76.dut.bus_addr : std_logic_vector(23 downto 0)>>;
      variable nrom, nfill, nbus, nbusy, ncyc, sec : integer := 0;
      variable pc : integer;
   begin
      if rising_edge(clk) and reset = '0' then
         ncyc := ncyc + 1;
         if h8_rd = '1' and h8_ack = '1' and unsigned(h8_addr) < 16#080000# then nrom := nrom + 1; end if;
         if ext_rd = '1' and ext_ready = '1' and ce = '1' and sel(ext_addr, 16#200000#, 16#2FFFFF#) then nfill := nfill + 1; end if;
         if (ext_rd = '1' or ext_wr = '1') and ext_ready = '1' and ce = '1' then nbus := nbus + 1; end if;
         pc := to_integer(unsigned(dbg_pc));
         if pc < 16#158A# or pc > 16#1591# then nbusy := nbusy + 1; end if;
         if ncyc = 60 * T then
            report "second " & integer'image(sec) & ": ROM reads " & integer'image(nrom) & ", SPROG bytes " &
                   integer'image(nfill) & ", C76 bus bytes " & integer'image(nbus) & ", busy " &
                   integer'image(nbusy / (60 * T / 100)) & "%";
            sec := sec + 1; ncyc := 0; nrom := 0; nfill := 0; nbus := 0; nbusy := 0;
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
      wait until rising_edge(clk); wait until rising_edge(clk); wait until rising_edge(clk);
      reset <= '0';
      loop
         wait until rising_edge(clk);
         assert dbg_valid = '0' report "H8: opcode not implemented at " & to_hstring(dbg_pc) severity failure;
         exit when done;
      end loop;
      wait;
   end process;
end architecture;
