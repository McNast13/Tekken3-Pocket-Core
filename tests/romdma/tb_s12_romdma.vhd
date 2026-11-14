-- Testbench for pocket/core/s12/s12_romdma.vhd. SDRAM channel 3 is modelled as sdram.sv behaves: sd_req is latched as a
-- request (so it must be a one-clock pulse: a second pulse before sd_ready is an error), the read takes a random 2-9 clocks,
-- and uses the address at the request or at completion, at random (early or late grant); grant is withheld at random. Each DMA
-- word is checked against MAME's rule: ROM[o] | ROM[o + 1] << 16 = the little-endian 32-bit word at byte offset o.
-- Run: tests/romdma/run.sh
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_s12_romdma is
end entity;

architecture tb of tb_s12_romdma is
   constant PROG : natural := 16#0400000#;
   constant BANK : natural := 16#0800000#;
   signal clk : std_logic := '0';
   signal reset, start, pop, valid, sd_req, sd_busy, sd_ready, grant : std_logic := '0';
   signal offset, data, sd_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal sd_addr : std_logic_vector(26 downto 0);
   signal done : boolean := false;

   function rom_byte(a : natural) return natural is
   begin
      return (a * 7 + a / 256 + a / 65536) mod 256;
   end function;

   function rom_word(a : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(rom_byte(a + 3), 8)) & std_logic_vector(to_unsigned(rom_byte(a + 2), 8)) &
             std_logic_vector(to_unsigned(rom_byte(a + 1), 8)) & std_logic_vector(to_unsigned(rom_byte(a), 8));
   end function;
begin
   clk <= not clk after 5 ns when not done;

   dut : entity work.s12_romdma
   port map (clk => clk, reset => reset, start => start, offset => offset, pop => pop, data => data, valid => valid,
             sd_grant_ok => grant, sd_req => sd_req, sd_busy => sd_busy, sd_addr => sd_addr, sd_ready => sd_ready, sd_dout => sd_dout);

   -- SDRAM channel 3 model
   sdram : process
      variable s1, s2 : positive := 7;
      variable r : real;
      variable lat, a : natural;
   begin
      wait until rising_edge(clk);
      sd_ready <= '0';
      if sd_req = '1' then
         a := to_integer(unsigned(sd_addr));                     -- granted at once: the address of the request ...
         uniform(s1, s2, r); lat := 2 + integer(trunc(r * 8.0));
         for i in 1 to lat loop
            wait until rising_edge(clk);
            assert sd_req = '0' report "second request while a read is in flight" severity failure;
            assert sd_busy = '1' report "busy dropped during a read" severity failure;
         end loop;
         uniform(s1, s2, r);
         if r < 0.5 then a := to_integer(unsigned(sd_addr)); end if;   -- ... or granted late: the address as it stands now
         sd_dout <= rom_word(a);
         assert a mod 4 = 0 report "unaligned SDRAM address" severity failure;
         sd_ready <= '1';
         wait until rising_edge(clk);
         sd_ready <= '0';
      end if;
   end process;

   -- channel 3 held off now and then (the wave reader's turn)
   arb : process
      variable s1, s2 : positive := 3;
      variable r : real;
   begin
      wait until rising_edge(clk);
      uniform(s1, s2, r);
      if r < 0.25 then grant <= '0'; else grant <= '1'; end if;
   end process;

   stim : process
      variable s1, s2 : positive := 11;
      variable r : real;
      variable errors : natural := 0;

      procedure run_dma(off : std_logic_vector(31 downto 0); words : natural; abort_after : natural) is
         variable base, o, got : natural;
      begin
         if off(31) = '1' then base := PROG; o := to_integer(unsigned(off(21 downto 0)));
         else base := BANK; o := to_integer(unsigned(off(24 downto 0))); end if;
         offset <= off; start <= '1';
         wait until rising_edge(clk);
         wait for 1 ns;
         start <= '0';
         got := 0;
         while got < words loop
            if got = abort_after then return; end if;             -- leave the DMA early: the next start must flush
            uniform(s1, s2, r);
            if valid = '1' and r < 0.6 then
               pop <= '1';
               if data /= rom_word(base + o + 4 * got) then
                  report "word " & integer'image(got) & " at offset " & to_hstring(off) & ": got " & to_hstring(data) &
                         " expected " & to_hstring(rom_word(base + o + 4 * got)) severity error;
                  errors := errors + 1;
               end if;
               got := got + 1;
            else
               pop <= '0';
            end if;
            wait until rising_edge(clk);
            wait for 1 ns;                                       -- sample after the DUT's registers have updated
            pop <= '0';
         end loop;
      end procedure;
   begin
      reset <= '1'; wait until rising_edge(clk); wait until rising_edge(clk); reset <= '0';
      run_dma(x"80000000", 64, 999);              -- program ROM, aligned
      run_dma(x"80012346", 64, 999);              -- program ROM, odd half-word
      run_dma(x"00123456", 64, 999);              -- banked ROM, odd half-word
      run_dma(x"01A00000", 64, 999);              -- banked ROM near the top of 28 MB, aligned
      run_dma(x"00000002", 40, 5);                -- abandoned after 5 words with reads in flight ...
      run_dma(x"0055AA00", 64, 999);              -- ... and the next DMA must not see any of them
      run_dma(x"80300002", 200, 999);             -- long odd DMA
      report "tb_s12_romdma: " & integer'image(errors) & " errors" severity note;
      assert errors = 0 report "FAILED" severity failure;
      done <= true;
      wait;
   end process;
end architecture;
