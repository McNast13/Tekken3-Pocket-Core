-- Replays MAME's recording of Tekken 3's H8 into pocket/core/s12/h8_cpu.vhd (files from tests/h8/make_replay.py):
-- the CPU starts from MAME's registers and RAM snapshot, reads of what the H8 does not hold itself come from MAME's
-- read log in order, interrupts are raised before the instruction numbers MAME took them at, and before every
-- instruction PC, CCR and ER0-ER7 must equal MAME's. Stops at the first difference. Run: tests/h8/cpu/run.sh
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_h8_cpu is
   -- FLAT: random-instruction tests (tests/h8/rand): every address from 0x080000 up is the 64 KB RAM (address mod 64 KB),
   -- nothing is "outside"
   generic (REF : string := "../ref"; MAXINS : integer := 200000; FLAT : boolean := false);
end entity;

architecture tb of tb_h8_cpu is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal done : boolean := false;
   signal bus_addr : std_logic_vector(23 downto 0);
   signal bus_wdata, bus_rdata : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_rd, bus_wr, bus_ack, irq, irq_ack, illegal, dstart : std_logic := '0';
   signal bus_be : std_logic_vector(1 downto 0);
   signal irq_vec : std_logic_vector(5 downto 0) := (others => '0');
   signal syscr_ue : std_logic := '0';
   signal load_pc : std_logic_vector(23 downto 0);
   signal load_ccr : std_logic_vector(7 downto 0);
   signal load_er : std_logic_vector(255 downto 0);
   signal dpc : std_logic_vector(23 downto 0);
   signal dccr : std_logic_vector(7 downto 0);
   signal der : std_logic_vector(255 downto 0);
   signal started : boolean := false;

   type rom_t is array (0 to 262143) of std_logic_vector(15 downto 0);
   type ram_t is array (0 to 65535 + 512) of std_logic_vector(7 downto 0);
   shared variable rom : rom_t;
   shared variable ram : ram_t;
   signal ninstr : integer := 0;

   function outside(a : unsigned(23 downto 0)) return boolean is
   begin
      return (a >= 16#080000# and a <= 16#083FFF#) or (a >= 16#200000# and a <= 16#7FFFFF#) or a >= 16#FFFF10#;
   end function;
begin
   clk <= not clk after 5 ns when not done;

   dut : entity work.h8_cpu
      port map (clk => clk, ce => '1', reset => reset, bus_addr => bus_addr, bus_wdata => bus_wdata, bus_rdata => bus_rdata,
                bus_rd => bus_rd, bus_wr => bus_wr, bus_be => bus_be, bus_ack => bus_ack, irq => irq, irq_vec => irq_vec,
                irq_ack => irq_ack, syscr_ue => syscr_ue, ccr_o => open, load_state => '1', load_pc => load_pc,
                load_ccr => load_ccr, load_er => load_er, dbg_start => dstart, dbg_pc => dpc, dbg_ccr => dccr, dbg_er => der,
                dbg_illegal => illegal);

   -- memory: one clock to answer
   mem : process (clk)
      file rf : text;
      variable l : line;
      variable ra : std_logic_vector(23 downto 0);
      variable rd : std_logic_vector(15 downto 0);
      variable a : unsigned(23 downto 0);
      variable i : integer;
      variable opened : boolean := false;
      variable nreads : integer := 0;
   begin
      if rising_edge(clk) then
         if not opened then file_open(rf, REF & "/reads.txt", read_mode); opened := true; end if;
         bus_ack <= '0';
         if (bus_rd = '1' or bus_wr = '1') and bus_ack = '0' then
            a := unsigned(bus_addr);
            bus_ack <= '1';
            if bus_rd = '1' then
               if FLAT and a >= 16#080000# then
                  i := to_integer(a(15 downto 1) & '0');
                  bus_rdata <= ram(i) & ram(i + 1);
               elsif outside(a) then
                  assert not endfile(rf) report "CPU read " & to_hstring(bus_addr) & " beyond the end of MAME's read log" severity failure;
                  readline(rf, l); hread(l, ra); hread(l, rd);
                  nreads := nreads + 1;
                  assert ra(23 downto 1) = bus_addr(23 downto 1)
                     report "read order differs: CPU reads " & to_hstring(bus_addr) & ", MAME read " & to_hstring(ra) &
                            " (outside read " & integer'image(nreads) & ", instruction " & integer'image(ninstr) & ")" severity failure;
                  bus_rdata <= rd;
               elsif a < 16#080000# then
                  bus_rdata <= rom(to_integer(a(18 downto 1)));
               elsif a <= 16#08FFFF# then
                  i := to_integer(a(15 downto 1) & '0');
                  bus_rdata <= ram(i) & ram(i + 1);
               elsif a >= 16#FFFD10# and a <= 16#FFFF0F# then
                  i := 65536 + to_integer(a - 16#FFFD10#);
                  i := i - (i mod 2);
                  bus_rdata <= ram(i) & ram(i + 1);
               else
                  report "CPU reads unmapped " & to_hstring(bus_addr) & " at instruction " & integer'image(ninstr) severity failure;
               end if;
            else
               i := -1;
               if FLAT and a >= 16#080000# then i := to_integer(a(15 downto 0));
               elsif a >= 16#080000# and a <= 16#08FFFF# then i := to_integer(a(15 downto 0));
               elsif a >= 16#FFFD10# and a <= 16#FFFF0F# then i := 65536 + to_integer(a - 16#FFFD10#); end if;
               if i >= 0 then
                  if bus_be = "11" then
                     ram(i - (i mod 2)) := bus_wdata(15 downto 8); ram(i - (i mod 2) + 1) := bus_wdata(7 downto 0);
                  elsif bus_be = "10" then
                     ram(i) := bus_wdata(15 downto 8);
                  else
                     ram(i) := bus_wdata(7 downto 0);
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;

   main : process
      file f : text;
      variable l : line;
      variable w16 : std_logic_vector(15 downto 0);
      variable b8 : std_logic_vector(7 downto 0);
      variable v32 : std_logic_vector(31 downto 0);
      variable ers : std_logic_vector(255 downto 0);
      variable epc : std_logic_vector(23 downto 0);
      variable eccr : std_logic_vector(7 downto 0);
      variable n, irq_at, irq_v, idle : integer := 0;
      file ef, qf : text;
      variable have_irq : boolean := false;
      variable s : line;
   begin
      file_open(f, REF & "/rom.hex", read_mode);
      for i in 0 to 262143 loop readline(f, l); hread(l, w16); rom(i) := w16; end loop;
      file_close(f);
      file_open(f, REF & "/ram.hex", read_mode);
      for i in 0 to 65535 + 512 loop readline(f, l); hread(l, b8); ram(i) := b8; end loop;
      file_close(f);
      file_open(f, REF & "/start.txt", read_mode);
      readline(f, l);
      hread(l, v32); load_pc <= v32(23 downto 0);
      hread(l, v32); load_ccr <= v32(7 downto 0);
      hread(l, v32); syscr_ue <= v32(3);
      for i in 0 to 7 loop hread(l, v32); ers(32 * i + 31 downto 32 * i) := v32; end loop;
      load_er <= ers;
      file_close(f);
      file_open(ef, REF & "/expect.txt", read_mode);
      file_open(qf, REF & "/irqs.txt", read_mode);
      if not endfile(qf) then readline(qf, l); read(l, irq_at); read(l, irq_v); have_irq := true; end if;
      wait until rising_edge(clk); wait until rising_edge(clk);
      reset <= '0';
      loop
         wait until rising_edge(clk);
         if illegal = '1' then
            report "instruction " & integer'image(n) & " at " & to_hstring(dpc) & ": opcode not implemented" severity failure;
         end if;
         if irq_ack = '1' then irq <= '0'; end if;
         if dstart = '1' then
            idle := 0;
            exit when endfile(ef) or n >= MAXINS;
            readline(ef, l); hread(l, epc); hread(l, eccr);
            for i in 0 to 7 loop hread(l, v32); ers(32 * i + 31 downto 32 * i) := v32; end loop;
            if dpc /= epc or dccr /= eccr or der /= ers then
               write(s, string'("MISMATCH before instruction ") & integer'image(n)); writeline(output, s);
               write(s, string'("  MAME: PC ") & to_hstring(epc) & " CCR " & to_hstring(eccr));
               for i in 0 to 7 loop write(s, string'(" ") & to_hstring(ers(32 * i + 31 downto 32 * i))); end loop;
               writeline(output, s);
               write(s, string'("  VHDL: PC ") & to_hstring(dpc) & " CCR " & to_hstring(dccr));
               for i in 0 to 7 loop write(s, string'(" ") & to_hstring(der(32 * i + 31 downto 32 * i))); end loop;
               writeline(output, s);
               report "FAILED" severity failure;
            end if;
            ninstr <= n;
            -- the interrupt MAME took before instruction irq_at: raise it once instruction irq_at - 1 has started
            if have_irq and n + 1 = irq_at then
               irq <= '1'; irq_vec <= std_logic_vector(to_unsigned(irq_v, 6));
               if not endfile(qf) then readline(qf, l); read(l, irq_at); read(l, irq_v); else have_irq := false; end if;
            end if;
            n := n + 1;
         else
            idle := idle + 1;
            assert idle < 2000 report "no instruction for 2000 clocks after instruction " & integer'image(n) &
                                      " (PC " & to_hstring(dpc) & ")" severity failure;
         end if;
      end loop;
      if FLAT then                                           -- random tests: the RAM must also be MAME's at the end
         wait until rising_edge(clk); wait until rising_edge(clk);
         file_open(f, REF & "/expect_ram.hex", read_mode);
         for i in 0 to 65535 loop
            readline(f, l); hread(l, b8);
            if ram(i) /= b8 then
               report "RAM differs at " & to_hstring(to_unsigned(16#080000# + i, 24)) & ": VHDL " & to_hstring(ram(i)) &
                      ", MAME " & to_hstring(b8) severity failure;
            end if;
         end loop;
         file_close(f);
         report "tb_h8_cpu: RAM matches MAME at the end" severity note;
      end if;
      report "tb_h8_cpu: " & integer'image(n) & " instructions match MAME" severity note;
      done <= true;
      wait;
   end process;
end architecture;
