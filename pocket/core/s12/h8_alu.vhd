-- H8/300H ALU for Tekken 3's H8/3002 (docs/H8.md). Combinational: result and CCR for one operation at byte, word or
-- long size. The flag rules are MAME's (tools/h8model/mame/h8.cpp do_* and set_nz* helpers, h8.lst daa/das), which
-- the reference recordings come from; tests/h8/alu checks every operation against the generated Python model.
--   op    operation (constants below); sz "00" byte, "01" word, "10" long
--   a, b  operands, used at the size given (upper bits ignored); shifts, rotates, daa and das work on a
-- CCR bits: I 7, UI 6, H 5, U 4, N 3, Z 2, V 1, C 0. Only the flags an operation affects change.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package h8_alu_pkg is
   constant ALU_ADD   : unsigned(4 downto 0) := to_unsigned(0, 5);    -- a + b: H N Z V C
   constant ALU_ADDX  : unsigned(4 downto 0) := to_unsigned(1, 5);    -- a + b + C: H N V C, Z only cleared (byte)
   constant ALU_SUB   : unsigned(4 downto 0) := to_unsigned(2, 5);    -- a - b: H N Z V C (cmp, neg = 0 - b)
   constant ALU_SUBX  : unsigned(4 downto 0) := to_unsigned(3, 5);    -- a - b - C: H N V C, Z only cleared (byte)
   constant ALU_INC   : unsigned(4 downto 0) := to_unsigned(4, 5);    -- a + b: N Z V
   constant ALU_DEC   : unsigned(4 downto 0) := to_unsigned(5, 5);    -- a - b: N Z V
   constant ALU_NZV   : unsigned(4 downto 0) := to_unsigned(6, 5);    -- b: N Z, V cleared (mov, logic, not, ext)
   constant ALU_NZ    : unsigned(4 downto 0) := to_unsigned(7, 5);    -- b: N Z (mulxs)
   constant ALU_SHAL  : unsigned(4 downto 0) := to_unsigned(8, 5);
   constant ALU_SHAR  : unsigned(4 downto 0) := to_unsigned(9, 5);
   constant ALU_SHLL  : unsigned(4 downto 0) := to_unsigned(10, 5);
   constant ALU_SHLR  : unsigned(4 downto 0) := to_unsigned(11, 5);
   constant ALU_ROTL  : unsigned(4 downto 0) := to_unsigned(12, 5);
   constant ALU_ROTR  : unsigned(4 downto 0) := to_unsigned(13, 5);
   constant ALU_ROTXL : unsigned(4 downto 0) := to_unsigned(14, 5);
   constant ALU_ROTXR : unsigned(4 downto 0) := to_unsigned(15, 5);
   constant ALU_DAA   : unsigned(4 downto 0) := to_unsigned(16, 5);   -- byte
   constant ALU_DAS   : unsigned(4 downto 0) := to_unsigned(17, 5);   -- byte
   constant ALU_PASS  : unsigned(4 downto 0) := to_unsigned(18, 5);   -- b, flags unchanged (adds, subs, mulxu)
end package;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.h8_alu_pkg.all;

entity h8_alu is
   port (
      op      : in  unsigned(4 downto 0);
      sz      : in  std_logic_vector(1 downto 0);
      a, b    : in  std_logic_vector(31 downto 0);
      ccr_in  : in  std_logic_vector(7 downto 0);
      res     : out std_logic_vector(31 downto 0);
      ccr_out : out std_logic_vector(7 downto 0)
   );
end entity;

