-- The C352's registers and voice positions as MAME 0.289's c352.cpp keeps them, for the H8 testbenches (tests/h8/sys,
-- tests/h8/c76): the H8 polls the voice flags, so when a sample ends matters, and it depends only on what the H8 wrote
-- (bank, start, end, loop, frequency, flags) and the sample clock (88.2 kHz: 25.4016 MHz / 288, one per 384 clocks of
-- 33.8688 MHz). No wave data or audio. Registers: word offsets 0-0xFF are 32 voices of 8 (vol_f, vol_r, freq, flags,
-- bank, start, end, loop), 0x200 control.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package c352_model_pkg is
   type c352_regs_t is array (0 to 1023) of std_logic_vector(15 downto 0);
   type c352_pos_t is array (0 to 31) of unsigned(23 downto 0);
   type c352_cnt_t is array (0 to 31) of unsigned(15 downto 0);
   constant C352_CLKS : integer := 384;    -- clocks of 33.8688 MHz per C352 sample
   -- a write to 0x404 (word 0x202): run the key-ons and key-offs (c352_device::write)
   procedure c352_keys(variable r : inout c352_regs_t; variable pos : inout c352_pos_t; variable cnt : inout c352_cnt_t);
   -- one sample: advance every busy voice (c352_device::sound_stream_update / fetch_sample)
   procedure c352_tick(variable r : inout c352_regs_t; variable pos : inout c352_pos_t; variable cnt : inout c352_cnt_t);
end package;

package body c352_model_pkg is
   constant BUSY : integer := 15;
   constant KEYON : integer := 14;
   constant KEYOFF : integer := 13;
   constant LOOPHIST : integer := 11;
   constant LDIR : integer := 6;
   constant LINK : integer := 5;
   constant NOISE : integer := 4;
   constant LOOPF : integer := 1;
   constant REVERSE : integer := 0;

   procedure c352_keys(variable r : inout c352_regs_t; variable pos : inout c352_pos_t; variable cnt : inout c352_cnt_t) is
      variable f : std_logic_vector(15 downto 0);
   begin
      for v in 0 to 31 loop
         f := r(8 * v + 3);
         if f(KEYON) = '1' then
            pos(v) := unsigned(r(8 * v + 4)(7 downto 0)) & unsigned(r(8 * v + 5));
            cnt(v) := x"FFFF";
            f(BUSY) := '1'; f(KEYON) := '0'; f(LOOPHIST) := '0';
         end if;
         if f(KEYOFF) = '1' then
            f(BUSY) := '0'; f(KEYOFF) := '0';
            cnt(v) := x"FFFF";
         end if;
         r(8 * v + 3) := f;
      end loop;
   end procedure;

   procedure c352_tick(variable r : inout c352_regs_t; variable pos : inout c352_pos_t; variable cnt : inout c352_cnt_t) is
      variable f : std_logic_vector(15 downto 0);
      variable nxt : unsigned(16 downto 0);
      variable p16, wend, wloop : unsigned(15 downto 0);
   begin
      for v in 0 to 31 loop
         f := r(8 * v + 3);
         if f(BUSY) = '1' then
            nxt := ('0' & cnt(v)) + unsigned(r(8 * v + 2));
            if nxt(16) = '1' and f(NOISE) = '0' then            -- fetch_sample: the position moves
               p16 := pos(v)(15 downto 0);
               wend := unsigned(r(8 * v + 6)); wloop := unsigned(r(8 * v + 7));
               if f(LOOPF) = '1' and f(REVERSE) = '1' then        -- ping-pong loop: never ends
                  if f(LDIR) = '1' and p16 = wloop then f(LDIR) := '0';
                  elsif f(LDIR) = '0' and p16 = wend then f(LDIR) := '1'; end if;
                  if f(LDIR) = '1' then pos(v) := pos(v) - 1; else pos(v) := pos(v) + 1; end if;
               elsif p16 = wend then
                  if f(LINK) = '1' and f(LOOPF) = '1' then
                     pos(v) := unsigned(r(8 * v + 5)(7 downto 0)) & wloop; f(LOOPHIST) := '1';
                  elsif f(LOOPF) = '1' then
                     pos(v) := pos(v)(23 downto 16) & wloop; f(LOOPHIST) := '1';
                  else
                     f(KEYOFF) := '1'; f(BUSY) := '0';           -- the sample ended
                  end if;
               else
                  if f(REVERSE) = '1' then pos(v) := pos(v) - 1; else pos(v) := pos(v) + 1; end if;
               end if;
            end if;
            cnt(v) := nxt(15 downto 0);
            r(8 * v + 3) := f;
         end if;
      end loop;
   end procedure;
end package body;
