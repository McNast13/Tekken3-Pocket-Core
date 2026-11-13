-- H8/300H CPU sizing model (docs/STUDY.md, fit: "H8/300H datapath synthesised alone").
--
-- NOT a working CPU. It has the full-width datapath an H8/300H core needs, driven by a writable microcode store, so
-- Quartus can neither prune nor simplify it and the fit report gives a real ALM count and Fmax before the core exists:
--   ER0-ER7 with byte (RnH/RnL), word (Rn/En) and long lanes, two read ports and one write port;
--   32-bit ALU (add/addx/sub/subx/cmp/and/or/xor/not/neg/mov/extu/exts/daa/das) with H, N, Z, V, C at all three sizes;
--   shifter/rotator by 1 (shal/shar/shll/shlr/rotl/rotr/rotxl/rotxr) at all three sizes;
--   bit unit (bset/bclr/bnot/btst/bld/bild/bst/bist/band/biand/bor/bior/bxor/bixor) on a byte, bit number from an
--   immediate or a register;
--   mulxu/mulxs .b/.w (one DSP multiply); divxu/divxs .b/.w (iterative, one bit a clock, signed by negating around it);
--   effective address: register indirect, d16/d24 displacement, pre-decrement/post-increment by 1/2/4, @aa:8/16/24,
--   memory indirect @@aa:8 and vectors; PC with +2, disp8/disp16 branches and the 16 Bcc conditions; CCR with
--   ldc/stc/andc/orc/xorc; a 32-bit memory data register for long accesses as two word cycles; five instruction words.
-- Control: the first instruction word (or a prefix word's second word) indexes a decode table that gives the microcode
-- address; the microcode is 1024 x 72 bits. Both are RAMs loaded through ucode_* so their contents stay opaque.
-- Interrupts: a request with a vector number, taken at instruction boundaries when CCR.I is clear.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity h8_size is
   port (
      clk        : in  std_logic;
      ce         : in  std_logic;
      reset      : in  std_logic;
      -- microcode / decode table load (writable so their contents are opaque to synthesis)
      ucode_we   : in  std_logic;
      ucode_sel  : in  std_logic;                       -- 0 = microcode word, 1 = decode table entry
      ucode_addr : in  std_logic_vector(11 downto 0);
      ucode_data : in  std_logic_vector(71 downto 0);
      -- external bus (16-bit, big-endian: the even byte is D15-D8)
      bus_addr   : out std_logic_vector(23 downto 0);
      bus_dout   : out std_logic_vector(15 downto 0);
      bus_din    : in  std_logic_vector(15 downto 0);
      bus_rd     : out std_logic;
      bus_wr     : out std_logic;
      bus_be     : out std_logic_vector(1 downto 0);
      bus_ready  : in  std_logic;
      -- interrupt controller
      irq        : in  std_logic;
      irq_vec    : in  std_logic_vector(5 downto 0);
      irq_ack    : out std_logic
   );
end entity;

architecture arch of h8_size is
   subtype w32 is unsigned(31 downto 0);
   type regfile_t is array (0 to 7) of w32;
   signal er : regfile_t := (others => (others => '0'));

   type urom_t is array (0 to 1023) of std_logic_vector(71 downto 0);
   signal urom : urom_t;
   attribute ramstyle : string;
   attribute ramstyle of urom : signal is "M10K";
   type dtab_t is array (0 to 4095) of std_logic_vector(9 downto 0);
   signal dtab : dtab_t;
   attribute ramstyle of dtab : signal is "M10K";

   signal upc, dispatch : unsigned(9 downto 0) := (others => '0');
   signal mi : std_logic_vector(71 downto 0) := (others => '0');

   type irq_t is array (0 to 4) of std_logic_vector(15 downto 0);
   signal ir : irq_t := (others => (others => '0'));
   signal pc  : unsigned(23 downto 0) := (others => '0');
   signal mar : unsigned(23 downto 0) := (others => '0');
   signal mdr, tmp : w32 := (others => '0');
   -- CCR: I UI H U N Z V C
   signal ccr : std_logic_vector(7 downto 0) := x"80";

   -- microcode fields
   alias f_seq    : std_logic_vector(1 downto 0) is mi(1 downto 0);    -- next, jump, dispatch, conditional jump
   alias f_cond   : std_logic_vector(4 downto 0) is mi(6 downto 2);
   alias f_target : std_logic_vector(9 downto 0) is mi(16 downto 7);
   alias f_rsa    : std_logic_vector(2 downto 0) is mi(19 downto 17);  -- register field (nibble) for read port A
   alias f_rsb    : std_logic_vector(2 downto 0) is mi(22 downto 20);
   alias f_size   : std_logic_vector(1 downto 0) is mi(24 downto 23);  -- 00 byte, 01 word, 10 long
   alias f_szir   : std_logic is mi(25);                               -- size from the instruction word instead
   alias f_asrc   : std_logic_vector(2 downto 0) is mi(28 downto 26);
   alias f_bsrc   : std_logic_vector(3 downto 0) is mi(32 downto 29);
   alias f_alu    : std_logic_vector(3 downto 0) is mi(36 downto 33);
   alias f_sh     : std_logic_vector(2 downto 0) is mi(39 downto 37);
   alias f_res    : std_logic_vector(2 downto 0) is mi(42 downto 40);
   alias f_flagwe : std_logic is mi(43);
   alias f_flagmd : std_logic_vector(1 downto 0) is mi(45 downto 44);  -- arithmetic, logic (V=0), shift, bit (C only)
   alias f_regwe  : std_logic is mi(46);
   alias f_wsel   : std_logic_vector(2 downto 0) is mi(49 downto 47);
   alias f_eabase : std_logic_vector(1 downto 0) is mi(51 downto 50);
   alias f_eadisp : std_logic_vector(2 downto 0) is mi(54 downto 52);
   alias f_marwe  : std_logic is mi(55);
   alias f_marsrc : std_logic_vector(1 downto 0) is mi(57 downto 56);
   alias f_bus    : std_logic_vector(1 downto 0) is mi(59 downto 58);  -- none, read, write, instruction fetch
   alias f_pc     : std_logic_vector(2 downto 0) is mi(62 downto 60);
   alias f_irwr   : std_logic_vector(2 downto 0) is mi(65 downto 63);
   alias f_mdr    : std_logic_vector(1 downto 0) is mi(67 downto 66);
   alias f_tmpwe  : std_logic is mi(68);
   alias f_div    : std_logic_vector(1 downto 0) is mi(70 downto 69);  -- none, divxu, divxs
   alias f_ccrwe  : std_logic is mi(71);

   signal size : std_logic_vector(1 downto 0);
   signal na, nb, nw : std_logic_vector(3 downto 0);
   signal ra, rb, a, b, alu_r, sh_r, res, ea : w32;
   signal mul_r, div_r : w32;
   signal bit_r : unsigned(7 downto 0);
   signal bit_c, cond_ok, stall : std_logic;
   signal alu_c, alu_v, alu_h, sh_c, sh_v : std_logic;

   -- divider
   signal div_busy, div_neg_q, div_neg_r : std_logic := '0';
   signal div_cnt : unsigned(4 downto 0) := (others => '0');
   signal div_rem : unsigned(32 downto 0) := (others => '0');
   signal div_quo : unsigned(15 downto 0) := (others => '0');
   signal div_dsr : unsigned(15 downto 0) := (others => '0');
   signal div_word : std_logic := '0';

   function nib(sel : std_logic_vector(2 downto 0); i0, i1, i2 : std_logic_vector(15 downto 0)) return std_logic_vector is
   begin
      case sel is
         when "000"  => return i0(3 downto 0);
         when "001"  => return i0(7 downto 4);
         when "010"  => return i1(3 downto 0);
         when "011"  => return i1(7 downto 4);
         when "100"  => return i0(11 downto 8);
         when "101"  => return i1(11 downto 8);
         when "110"  => return "0111";              -- ER7 = SP
         when others => return i2(3 downto 0);
      end case;
   end function;

   -- read a register lane: byte RnH (n3=0) / RnL (n3=1), word Rn (n3=0) / En (n3=1), long ERn
   function rd(rf : regfile_t; n : std_logic_vector(3 downto 0); sz : std_logic_vector(1 downto 0)) return unsigned is
      variable r : w32 := rf(to_integer(unsigned(n(2 downto 0))));
   begin
      case sz is
         when "00" =>
            if n(3) = '0' then return resize(r(15 downto 8), 32); else return resize(r(7 downto 0), 32); end if;
         when "01" =>
            if n(3) = '0' then return resize(r(15 downto 0), 32); else return resize(r(31 downto 16), 32); end if;
         when others => return r;
      end case;
   end function;

   function msb(v : w32; sz : std_logic_vector(1 downto 0)) return std_logic is
   begin
      case sz is
         when "00"   => return v(7);
         when "01"   => return v(15);
         when others => return v(31);
      end case;
   end function;

   function zero(v : w32; sz : std_logic_vector(1 downto 0)) return std_logic is
   begin
      case sz is
         when "00"   => if v(7 downto 0) = 0 then return '1'; else return '0'; end if;
         when "01"   => if v(15 downto 0) = 0 then return '1'; else return '0'; end if;
         when others => if v = 0 then return '1'; else return '0'; end if;
      end case;
   end function;
begin
   -- microcode and decode table: synchronous RAMs (M10K)
   process (clk)
   begin
      if rising_edge(clk) then
         if ucode_we = '1' and ucode_sel = '0' then urom(to_integer(unsigned(ucode_addr(9 downto 0)))) <= ucode_data; end if;
         if ucode_we = '1' and ucode_sel = '1' then dtab(to_integer(unsigned(ucode_addr))) <= ucode_data(9 downto 0); end if;
      end if;
   end process;

   -- decode: the first word's top 12 bits, or for the 01/0A/1A/7x prefixes the second word's top byte
   process (clk)
      variable da : std_logic_vector(11 downto 0);
   begin
      if rising_edge(clk) then
         if ir(0)(15 downto 8) = x"01" or ir(0)(15 downto 8) = x"0A" or ir(0)(15 downto 8) = x"1A" or ir(0)(15 downto 12) = x"7" then
            da := "1111" & ir(1)(15 downto 8) xor ("00" & ir(0)(13 downto 12) & ir(0)(11 downto 8) & "0000");
         else
            da := ir(0)(15 downto 4);
         end if;
         dispatch <= unsigned(dtab(to_integer(unsigned(da))));
         mi <= urom(to_integer(upc));
      end if;
   end process;

   size <= ir(0)(9 downto 8) when f_szir = '1' else f_size;
   na <= nib(f_rsa, ir(0), ir(1), ir(2));
   nb <= nib(f_rsb, ir(0), ir(1), ir(2));
   nw <= nib(f_wsel, ir(0), ir(1), ir(2));
   ra <= rd(er, na, size);
   rb <= rd(er, nb, size);

   with f_asrc select a <=
      ra                         when "000",
      resize(pc, 32)             when "001",
      resize(unsigned(ccr), 32)  when "010",
      mdr                        when "011",
      resize(mar, 32)            when "100",
      tmp                        when "101",
      (others => '0')            when others;

   with f_bsrc select b <=
      rb                                                         when "0000",
      resize(unsigned(ir(0)(7 downto 0)), 32)                    when "0001",
      resize(unsigned(ir(1)), 32)                                when "0010",
      unsigned(ir(1)) & unsigned(ir(2))                          when "0011",
      to_unsigned(1, 32)                                         when "0100",
      to_unsigned(2, 32)                                         when "0101",
      to_unsigned(4, 32)                                         when "0110",
      mdr                                                        when "0111",
      resize(unsigned(ir(0)(6 downto 4)), 32)                    when "1000",   -- bit number #xx:3
      tmp                                                        when "1001",
      resize(unsigned(ir(1)(7 downto 0)) & unsigned(ir(2)), 32)  when "1010",   -- 24-bit immediate / address
      unsigned(ir(2)) & unsigned(ir(3))                          when "1011",   -- 32-bit immediate after a prefix
      (others => '0')                                            when others;

   -- ALU
   process (all)
      variable s : unsigned(32 downto 0);
      variable ci : unsigned(0 downto 0);
      variable bb, r : w32;
      variable h, cy : std_logic;
      variable sub : boolean;
      variable lo, hi : unsigned(3 downto 0);
      variable adj : unsigned(7 downto 0);
   begin
      sub := f_alu = "0010" or f_alu = "0011" or f_alu = "0100" or f_alu = "1001";
      ci := "0";
      if (f_alu = "0001" or f_alu = "0011") then ci(0) := ccr(0); end if;
      bb := b;
      if f_alu = "1001" then bb := a; end if;                             -- neg: 0 - a
      if sub then bb := not bb; ci(0) := not ci(0); end if;
      if f_alu = "1001" then s := ('0' & to_unsigned(0, 32)) + ('0' & bb) + ci;
      else s := ('0' & a) + ('0' & bb) + ci; end if;
      r := s(31 downto 0);
      -- carries out of bits 3/11/27 (H) and 7/15/31 (C) are the sum bit xor both operand bits one place up
      case size is
         when "00"   => h := a(4) xor bb(4) xor r(4);    cy := a(8) xor bb(8) xor r(8);
                        alu_v <= (a(7) xnor bb(7)) and (a(7) xor r(7));
         when "01"   => h := a(12) xor bb(12) xor r(12); cy := a(16) xor bb(16) xor r(16);
                        alu_v <= (a(15) xnor bb(15)) and (a(15) xor r(15));
         when others => h := a(28) xor bb(28) xor r(28); cy := s(32);
                        alu_v <= (a(31) xnor bb(31)) and (a(31) xor r(31));
      end case;
      if sub then h := not h; cy := not cy; end if;                       -- borrows
      alu_h <= h;
      alu_c <= cy;
      case f_alu is
         when "0101" => r := a and b;
         when "0110" => r := a or b;
         when "0111" => r := a xor b;
         when "1000" => r := not a;
         when "1010" => r := b;                                            -- mov
         when "1011" =>                                                    -- extu
            if size = "01" then r := resize(a(7 downto 0), 32); else r := resize(a(15 downto 0), 32); end if;
         when "1100" =>                                                    -- exts
            if size = "01" then r := unsigned(resize(signed(a(7 downto 0)), 32));
            else r := unsigned(resize(signed(a(15 downto 0)), 32)); end if;
         when "1101" | "1110" =>                                           -- daa / das (byte)
            lo := a(3 downto 0); hi := a(7 downto 4); adj := x"00";
            if ccr(5) = '1' or lo > 9 then adj(3 downto 0) := x"6"; end if;
            if ccr(0) = '1' or hi > 9 or (hi = 9 and lo > 9) then adj(7 downto 4) := x"6"; end if;
            if f_alu = "1101" then r := resize(a(7 downto 0) + adj, 32); else r := resize(a(7 downto 0) - adj, 32); end if;
         when others => null;
      end case;
      alu_r <= r;
   end process;

   -- shifter / rotator by one bit
   process (all)
      variable r : w32;
      variable top, bot : std_logic;
      variable n : integer range 7 to 31;
   begin
      case size is
         when "00" => n := 7; when "01" => n := 15; when others => n := 31;
      end case;
      top := a(n); bot := a(0); r := a;
      case f_sh is
         when "000" | "010" => r := shift_left(a, 1); sh_c <= top;                       -- shal / shll
         when "001"         => r := shift_right(a, 1); r(n) := top; sh_c <= bot;         -- shar
         when "011"         => r := shift_right(a, 1); r(n) := '0'; sh_c <= bot;         -- shlr
         when "100"         => r := shift_left(a, 1); r(0) := top; sh_c <= top;          -- rotl
         when "101"         => r := shift_right(a, 1); r(n) := bot; sh_c <= bot;         -- rotr
         when "110"         => r := shift_left(a, 1); r(0) := ccr(0); sh_c <= top;       -- rotxl
         when others        => r := shift_right(a, 1); r(n) := ccr(0); sh_c <= bot;      -- rotxr
      end case;
      if f_sh = "000" then sh_v <= a(n) xor a(n - 1); else sh_v <= '0'; end if;   -- shal sets V
      sh_r <= r;
   end process;

   -- bit unit: byte in a(7..0), bit number in b(2..0)
   process (all)
      variable v : unsigned(7 downto 0);
      variable k : integer range 0 to 7;
      variable bitv, inv : std_logic;
   begin
      v := a(7 downto 0); k := to_integer(b(2 downto 0)); bitv := v(k);
      inv := f_alu(3);                                                     -- the "i" forms invert the bit
      bit_c <= ccr(0);
      case f_alu(2 downto 0) is
         when "000" => v(k) := '1';                                        -- bset
         when "001" => v(k) := '0';                                        -- bclr
         when "010" => v(k) := not v(k);                                   -- bnot
         when "011" => bit_c <= bitv xor inv;                              -- bld / bild
         when "100" => v(k) := ccr(0) xor inv;                             -- bst / bist
         when "101" => bit_c <= ccr(0) and (bitv xor inv);                 -- band / biand
         when "110" => bit_c <= ccr(0) or (bitv xor inv);                  -- bor / bior
         when others => bit_c <= ccr(0) xor (bitv xor inv);                -- bxor / bixor
      end case;
      bit_r <= v;
   end process;

   -- multiplier: mulxu/mulxs .b (8x8) and .w (16x16), signedness from the prefix
   process (all)
      variable x, y : signed(16 downto 0);
   begin
      if size = "00" then
         x := resize(signed('0' & a(7 downto 0)), 17); y := resize(signed('0' & b(7 downto 0)), 17);
         if ir(0)(15 downto 8) = x"01" then x := resize(signed(a(7 downto 0)), 17); y := resize(signed(b(7 downto 0)), 17); end if;
      else
         x := signed('0' & a(15 downto 0)); y := signed('0' & b(15 downto 0));
         if ir(0)(15 downto 8) = x"01" then x := resize(signed(a(15 downto 0)), 17); y := resize(signed(b(15 downto 0)), 17); end if;
      end if;
      mul_r <= unsigned(resize(x * y, 32));
   end process;

   -- divider: restoring, one quotient bit a clock; divxs negates operands and results around it
   div_r <= (div_rem(15 downto 0) & div_quo) when div_word = '1' else
            resize(div_rem(7 downto 0) & div_quo(7 downto 0), 32);
   process (clk)
      variable t : unsigned(32 downto 0);
      variable dd : w32;
      variable ds : unsigned(15 downto 0);
   begin
      if rising_edge(clk) then
         if ce = '1' then
            if f_div /= "00" and div_busy = '0' then
               dd := a; ds := b(15 downto 0);
               div_word <= size(0) or size(1);
               div_neg_q <= '0'; div_neg_r <= '0';
               if f_div = "10" then                                        -- divxs
                  if a(31) = '1' then dd := unsigned(-signed(a)); end if;
                  if b(15) = '1' then ds := unsigned(-signed(b(15 downto 0))); end if;
                  div_neg_q <= a(31) xor b(15); div_neg_r <= a(31);
               end if;
               if size = "00" then
                  div_rem <= resize(dd(15 downto 8), 33); div_quo <= dd(7 downto 0) & x"00";
                  div_dsr <= x"00" & ds(7 downto 0); div_cnt <= to_unsigned(8, 5);
               else
                  div_rem <= resize(dd(31 downto 16), 33); div_quo <= dd(15 downto 0);
                  div_dsr <= ds; div_cnt <= to_unsigned(16, 5);
               end if;
               div_busy <= '1';
            elsif div_busy = '1' then
               t := div_rem(31 downto 0) & div_quo(15);
               if t >= ('0' & x"0000" & div_dsr) then
                  div_rem <= t - ('0' & x"0000" & div_dsr); div_quo <= div_quo(14 downto 0) & '1';
               else
                  div_rem <= t; div_quo <= div_quo(14 downto 0) & '0';
               end if;
               div_cnt <= div_cnt - 1;
               if div_cnt = 1 then
                  div_busy <= '0';
               end if;
            elsif div_neg_q = '1' or div_neg_r = '1' then
               if div_neg_q = '1' then div_quo <= unsigned(-signed(div_quo)); end if;
               if div_neg_r = '1' then div_rem <= unsigned(-signed(div_rem)); end if;
               div_neg_q <= '0'; div_neg_r <= '0';
            end if;
         end if;
      end if;
   end process;

   -- effective address
   process (all)
      variable base, disp : unsigned(23 downto 0);
      variable step : unsigned(23 downto 0);
   begin
      case f_eabase is
         when "00"   => base := ra(23 downto 0);
         when "01"   => base := pc;
         when "10"   => base := er(7)(23 downto 0);
         when others => base := (others => '0');
      end case;
      case size is
         when "00" => step := to_unsigned(1, 24); when "01" => step := to_unsigned(2, 24); when others => step := to_unsigned(4, 24);
      end case;
      case f_eadisp is
         when "000"  => disp := (others => '0');
         when "001"  => disp := unsigned(resize(signed(ir(1)), 24));                               -- d:16
         when "010"  => disp := unsigned(ir(2)(7 downto 0)) & unsigned(ir(3));                     -- d:24
         when "011"  => disp := (not step) + 1;                                                    -- @-ERn
         when "100"  => disp := step;                                                              -- @ERn+
         when "101"  => disp := x"FFFF" & unsigned(ir(0)(7 downto 0));                              -- @aa:8
         when "110"  => disp := unsigned(resize(signed(ir(1)), 24));                               -- @aa:16
         when others => disp := resize(unsigned(irq_vec) & "00", 24);                              -- vector
      end case;
      ea <= resize(base + disp, 32);
   end process;

   -- branch conditions
   process (all)
      variable c : std_logic_vector(3 downto 0);
      variable n, z, v, cy : std_logic;
   begin
      n := ccr(3); z := ccr(2); v := ccr(1); cy := ccr(0);
      if f_cond(4) = '0' then c := ir(0)(11 downto 8); else c := ir(1)(11 downto 8); end if;
      case c is
         when x"0" => cond_ok <= '1';
         when x"1" => cond_ok <= '0';
         when x"2" => cond_ok <= not (cy or z);
         when x"3" => cond_ok <= cy or z;
         when x"4" => cond_ok <= not cy;
         when x"5" => cond_ok <= cy;
         when x"6" => cond_ok <= not z;
         when x"7" => cond_ok <= z;
         when x"8" => cond_ok <= not v;
         when x"9" => cond_ok <= v;
         when x"A" => cond_ok <= not n;
         when x"B" => cond_ok <= n;
         when x"C" => cond_ok <= not (n xor v);
         when x"D" => cond_ok <= n xor v;
         when x"E" => cond_ok <= not (z or (n xor v));
         when others => cond_ok <= z or (n xor v);
      end case;
      case f_cond(3 downto 0) is                                           -- other microcode conditions
         when x"1" => cond_ok <= div_busy;
         when x"2" => cond_ok <= irq and not ccr(7);
         when x"3" => cond_ok <= size(1);
         when x"4" => cond_ok <= mar(0);
         when x"5" => cond_ok <= bit_c;
         when others => null;
      end case;
   end process;

   with f_res select res <=
      alu_r                  when "000",
      sh_r                   when "001",
      mdr                    when "010",
      ea                     when "011",
      mul_r                  when "100",
      div_r                  when "101",
      resize(bit_r, 32)      when "110",
      b                      when others;

   stall <= '1' when (f_bus /= "00" and bus_ready = '0') or (f_div /= "00" and div_busy = '1') else '0';

   bus_addr <= std_logic_vector(mar);
   bus_rd   <= '1' when f_bus = "01" or f_bus = "11" else '0';
   bus_wr   <= '1' when f_bus = "10" else '0';
   bus_be   <= "11" when size /= "00" else (not mar(0)) & mar(0);       -- byte: even address = upper lane
   bus_dout <= std_logic_vector(mdr(31 downto 16)) when f_mdr = "01" else
               std_logic_vector(mdr(7 downto 0)) & std_logic_vector(mdr(7 downto 0)) when size = "00" else
               std_logic_vector(mdr(15 downto 0));
   irq_ack  <= '1' when f_cond = "00010" and f_seq = "11" and ce = '1' else '0';

   process (clk)
      variable wv : w32;
      variable i : integer range 0 to 7;
      variable fl : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk) then
         if reset = '1' then
            upc <= (others => '0');
            ccr <= x"80";
            pc <= (others => '0');
         elsif ce = '1' and stall = '0' then
            -- sequencer
            case f_seq is
               when "00"   => upc <= upc + 1;
               when "01"   => upc <= unsigned(f_target);
               when "10"   => upc <= dispatch;
               when others => if cond_ok = '1' then upc <= unsigned(f_target); else upc <= upc + 1; end if;
            end case;

            -- register write, by lane
            if f_regwe = '1' then
               i := to_integer(unsigned(nw(2 downto 0)));
               wv := er(i);
               case size is
                  when "00" =>
                     if nw(3) = '0' then wv(15 downto 8) := res(7 downto 0); else wv(7 downto 0) := res(7 downto 0); end if;
                  when "01" =>
                     if nw(3) = '0' then wv(15 downto 0) := res(15 downto 0); else wv(31 downto 16) := res(15 downto 0); end if;
                  when others => wv := res;
               end case;
               er(i) <= wv;
            end if;
            -- address register writeback for @-ERn / @ERn+
            if f_eadisp = "011" or f_eadisp = "100" then
               i := to_integer(unsigned(na(2 downto 0)));
               er(i)(23 downto 0) <= ea(23 downto 0);
            end if;

            -- flags
            if f_flagwe = '1' then
               case f_flagmd is
                  when "00" => ccr(5) <= alu_h; ccr(3) <= msb(alu_r, size); ccr(2) <= zero(alu_r, size); ccr(1) <= alu_v; ccr(0) <= alu_c;
                  when "01" => ccr(3) <= msb(res, size); ccr(2) <= zero(res, size); ccr(1) <= '0';
                  when "10" => ccr(3) <= msb(sh_r, size); ccr(2) <= zero(sh_r, size); ccr(1) <= sh_v; ccr(0) <= sh_c;
                  when others => ccr(0) <= bit_c; if f_alu(2 downto 0) = "011" then null; else ccr(2) <= not a(to_integer(b(2 downto 0))); end if;
               end case;
            end if;
            if f_ccrwe = '1' then ccr <= std_logic_vector(res(7 downto 0)); end if;

            if f_tmpwe = '1' then tmp <= res; end if;

            -- memory address / data
            if f_marwe = '1' then
               case f_marsrc is
                  when "00"   => mar <= ea(23 downto 0);
                  when "01"   => mar <= pc;
                  when "10"   => mar <= mar + 2;
                  when others => mar <= er(7)(23 downto 0);
               end case;
            end if;
            case f_mdr is
               when "01"   => mdr(31 downto 16) <= unsigned(bus_din);
               when "10"   => if size = "00" then
                                 if mar(0) = '0' then mdr <= resize(unsigned(bus_din(15 downto 8)), 32);
                                 else mdr <= resize(unsigned(bus_din(7 downto 0)), 32); end if;
                              else mdr(15 downto 0) <= unsigned(bus_din); end if;
               when "11"   => mdr <= res;
               when others => null;
            end case;

            -- instruction words
            if f_bus = "11" and f_irwr /= "111" then
               ir(to_integer(unsigned(f_irwr)) mod 5) <= bus_din;
            end if;

            -- program counter
            case f_pc is
               when "001"  => pc <= pc + 2;
               when "010"  => pc <= ea(23 downto 0);
               when "011"  => pc <= pc + unsigned(resize(signed(ir(0)(7 downto 0)), 24));
               when "100"  => pc <= pc + unsigned(resize(signed(ir(1)), 24));
               when "101"  => pc <= mdr(23 downto 0);
               when others => null;
            end case;
         end if;
      end if;
   end process;
end architecture;
