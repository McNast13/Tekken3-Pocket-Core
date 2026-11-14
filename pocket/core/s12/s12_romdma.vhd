-- System 12 ROM DMA fetcher (docs/CORE_T3.md item 5).
--
-- On System 12, DMA channel 5 copies ROM into main RAM. The game first writes the ROM offset (0x1F700000 + o, data d:
-- offset = o * 2 or d << 16; bit 31 selects the program ROM, otherwise the banked ROM), then starts channel 5. MAME
-- (namcos12_rom_read) builds each 32-bit RAM word from two 16-bit ROM words: ROM[o] or ROM[o + 1] << 16, which is a
-- little-endian 32-bit read of the ROM image at byte offset o, as long as the image sits in SDRAM byte for byte.
--
-- This block prefetches those words from SDRAM into an 8-word FIFO as soon as a channel 5 DMA starts, and the DMA pops
-- one word per RAM write (dma.vhd stalls while the FIFO is empty). The offset is 2-byte aligned, so for an odd half-word
-- start the upper half of each SDRAM word is carried into the next DMA word. Prefetching may run past the end of the
-- DMA; the next start flushes it.
--
-- SDRAM side (sdram.sv channel 3, shared with the C352 wave reader): sd_req is a one-clock pulse (sdram.sv latches
-- it, and would latch a second request if it stayed high); sd_addr stays steady from the pulse until sd_ready, since
-- sdram.sv re-registers the address every clock until its arbiter grants (see the 2026-07-11 ch3 address-hold fix in
-- SYSTEM11.sv). busy is high for the whole read. sd_grant_ok lets the owner of channel 3 hold this block off.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity s12_romdma is
   generic (
      PROGROM_BASE   : unsigned(26 downto 0) := to_unsigned(16#0400000#, 27);   -- 4 MB program ROM
      BANKROM_BASE   : unsigned(26 downto 0) := to_unsigned(16#0800000#, 27)    -- 28 MB banked ROM
   );
   port (
      clk            : in  std_logic;
      reset          : in  std_logic;
      -- DMA side
      start          : in  std_logic;                       -- pulse: a channel 5 DMA (ROM -> RAM) begins
      offset         : in  std_logic_vector(31 downto 0);   -- the 0x1F700000 offset register
      pop            : in  std_logic;                       -- the DMA takes data (only while valid)
      data           : out std_logic_vector(31 downto 0);
      valid          : out std_logic;
      -- SDRAM side
      sd_grant_ok    : in  std_logic;                       -- channel 3 free for this block
      sd_req         : out std_logic;                       -- one-clock pulse
      sd_busy        : out std_logic;                       -- a read is in flight (owns channel 3's address)
      sd_addr        : out std_logic_vector(26 downto 0);
      sd_ready       : in  std_logic;
      sd_dout        : in  std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of s12_romdma is
   type fifo_t is array (0 to 7) of std_logic_vector(31 downto 0);
   signal fifo : fifo_t;
   signal wp, rp : unsigned(2 downto 0) := (others => '0');
   signal count : unsigned(3 downto 0) := (others => '0');
   signal addr : unsigned(26 downto 0) := (others => '0');   -- next SDRAM word (4-byte aligned)
   signal odd, have_carry, active, busy, req : std_logic := '0';
   signal carry : std_logic_vector(15 downto 0) := (others => '0');
   signal gen : unsigned(1 downto 0) := (others => '0');      -- bumped on start: a read in flight from before is dropped
   signal req_gen : unsigned(1 downto 0) := (others => '0');
begin
   data  <= fifo(to_integer(rp));
   valid <= '1' when count /= 0 else '0';
   sd_req  <= req;
   sd_busy <= busy;
   sd_addr <= std_logic_vector(addr);

   process (clk)
      variable push : boolean;
      variable word : std_logic_vector(31 downto 0);
      variable base : unsigned(26 downto 0);
      variable o    : unsigned(26 downto 0);
      variable n    : unsigned(3 downto 0);
   begin
      if rising_edge(clk) then
         push := false;
         req <= '0';
         n := count;
         if pop = '1' and count /= 0 then
            rp <= rp + 1;
            n := n - 1;
         end if;

         if reset = '1' then
            active <= '0'; busy <= '0'; wp <= (others => '0'); rp <= (others => '0'); n := (others => '0');
         elsif start = '1' then
            if offset(31) = '1' then
               base := PROGROM_BASE; o := resize(unsigned(offset(21 downto 0)), 27);      -- 4 MB
            else
               base := BANKROM_BASE; o := resize(unsigned(offset(24 downto 0)), 27);      -- up to 32 MB
            end if;
            addr <= base + (o(26 downto 2) & "00");
            odd <= o(1);
            have_carry <= '0';
            active <= '1';
            gen <= gen + 1;
            wp <= (others => '0'); rp <= (others => '0'); n := (others => '0');
            if busy = '1' and sd_ready = '0' then
               null;                                     -- the old read finishes below and is dropped by gen
            else
               busy <= '0';
            end if;
         else
            if busy = '1' and sd_ready = '1' then
               busy <= '0';
               if req_gen = gen then
                  addr <= addr + 4;
                  if odd = '0' then
                     word := sd_dout; push := true;
                  elsif have_carry = '0' then
                     carry <= sd_dout(31 downto 16); have_carry <= '1';  -- first word of an odd start: keep the upper half
                  else
                     word := sd_dout(15 downto 0) & carry; carry <= sd_dout(31 downto 16); push := true;
                  end if;
               end if;
            elsif busy = '0' and active = '1' and sd_grant_ok = '1' and count < 6 then
               busy <= '1';                              -- room for this word and one in flight
               req <= '1';
               req_gen <= gen;
            end if;
         end if;

         if push then
            fifo(to_integer(wp)) <= word;
            wp <= wp + 1;
            n := n + 1;
         end if;
         count <= n;
      end if;
   end process;
end architecture;
