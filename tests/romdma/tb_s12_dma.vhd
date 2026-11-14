-- System test of the ROM DMA path: the core's dma.vhd (from an assembled core tree) with pocket/core/s12/s12_romdma.vhd
-- and an SDRAM channel 3 model (as tb_s12_romdma). The DMA registers are programmed the way Tekken 3 does it in MAME
-- (2026-11-14 trace): DPCR 0x33B33333, DICR 0x00A00000 (master + channel 5 IRQ), MADR, BCR = words, CHCR 0x01000000
-- (manual mode, start bit 24 only), then DICR 0x20A00000 to acknowledge. Each DMA must raise irqOut, clear CHCR bit 24,
-- and write ROM[o] | ROM[o + 1] << 16 to every RAM word (checked through dma.vhd's RAM write FIFO).
-- Run: tests/romdma/run_dma.sh CORE_TREE
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_s12_dma is
end entity;

architecture tb of tb_s12_dma is
   constant PROG : natural := 16#0400000#;
   constant BANK : natural := 16#0800000#;
   signal clk, clk3x : std_logic := '0';
   signal clk3xIndex : std_logic := '0';
   signal clk1xToggle, clk1xToggle3x, clk1xToggle3x_1 : std_logic := '0';
   signal reset : std_logic := '1';
   signal done : boolean := false;
   -- DMA bus
   signal bus_addr : unsigned(6 downto 0) := (others => '0');
   signal bus_dataWrite, bus_dataRead : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_read, bus_write : std_logic := '0';
   signal irqOut, dmaRequest, dmaStallCPU, dmaOn : std_logic;
   signal cpuPaused : std_logic := '0';
   signal fifo_adr : std_logic_vector(22 downto 0);
   signal fifo_data : std_logic_vector(31 downto 0);
   signal fifo_empty, fifo_read : std_logic := '0';
   -- ROM DMA
   signal romdma_start, romdma_pop, romdma_valid : std_logic;
   signal romdma_data : std_logic_vector(31 downto 0);
   signal offset : std_logic_vector(31 downto 0) := (others => '0');
   signal sd_req, sd_busy, sd_ready, grant : std_logic := '0';
   signal sd_addr : std_logic_vector(26 downto 0);
   signal sd_dout : std_logic_vector(31 downto 0) := (others => '0');
   -- RAM writes seen
   type ram_t is array (0 to 1023) of std_logic_vector(31 downto 0);
   signal ram : ram_t := (others => (others => 'U'));
   signal ram_base : natural := 0;
   signal ram_writes : natural := 0;

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
   clk   <= not clk after 15 ns when not done;      -- clk1x ~33 MHz
   clk3x <= not clk3x after 5 ns when not done;

   idma : entity work.dma
   port map (
      clk1x => clk, clk3x => clk3x, clk3xIndex => clk3xIndex, ce => '1', reset => reset,
      errorCHOP => open, errorDMACPU => open, errorDMAFIFO => open,
      TURBO => '0', TURBO_CACHE => '0', ram8mb => '1', ignoreCDTiming => '1',
      canDMA => '1', cpuPaused => cpuPaused, dmaRequest => dmaRequest, dmaStallCPU => dmaStallCPU, dmaOn => dmaOn, irqOut => irqOut,
      ram_Adr => open, ram_cnt => open, ram_ena => open,
      dma_wr => '0', dma_reqprocessed => '0', dma_data => (others => '0'),
      ram_dmafifo_adr => fifo_adr, ram_dmafifo_data => fifo_data, ram_dmafifo_empty => fifo_empty, ram_dmafifo_read => fifo_read,
      dma_cache_Adr => open, dma_cache_data => open, dma_cache_write => open,
      gpu_dmaRequest => '0', DMA_GPU_waiting => open, DMA_GPU_writeEna => open, DMA_GPU_readEna => open, DMA_GPU_write => open,
      DMA_GPU_read => (others => '0'),
      mdec_dmaWriteRequest => '0', mdec_dmaReadRequest => '0', DMA_MDEC_writeEna => open, DMA_MDEC_readEna => open,
      DMA_MDEC_write => open, DMA_MDEC_read => (others => '0'),
      cd_memctrl => (others => '0'), com0_delay => (others => '0'), DMA_CD_readEna => open, DMA_CD_read => (others => '0'),
      spu_timing_on => '0', spu_timing_value => (others => '0'), spu_dmaRequest => '0',
      DMA_SPU_writeEna => open, DMA_SPU_readEna => open, DMA_SPU_write => open, DMA_SPU_read => (others => '0'),
      romdma_start => romdma_start, romdma_pop => romdma_pop, romdma_data => romdma_data, romdma_valid => romdma_valid,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => bus_read, bus_write => bus_write,
      bus_dataRead => bus_dataRead,
      loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => open);

   ifetch : entity work.s12_romdma
   port map (clk => clk, reset => reset, start => romdma_start, offset => offset, pop => romdma_pop, data => romdma_data,
             valid => romdma_valid, sd_grant_ok => grant, sd_req => sd_req, sd_busy => sd_busy, sd_addr => sd_addr,
             sd_ready => sd_ready, sd_dout => sd_dout);

   -- SDRAM channel 3: request latched, 2-9 clocks, address at request or at completion
   sdram : process
      variable s1, s2 : positive := 5;
      variable r : real;
      variable lat, a : natural;
   begin
      wait until rising_edge(clk);
      sd_ready <= '0';
      if sd_req = '1' then
         a := to_integer(unsigned(sd_addr));
         uniform(s1, s2, r); lat := 2 + integer(trunc(r * 8.0));
         for i in 1 to lat loop
            wait until rising_edge(clk);
            assert sd_req = '0' report "second request while a read is in flight" severity failure;
         end loop;
         uniform(s1, s2, r);
         if r < 0.5 then a := to_integer(unsigned(sd_addr)); end if;
         sd_dout <= rom_word(a);
         sd_ready <= '1';
         wait until rising_edge(clk);
         sd_ready <= '0';
      end if;
   end process;

   arb : process
      variable s1, s2 : positive := 9;
      variable r : real;
   begin
      wait until rising_edge(clk);
      uniform(s1, s2, r);
      if r < 0.25 then grant <= '0'; else grant <= '1'; end if;
   end process;

   -- main RAM side (sdram.sv, clk3x): drain dma.vhd's write FIFO now and then, one-clk3x read pulses, record the words
   drain : process
      variable s1, s2 : positive := 13;
      variable r : real;
      variable i : integer;
   begin
      wait until rising_edge(clk3x);
      fifo_read <= '0';
      if fifo_read = '1' then wait until rising_edge(clk3x); end if;   -- at most every other clk3x
      uniform(s1, s2, r);
      if fifo_empty = '0' and r < 0.7 then
         fifo_read <= '1';
         i := (to_integer(unsigned(fifo_adr)) - ram_base) / 4;
         assert i >= 0 and i <= 1023 report "RAM write outside the test window" severity failure;
         ram(i) <= fifo_data;
         ram_writes <= ram_writes + 1;
      end if;
   end process;

   stim : process
      variable errors : natural := 0;

      procedure wr(a : natural; d : std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk);
         bus_addr <= to_unsigned(a, 7); bus_dataWrite <= d; bus_write <= '1';
         wait until rising_edge(clk);
         bus_write <= '0';
      end procedure;

      procedure rd(a : natural; d : out std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk);
         bus_addr <= to_unsigned(a, 7); bus_read <= '1';
         wait until rising_edge(clk);
         bus_read <= '0';
         wait until rising_edge(clk);
         d := bus_dataRead;
      end procedure;

      procedure rom_dma(off : std_logic_vector(31 downto 0); madr : natural; words : natural) is
         variable base, o, n : natural;
         variable chcr : std_logic_vector(31 downto 0);
         variable irq_seen : boolean := false;
      begin
         if off(31) = '1' then base := PROG; o := to_integer(unsigned(off(21 downto 0)));
         else base := BANK; o := to_integer(unsigned(off(24 downto 0))); end if;
         wait until rising_edge(clk);
         ram_base <= madr;                                 -- (ram has one driver, the drain process)
         offset <= off;                                    -- memorymux's 0x1F700000 register
         wr(16#70#, x"33B33333");                          -- DPCR
         wr(16#50#, x"80" & std_logic_vector(to_unsigned(madr, 24)));   -- MADR (kseg0, as the game writes it)
         wr(16#54#, std_logic_vector(to_unsigned(words, 32)));                 -- BCR
         n := ram_writes;
         wr(16#58#, x"01000000");                          -- CHCR: manual, start
         for t in 1 to 20 * words + 2000 loop
            wait until rising_edge(clk);
            if irqOut = '1' then irq_seen := true; end if;
            exit when irq_seen and ram_writes - n = words and fifo_empty = '1';
         end loop;
         if not irq_seen then report "DMA of " & integer'image(words) & " words: no IRQ" severity error; errors := errors + 1; end if;
         if ram_writes - n /= words then
            report "DMA of " & integer'image(words) & " words: " & integer'image(ram_writes - n) & " RAM writes" severity error;
            errors := errors + 1;
         end if;
         for t in 1 to 1000 loop                           -- let dma.vhd finish (STOPPING -> OFF), as the game's IRQ handler would
            exit when dmaOn = '0';
            wait until rising_edge(clk);
         end loop;
         if dmaOn /= '0' then report "DMA engine still on 1000 clocks after the DMA" severity error; errors := errors + 1; end if;
         rd(16#58#, chcr);
         if chcr(24) /= '0' then report "CHCR start bit still set after the DMA" severity error; errors := errors + 1; end if;
         for k in 0 to words - 1 loop
            if ram(k) /= rom_word(base + o + 4 * k) then
               report "word " & integer'image(k) & ": got " & to_hstring(ram(k)) & " expected " &
                      to_hstring(rom_word(base + o + 4 * k)) severity error;
               errors := errors + 1;
               exit;
            end if;
         end loop;
         wr(16#74#, x"20A00000");                          -- DICR: acknowledge channel 5
      end procedure;
   begin
      reset <= '1';
      for i in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      wr(16#74#, x"00A00000");                             -- DICR: master enable + channel 5 IRQ
      rom_dma(x"00C95E38", 16#3FFF90#, 1);                 -- the first DMAs of Tekken 3's boot (MAME log)
      rom_dma(x"00C95E3C", 16#273338#, 522);
      rom_dma(x"82247460", 16#3FFF90#, 1);
      rom_dma(x"82247464", 16#273CA8#, 16);
      rom_dma(x"0111D48C", 16#273CE8#, 14);
      report "tb_s12_dma: " & integer'image(errors) & " errors" severity note;
      assert errors = 0 report "FAILED" severity failure;
      done <= true;
      wait;
   end process;

   -- the CPU/DMA hand-over exactly as psx_top.vhd does it (ce = 1, no pause, canDMA = 1): dma.vhd's REP timing runs only
   -- while cpuPaused = 1
   process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then cpuPaused <= '0';
         elsif (cpuPaused = '1' and dmaOn = '1') or dmaRequest = '1' then cpuPaused <= '1';
         elsif dmaOn = '0' then cpuPaused <= '0';
         end if;
      end if;
   end process;

   -- clk3xIndex exactly as psx_top.vhd makes it
   process (clk) begin if rising_edge(clk) then clk1xToggle <= not clk1xToggle; end if; end process;
   process (clk3x)
   begin
      if rising_edge(clk3x) then
         clk1xToggle3x   <= clk1xToggle;
         clk1xToggle3x_1 <= clk1xToggle3x;
         clk3xIndex      <= '0';
         if (clk1xToggle3x_1 = clk1xToggle) then clk3xIndex <= '1'; end if;
      end if;
   end process;
end architecture;
