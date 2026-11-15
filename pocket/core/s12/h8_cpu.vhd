-- H8/300H CPU for Tekken 3's H8/3002 (docs/H8.md): advanced mode (24-bit addresses, 32-bit vectors and stack frames),
-- multi-cycle, not cycle-exact (the sound program's timing comes from its timer interrupts). Instruction behaviour is
-- MAME's (tools/h8model/mame/h8.lst); the flag rules are in h8_alu.vhd. Checked against the MAME recording by
-- tests/h8/cpu (replay of Tekken 3's own H8 program).
--
-- Bus: 16-bit, big-endian (the even byte is bits 15-8). A request (bus_rd or bus_wr, with bus_addr, bus_be and
-- bus_wdata) is held until bus_ack, for one clock; read data is taken from bus_rdata in that clock. bus_be: "11" word
-- (bus_addr even), "10" the even byte, "01" the odd byte; for a byte write the byte is on both lanes.
-- Interrupts: irq with irq_vec is taken between instructions (the interrupt controller has already applied the
-- CCR masks); irq_ack pulses as the vector is read. syscr_ue is SYSCR's UE bit: 0 = an interrupt sets I and UI.
-- Test start: with load_state = 1 during reset, the CPU starts at load_pc with load_ccr and load_er instead of
-- reading the reset vector.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.h8_alu_pkg.all;

entity h8_cpu is
   port (
      clk, ce, reset : in  std_logic;
      bus_addr   : out std_logic_vector(23 downto 0);
      bus_wdata  : out std_logic_vector(15 downto 0);
      bus_rdata  : in  std_logic_vector(15 downto 0);
      bus_rd     : out std_logic;
      bus_wr     : out std_logic;
      bus_be     : out std_logic_vector(1 downto 0);
      bus_ack    : in  std_logic;
      irq        : in  std_logic;
      irq_vec    : in  std_logic_vector(5 downto 0);
      irq_ack    : out std_logic;
      syscr_ue   : in  std_logic;
      ccr_o      : out std_logic_vector(7 downto 0);
      -- test / debug
      load_state : in  std_logic := '0';
      load_pc    : in  std_logic_vector(23 downto 0) := (others => '0');
      load_ccr   : in  std_logic_vector(7 downto 0) := (others => '0');
      load_er    : in  std_logic_vector(255 downto 0) := (others => '0');
      dbg_start  : out std_logic;                          -- an instruction starts: dbg_pc / dbg_ccr / dbg_er are its "before"
      dbg_pc     : out std_logic_vector(23 downto 0);
      dbg_ccr    : out std_logic_vector(7 downto 0);
      dbg_er     : out std_logic_vector(255 downto 0);
      dbg_illegal : out std_logic                          -- an opcode this core does not have (stays set)
   );
end entity;

architecture rtl of h8_cpu is
   type regs_t is array (0 to 7) of unsigned(31 downto 0);
   signal er  : regs_t := (others => (others => '0'));
   signal ccr : std_logic_vector(7 downto 0) := x"80";
   signal pc  : unsigned(23 downto 0) := (others => '0');
   type ir_t is array (0 to 4) of std_logic_vector(15 downto 0);
   signal ir  : ir_t := (others => (others => '0'));

   type state_t is (S_RESET, S_RESETV, S_BOUND, S_FETCH, S_FETCHX, S_EXEC, S_BUS, S_ALU, S_IRQ, S_HALT);
   signal st, ret_st : state_t := S_RESET;
   signal step, ret_step : integer range 0 to 31 := 0;
   signal nwords, nfetched : integer range 0 to 5 := 1;
   signal ins_pc : unsigned(23 downto 0) := (others => '0');      -- address of the instruction executing

   -- bus request
   signal b_addr  : unsigned(23 downto 0) := (others => '0');
   signal b_wdata : std_logic_vector(15 downto 0) := (others => '0');
   signal b_rd, b_wr : std_logic := '0';
   signal b_be    : std_logic_vector(1 downto 0) := "11";
   signal mdr     : std_logic_vector(15 downto 0) := (others => '0');   -- last read word (byte reads: in 7-0)

   -- operation set up by the decode
   signal ea      : unsigned(31 downto 0) := (others => '0');
   signal tmp     : unsigned(31 downto 0) := (others => '0');    -- memory operand / long data being assembled
   signal tmp2    : unsigned(31 downto 0) := (others => '0');
   signal sz      : std_logic_vector(1 downto 0) := "00";         -- "00" byte, "01" word, "10" long
   signal dreg    : std_logic_vector(3 downto 0) := (others => '0');
   signal wb      : std_logic := '0';                             -- the ALU result goes to dreg
   signal setccr  : std_logic := '0';                             -- the ALU's CCR is kept

   -- ALU
   signal alu_op  : unsigned(4 downto 0) := ALU_PASS;
   signal alu_sz  : std_logic_vector(1 downto 0) := "00";
   signal alu_a, alu_b, alu_res : std_logic_vector(31 downto 0) := (others => '0');
   signal alu_ccr : std_logic_vector(7 downto 0);
   signal illegal : std_logic := '0';
   signal vecn    : unsigned(5 downto 0) := (others => '0');    -- vector being taken (interrupt or trapa)
   signal trap    : std_logic := '0';                           -- it is a trapa: no irq_ack

   function sx8(v : std_logic_vector(7 downto 0)) return unsigned is
   begin
      return unsigned(resize(signed(v), 32));
   end function;
   function sx16(v : std_logic_vector(15 downto 0)) return unsigned is
   begin
      return unsigned(resize(signed(v), 32));
   end function;
   function bsize(s : std_logic_vector(1 downto 0)) return unsigned is      -- 1, 2, 4
   begin
      case s is
         when "00" => return to_unsigned(1, 32);
         when "01" => return to_unsigned(2, 32);
         when others => return to_unsigned(4, 32);
      end case;
   end function;
   -- Bcc condition, h8.lst: bt bf bhi bls bcc bcs bne beq bvc bvs bpl bmi bge blt bgt ble
   function cond(c : std_logic_vector(3 downto 0); f : std_logic_vector(7 downto 0)) return boolean is
      variable n, z, v, cy : boolean;
   begin
      n := f(3) = '1'; z := f(2) = '1'; v := f(1) = '1'; cy := f(0) = '1';
      case c is
         when x"0" => return true;
         when x"1" => return false;
         when x"2" => return not (cy or z);
         when x"3" => return cy or z;
         when x"4" => return not cy;
         when x"5" => return cy;
         when x"6" => return not z;
         when x"7" => return z;
         when x"8" => return not v;
         when x"9" => return v;
         when x"A" => return not n;
         when x"B" => return n;
         when x"C" => return n = v;
         when x"D" => return n /= v;
         when x"E" => return not z and (n = v);
         when others => return z or (n /= v);
      end case;
   end function;
begin
   ialu : entity work.h8_alu
      port map (op => alu_op, sz => alu_sz, a => alu_a, b => alu_b, ccr_in => ccr, res => alu_res, ccr_out => alu_ccr);

   bus_addr  <= std_logic_vector(b_addr);
   bus_wdata <= b_wdata;
   bus_rd    <= b_rd;
   bus_wr    <= b_wr;
   bus_be    <= b_be;
   ccr_o     <= ccr;
   dbg_pc    <= std_logic_vector(pc);
   dbg_ccr   <= ccr;
   dbg_illegal <= illegal;
   g_dbg : for i in 0 to 7 generate
      dbg_er(32 * i + 31 downto 32 * i) <= std_logic_vector(er(i));
   end generate;

   process (clk)
      variable w0, w1    : std_logic_vector(15 downto 0);
      variable hi        : std_logic_vector(7 downto 0);
      variable r         : integer range 0 to 7;
      variable v32       : unsigned(31 downto 0);
      variable bitn      : integer range 0 to 7;
      variable bval      : std_logic_vector(7 downto 0);
      variable c         : std_logic;
      variable q, rm     : unsigned(31 downto 0);
      variable sq        : signed(31 downto 0);
      variable lsz       : std_logic_vector(1 downto 0);

      -- register file access (MAME h8.h / h8h.h): r8 n: bit 3 = low byte; r16 n: bit 3 = E (high) word; r32: n mod 8
      -- results are (7 downto 0) / (15 downto 0) whichever half they come from, so callers can slice them
      impure function rd8(n : std_logic_vector(3 downto 0)) return std_logic_vector is
         variable v : std_logic_vector(7 downto 0);
      begin
         if n(3) = '1' then v := std_logic_vector(er(to_integer(unsigned(n(2 downto 0))))(7 downto 0));
         else v := std_logic_vector(er(to_integer(unsigned(n(2 downto 0))))(15 downto 8)); end if;
         return v;
      end function;
      impure function rd16(n : std_logic_vector(3 downto 0)) return std_logic_vector is
         variable v : std_logic_vector(15 downto 0);
      begin
         if n(3) = '1' then v := std_logic_vector(er(to_integer(unsigned(n(2 downto 0))))(31 downto 16));
         else v := std_logic_vector(er(to_integer(unsigned(n(2 downto 0))))(15 downto 0)); end if;
         return v;
      end function;
      impure function rd32(n : std_logic_vector(3 downto 0)) return unsigned is
      begin
         return er(to_integer(unsigned(n(2 downto 0))));
      end function;
      -- register value at a size, zero-extended
      impure function rdsz(n : std_logic_vector(3 downto 0); s : std_logic_vector(1 downto 0)) return std_logic_vector is
      begin
         case s is
            when "00"   => return x"000000" & rd8(n);
            when "01"   => return x"0000" & rd16(n);
            when others => return std_logic_vector(rd32(n));
         end case;
      end function;
      procedure wr8(n : std_logic_vector(3 downto 0); v : std_logic_vector(7 downto 0)) is
         variable i : integer range 0 to 7;
      begin
         i := to_integer(unsigned(n(2 downto 0)));
         if n(3) = '1' then er(i)(7 downto 0) <= unsigned(v); else er(i)(15 downto 8) <= unsigned(v); end if;
      end procedure;
      procedure wr16(n : std_logic_vector(3 downto 0); v : std_logic_vector(15 downto 0)) is
         variable i : integer range 0 to 7;
      begin
         i := to_integer(unsigned(n(2 downto 0)));
         if n(3) = '1' then er(i)(31 downto 16) <= unsigned(v); else er(i)(15 downto 0) <= unsigned(v); end if;
      end procedure;
      procedure wr32(n : std_logic_vector(3 downto 0); v : unsigned(31 downto 0)) is
      begin
         er(to_integer(unsigned(n(2 downto 0)))) <= v;
      end procedure;
      procedure wrsz(n : std_logic_vector(3 downto 0); s : std_logic_vector(1 downto 0); v : std_logic_vector(31 downto 0)) is
      begin
         case s is
            when "00"   => wr8(n, v(7 downto 0));
            when "01"   => wr16(n, v(15 downto 0));
            when others => wr32(n, unsigned(v));
         end case;
      end procedure;
      -- bus requests: return to (S_EXEC, step k) when acknowledged
      procedure rd_word(a_in : unsigned; k : integer) is
         variable a : unsigned(a_in'length - 1 downto 0) := a_in;   -- any range in, DOWNTO here
      begin
         b_addr <= a(23 downto 1) & '0'; b_be <= "11"; b_rd <= '1'; ret_st <= S_EXEC; ret_step <= k; st <= S_BUS;
      end procedure;
      procedure rd_byte(a_in : unsigned; k : integer) is
         variable a : unsigned(a_in'length - 1 downto 0) := a_in;   -- any range in, DOWNTO here
      begin
         b_addr <= a(23 downto 0);
         if a(0) = '0' then b_be <= "10"; else b_be <= "01"; end if;
         b_rd <= '1'; ret_st <= S_EXEC; ret_step <= k; st <= S_BUS;
      end procedure;
      procedure wr_word(a_in : unsigned; d : std_logic_vector(15 downto 0); k : integer) is
         variable a : unsigned(a_in'length - 1 downto 0) := a_in;   -- any range in, DOWNTO here
      begin
         b_addr <= a(23 downto 1) & '0'; b_be <= "11"; b_wdata <= d; b_wr <= '1'; ret_st <= S_EXEC; ret_step <= k; st <= S_BUS;
      end procedure;
      procedure wr_byte(a_in : unsigned; d : std_logic_vector(7 downto 0); k : integer) is
         variable a : unsigned(a_in'length - 1 downto 0) := a_in;   -- any range in, DOWNTO here
      begin
         b_addr <= a(23 downto 0);
         if a(0) = '0' then b_be <= "10"; else b_be <= "01"; end if;
         b_wdata <= d & d; b_wr <= '1'; ret_st <= S_EXEC; ret_step <= k; st <= S_BUS;
      end procedure;
      -- ALU step: compute, then (S_ALU) keep result / CCR as wb / setccr say, then continue at (S_EXEC, k)
      procedure alu(op : unsigned(4 downto 0); s : std_logic_vector(1 downto 0); a, b : std_logic_vector(31 downto 0);
                    d : std_logic_vector(3 downto 0); w, f : std_logic; k : integer) is
      begin
         alu_op <= op; alu_sz <= s; alu_a <= a; alu_b <= b; dreg <= d; sz <= s; wb <= w; setccr <= f;
         ret_step <= k; st <= S_ALU;
      end procedure;
      procedure done is                             -- the instruction ends: an interrupt, or the next fetch
      begin
         if irq = '1' then
            st <= S_IRQ; step <= 0; vecn <= unsigned(irq_vec); trap <= '0';
         else
            st <= S_FETCH; dbg_start <= '1';
         end if;
      end procedure;
      procedure bad is
      begin
         illegal <= '1'; st <= S_HALT;
      end procedure;
   begin
      if rising_edge(clk) then
         dbg_start <= '0';
         irq_ack <= '0';
         if reset = '1' then
            st <= S_RESET; b_rd <= '0'; b_wr <= '0'; illegal <= '0';
            if load_state = '1' then
               pc <= unsigned(load_pc); ccr <= load_ccr;
               for i in 0 to 7 loop er(i) <= unsigned(load_er(32 * i + 31 downto 32 * i)); end loop;
            end if;
         elsif ce = '1' then
            case st is
               when S_RESET =>
                  if load_state = '1' then
                     st <= S_FETCH; dbg_start <= '1';
                  else
                     ccr <= ccr or x"80";
                     rd_word(to_unsigned(0, 24), 0); ret_st <= S_RESETV;
                  end if;
               when S_RESETV =>                               -- 32-bit reset vector at 0
                  if step = 0 then
                     tmp(31 downto 16) <= unsigned(mdr); rd_word(to_unsigned(2, 24), 1); ret_st <= S_RESETV;
                  else
                     pc <= tmp(23 downto 16) & unsigned(mdr); st <= S_FETCH; dbg_start <= '1';
                  end if;

               when S_BUS =>
                  if bus_ack = '1' then
                     b_rd <= '0'; b_wr <= '0';
                     if b_be = "10" then mdr <= x"00" & bus_rdata(15 downto 8);
                     elsif b_be = "01" then mdr <= x"00" & bus_rdata(7 downto 0);
                     else mdr <= bus_rdata; end if;
                     st <= ret_st; step <= ret_step;
                  end if;

               when S_ALU =>
                  if wb = '1' then wrsz(dreg, sz, alu_res); end if;
                  if setccr = '1' then ccr <= alu_ccr; end if;
                  tmp2 <= unsigned(alu_res);
                  st <= S_EXEC; step <= ret_step;

               when S_BOUND =>
                  if irq = '1' then
                     st <= S_IRQ; step <= 0; vecn <= unsigned(irq_vec); trap <= '0';
                  else
                     st <= S_FETCH; dbg_start <= '1';
                  end if;

               when S_IRQ =>                                  -- MAME "irq h": push PC (low word, then CCR:PC high byte)
                  case step is
                     when 0 =>
                        v32 := er(7) - 2; er(7) <= v32;
                        wr_word(v32, std_logic_vector(pc(15 downto 0)), 1); ret_st <= S_IRQ;
                     when 1 =>
                        v32 := er(7) - 2; er(7) <= v32;
                        wr_word(v32, ccr & std_logic_vector(pc(23 downto 16)), 2); ret_st <= S_IRQ;
                     when 2 =>
                        irq_ack <= not trap;
                        tmp <= resize(vecn & "00", 32);
                        rd_word(resize(vecn & "00", 24), 3); ret_st <= S_IRQ;
                     when 3 =>
                        tmp2(31 downto 16) <= unsigned(mdr);
                        rd_word(tmp(23 downto 0) + 2, 4); ret_st <= S_IRQ;
                     when others =>
                        pc <= tmp2(23 downto 16) & unsigned(mdr);
                        if syscr_ue = '1' then ccr(7) <= '1'; else ccr(7 downto 6) <= "11"; end if;
                        st <= S_FETCH; dbg_start <= '1';
                  end case;

               when S_FETCH =>                                -- the opcode word; then its length
                  ins_pc <= pc;
                  rd_word(pc, 0); ret_st <= S_FETCHX; nfetched <= 0;

               when S_FETCHX =>
                  ir(nfetched) <= mdr;
                  pc <= pc + 2;
                  if nfetched = 0 then
                     w0 := mdr; hi := w0(15 downto 8);
                     -- instruction length in words, from the first word (and for 01xx the second, read next)
                     case hi is
                        when x"58" | x"5A" | x"5C" | x"5E" | x"6E" | x"6F" | x"79" | x"7B" | x"7C" | x"7D" | x"7E" | x"7F" =>
                           nwords <= 2;
                        when x"6A" | x"6B" =>
                           if w0(7 downto 4) = x"2" or w0(7 downto 4) = x"A" then nwords <= 3; else nwords <= 2; end if;
                        when x"78" => nwords <= 4;
                        when x"7A" => nwords <= 3;
                        when x"01" =>
                           if w0(7 downto 0) = x"00" or w0(7 downto 0) = x"40" or w0(7 downto 0) = x"C0" or
                              w0(7 downto 0) = x"D0" or w0(7 downto 0) = x"F0" then
                              nwords <= 2;                     -- at least: refined when the second word is in
                           else
                              nwords <= 1;
                           end if;
                        when others => nwords <= 1;
                     end case;
                  elsif nfetched = 1 and ir(0)(15 downto 8) = x"01" and (ir(0)(7 downto 0) = x"00" or ir(0)(7 downto 0) = x"40") then
                     w1 := mdr;                               -- mov.l / ldc.w / stc.w with an effective address
                     if w1(15 downto 8) = x"6B" then
                        if w1(7 downto 4) = x"2" or w1(7 downto 4) = x"A" then nwords <= 4; else nwords <= 3; end if;
                     elsif w1(15 downto 8) = x"6F" then nwords <= 3;
                     elsif w1(15 downto 8) = x"78" then nwords <= 5;
                     end if;
                  end if;
                  nfetched <= nfetched + 1;
                  if (nfetched = 0 and not (mdr(15 downto 8) = x"58" or mdr(15 downto 8) = x"5A" or mdr(15 downto 8) = x"5C" or
                                            mdr(15 downto 8) = x"5E" or mdr(15 downto 8) = x"6E" or mdr(15 downto 8) = x"6F" or
                                            mdr(15 downto 8) = x"79" or mdr(15 downto 8) = x"7B" or mdr(15 downto 8) = x"7C" or
                                            mdr(15 downto 8) = x"7D" or mdr(15 downto 8) = x"7E" or mdr(15 downto 8) = x"7F" or
                                            mdr(15 downto 8) = x"6A" or mdr(15 downto 8) = x"6B" or mdr(15 downto 8) = x"78" or
                                            mdr(15 downto 8) = x"7A" or
                                            (mdr(15 downto 8) = x"01" and (mdr(7 downto 0) = x"00" or mdr(7 downto 0) = x"40" or
                                             mdr(7 downto 0) = x"C0" or mdr(7 downto 0) = x"D0" or mdr(7 downto 0) = x"F0"))))
                     or (nfetched > 0 and nfetched + 1 >= nwords and
                         not (nfetched = 1 and ir(0)(15 downto 8) = x"01" and (ir(0)(7 downto 0) = x"00" or ir(0)(7 downto 0) = x"40") and
                              (mdr(15 downto 8) = x"6B" or mdr(15 downto 8) = x"6F" or mdr(15 downto 8) = x"78"))) then
                     st <= S_EXEC; step <= 0;
                  else
                     rd_word(pc + 2, 0); ret_st <= S_FETCHX;
                  end if;

               when S_EXEC =>
                  w0 := ir(0); hi := w0(15 downto 8);
                  case hi is
                     -------------------------------------------------------------- 00 nop
                     when x"00" =>
                        if w0(7 downto 0) = x"00" then done; else bad; end if;

                     -------------------------------------------------------------- 01 prefixed
                     when x"01" =>
                        w1 := ir(1);
                        if w0(7 downto 0) = x"00" or w0(7 downto 0) = x"40" then
                           -- mov.l (0100) / ldc.w, stc.w (0140) with a memory operand; w1 6x selects the mode
                           -- size now (a variable: sz, the signal, only changes at the next clock)
                           if w0(7 downto 0) = x"00" then lsz := "10"; else lsz := "01"; end if;
                           sz <= lsz;
                           case step is
                              when 0 =>
                                 case w1(15 downto 8) is
                                    when x"69" => ea <= rd32('0' & w1(6 downto 4));
                                    when x"6B" =>
                                       if w1(7 downto 4) = x"2" or w1(7 downto 4) = x"A" then
                                          ea <= unsigned(ir(2)) & unsigned(ir(3));
                                       else
                                          ea <= sx16(ir(2));
                                       end if;
                                    when x"6D" =>                -- @ERs+ (load) / @-ERd (store)
                                       if w1(7) = '0' then
                                          ea <= rd32('0' & w1(6 downto 4));
                                       else
                                          ea <= rd32('0' & w1(6 downto 4)) - bsize(lsz);
                                       end if;
                                    when x"6F" => ea <= rd32('0' & w1(6 downto 4)) + sx16(ir(2));
                                    when x"78" => ea <= rd32('0' & w1(6 downto 4)) + (unsigned(ir(3)) & unsigned(ir(4)));
                                    when others => bad;
                                 end case;
                                 step <= 1;
                              when 1 =>
                                 if w0(7 downto 0) = x"00" then
                                    if (w1(15 downto 8) /= x"78" and w1(7) = '0') or (w1(15 downto 8) = x"78" and ir(2)(7) = '0') then
                                       rd_word(ea, 2);           -- load: high word
                                    else
                                       if w1(15 downto 8) = x"6D" then wr32('0' & w1(6 downto 4), ea); end if;
                                       if w1(15 downto 8) = x"78" then r := to_integer(unsigned(ir(2)(2 downto 0)));
                                       else r := to_integer(unsigned(w1(2 downto 0))); end if;
                                       alu(ALU_NZV, "10", x"00000000", std_logic_vector(er(r)), "0000", '0', '1', 10);
                                    end if;
                                 else                            -- ldc.w (load CCR from the high byte) / stc.w
                                    if (w1(15 downto 8) /= x"78" and w1(7) = '0') or (w1(15 downto 8) = x"78" and ir(2)(7) = '0') then
                                       rd_word(ea, 20);
                                    else
                                       if w1(15 downto 8) = x"6D" then wr32('0' & w1(6 downto 4), ea); end if;
                                       wr_word(ea, ccr & ccr, 22);
                                    end if;
                                 end if;
                              when 2 =>
                                 tmp(31 downto 16) <= unsigned(mdr); rd_word(ea + 2, 3);
                              when 3 =>
                                 v32 := tmp(31 downto 16) & unsigned(mdr);
                                 if w1(15 downto 8) = x"6D" then wr32('0' & w1(6 downto 4), ea + 4); end if;
                                 if w1(15 downto 8) = x"78" then
                                    alu(ALU_NZV, "10", x"00000000", std_logic_vector(v32), '0' & ir(2)(2 downto 0), '1', '1', 30);
                                 else
                                    alu(ALU_NZV, "10", x"00000000", std_logic_vector(v32), '0' & w1(2 downto 0), '1', '1', 30);
                                 end if;
                              when 10 => wr_word(ea, std_logic_vector(tmp2(31 downto 16)), 11);
                              when 11 => wr_word(ea + 2, std_logic_vector(tmp2(15 downto 0)), 30);
                              when 20 =>
                                 ccr <= mdr(15 downto 8);
                                 if w1(15 downto 8) = x"6D" then wr32('0' & w1(6 downto 4), ea + 2); end if;
                                 done;
                              when 22 => done;
                              when others => done;
                           end case;
                        elsif w0(7 downto 0) = x"80" then       -- sleep: wait for an interrupt
                           if irq = '1' then done; end if;
                        elsif w0(7 downto 0) = x"C0" then       -- mulxs.b: s8(Rd low byte) * s8(Rs) / mulxs.w
                           if step /= 0 then
                              done;
                           elsif w1(15 downto 8) = x"50" then
                              sq := resize(signed(rd16(w1(3 downto 0))(7 downto 0)) * signed(rd8(w1(7 downto 4))), 32);
                              alu(ALU_NZ, "01", x"00000000", std_logic_vector(sq), w1(3 downto 0), '1', '1', 30);
                           elsif w1(15 downto 8) = x"52" then
                              sq := resize(signed(rd16('0' & w1(2 downto 0))) * signed(rd16(w1(7 downto 4))), 32);
                              alu(ALU_NZ, "10", x"00000000", std_logic_vector(sq), '0' & w1(2 downto 0), '1', '1', 30);
                           else
                              bad;
                           end if;
                        elsif w0(7 downto 0) = x"D0" then       -- divxs.b / divxs.w
                           if step = 0 then
                              if w1(15 downto 8) = x"51" then
                                 tmp <= unsigned(resize(signed(rd16(w1(3 downto 0))), 32));
                                 tmp2 <= unsigned(resize(signed(rd8(w1(7 downto 4))), 32));
                              else
                                 tmp <= rd32('0' & w1(2 downto 0));
                                 tmp2 <= unsigned(resize(signed(rd16(w1(7 downto 4))), 32));
                              end if;
                              step <= 1;
                           else
                              ccr(2) <= '0'; ccr(3) <= '0';
                              if tmp2 = 0 then
                                 ccr(2) <= '1';
                              else
                                 -- truncating signed division (h8.lst divxs: quotient toward zero, remainder with p's sign)
                                 sq := signed(tmp) / signed(tmp2);
                                 v32 := unsigned(signed(tmp) rem signed(tmp2));
                                 if sq < 0 then ccr(3) <= '1'; end if;
                                 if w1(15 downto 8) = x"51" then
                                    wr16(w1(3 downto 0), std_logic_vector(v32(7 downto 0)) & std_logic_vector(sq(7 downto 0)));
                                 else
                                    wr32('0' & w1(2 downto 0), v32(15 downto 0) & unsigned(sq(15 downto 0)));
                                 end if;
                              end if;
                              done;
                           end if;
                        elsif w0(7 downto 0) = x"F0" then       -- or.l / xor.l / and.l ERs, ERd
                           if step = 0 then
                              case w1(15 downto 8) is
                                 when x"64" => v32 := rd32('0' & w1(6 downto 4)) or rd32('0' & w1(2 downto 0));
                                 when x"65" => v32 := rd32('0' & w1(6 downto 4)) xor rd32('0' & w1(2 downto 0));
                                 when others => v32 := rd32('0' & w1(6 downto 4)) and rd32('0' & w1(2 downto 0));
                              end case;
                              alu(ALU_NZV, "10", x"00000000", std_logic_vector(v32), '0' & w1(2 downto 0), '1', '1', 1);
                           else
                              done;
                           end if;
                        else
                           bad;
                        end if;

                     -------------------------------------------------------------- 02-07 CCR
                     when x"02" => wr8(w0(3 downto 0), ccr); done;                                          -- stc ccr, r8
                     when x"03" => ccr <= rd8(w0(3 downto 0)); done;                                       -- ldc r8, ccr
                     when x"04" => ccr <= ccr or w0(7 downto 0); done;                                     -- orc
                     when x"05" => ccr <= ccr xor w0(7 downto 0); done;                                    -- xorc
                     when x"06" => ccr <= ccr and w0(7 downto 0); done;                                    -- andc
                     when x"07" => ccr <= w0(7 downto 0); done;                                            -- ldc #imm

                     -------------------------------------------------------------- register ALU, one word
                     when x"08" | x"09" | x"0A" | x"0B" | x"0C" | x"0D" | x"0E" | x"0F" | x"10" | x"11" | x"12" | x"13" |
                          x"14" | x"15" | x"16" | x"17" | x"18" | x"19" | x"1A" | x"1B" | x"1C" | x"1D" | x"1E" | x"1F" |
                          x"64" | x"65" | x"66" =>
                        if step = 0 then
                           case hi is
                              when x"08" => alu(ALU_ADD, "00", rdsz(w0(3 downto 0), "00"), rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);
                              when x"09" => alu(ALU_ADD, "01", rdsz(w0(3 downto 0), "01"), rdsz(w0(7 downto 4), "01"), w0(3 downto 0), '1', '1', 1);
                              when x"0A" =>
                                 if w0(7 downto 4) = x"0" then             -- inc.b
                                    alu(ALU_INC, "00", rdsz(w0(3 downto 0), "00"), x"00000001", w0(3 downto 0), '1', '1', 1);
                                 elsif w0(7) = '1' and w0(3) = '0' then    -- add.l ERs, ERd
                                    alu(ALU_ADD, "10", rdsz('0' & w0(2 downto 0), "10"), rdsz('0' & w0(6 downto 4), "10"), '0' & w0(2 downto 0), '1', '1', 1);
                                 else bad; end if;
                              when x"0B" =>
                                 case w0(7 downto 4) is
                                    when x"0" => alu(ALU_PASS, "10", x"00000000", std_logic_vector(rd32(w0(3 downto 0)) + 1), '0' & w0(2 downto 0), '1', '0', 1);   -- adds #1
                                    when x"8" => alu(ALU_PASS, "10", x"00000000", std_logic_vector(rd32(w0(3 downto 0)) + 2), '0' & w0(2 downto 0), '1', '0', 1);   -- adds #2
                                    when x"9" => alu(ALU_PASS, "10", x"00000000", std_logic_vector(rd32(w0(3 downto 0)) + 4), '0' & w0(2 downto 0), '1', '0', 1);   -- adds #4
                                    when x"5" => alu(ALU_INC, "01", rdsz(w0(3 downto 0), "01"), x"00000001", w0(3 downto 0), '1', '1', 1);                          -- inc.w #1
                                    when x"D" => alu(ALU_INC, "01", rdsz(w0(3 downto 0), "01"), x"00000002", w0(3 downto 0), '1', '1', 1);                          -- inc.w #2
                                    when x"7" => alu(ALU_INC, "10", rdsz('0' & w0(2 downto 0), "10"), x"00000001", '0' & w0(2 downto 0), '1', '1', 1);              -- inc.l #1
                                    when x"F" => alu(ALU_INC, "10", rdsz('0' & w0(2 downto 0), "10"), x"00000002", '0' & w0(2 downto 0), '1', '1', 1);              -- inc.l #2
                                    when others => bad;
                                 end case;
                              when x"0C" => alu(ALU_NZV, "00", x"00000000", rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);                             -- mov.b
                              when x"0D" => alu(ALU_NZV, "01", x"00000000", rdsz(w0(7 downto 4), "01"), w0(3 downto 0), '1', '1', 1);                             -- mov.w
                              when x"0E" => alu(ALU_ADDX, "00", rdsz(w0(3 downto 0), "00"), rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);
                              when x"0F" =>
                                 if w0(7 downto 4) = x"0" then
                                    alu(ALU_DAA, "00", rdsz(w0(3 downto 0), "00"), x"00000000", w0(3 downto 0), '1', '1', 1);
                                 elsif w0(7) = '1' and w0(3) = '0' then   -- mov.l ERs, ERd
                                    alu(ALU_NZV, "10", x"00000000", rdsz('0' & w0(6 downto 4), "10"), '0' & w0(2 downto 0), '1', '1', 1);
                                 else bad; end if;
                              when x"10" | x"11" | x"12" | x"13" =>
                                 -- shifts / rotates by one: 10 shll(0x)/shal(8x), 11 shlr/shar, 12 rotxl/rotl, 13 rotxr/rotr;
                                 -- bits 5-4: 0 byte, 1 word, 3 long
                                 case w0(5 downto 4) is
                                    when "00" => sz <= "00";
                                    when "01" => sz <= "01";
                                    when others => sz <= "10";
                                 end case;
                                 if w0(5 downto 4) = "10" then bad;
                                 else
                                    case hi & w0(7) is
                                       when x"10" & '0' => alu_op <= ALU_SHLL;
                                       when x"10" & '1' => alu_op <= ALU_SHAL;
                                       when x"11" & '0' => alu_op <= ALU_SHLR;
                                       when x"11" & '1' => alu_op <= ALU_SHAR;
                                       when x"12" & '0' => alu_op <= ALU_ROTXL;
                                       when x"12" & '1' => alu_op <= ALU_ROTL;
                                       when x"13" & '0' => alu_op <= ALU_ROTXR;
                                       when others      => alu_op <= ALU_ROTR;
                                    end case;
                                    step <= 2;
                                 end if;
                              when x"14" => alu(ALU_NZV, "00", x"00000000", rdsz(w0(3 downto 0), "00") or rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);
                              when x"15" => alu(ALU_NZV, "00", x"00000000", rdsz(w0(3 downto 0), "00") xor rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);
                              when x"16" => alu(ALU_NZV, "00", x"00000000", rdsz(w0(3 downto 0), "00") and rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);
                              when x"17" =>
                                 case w0(7 downto 4) is
                                    when x"0" => alu(ALU_NZV, "00", x"00000000", not rdsz(w0(3 downto 0), "00"), w0(3 downto 0), '1', '1', 1);                 -- not.b
                                    when x"1" => alu(ALU_NZV, "01", x"00000000", not rdsz(w0(3 downto 0), "01"), w0(3 downto 0), '1', '1', 1);                 -- not.w
                                    when x"3" => alu(ALU_NZV, "10", x"00000000", not rdsz('0' & w0(2 downto 0), "10"), '0' & w0(2 downto 0), '1', '1', 1);     -- not.l
                                    when x"5" => alu(ALU_NZV, "01", x"00000000", x"000000" & rd16(w0(3 downto 0))(7 downto 0), w0(3 downto 0), '1', '1', 1);   -- extu.w
                                    when x"7" => alu(ALU_NZV, "10", x"00000000", x"0000" & rd16('0' & w0(2 downto 0)), '0' & w0(2 downto 0), '1', '1', 1);     -- extu.l
                                    when x"8" => alu(ALU_SUB, "00", x"00000000", rdsz(w0(3 downto 0), "00"), w0(3 downto 0), '1', '1', 1);                     -- neg.b
                                    when x"9" => alu(ALU_SUB, "01", x"00000000", rdsz(w0(3 downto 0), "01"), w0(3 downto 0), '1', '1', 1);                     -- neg.w
                                    when x"B" => alu(ALU_SUB, "10", x"00000000", rdsz('0' & w0(2 downto 0), "10"), '0' & w0(2 downto 0), '1', '1', 1);         -- neg.l
                                    when x"D" => alu(ALU_NZV, "01", x"00000000", std_logic_vector(sx8(rd16(w0(3 downto 0))(7 downto 0))), w0(3 downto 0), '1', '1', 1);   -- exts.w
                                    when x"F" => alu(ALU_NZV, "10", x"00000000", std_logic_vector(sx16(rd16('0' & w0(2 downto 0)))), '0' & w0(2 downto 0), '1', '1', 1);  -- exts.l
                                    when others => bad;
                                 end case;
                              when x"18" => alu(ALU_SUB, "00", rdsz(w0(3 downto 0), "00"), rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);
                              when x"19" => alu(ALU_SUB, "01", rdsz(w0(3 downto 0), "01"), rdsz(w0(7 downto 4), "01"), w0(3 downto 0), '1', '1', 1);
                              when x"1A" =>
                                 if w0(7 downto 4) = x"0" then
                                    alu(ALU_DEC, "00", rdsz(w0(3 downto 0), "00"), x"00000001", w0(3 downto 0), '1', '1', 1);
                                 elsif w0(7) = '1' and w0(3) = '0' then    -- sub.l
                                    alu(ALU_SUB, "10", rdsz('0' & w0(2 downto 0), "10"), rdsz('0' & w0(6 downto 4), "10"), '0' & w0(2 downto 0), '1', '1', 1);
                                 else bad; end if;
                              when x"1B" =>
                                 case w0(7 downto 4) is
                                    when x"0" => alu(ALU_PASS, "10", x"00000000", std_logic_vector(rd32(w0(3 downto 0)) - 1), '0' & w0(2 downto 0), '1', '0', 1);   -- subs #1
                                    when x"8" => alu(ALU_PASS, "10", x"00000000", std_logic_vector(rd32(w0(3 downto 0)) - 2), '0' & w0(2 downto 0), '1', '0', 1);
                                    when x"9" => alu(ALU_PASS, "10", x"00000000", std_logic_vector(rd32(w0(3 downto 0)) - 4), '0' & w0(2 downto 0), '1', '0', 1);
                                    when x"5" => alu(ALU_DEC, "01", rdsz(w0(3 downto 0), "01"), x"00000001", w0(3 downto 0), '1', '1', 1);
                                    when x"D" => alu(ALU_DEC, "01", rdsz(w0(3 downto 0), "01"), x"00000002", w0(3 downto 0), '1', '1', 1);
                                    when x"7" => alu(ALU_DEC, "10", rdsz('0' & w0(2 downto 0), "10"), x"00000001", '0' & w0(2 downto 0), '1', '1', 1);
                                    when x"F" => alu(ALU_DEC, "10", rdsz('0' & w0(2 downto 0), "10"), x"00000002", '0' & w0(2 downto 0), '1', '1', 1);
                                    when others => bad;
                                 end case;
                              when x"1C" => alu(ALU_SUB, "00", rdsz(w0(3 downto 0), "00"), rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '0', '1', 1);   -- cmp.b
                              when x"1D" => alu(ALU_SUB, "01", rdsz(w0(3 downto 0), "01"), rdsz(w0(7 downto 4), "01"), w0(3 downto 0), '0', '1', 1);   -- cmp.w
                              when x"1E" => alu(ALU_SUBX, "00", rdsz(w0(3 downto 0), "00"), rdsz(w0(7 downto 4), "00"), w0(3 downto 0), '1', '1', 1);
                              when x"1F" =>
                                 if w0(7 downto 4) = x"0" then
                                    alu(ALU_DAS, "00", rdsz(w0(3 downto 0), "00"), x"00000000", w0(3 downto 0), '1', '1', 1);
                                 elsif w0(7) = '1' and w0(3) = '0' then    -- cmp.l
                                    alu(ALU_SUB, "10", rdsz('0' & w0(2 downto 0), "10"), rdsz('0' & w0(6 downto 4), "10"), '0' & w0(2 downto 0), '0', '1', 1);
                                 else bad; end if;
                              when x"64" => alu(ALU_NZV, "01", x"00000000", rdsz(w0(3 downto 0), "01") or rdsz(w0(7 downto 4), "01"), w0(3 downto 0), '1', '1', 1);
                              when x"65" => alu(ALU_NZV, "01", x"00000000", rdsz(w0(3 downto 0), "01") xor rdsz(w0(7 downto 4), "01"), w0(3 downto 0), '1', '1', 1);
                              when others => alu(ALU_NZV, "01", x"00000000", rdsz(w0(3 downto 0), "01") and rdsz(w0(7 downto 4), "01"), w0(3 downto 0), '1', '1', 1);
                           end case;
                        elsif step = 2 then                       -- shifts: operand at the size set above
                           if sz = "10" then
                              alu(alu_op, sz, rdsz('0' & w0(2 downto 0), sz), x"00000000", '0' & w0(2 downto 0), '1', '1', 1);
                           else
                              alu(alu_op, sz, rdsz(w0(3 downto 0), sz), x"00000000", w0(3 downto 0), '1', '1', 1);
                           end if;
                        else
                           done;
                        end if;

                     -------------------------------------------------------------- 2x / 3x mov.b @aa:8
                     when x"20" | x"21" | x"22" | x"23" | x"24" | x"25" | x"26" | x"27" |
                          x"28" | x"29" | x"2A" | x"2B" | x"2C" | x"2D" | x"2E" | x"2F" =>
                        case step is
                           when 0 => rd_byte(x"FFFF" & unsigned(w0(7 downto 0)), 1);
                           when 1 => alu(ALU_NZV, "00", x"00000000", x"000000" & mdr(7 downto 0), w0(11 downto 8), '1', '1', 2);
                           when others => done;
                        end case;
                     when x"30" | x"31" | x"32" | x"33" | x"34" | x"35" | x"36" | x"37" |
                          x"38" | x"39" | x"3A" | x"3B" | x"3C" | x"3D" | x"3E" | x"3F" =>
                        case step is
                           when 0 => alu(ALU_NZV, "00", x"00000000", rdsz(w0(11 downto 8), "00"), "0000", '0', '1', 1);
                           when 1 => wr_byte(x"FFFF" & unsigned(w0(7 downto 0)), std_logic_vector(tmp2(7 downto 0)), 2);
                           when others => done;
                        end case;

                     -------------------------------------------------------------- 4x Bcc d8, 58 Bcc d16
                     when x"40" | x"41" | x"42" | x"43" | x"44" | x"45" | x"46" | x"47" |
                          x"48" | x"49" | x"4A" | x"4B" | x"4C" | x"4D" | x"4E" | x"4F" =>
                        if cond(hi(3 downto 0), ccr) then pc <= ins_pc + 2 + sx8(w0(7 downto 0))(23 downto 0); end if;
                        done;
                     when x"58" =>
                        if w0(3 downto 0) /= x"0" then bad;
                        else
                           if cond(w0(7 downto 4), ccr) then pc <= ins_pc + 4 + sx16(ir(1))(23 downto 0); end if;
                           done;
                        end if;

                     -------------------------------------------------------------- 50-53 mulxu / divxu
                     when x"50" =>
                        wr16(w0(3 downto 0), std_logic_vector(unsigned(rd16(w0(3 downto 0))(7 downto 0)) * unsigned(rd8(w0(7 downto 4)))));
                        done;
                     when x"52" =>
                        if w0(3) = '1' then bad;
                        else
                           wr32('0' & w0(2 downto 0), unsigned(rd16('0' & w0(2 downto 0))) * unsigned(rd16(w0(7 downto 4))));
                           done;
                        end if;
                     when x"51" | x"53" =>
                        if step = 0 then
                           if hi = x"51" then
                              tmp <= resize(unsigned(rd16(w0(3 downto 0))), 32); tmp2 <= resize(unsigned(rd8(w0(7 downto 4))), 32);
                           else
                              tmp <= rd32('0' & w0(2 downto 0)); tmp2 <= resize(unsigned(rd16(w0(7 downto 4))), 32);
                           end if;
                           step <= 1;
                        else
                           ccr(2) <= '0'; ccr(3) <= '0';
                           if (hi = x"51" and tmp2(7) = '1') or (hi = x"53" and tmp2(15) = '1') then ccr(3) <= '1'; end if;
                           if tmp2 = 0 then
                              ccr(2) <= '1';
                           else
                              q := tmp / tmp2; rm := tmp mod tmp2;
                              if hi = x"51" then
                                 wr16(w0(3 downto 0), std_logic_vector(rm(7 downto 0)) & std_logic_vector(q(7 downto 0)));
                              else
                                 wr32('0' & w0(2 downto 0), rm(15 downto 0) & q(15 downto 0));
                              end if;
                           end if;
                           done;
                        end if;

                     -------------------------------------------------------------- 54 rts, 56 rte
                     when x"54" | x"56" =>
                        case step is
                           when 0 => rd_word(er(7), 1);
                           when 1 => tmp(31 downto 16) <= unsigned(mdr); rd_word(er(7) + 2, 2);
                           when others =>
                              if hi = x"54" then
                                 pc <= tmp(23 downto 16) & unsigned(mdr);
                              else
                                 ccr <= std_logic_vector(tmp(31 downto 24));
                                 pc <= tmp(23 downto 16) & unsigned(mdr);
                              end if;
                              er(7) <= er(7) + 4;
                              done;
                        end case;

                     -------------------------------------------------------------- 57 trapa #n
                     when x"57" =>
                        -- trapa #n: the interrupt entry with vector 8 + n (H8/3002). Hitachi's manual sets I (and UI when
                        -- UE = 0) as for an interrupt; MAME's trapa leaves CCR alone. The manual is followed (docs/H8.md).
                        if w0(3 downto 0) /= x"0" or w0(7 downto 6) /= "00" then bad;
                        else
                           vecn <= to_unsigned(8, 6) + unsigned(w0(5 downto 4)); trap <= '1';
                           st <= S_IRQ; step <= 0;
                        end if;

                     -------------------------------------------------------------- jmp / jsr / bsr
                     when x"55" | x"5C" | x"5D" | x"5E" | x"5F" | x"59" | x"5A" | x"5B" =>
                        case step is
                           when 0 =>
                              -- target into tmp2, return address into tmp
                              tmp <= resize(pc, 32);                       -- pc is past the whole instruction
                              case hi is
                                 when x"55" => tmp2 <= resize(ins_pc + 2 + sx8(w0(7 downto 0))(23 downto 0), 32); step <= 3;
                                 when x"5C" => tmp2 <= resize(ins_pc + 4 + sx16(ir(1))(23 downto 0), 32); step <= 3;
                                 when x"59" | x"5D" => tmp2 <= rd32('0' & w0(6 downto 4)); step <= 3;
                                 when x"5A" | x"5E" => tmp2 <= resize(unsigned(w0(7 downto 0)) & unsigned(ir(1)), 32); step <= 3;
                                 when others => rd_word(resize(unsigned(w0(7 downto 0)), 24), 1);       -- @@aa:8
                              end case;
                           when 1 => tmp2(31 downto 16) <= unsigned(mdr); rd_word(resize(unsigned(w0(7 downto 0)), 24) + 2, 2);
                           when 2 => tmp2(15 downto 0) <= unsigned(mdr); step <= 3;
                           when 3 =>
                              if hi = x"59" or hi = x"5A" or hi = x"5B" then   -- jmp
                                 pc <= tmp2(23 downto 0); done;
                              else                                             -- push the 32-bit return address
                                 v32 := er(7) - 4; er(7) <= v32;
                                 wr_word(v32, std_logic_vector(tmp(31 downto 16)), 4);
                              end if;
                           when 4 => wr_word(er(7) + 2, std_logic_vector(tmp(15 downto 0)), 5);
                           when others => pc <= tmp2(23 downto 0); done;
                        end case;

                     -------------------------------------------------------------- 60-63, 67, 70-77 bit ops on a register
                     when x"60" | x"61" | x"62" | x"63" | x"67" | x"70" | x"71" | x"72" | x"73" | x"74" | x"75" | x"76" | x"77" =>
                        if hi(7 downto 4) = x"6" and hi /= x"67" then
                           bitn := to_integer(unsigned(rd8(w0(7 downto 4))(2 downto 0)));
                        else
                           bitn := to_integer(unsigned(w0(6 downto 4)));
                        end if;
                        bval := rd8(w0(3 downto 0));
                        c := ccr(0);
                        case hi is
                           when x"60" | x"70" => bval(bitn) := '1'; wr8(w0(3 downto 0), bval);        -- bset
                           when x"61" | x"71" => bval(bitn) := not bval(bitn); wr8(w0(3 downto 0), bval);   -- bnot
                           when x"62" | x"72" => bval(bitn) := '0'; wr8(w0(3 downto 0), bval);        -- bclr
                           when x"63" | x"73" => ccr(2) <= not bval(bitn);                            -- btst
                           when x"67" =>                                                              -- bst / bist
                              if w0(7) = '0' then bval(bitn) := c; else bval(bitn) := not c; end if;
                              wr8(w0(3 downto 0), bval);
                           when x"74" => if w0(7) = '0' then ccr(0) <= c or bval(bitn); else ccr(0) <= c or not bval(bitn); end if;     -- bor / bior
                           when x"75" => if w0(7) = '0' then ccr(0) <= c xor bval(bitn); else ccr(0) <= c xor not bval(bitn); end if;   -- bxor / bixor
                           when x"76" => if w0(7) = '0' then ccr(0) <= c and bval(bitn); else ccr(0) <= c and not bval(bitn); end if;   -- band / biand
                           when others => if w0(7) = '0' then ccr(0) <= bval(bitn); else ccr(0) <= not bval(bitn); end if;             -- bld / bild
                        end case;
                        done;

                     -------------------------------------------------------------- 7C-7F bit ops on memory (@ERd / @aa:8)
                     when x"7C" | x"7D" | x"7E" | x"7F" =>
                        w1 := ir(1);
                        case step is
                           when 0 =>
                              if hi = x"7C" or hi = x"7D" then ea <= rd32('0' & w0(6 downto 4));
                              else ea <= x"00FFFF" & unsigned(w0(7 downto 0)); end if;
                              step <= 1;
                           when 1 => rd_byte(ea, 2);
                           when 2 =>
                              if w1(15 downto 8) = x"60" or w1(15 downto 8) = x"61" or w1(15 downto 8) = x"62" or w1(15 downto 8) = x"63" then
                                 bitn := to_integer(unsigned(rd8(w1(7 downto 4))(2 downto 0)));
                              else
                                 bitn := to_integer(unsigned(w1(6 downto 4)));
                              end if;
                              bval := mdr(7 downto 0);
                              c := ccr(0);
                              tmp(7 downto 0) <= unsigned(bval);
                              if hi = x"7C" or hi = x"7E" then             -- tests and loads: no write
                                 case w1(15 downto 8) is
                                    when x"63" | x"73" => ccr(2) <= not bval(bitn);
                                    when x"74" => if w1(7) = '0' then ccr(0) <= c or bval(bitn); else ccr(0) <= c or not bval(bitn); end if;
                                    when x"75" => if w1(7) = '0' then ccr(0) <= c xor bval(bitn); else ccr(0) <= c xor not bval(bitn); end if;
                                    when x"76" => if w1(7) = '0' then ccr(0) <= c and bval(bitn); else ccr(0) <= c and not bval(bitn); end if;
                                    when x"77" => if w1(7) = '0' then ccr(0) <= bval(bitn); else ccr(0) <= not bval(bitn); end if;
                                    when others => bad;
                                 end case;
                                 done;
                              else
                                 case w1(15 downto 8) is
                                    when x"60" | x"70" => bval(bitn) := '1';
                                    when x"61" | x"71" => bval(bitn) := not bval(bitn);
                                    when x"62" | x"72" => bval(bitn) := '0';
                                    when x"67" => if w1(7) = '0' then bval(bitn) := c; else bval(bitn) := not c; end if;
                                    when others => bad;
                                 end case;
                                 wr_byte(ea, bval, 3);
                              end if;
                           when others => done;
                        end case;

                     -------------------------------------------------------------- 68-6F, 78 mov.b / mov.w with memory
                     when x"68" | x"69" | x"6A" | x"6B" | x"6C" | x"6D" | x"6E" | x"6F" | x"78" =>
                        -- size: 68 6A 6C 6E byte, 69 6B 6D 6F word; 78: the second word's 6A / 6B
                        if hi = x"78" then w1 := ir(1); else w1 := w0; end if;
                        case step is
                           when 0 =>
                              if w1(8) = '0' then sz <= "00"; else sz <= "01"; end if;
                              case hi is
                                 when x"68" | x"69" => ea <= rd32('0' & w0(6 downto 4));
                                 when x"6A" | x"6B" =>
                                    if w0(7 downto 4) = x"0" or w0(7 downto 4) = x"8" then ea <= sx16(ir(1));
                                    elsif w0(7 downto 4) = x"2" or w0(7 downto 4) = x"A" then ea <= unsigned(ir(1)) & unsigned(ir(2));
                                    else bad; end if;
                                 when x"6C" | x"6D" =>
                                    if w0(7) = '0' then ea <= rd32('0' & w0(6 downto 4));
                                    elsif w0(8) = '0' then ea <= rd32('0' & w0(6 downto 4)) - 1;
                                    else ea <= rd32('0' & w0(6 downto 4)) - 2; end if;
                                 when x"6E" | x"6F" => ea <= rd32('0' & w0(6 downto 4)) + sx16(ir(1));
                                 when others => ea <= rd32('0' & w0(6 downto 4)) + (unsigned(ir(2)) & unsigned(ir(3)));   -- 78: d24
                              end case;
                              step <= 1;
                           when 1 =>
                              if w1(7) = '0' then                           -- load
                                 if sz = "00" then rd_byte(ea, 2); else rd_word(ea, 2); end if;
                              else                                          -- store: flags from the register first
                                 if (hi = x"6C" or hi = x"6D") then wr32('0' & w0(6 downto 4), ea); end if;
                                 alu(ALU_NZV, sz, x"00000000", rdsz(w1(3 downto 0), sz), "0000", '0', '1', 4);
                              end if;
                           when 2 =>
                              if hi = x"6C" or hi = x"6D" then wr32('0' & w0(6 downto 4), ea + bsize(sz)); end if;
                              alu(ALU_NZV, sz, x"00000000", x"0000" & mdr, w1(3 downto 0), '1', '1', 3);
                           when 3 => done;
                           when 4 =>
                              if sz = "00" then wr_byte(ea, std_logic_vector(tmp2(7 downto 0)), 3);
                              else wr_word(ea, std_logic_vector(tmp2(15 downto 0)), 3); end if;
                           when others => done;
                        end case;

                     -------------------------------------------------------------- 79 / 7A immediate .w / .l
                     when x"79" | x"7A" =>
                        if step = 0 then
                           if hi = x"79" then sz <= "01"; v32 := x"0000" & unsigned(ir(1));
                           else sz <= "10"; v32 := unsigned(ir(1)) & unsigned(ir(2)); end if;
                           if hi = x"79" then
                              case w0(7 downto 4) is
                                 when x"0" => alu(ALU_NZV, "01", x"00000000", std_logic_vector(v32), w0(3 downto 0), '1', '1', 1);
                                 when x"1" => alu(ALU_ADD, "01", rdsz(w0(3 downto 0), "01"), std_logic_vector(v32), w0(3 downto 0), '1', '1', 1);
                                 when x"2" => alu(ALU_SUB, "01", rdsz(w0(3 downto 0), "01"), std_logic_vector(v32), w0(3 downto 0), '0', '1', 1);
                                 when x"3" => alu(ALU_SUB, "01", rdsz(w0(3 downto 0), "01"), std_logic_vector(v32), w0(3 downto 0), '1', '1', 1);
                                 when x"4" => alu(ALU_NZV, "01", x"00000000", rdsz(w0(3 downto 0), "01") or std_logic_vector(v32), w0(3 downto 0), '1', '1', 1);
                                 when x"5" => alu(ALU_NZV, "01", x"00000000", rdsz(w0(3 downto 0), "01") xor std_logic_vector(v32), w0(3 downto 0), '1', '1', 1);
                                 when x"6" => alu(ALU_NZV, "01", x"00000000", rdsz(w0(3 downto 0), "01") and std_logic_vector(v32), w0(3 downto 0), '1', '1', 1);
                                 when others => bad;
                              end case;
                           else
                              if w0(3) = '1' then bad; end if;
                              case w0(7 downto 4) is
                                 when x"0" => alu(ALU_NZV, "10", x"00000000", std_logic_vector(v32), '0' & w0(2 downto 0), '1', '1', 1);
                                 when x"1" => alu(ALU_ADD, "10", rdsz('0' & w0(2 downto 0), "10"), std_logic_vector(v32), '0' & w0(2 downto 0), '1', '1', 1);
                                 when x"2" => alu(ALU_SUB, "10", rdsz('0' & w0(2 downto 0), "10"), std_logic_vector(v32), '0' & w0(2 downto 0), '0', '1', 1);
                                 when x"3" => alu(ALU_SUB, "10", rdsz('0' & w0(2 downto 0), "10"), std_logic_vector(v32), '0' & w0(2 downto 0), '1', '1', 1);
                                 when x"4" => alu(ALU_NZV, "10", x"00000000", rdsz('0' & w0(2 downto 0), "10") or std_logic_vector(v32), '0' & w0(2 downto 0), '1', '1', 1);
                                 when x"5" => alu(ALU_NZV, "10", x"00000000", rdsz('0' & w0(2 downto 0), "10") xor std_logic_vector(v32), '0' & w0(2 downto 0), '1', '1', 1);
                                 when x"6" => alu(ALU_NZV, "10", x"00000000", rdsz('0' & w0(2 downto 0), "10") and std_logic_vector(v32), '0' & w0(2 downto 0), '1', '1', 1);
                                 when others => bad;
                              end case;
                           end if;
                        else
                           done;
                        end if;

                     -------------------------------------------------------------- 7B eepmov.b / .w
                     when x"7B" =>
                        -- block move: R4L (.b) or R4 (.w) bytes from @ER5 to @ER6, both incremented
                        case step is
                           when 0 =>
                              if (w0(7 downto 0) = x"5C" and er(4)(7 downto 0) = 0) or
                                 (w0(7 downto 0) = x"D4" and er(4)(15 downto 0) = 0) then
                                 done;
                              else
                                 rd_byte(er(5), 1);
                              end if;
                           when 1 => wr_byte(er(6), mdr(7 downto 0), 2);
                           when others =>
                              er(5) <= er(5) + 1; er(6) <= er(6) + 1;
                              if w0(7 downto 0) = x"5C" then er(4)(7 downto 0) <= er(4)(7 downto 0) - 1;
                              else er(4)(15 downto 0) <= er(4)(15 downto 0) - 1; end if;
                              step <= 0;
                        end case;

                     -------------------------------------------------------------- 8x-Fx byte immediate
                     when others =>
                        if hi(7) = '1' then
                           if step = 0 then
                              case hi(7 downto 4) is
                                 when x"8" => alu(ALU_ADD,  "00", rdsz(w0(11 downto 8), "00"), x"000000" & w0(7 downto 0), w0(11 downto 8), '1', '1', 1);
                                 when x"9" => alu(ALU_ADDX, "00", rdsz(w0(11 downto 8), "00"), x"000000" & w0(7 downto 0), w0(11 downto 8), '1', '1', 1);
                                 when x"A" => alu(ALU_SUB,  "00", rdsz(w0(11 downto 8), "00"), x"000000" & w0(7 downto 0), w0(11 downto 8), '0', '1', 1);
                                 when x"B" => alu(ALU_SUBX, "00", rdsz(w0(11 downto 8), "00"), x"000000" & w0(7 downto 0), w0(11 downto 8), '1', '1', 1);
                                 when x"C" => alu(ALU_NZV,  "00", x"00000000", rdsz(w0(11 downto 8), "00") or (x"000000" & w0(7 downto 0)), w0(11 downto 8), '1', '1', 1);
                                 when x"D" => alu(ALU_NZV,  "00", x"00000000", rdsz(w0(11 downto 8), "00") xor (x"000000" & w0(7 downto 0)), w0(11 downto 8), '1', '1', 1);
                                 when x"E" => alu(ALU_NZV,  "00", x"00000000", rdsz(w0(11 downto 8), "00") and (x"000000" & w0(7 downto 0)), w0(11 downto 8), '1', '1', 1);
                                 when others => alu(ALU_NZV, "00", x"00000000", x"000000" & w0(7 downto 0), w0(11 downto 8), '1', '1', 1);
                              end case;
                           else
                              done;
                           end if;
                        else
                           bad;
                        end if;
                  end case;

               when S_HALT => null;
            end case;
         end if;
      end if;
   end process;
end architecture;