architecture rtl of h8_alu is
begin
   process (op, sz, a, b, ccr_in)
      variable msb, hb   : integer range 0 to 31;              -- sign bit; half-carry: carry out of bit hb
      variable mask      : unsigned(31 downto 0);
      variable ua, ub, r : unsigned(31 downto 0);
      variable s         : unsigned(32 downto 0);               -- sum / difference with carry
      variable hs        : unsigned(28 downto 0);
      variable hmask     : unsigned(28 downto 0);       -- the bits below the half-carry: 0xF / 0xFFF / 0xFFFFFFF
      variable cin       : unsigned(0 downto 0);
      variable c         : std_logic_vector(7 downto 0);
      variable adj       : unsigned(7 downto 0);
      variable n, z      : std_logic;

      -- C's "res & 0x100" on an n-bit sum computed in a wider integer: the bit just above the size
      function above(v : unsigned(32 downto 0); m : integer) return std_logic is
      begin
         return v(m + 1);
      end function;
   begin
      case sz is
         when "00"   => msb := 7;  hb := 3;  mask := x"000000FF"; hmask := to_unsigned(16#F#, 29);
         when "01"   => msb := 15; hb := 11; mask := x"0000FFFF"; hmask := to_unsigned(16#FFF#, 29);
         when others => msb := 31; hb := 27; mask := x"FFFFFFFF"; hmask := to_unsigned(16#FFFFFFF#, 29);
      end case;
      ua := unsigned(a) and mask;
      ub := unsigned(b) and mask;
      c := ccr_in;
      r := (others => '0');
      if c(0) = '1' then cin := "1"; else cin := "0"; end if;

      case op is
         when ALU_ADD | ALU_ADDX | ALU_INC =>
            if op = ALU_ADDX then
               s := ('0' & ua) + ('0' & ub) + cin;
               hs := resize(ua(28 downto 0) and hmask, 29)
                     + resize(ub(28 downto 0) and hmask, 29) + cin;
            else
               s := ('0' & ua) + ('0' & ub);
               hs := resize(ua(28 downto 0) and hmask, 29)
                     + resize(ub(28 downto 0) and hmask, 29);
            end if;
            r := s(31 downto 0) and mask;
            if r = 0 then z := '1'; else z := '0'; end if;
            n := r(msb);
            if op = ALU_INC then
               c(3) := n and not z; c(2) := z;
            else
               c(5) := hs(hb + 1);
               c(0) := above(s, msb);
               if op = ALU_ADDX then
                  c(3) := n;
                  if z = '0' then c(2) := '0'; end if;
               else
                  c(3) := n and not z; c(2) := z;
               end if;
            end if;
            c(1) := (not (ua(msb) xor ub(msb))) and (ua(msb) xor r(msb));
         when ALU_SUB | ALU_SUBX | ALU_DEC =>
            if op = ALU_SUBX then
               s := ('0' & ua) - ('0' & ub) - cin;
               hs := resize(ua(28 downto 0) and hmask, 29)
                     - resize(ub(28 downto 0) and hmask, 29) - cin;
            else
               s := ('0' & ua) - ('0' & ub);
               hs := resize(ua(28 downto 0) and hmask, 29)
                     - resize(ub(28 downto 0) and hmask, 29);
            end if;
            r := s(31 downto 0) and mask;
            if r = 0 then z := '1'; else z := '0'; end if;
            n := r(msb);
            if op = ALU_DEC then
               c(3) := n and not z; c(2) := z;
            else
               c(5) := hs(hb + 1);
               c(0) := above(s, msb);
               if op = ALU_SUBX then
                  c(3) := n;
                  if z = '0' then c(2) := '0'; end if;
               else
                  c(3) := n and not z; c(2) := z;
               end if;
            end if;
            c(1) := (ua(msb) xor ub(msb)) and (ua(msb) xor r(msb));
         when ALU_NZV | ALU_NZ =>
            r := ub;
            if r = 0 then z := '1'; else z := '0'; end if;
            c(3) := r(msb) and not z; c(2) := z;
            if op = ALU_NZV then c(1) := '0'; end if;
         when ALU_SHAL | ALU_SHLL =>
            r := shift_left(ua, 1) and mask;
            c(0) := ua(msb);
            c(1) := '0';
            if op = ALU_SHAL then c(1) := ua(msb) xor ua(msb - 1); end if;
            if r = 0 then z := '1'; else z := '0'; end if;
            c(3) := r(msb) and not z; c(2) := z;
         when ALU_SHAR | ALU_SHLR =>
            r := shift_right(ua, 1);
            if op = ALU_SHAR then r(msb) := ua(msb); end if;
            c(0) := ua(0); c(1) := '0';
            if r = 0 then z := '1'; else z := '0'; end if;
            c(3) := r(msb) and not z; c(2) := z;
         when ALU_ROTL | ALU_ROTXL =>
            r := shift_left(ua, 1) and mask;
            if op = ALU_ROTL then r(0) := ua(msb); else r(0) := ccr_in(0); end if;
            c(0) := ua(msb); c(1) := '0';
            if r = 0 then z := '1'; else z := '0'; end if;
            c(3) := r(msb) and not z; c(2) := z;
         when ALU_ROTR | ALU_ROTXR =>
            r := shift_right(ua, 1);
            if op = ALU_ROTR then r(msb) := ua(0); else r(msb) := ccr_in(0); end if;
            c(0) := ua(0); c(1) := '0';
            if r = 0 then z := '1'; else z := '0'; end if;
            c(3) := r(msb) and not z; c(2) := z;
         when ALU_DAA | ALU_DAS =>
            -- the correction (h8.lst daa.b / das.b), then add8's flags on a + correction
            adj := x"00";
            if op = ALU_DAA then
               if ccr_in(0) = '1' then
                  if ccr_in(5) = '1' then
                     if ua(7 downto 4) <= 3 and ua(3 downto 0) <= 3 then adj := x"66"; end if;
                  elsif ua(7 downto 4) <= 2 then
                     if ua(3 downto 0) <= 9 then adj := x"60"; else adj := x"66"; end if;
                  end if;
               else
                  if ccr_in(5) = '1' then
                     if ua(3 downto 0) <= 3 then
                        if ua(7 downto 4) <= 9 then adj := x"06"; else adj := x"66"; end if;
                     end if;
                  elsif ua(3 downto 0) <= 9 then
                     if ua(7 downto 4) <= 9 then adj := x"00"; else adj := x"60"; end if;
                  else
                     if ua(7 downto 4) <= 8 then adj := x"06"; else adj := x"66"; end if;
                  end if;
               end if;
            else
               if ccr_in(0) = '1' then
                  if ccr_in(5) = '1' then
                     if ua(7 downto 4) >= 6 and ua(3 downto 0) >= 6 then adj := x"9A"; end if;
                  elsif ua(7 downto 4) >= 7 and ua(3 downto 0) <= 9 then
                     adj := x"A0";
                  end if;
               elsif ccr_in(5) = '1' then
                  if ua(7 downto 4) <= 8 and ua(3 downto 0) >= 6 then adj := x"FA"; end if;
               end if;
            end if;
            s := ('0' & x"000000" & ua(7 downto 0)) + ('0' & x"000000" & adj);
            hs := resize(ua(3 downto 0), 29) + resize(adj(3 downto 0), 29);
            r := s(31 downto 0) and x"000000FF";
            if r = 0 then z := '1'; else z := '0'; end if;
            c(5) := hs(4); c(0) := s(8);
            c(3) := r(7) and not z; c(2) := z;
            c(1) := (not (ua(7) xor adj(7))) and (ua(7) xor r(7));
         when others =>                                          -- ALU_PASS
            r := ub;
      end case;
      res <= std_logic_vector(r);
      ccr_out <= c;
   end process;
end architecture;
