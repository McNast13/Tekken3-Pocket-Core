-- H8/300H CPU for Tekken 3's H8/3002 (docs/H8.md): advanced mode (24-bit addresses, 32-bit vectors and stack frames),
-- not cycle-exact (the sound program's timing comes from its timer interrupts). Instruction behaviour is MAME's
-- (tools/h8model/mame/h8.lst); the flag rules are in h8_alu.vhd. Checked against the MAME recording by tests/h8/cpu
-- (replay of Tekken 3's own H8 program) and against the generated model by tests/h8/rand.
--
-- Structure (sized for the Pocket: synth/h8_size h8_cpu_size): a fixed datapath - two register read ports, one address
-- adder, one ALU, one logic unit, one multiplier, a one-bit-per-clock divider and one register write port - steered by a
-- step sequencer per instruction. The sequencer only picks small select codes (operand sources, address offset, write
-- data, bus data, jump target); each datapath selector is built once after it. A two-word prefetch queue keeps the bus
-- busy while instructions execute; a taken branch flushes it. Writes are posted: the instruction does not wait for them.
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
   type ir_t is array (0 to 4) of std_logic_vector(15 downto 0);
   signal ir  : ir_t := (others => (others => '0'));
   signal ipc : unsigned(23 downto 0) := (others => '0');   -- the instruction in ir; from its end on, the next one
   signal dpc : unsigned(23 downto 0) := (others => '0');   -- the next word into ir (past the instruction once it is in)
   signal fpc : unsigned(23 downto 0) := (others => '0');   -- the next word to prefetch
   type fq_t is array (0 to 1) of std_logic_vector(15 downto 0);
   signal fq   : fq_t := (others => (others => '0'));       -- prefetched words, from dpc on
   signal fcnt : integer range 0 to 2 := 0;
   signal nf, nlen : integer range 0 to 5 := 0;               -- words in ir; the instruction's length

   type state_t is (S_RESET, S_DEC, S_EXEC, S_WAIT, S_IRQ, S_HALT);
   signal st, ret_st : state_t := S_RESET;
   signal step, ret_step : integer range 0 to 7 := 0;

   -- bus request
   signal b_addr  : unsigned(23 downto 0) := (others => '0');
   signal b_wdata : std_logic_vector(15 downto 0) := (others => '0');
   signal b_rd, b_wr : std_logic := '0';
   signal b_be    : std_logic_vector(1 downto 0) := "11";
   signal b_fetch : std_logic := '0';                             -- the request is a prefetch
   signal b_disc  : std_logic := '0';                             -- ... whose word is no longer wanted (flushed)
   signal b_hold  : std_logic := '0';                             -- a data read with another access right after it
   signal mdr     : std_logic_vector(15 downto 0) := (others => '0');   -- last data read (byte reads: in 7-0)

   signal ea      : unsigned(31 downto 0) := (others => '0');    -- address kept for an instruction's next access
   signal tmp     : unsigned(31 downto 0) := (others => '0');    -- long data / jump target being assembled
   signal illegal : std_logic := '0';
   signal vecn    : unsigned(5 downto 0) := (others => '0');     -- vector being taken (interrupt, trapa, reset)
   signal trap    : std_logic := '0';                            -- not an interrupt: no irq_ack

   -- divider (divxu, divxs): restoring, one quotient bit per clock
   signal dv_q    : unsigned(31 downto 0) := (others => '0');    -- dividend, shifted out as the quotient comes in
   signal dv_r    : unsigned(15 downto 0) := (others => '0');
   signal dv_d    : unsigned(15 downto 0) := (others => '0');
   signal dv_n    : integer range 0 to 32 := 0;
   signal dv_qneg, dv_rneg : std_logic := '0';
   signal prod    : signed(33 downto 0) := (others => '0');      -- multiplier output, registered: mul takes 2 clocks

   constant SZB : std_logic_vector(1 downto 0) := "00";
   constant SZW : std_logic_vector(1 downto 0) := "01";
   constant SZL : std_logic_vector(1 downto 0) := "10";
   -- address adder: base + offset
   constant EB_S  : integer := 0;     -- port S register
   constant EB_0  : integer := 1;     -- zero (absolute addresses)
   constant EB_PC : integer := 2;     -- dpc (branch targets)
   constant EB_EA : integer := 3;     -- ea (an instruction's next access)
   constant EO_K     : integer := 0;  -- the small constant ek
   constant EO_SX8   : integer := 1;  -- sign-extended w0 low byte (Bcc d8, bsr d8)
   constant EO_SX161 : integer := 2;  -- sign-extended ir(1)
   constant EO_SX162 : integer := 3;  -- sign-extended ir(2)
   constant EO_L12   : integer := 4;  -- ir(1) & ir(2)
   constant EO_L23   : integer := 5;  -- ir(2) & ir(3)
   constant EO_L34   : integer := 6;  -- ir(3) & ir(4)
   constant EO_AA8   : integer := 7;  -- 0xFFFF00 + w0 low byte (@aa:8)
   constant EO_A24   : integer := 8;  -- w0 low byte & ir(1) (jmp / jsr @aa:24)
   constant EO_LO8   : integer := 9;  -- w0 low byte (@@aa:8)
   constant EO_VEC   : integer := 10; -- vecn * 4
   -- ALU operands: a is port D (at the operation's size) or 0; b one of these
   constant B_0     : integer := 0;
   constant B_S     : integer := 1;   -- port S at the size
   constant B_D     : integer := 2;   -- port D at the size (neg)
   constant B_NOTD  : integer := 3;
   constant B_IMM   : integer := 4;   -- imm (decoded)
   constant B_MDR   : integer := 5;
   constant B_TMDR  : integer := 6;   -- tmp high word & mdr (mov.l load)
   constant B_EXTU8 : integer := 7;
   constant B_EXTU16 : integer := 8;
   constant B_EXTS8 : integer := 9;
   constant B_EXTS16 : integer := 10;
   constant B_PROD  : integer := 11;
   constant B_CCR   : integer := 12;
   constant B_BIT   : integer := 13;  -- bval (bit operations)
   -- register write data
   constant W_ALU : integer := 0;
   constant W_EA  : integer := 1;
   constant W_DIV : integer := 2;
   -- bus write data
   constant D_D8   : integer := 0;    -- port D byte, both lanes
   constant D_D16  : integer := 1;
   constant D_DHI  : integer := 2;    -- port D high word (mov.l)
   constant D_TLO  : integer := 3;    -- tmp low word (mov.l)
   constant D_CCR  : integer := 4;    -- ccr, both lanes (stc.w)
   constant D_PCLO : integer := 5;    -- ipc low word (interrupt frame)
   constant D_PCHI : integer := 6;    -- ccr & ipc high byte
   constant D_RHI  : integer := 7;    -- 0 & dpc high byte (return address)
   constant D_RLO  : integer := 8;
   constant D_MDR8 : integer := 9;    -- mdr byte, both lanes (eepmov)
   constant D_BIT  : integer := 10;   -- bval, both lanes
   -- jump target
   constant J_EA : integer := 0;
   constant J_S  : integer := 1;
   constant J_TM : integer := 2;      -- tmp(23:16) & mdr
   constant J_T  : integer := 3;      -- tmp

   function sx8(v : std_logic_vector(7 downto 0)) return unsigned is
   begin
      return unsigned(resize(signed(v), 32));
   end function;
   function sx16(v : std_logic_vector(15 downto 0)) return unsigned is
   begin
      return unsigned(resize(signed(v), 32));
   end function;
   -- register views (MAME h8.h / h8h.h): r8 n: bit 3 = low byte; r16 n: bit 3 = E (high) word
   -- (results are (7 downto 0) / (15 downto 0) whichever half they come from, so callers can slice them)
   function v8(r : unsigned(31 downto 0); n : std_logic_vector(3 downto 0)) return std_logic_vector is
      variable v : std_logic_vector(7 downto 0);
   begin
      if n(3) = '1' then v := std_logic_vector(r(7 downto 0)); else v := std_logic_vector(r(15 downto 8)); end if;
      return v;
   end function;
   function v16(r : unsigned(31 downto 0); n : std_logic_vector(3 downto 0)) return std_logic_vector is
      variable v : std_logic_vector(15 downto 0);
   begin
      if n(3) = '1' then v := std_logic_vector(r(31 downto 16)); else v := std_logic_vector(r(15 downto 0)); end if;
      return v;
   end function;
   function vsz(r : unsigned(31 downto 0); n : std_logic_vector(3 downto 0); s : std_logic_vector(1 downto 0))
      return std_logic_vector is
   begin
      case s is
         when "00"   => return x"000000" & v8(r, n);
         when "01"   => return x"0000" & v16(r, n);
         when others => return std_logic_vector(r);
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
   -- instruction length in words from the first word (01 00 / 01 40: at least 2, the second word says)
   function len1(w : std_logic_vector(15 downto 0)) return integer is
   begin
      case w(15 downto 8) is
         when x"58" | x"5A" | x"5C" | x"5E" | x"6E" | x"6F" | x"79" | x"7B" | x"7C" | x"7D" | x"7E" | x"7F" => return 2;
         when x"6A" | x"6B" =>
            if w(7 downto 4) = x"2" or w(7 downto 4) = x"A" then return 3; else return 2; end if;
         when x"78" => return 4;
         when x"7A" => return 3;
         when x"01" =>
            if w(7 downto 0) = x"00" or w(7 downto 0) = x"40" or w(7 downto 0) = x"C0" or w(7 downto 0) = x"D0" or
               w(7 downto 0) = x"F0" then
               return 2;
            else
               return 1;
            end if;
         when others => return 1;
      end case;
   end function;
   -- mov.l / ldc.w / stc.w with a memory operand: the length from the second word
   function len2(w : std_logic_vector(15 downto 0)) return integer is
   begin
      case w(15 downto 8) is
         when x"6B" => if w(7 downto 4) = x"2" or w(7 downto 4) = x"A" then return 4; else return 3; end if;
         when x"6F" => return 3;
         when x"78" => return 5;
         when others => return 2;
      end case;
   end function;
begin
   bus_addr  <= std_logic_vector(b_addr);
   bus_wdata <= b_wdata;
   bus_rd    <= b_rd;
   bus_wr    <= b_wr;
   bus_be    <= b_be;
   ccr_o     <= ccr;
   dbg_pc    <= std_logic_vector(ipc);
   dbg_ccr   <= ccr;
   dbg_illegal <= illegal;
   g_dbg : for i in 0 to 7 generate
      dbg_er(32 * i + 31 downto 32 * i) <= std_logic_vector(er(i));
   end generate;

   process (clk)
      variable w0, w1, w   : std_logic_vector(15 downto 0);
      variable hi          : std_logic_vector(7 downto 0);
      variable ixd, ixs    : std_logic_vector(3 downto 0);       -- register ports: D (data / destination), S (source / address)
      variable rD, rS      : unsigned(31 downto 0);
      variable eb, eo      : integer range 0 to 15;
      variable ek          : integer range -4 to 4;
      variable eoff, base, ea_v : unsigned(31 downto 0);
      variable imm         : std_logic_vector(31 downto 0);
      variable bfree, dack : boolean;
      variable fqv         : fq_t;
      variable fc          : integer range 0 to 3;
      variable len         : integer range 0 to 5;
      -- ALU / logic unit
      variable ago, aset, awb, ad : boolean;                      -- ad: a is port D (else 0)
      variable aop         : unsigned(4 downto 0);
      variable asz         : std_logic_vector(1 downto 0);
      variable bsel        : integer range 0 to 15;
      variable aa, ab      : std_logic_vector(31 downto 0);
      variable lop         : integer range 0 to 3;                 -- 1 or, 2 xor, 3 and: b := a op b, a := 0
      variable ares        : std_logic_vector(31 downto 0);
      variable accr        : std_logic_vector(7 downto 0);
      -- register write port
      variable wen         : boolean;
      variable widx        : std_logic_vector(3 downto 0);
      variable wsz         : std_logic_vector(1 downto 0);
      variable wsel        : integer range 0 to 3;
      variable wdat        : unsigned(31 downto 0);
      -- bus request, jump, end of instruction
      variable bq          : integer range 0 to 2;                 -- 1 read, 2 write
      variable bqs, bqbyte, bqhold : boolean;                      -- address: port S (else the adder); byte
      variable bqd         : integer range 0 to 15;
      variable bqk         : integer range 0 to 7;
      variable bqback      : state_t;
      variable ba          : unsigned(23 downto 0);
      variable flush, fin, badv : boolean;
      variable jsel        : integer range 0 to 3;
      variable tgt         : unsigned(23 downto 0);
      -- multiplier, divider
      variable msgn, mbyte : boolean;
      variable ma, mb      : signed(16 downto 0);
      variable dnd         : unsigned(31 downto 0);
      variable dsr         : unsigned(15 downto 0);
      variable dneg, sneg  : boolean;
      variable t17         : unsigned(16 downto 0);
      variable q32         : unsigned(31 downto 0);
      variable r16         : unsigned(15 downto 0);
      variable divres      : unsigned(31 downto 0);
      variable sz          : std_logic_vector(1 downto 0);
      variable ld, lng     : boolean;
      variable bitn        : integer range 0 to 7;
      variable bval        : std_logic_vector(7 downto 0);
      variable c           : std_logic;
      variable i           : integer range 0 to 7;

      procedure alu_do(op : unsigned(4 downto 0); sv : std_logic_vector(1 downto 0); a_is_d : boolean; b : integer;
                       wbv, setv : boolean) is
      begin
         ago := true; aop := op; asz := sv; ad := a_is_d; bsel := b; awb := wbv; aset := setv;
      end procedure;
      procedure regw(n : std_logic_vector(3 downto 0); sv : std_logic_vector(1 downto 0); src : integer) is
      begin
         wen := true; widx := n; wsz := sv; wsel := src;
      end procedure;
      -- data accesses (the caller has checked bfree); address: port S when from_s, else the adder. A read waits in
      -- S_WAIT, then continues at (back, k)
      procedure rd_bus(from_s, byte : boolean; k : integer; hold : boolean; back : state_t) is
      begin
         bq := 1; bqs := from_s; bqbyte := byte; bqk := k; bqhold := hold; bqback := back;
      end procedure;
      procedure wr_bus(from_s : boolean; d : integer; byte : boolean) is
      begin
         bq := 2; bqs := from_s; bqd := d; bqbyte := byte;
      end procedure;
      procedure jump(j : integer) is
      begin
         flush := true; jsel := j;
      end procedure;
      procedure done is                             -- the instruction ends: an interrupt, or the next instruction
      begin
         fin := true;
      end procedure;
      procedure bad is
      begin
         badv := true;
      end procedure;
   begin
      if rising_edge(clk) then
         dbg_start <= '0';
         irq_ack <= '0';
         if reset = '1' then
            st <= S_RESET; b_rd <= '0'; b_wr <= '0'; b_disc <= '0'; illegal <= '0'; fcnt <= 0;
            if load_state = '1' then
               ipc <= unsigned(load_pc); dpc <= unsigned(load_pc); fpc <= unsigned(load_pc); ccr <= load_ccr;
               for k in 0 to 7 loop er(k) <= unsigned(load_er(32 * k + 31 downto 32 * k)); end loop;
            end if;
         elsif ce = '1' then
            ago := false; aset := false; awb := false; ad := false; lop := 0; bsel := B_0;
            aop := ALU_PASS; asz := SZB;
            wen := false; widx := "0000"; wsz := SZB; wsel := W_ALU;
            bq := 0; bqs := false; bqbyte := false; bqhold := false; bqd := D_D8; bqk := 0; bqback := S_EXEC;
            flush := false; fin := false; badv := false; jsel := J_EA; dack := false;
            divres := (others => '0'); bval := (others => '0');

            ------------------------------------------------------------------ bus: the request in flight
            bfree := (b_rd = '0' and b_wr = '0') or bus_ack = '1';
            fqv := fq; fc := fcnt;
            if bus_ack = '1' then
               b_rd <= '0'; b_wr <= '0';
               if b_fetch = '1' then
                  if b_disc = '0' then fqv(fc) := bus_rdata; fc := fc + 1; end if;
                  b_disc <= '0';
               else
                  if b_be = "10" then mdr <= x"00" & bus_rdata(15 downto 8);
                  elsif b_be = "01" then mdr <= x"00" & bus_rdata(7 downto 0);
                  else mdr <= bus_rdata; end if;
                  dack := true;
               end if;
            end if;

            ------------------------------------------------------------------ decode: register ports, address adder, immediate
            w0 := ir(0); w1 := ir(1); hi := w0(15 downto 8);
            ixd := w0(3 downto 0); ixs := w0(7 downto 4);
            eb := EB_S; eo := EO_K; ek := 0;
            imm := (others => '0');
            if st = S_IRQ then                                    -- push the PC and CCR, read the vector
               ixs := "0111";
               case step is
                  when 0 | 1 => ek := -2;
                  when 2 => eb := EB_0; eo := EO_VEC;
                  when others => eb := EB_EA; ek := 2;
               end case;
            else
               case hi is
                  when x"01" =>
                     if w0(7 downto 0) = x"00" or w0(7 downto 0) = x"40" then
                        ixs := '0' & w1(6 downto 4);
                        if w1(15 downto 8) = x"78" then ixd := '0' & ir(2)(2 downto 0); else ixd := '0' & w1(2 downto 0); end if;
                        if step /= 0 then
                           eb := EB_EA; ek := 2;
                        else
                           case w1(15 downto 8) is
                              when x"6B" =>
                                 eb := EB_0;
                                 if w1(7 downto 4) = x"2" or w1(7 downto 4) = x"A" then eo := EO_L23; else eo := EO_SX162; end if;
                              when x"6D" =>                                -- @ERs+ (load) / @-ERd (store)
                                 if w0(7 downto 0) = x"00" then
                                    if w1(7) = '0' then ek := 4; else ek := -4; end if;
                                 else
                                    if w1(7) = '0' then ek := 2; else ek := -2; end if;
                                 end if;
                              when x"6F" => eo := EO_SX162;
                              when x"78" => eo := EO_L34;
                              when others => null;                       -- 69: @ERs
                           end case;
                        end if;
                     elsif w1(15 downto 8) = x"52" or w1(15 downto 8) = x"53" then   -- mulxs.w / divxs.w: Rs, ERd
                        ixs := w1(7 downto 4); ixd := '0' & w1(2 downto 0);
                     else                                                 -- mulxs.b / divxs.b, or/xor/and.l
                        ixs := w1(7 downto 4); ixd := w1(3 downto 0);
                     end if;
                  when x"0A" | x"1A" => imm := x"00000001";               -- inc.b / dec.b
                  when x"0B" | x"1B" =>                                   -- adds / subs, inc / dec .w .l: 1, 2 or 4
                     case w0(7 downto 4) is
                        when x"8" | x"D" | x"F" => imm := x"00000002";
                        when x"9" => imm := x"00000004";
                        when others => imm := x"00000001";
                     end case;
                  when x"20" | x"21" | x"22" | x"23" | x"24" | x"25" | x"26" | x"27" |
                       x"28" | x"29" | x"2A" | x"2B" | x"2C" | x"2D" | x"2E" | x"2F" |
                       x"30" | x"31" | x"32" | x"33" | x"34" | x"35" | x"36" | x"37" |
                       x"38" | x"39" | x"3A" | x"3B" | x"3C" | x"3D" | x"3E" | x"3F" =>
                     ixd := w0(11 downto 8); eb := EB_0; eo := EO_AA8;
                  when x"40" | x"41" | x"42" | x"43" | x"44" | x"45" | x"46" | x"47" |
                       x"48" | x"49" | x"4A" | x"4B" | x"4C" | x"4D" | x"4E" | x"4F" =>
                     eb := EB_PC; eo := EO_SX8;
                  when x"58" => eb := EB_PC; eo := EO_SX161;
                  when x"52" | x"53" => ixd := '0' & w0(2 downto 0);
                  when x"54" | x"56" =>                                    -- rts / rte: @SP, @SP+2, then SP + 4
                     ixs := "0111";
                     case step is
                        when 0 => null;
                        when 1 => ek := 2;
                        when others => ek := 4;
                     end case;
                  when x"55" | x"59" | x"5A" | x"5B" | x"5C" | x"5D" | x"5E" | x"5F" =>
                     case step is
                        when 0 =>
                           case hi is
                              when x"55" => eb := EB_PC; eo := EO_SX8;
                              when x"5C" => eb := EB_PC; eo := EO_SX161;
                              when x"59" | x"5D" => ixs := '0' & w0(6 downto 4);
                              when x"5A" | x"5E" => eb := EB_0; eo := EO_A24;
                              when others => eb := EB_0; eo := EO_LO8;      -- @@aa:8
                           end case;
                        when 4 => ixs := "0111"; ek := -4;                -- push the return address
                        when others => eb := EB_EA; ek := 2;
                     end case;
                  when x"68" | x"69" | x"6A" | x"6B" | x"6C" | x"6D" | x"6E" | x"6F" | x"78" =>
                     ixs := '0' & w0(6 downto 4);
                     if hi = x"78" then ixd := w1(3 downto 0); w := w1; else w := w0; end if;
                     case hi is
                        when x"6A" | x"6B" =>
                           eb := EB_0;
                           if w0(7 downto 4) = x"2" or w0(7 downto 4) = x"A" then eo := EO_L12; else eo := EO_SX161; end if;
                        when x"6C" | x"6D" =>
                           if w0(7) = '0' then                                 -- load: ERs, then ERs + size
                              if w(8) = '0' then ek := 1; else ek := 2; end if;
                           else                                                -- store: ERd - size
                              if w(8) = '0' then ek := -1; else ek := -2; end if;
                           end if;
                        when x"6E" | x"6F" => eo := EO_SX161;
                        when x"78" => eo := EO_L23;
                        when others => null;
                     end case;
                  when x"79" => imm := x"0000" & ir(1);
                  when x"7A" => imm := ir(1) & ir(2);
                  when x"7C" | x"7D" | x"7E" | x"7F" =>
                     ixs := '0' & w0(6 downto 4); ixd := w1(7 downto 4);
                     if step /= 0 then eb := EB_EA;
                     elsif hi = x"7E" or hi = x"7F" then eb := EB_0; eo := EO_AA8; end if;
                  when x"7B" =>                                            -- eepmov: R4L / R4 count, @ER5+ to @ER6+
                     if w0(7 downto 0) = x"5C" then ixd := "1100"; else ixd := "0100"; end if;
                     if step = 0 then ixs := "0101"; else ixs := "0110"; end if;
                     ek := 1; imm := x"00000001";
                  when x"80" | x"81" | x"82" | x"83" | x"84" | x"85" | x"86" | x"87" |
                       x"88" | x"89" | x"8A" | x"8B" | x"8C" | x"8D" | x"8E" | x"8F" |
                       x"90" | x"91" | x"92" | x"93" | x"94" | x"95" | x"96" | x"97" |
                       x"98" | x"99" | x"9A" | x"9B" | x"9C" | x"9D" | x"9E" | x"9F" |
                       x"A0" | x"A1" | x"A2" | x"A3" | x"A4" | x"A5" | x"A6" | x"A7" |
                       x"A8" | x"A9" | x"AA" | x"AB" | x"AC" | x"AD" | x"AE" | x"AF" |
                       x"B0" | x"B1" | x"B2" | x"B3" | x"B4" | x"B5" | x"B6" | x"B7" |
                       x"B8" | x"B9" | x"BA" | x"BB" | x"BC" | x"BD" | x"BE" | x"BF" |
                       x"C0" | x"C1" | x"C2" | x"C3" | x"C4" | x"C5" | x"C6" | x"C7" |
                       x"C8" | x"C9" | x"CA" | x"CB" | x"CC" | x"CD" | x"CE" | x"CF" |
                       x"D0" | x"D1" | x"D2" | x"D3" | x"D4" | x"D5" | x"D6" | x"D7" |
                       x"D8" | x"D9" | x"DA" | x"DB" | x"DC" | x"DD" | x"DE" | x"DF" |
                       x"E0" | x"E1" | x"E2" | x"E3" | x"E4" | x"E5" | x"E6" | x"E7" |
                       x"E8" | x"E9" | x"EA" | x"EB" | x"EC" | x"ED" | x"EE" | x"EF" |
                       x"F0" | x"F1" | x"F2" | x"F3" | x"F4" | x"F5" | x"F6" | x"F7" |
                       x"F8" | x"F9" | x"FA" | x"FB" | x"FC" | x"FD" | x"FE" | x"FF" =>
                     ixd := w0(11 downto 8); imm := x"000000" & w0(7 downto 0);
                  when others => null;
               end case;
            end if;
            rD := er(to_integer(unsigned(ixd(2 downto 0))));
            rS := er(to_integer(unsigned(ixs(2 downto 0))));
            case eb is
               when EB_S  => base := rS;
               when EB_0  => base := (others => '0');
               when EB_PC => base := resize(dpc, 32);
               when others => base := ea;
            end case;
            case eo is
               when EO_SX8   => eoff := sx8(w0(7 downto 0));
               when EO_SX161 => eoff := sx16(ir(1));
               when EO_SX162 => eoff := sx16(ir(2));
               when EO_L12   => eoff := unsigned(ir(1)) & unsigned(ir(2));
               when EO_L23   => eoff := unsigned(ir(2)) & unsigned(ir(3));
               when EO_L34   => eoff := unsigned(ir(3)) & unsigned(ir(4));
               when EO_AA8   => eoff := x"00FFFF" & unsigned(w0(7 downto 0));
               when EO_A24   => eoff := x"00" & unsigned(w0(7 downto 0)) & unsigned(ir(1));
               when EO_LO8   => eoff := x"000000" & unsigned(w0(7 downto 0));
               when EO_VEC   => eoff := resize(vecn & "00", 32);
               when others   => eoff := unsigned(to_signed(ek, 32));
            end case;
            ea_v := base + eoff;

            -- multiplier: mulxu.b / .w (50, 52), mulxs.b / .w (01 C0 50 / 52); Rd (low byte, or word) times Rs
            msgn := hi = x"01";
            mbyte := hi = x"50" or (hi = x"01" and w1(15 downto 8) = x"50");
            if mbyte then
               if msgn then ma := resize(signed(v16(rD, ixd)(7 downto 0)), 17); mb := resize(signed(v8(rS, ixs)), 17);
               else ma := signed(resize(unsigned(v16(rD, ixd)(7 downto 0)), 17)); mb := signed(resize(unsigned(v8(rS, ixs)), 17)); end if;
            else
               if msgn then ma := resize(signed(v16(rD, ixd)), 17); mb := resize(signed(v16(rS, ixs)), 17);
               else ma := signed(resize(unsigned(v16(rD, ixd)), 17)); mb := signed(resize(unsigned(v16(rS, ixs)), 17)); end if;
            end if;
            prod <= ma * mb;

            ------------------------------------------------------------------ sequencer
            case st is
               when S_RESET =>
                  if load_state = '1' then
                     st <= S_DEC; nf <= 0; dbg_start <= '1';
                  else
                     ccr <= ccr or x"80";
                     vecn <= (others => '0'); trap <= '1'; st <= S_IRQ; step <= 2;
                  end if;

               when S_WAIT =>
                  if dack then st <= ret_st; step <= ret_step; end if;

               when S_DEC =>                                      -- words from the prefetch queue into ir
                  if fc > 0 then
                     w := fqv(0); fqv(0) := fqv(1); fc := fc - 1;
                     ir(nf) <= w; dpc <= dpc + 2;
                     if nf = 0 then
                        len := len1(w);
                     elsif nf = 1 and ir(0)(15 downto 8) = x"01" and (ir(0)(7 downto 0) = x"00" or ir(0)(7 downto 0) = x"40") then
                        len := len2(w);
                     else
                        len := nlen;
                     end if;
                     nlen <= len;
                     if nf + 1 >= len then st <= S_EXEC; step <= 0; else nf <= nf + 1; end if;
                  end if;

               when S_IRQ =>
                  case step is
                     when 0 =>                                     -- push the PC's low word
                        if bfree then regw("0111", SZL, W_EA); wr_bus(false, D_PCLO, false); step <= 1; end if;
                     when 1 =>                                     -- then CCR and the PC's high byte
                        if bfree then regw("0111", SZL, W_EA); wr_bus(false, D_PCHI, false); step <= 2; end if;
                     when 2 =>                                     -- the vector
                        if bfree then irq_ack <= not trap; ea <= ea_v; rd_bus(false, false, 3, true, S_IRQ); end if;
                     when 3 =>
                        tmp(31 downto 16) <= unsigned(mdr);
                        if bfree then rd_bus(false, false, 4, false, S_IRQ); end if;
                     when others =>
                        jump(J_TM);
                        ipc <= tmp(23 downto 16) & unsigned(mdr);
                        if syscr_ue = '1' then ccr(7) <= '1'; else ccr(7 downto 6) <= "11"; end if;
                        st <= S_DEC; nf <= 0; dbg_start <= '1';
                  end case;

               when S_EXEC =>
                  case hi is
                     -------------------------------------------------------------- 00 nop
                     when x"00" =>
                        if w0(7 downto 0) = x"00" then done; else bad; end if;

                     -------------------------------------------------------------- 01 prefixed
                     when x"01" =>
                        if w0(7 downto 0) = x"00" or w0(7 downto 0) = x"40" then
                           -- mov.l (0100) / ldc.w, stc.w (0140) with a memory operand; w1 6x selects the mode
                           lng := w0(7 downto 0) = x"00";
                           if w1(15 downto 8) = x"78" then ld := ir(2)(7) = '0'; else ld := w1(7) = '0'; end if;
                           case step is
                              when 0 =>
                                 if bfree then
                                    -- @ERs+ loads read at ERs; the adder gives ERs + size for the write-back
                                    if w1(15 downto 8) = x"6D" and ld then ea <= rS; else ea <= ea_v; end if;
                                    if w1(15 downto 8) = x"6D" then regw(ixs, SZL, W_EA); end if;
                                    if ld then
                                       rd_bus(w1(15 downto 8) = x"6D", false, 1, lng, S_EXEC);
                                    elsif lng then
                                       tmp <= rD;
                                       wr_bus(false, D_DHI, false);
                                       alu_do(ALU_NZV, SZL, false, B_D, false, true);
                                       step <= 2;
                                    else
                                       wr_bus(false, D_CCR, false); done;
                                    end if;
                                 end if;
                              when 1 =>                                 -- the first word read
                                 if lng then
                                    tmp(31 downto 16) <= unsigned(mdr);
                                    if bfree then rd_bus(false, false, 3, false, S_EXEC); end if;
                                 else
                                    ccr <= mdr(15 downto 8); done;
                                 end if;
                              when 2 =>                                 -- mov.l store: the low word
                                 if bfree then wr_bus(false, D_TLO, false); done; end if;
                              when others =>                            -- mov.l load: both words in
                                 alu_do(ALU_NZV, SZL, false, B_TMDR, true, true); done;
                           end case;
                        elsif w0(7 downto 0) = x"80" then       -- sleep: wait for an interrupt
                           if irq = '1' then done; end if;
                        elsif w0(7 downto 0) = x"C0" then       -- mulxs.b / mulxs.w (step 0: the product is registered)
                           if step = 0 then
                              step <= 1;
                           elsif w1(15 downto 8) = x"50" then
                              alu_do(ALU_NZ, SZW, false, B_PROD, true, true); done;
                           elsif w1(15 downto 8) = x"52" then
                              alu_do(ALU_NZ, SZL, false, B_PROD, true, true); done;
                           else
                              bad;
                           end if;
                        elsif w0(7 downto 0) = x"D0" then       -- divxs.b / divxs.w (the divider below)
                           if w1(15 downto 8) /= x"51" and w1(15 downto 8) /= x"53" then bad; end if;
                        elsif w0(7 downto 0) = x"F0" then       -- or.l / xor.l / and.l ERs, ERd
                           case w1(15 downto 8) is
                              when x"64" => lop := 1;
                              when x"65" => lop := 2;
                              when others => lop := 3;
                           end case;
                           alu_do(ALU_NZV, SZL, true, B_S, true, true); done;
                        else
                           bad;
                        end if;

                     -------------------------------------------------------------- 02-07 CCR
                     when x"02" => alu_do(ALU_PASS, SZB, false, B_CCR, true, false); done;                 -- stc ccr, r8
                     when x"03" => ccr <= v8(rD, ixd); done;                                                 -- ldc r8, ccr
                     when x"04" => ccr <= ccr or w0(7 downto 0); done;                                     -- orc
                     when x"05" => ccr <= ccr xor w0(7 downto 0); done;                                    -- xorc
                     when x"06" => ccr <= ccr and w0(7 downto 0); done;                                    -- andc
                     when x"07" => ccr <= w0(7 downto 0); done;                                            -- ldc #imm

                     -------------------------------------------------------------- register ALU, one word
                     when x"08" => alu_do(ALU_ADD, SZB, true, B_S, true, true); done;
                     when x"09" => alu_do(ALU_ADD, SZW, true, B_S, true, true); done;
                     when x"0A" =>
                        if w0(7 downto 4) = x"0" then                -- inc.b
                           alu_do(ALU_INC, SZB, true, B_IMM, true, true); done;
                        elsif w0(7) = '1' and w0(3) = '0' then       -- add.l ERs, ERd
                           alu_do(ALU_ADD, SZL, true, B_S, true, true); done;
                        else bad; end if;
                     when x"0B" =>
                        case w0(7 downto 4) is
                           when x"0" | x"8" | x"9" => alu_do(ALU_ADD, SZL, true, B_IMM, true, false); done;   -- adds #1/2/4
                           when x"5" | x"D" => alu_do(ALU_INC, SZW, true, B_IMM, true, true); done;          -- inc.w #1/2
                           when x"7" | x"F" => alu_do(ALU_INC, SZL, true, B_IMM, true, true); done;          -- inc.l #1/2
                           when others => bad;
                        end case;
                     when x"0C" => alu_do(ALU_NZV, SZB, false, B_S, true, true); done;          -- mov.b
                     when x"0D" => alu_do(ALU_NZV, SZW, false, B_S, true, true); done;          -- mov.w
                     when x"0E" => alu_do(ALU_ADDX, SZB, true, B_S, true, true); done;
                     when x"0F" =>
                        if w0(7 downto 4) = x"0" then
                           alu_do(ALU_DAA, SZB, true, B_0, true, true); done;
                        elsif w0(7) = '1' and w0(3) = '0' then       -- mov.l ERs, ERd
                           alu_do(ALU_NZV, SZL, false, B_S, true, true); done;
                        else bad; end if;
                     when x"10" | x"11" | x"12" | x"13" =>
                        -- shifts / rotates by one: 10 shll(0x)/shal(8x), 11 shlr/shar, 12 rotxl/rotl, 13 rotxr/rotr;
                        -- bits 5-4: 0 byte, 1 word, 3 long
                        case w0(5 downto 4) is
                           when "00" => sz := SZB;
                           when "01" => sz := SZW;
                           when others => sz := SZL;
                        end case;
                        if w0(5 downto 4) = "10" then bad;
                        else
                           case hi & w0(7) is
                              when x"10" & '0' => aop := ALU_SHLL;
                              when x"10" & '1' => aop := ALU_SHAL;
                              when x"11" & '0' => aop := ALU_SHLR;
                              when x"11" & '1' => aop := ALU_SHAR;
                              when x"12" & '0' => aop := ALU_ROTXL;
                              when x"12" & '1' => aop := ALU_ROTL;
                              when x"13" & '0' => aop := ALU_ROTXR;
                              when others      => aop := ALU_ROTR;
                           end case;
                           alu_do(aop, sz, true, B_0, true, true); done;
                        end if;
                     when x"14" => lop := 1; alu_do(ALU_NZV, SZB, true, B_S, true, true); done;
                     when x"15" => lop := 2; alu_do(ALU_NZV, SZB, true, B_S, true, true); done;
                     when x"16" => lop := 3; alu_do(ALU_NZV, SZB, true, B_S, true, true); done;
                     when x"17" =>
                        case w0(7 downto 4) is
                           when x"0" => alu_do(ALU_NZV, SZB, false, B_NOTD, true, true); done;       -- not.b
                           when x"1" => alu_do(ALU_NZV, SZW, false, B_NOTD, true, true); done;       -- not.w
                           when x"3" => alu_do(ALU_NZV, SZL, false, B_NOTD, true, true); done;       -- not.l
                           when x"5" => alu_do(ALU_NZV, SZW, false, B_EXTU8, true, true); done;      -- extu.w
                           when x"7" => alu_do(ALU_NZV, SZL, false, B_EXTU16, true, true); done;     -- extu.l
                           when x"8" => alu_do(ALU_SUB, SZB, false, B_D, true, true); done;          -- neg.b
                           when x"9" => alu_do(ALU_SUB, SZW, false, B_D, true, true); done;          -- neg.w
                           when x"B" => alu_do(ALU_SUB, SZL, false, B_D, true, true); done;          -- neg.l
                           when x"D" => alu_do(ALU_NZV, SZW, false, B_EXTS8, true, true); done;      -- exts.w
                           when x"F" => alu_do(ALU_NZV, SZL, false, B_EXTS16, true, true); done;     -- exts.l
                           when others => bad;
                        end case;
                     when x"18" => alu_do(ALU_SUB, SZB, true, B_S, true, true); done;
                     when x"19" => alu_do(ALU_SUB, SZW, true, B_S, true, true); done;
                     when x"1A" =>
                        if w0(7 downto 4) = x"0" then
                           alu_do(ALU_DEC, SZB, true, B_IMM, true, true); done;
                        elsif w0(7) = '1' and w0(3) = '0' then       -- sub.l
                           alu_do(ALU_SUB, SZL, true, B_S, true, true); done;
                        else bad; end if;
                     when x"1B" =>
                        case w0(7 downto 4) is
                           when x"0" | x"8" | x"9" => alu_do(ALU_SUB, SZL, true, B_IMM, true, false); done;   -- subs #1/2/4
                           when x"5" | x"D" => alu_do(ALU_DEC, SZW, true, B_IMM, true, true); done;
                           when x"7" | x"F" => alu_do(ALU_DEC, SZL, true, B_IMM, true, true); done;
                           when others => bad;
                        end case;
                     when x"1C" => alu_do(ALU_SUB, SZB, true, B_S, false, true); done;   -- cmp.b
                     when x"1D" => alu_do(ALU_SUB, SZW, true, B_S, false, true); done;   -- cmp.w
                     when x"1E" => alu_do(ALU_SUBX, SZB, true, B_S, true, true); done;
                     when x"1F" =>
                        if w0(7 downto 4) = x"0" then
                           alu_do(ALU_DAS, SZB, true, B_0, true, true); done;
                        elsif w0(7) = '1' and w0(3) = '0' then       -- cmp.l
                           alu_do(ALU_SUB, SZL, true, B_S, false, true); done;
                        else bad; end if;
                     when x"64" => lop := 1; alu_do(ALU_NZV, SZW, true, B_S, true, true); done;
                     when x"65" => lop := 2; alu_do(ALU_NZV, SZW, true, B_S, true, true); done;
                     when x"66" => lop := 3; alu_do(ALU_NZV, SZW, true, B_S, true, true); done;

                     -------------------------------------------------------------- 2x / 3x mov.b @aa:8
                     when x"20" | x"21" | x"22" | x"23" | x"24" | x"25" | x"26" | x"27" |
                          x"28" | x"29" | x"2A" | x"2B" | x"2C" | x"2D" | x"2E" | x"2F" =>
                        if step = 0 then
                           if bfree then rd_bus(false, true, 1, false, S_EXEC); end if;
                        else
                           alu_do(ALU_NZV, SZB, false, B_MDR, true, true); done;
                        end if;
                     when x"30" | x"31" | x"32" | x"33" | x"34" | x"35" | x"36" | x"37" |
                          x"38" | x"39" | x"3A" | x"3B" | x"3C" | x"3D" | x"3E" | x"3F" =>
                        if bfree then
                           wr_bus(false, D_D8, true);
                           alu_do(ALU_NZV, SZB, false, B_D, false, true); done;
                        end if;

                     -------------------------------------------------------------- 4x Bcc d8, 58 Bcc d16
                     when x"40" | x"41" | x"42" | x"43" | x"44" | x"45" | x"46" | x"47" |
                          x"48" | x"49" | x"4A" | x"4B" | x"4C" | x"4D" | x"4E" | x"4F" =>
                        if cond(hi(3 downto 0), ccr) then jump(J_EA); end if;
                        done;
                     when x"58" =>
                        if w0(3 downto 0) /= x"0" then bad;
                        else
                           if cond(w0(7 downto 4), ccr) then jump(J_EA); end if;
                           done;
                        end if;

                     -------------------------------------------------------------- 50-53 mulxu / divxu
                     when x"50" =>                                       -- (step 0: the product is registered)
                        if step = 0 then step <= 1; else alu_do(ALU_PASS, SZW, false, B_PROD, true, false); done; end if;
                     when x"52" =>
                        if w0(3) = '1' then bad;
                        elsif step = 0 then step <= 1;
                        else alu_do(ALU_PASS, SZL, false, B_PROD, true, false); done; end if;
                     when x"51" | x"53" => null;                         -- the divider below

                     -------------------------------------------------------------- 54 rts, 56 rte
                     when x"54" | x"56" =>
                        case step is
                           when 0 => if bfree then rd_bus(false, false, 1, true, S_EXEC); end if;
                           when 1 =>
                              tmp(31 downto 16) <= unsigned(mdr);
                              if bfree then rd_bus(false, false, 2, false, S_EXEC); end if;
                           when others =>
                              if hi = x"56" then ccr <= std_logic_vector(tmp(31 downto 24)); end if;
                              regw("0111", SZL, W_EA);
                              jump(J_TM);
                              done;
                        end case;

                     -------------------------------------------------------------- 57 trapa #n
                     when x"57" =>
                        -- trapa #n: the interrupt entry with vector 8 + n (H8/3002). Hitachi's manual sets I (and UI when
                        -- UE = 0) as for an interrupt; MAME's trapa leaves CCR alone. The manual is followed (docs/H8.md).
                        if w0(3 downto 0) /= x"0" or w0(7 downto 6) /= "00" then bad;
                        else
                           vecn <= to_unsigned(8, 6) + unsigned(w0(5 downto 4)); trap <= '1';
                           ipc <= dpc; st <= S_IRQ; step <= 0;
                        end if;

                     -------------------------------------------------------------- jmp / jsr / bsr
                     when x"55" | x"5C" | x"5D" | x"5E" | x"5F" | x"59" | x"5A" | x"5B" =>
                        -- the target into tmp (step 0, or read from @aa:8 in steps 1-2), then jsr / bsr push the return
                        -- address (steps 4-5)
                        case step is
                           when 0 =>
                              case hi is
                                 when x"59" => jump(J_S); done;
                                 when x"5A" => jump(J_EA); done;
                                 when x"5D" => tmp <= resize(rS(23 downto 0), 32); step <= 4;
                                 when x"55" | x"5C" | x"5E" => tmp <= resize(ea_v(23 downto 0), 32); step <= 4;
                                 when others =>                                       -- @@aa:8
                                    if bfree then ea <= ea_v; rd_bus(false, false, 1, true, S_EXEC); end if;
                              end case;
                           when 1 =>
                              tmp(31 downto 16) <= unsigned(mdr);
                              if bfree then rd_bus(false, false, 2, false, S_EXEC); end if;
                           when 2 =>
                              if hi = x"5B" then jump(J_TM); done;
                              else tmp <= resize(tmp(23 downto 16) & unsigned(mdr), 32); step <= 4; end if;
                           when 4 =>
                              if bfree then regw("0111", SZL, W_EA); ea <= ea_v; wr_bus(false, D_RHI, false); step <= 5; end if;
                           when others =>
                              if bfree then wr_bus(false, D_RLO, false); jump(J_T); done; end if;
                        end case;

                     -------------------------------------------------------------- 60-63, 67, 70-77 bit ops on a register
                     when x"60" | x"61" | x"62" | x"63" | x"67" | x"70" | x"71" | x"72" | x"73" | x"74" | x"75" | x"76" | x"77" =>
                        if hi(7 downto 4) = x"6" and hi /= x"67" then
                           bitn := to_integer(unsigned(v8(rS, ixs)(2 downto 0)));
                        else
                           bitn := to_integer(unsigned(w0(6 downto 4)));
                        end if;
                        bval := v8(rD, ixd);
                        c := ccr(0);
                        case hi is
                           when x"60" | x"70" => bval(bitn) := '1'; alu_do(ALU_PASS, SZB, false, B_BIT, true, false);       -- bset
                           when x"61" | x"71" => bval(bitn) := not bval(bitn); alu_do(ALU_PASS, SZB, false, B_BIT, true, false);  -- bnot
                           when x"62" | x"72" => bval(bitn) := '0'; alu_do(ALU_PASS, SZB, false, B_BIT, true, false);       -- bclr
                           when x"63" | x"73" => ccr(2) <= not bval(bitn);                                                 -- btst
                           when x"67" =>                                                                                   -- bst / bist
                              if w0(7) = '0' then bval(bitn) := c; else bval(bitn) := not c; end if;
                              alu_do(ALU_PASS, SZB, false, B_BIT, true, false);
                           when x"74" => if w0(7) = '0' then ccr(0) <= c or bval(bitn); else ccr(0) <= c or not bval(bitn); end if;     -- bor / bior
                           when x"75" => if w0(7) = '0' then ccr(0) <= c xor bval(bitn); else ccr(0) <= c xor not bval(bitn); end if;   -- bxor / bixor
                           when x"76" => if w0(7) = '0' then ccr(0) <= c and bval(bitn); else ccr(0) <= c and not bval(bitn); end if;   -- band / biand
                           when others => if w0(7) = '0' then ccr(0) <= bval(bitn); else ccr(0) <= not bval(bitn); end if;             -- bld / bild
                        end case;
                        done;

                     -------------------------------------------------------------- 7C-7F bit ops on memory (@ERd / @aa:8)
                     when x"7C" | x"7D" | x"7E" | x"7F" =>
                        if step = 0 then
                           if bfree then
                              ea <= ea_v;
                              rd_bus(false, true, 1, hi = x"7D" or hi = x"7F", S_EXEC);
                           end if;
                        else
                           if w1(15 downto 8) = x"60" or w1(15 downto 8) = x"61" or w1(15 downto 8) = x"62" or w1(15 downto 8) = x"63" then
                              bitn := to_integer(unsigned(v8(rD, ixd)(2 downto 0)));
                           else
                              bitn := to_integer(unsigned(w1(6 downto 4)));
                           end if;
                           bval := mdr(7 downto 0);
                           c := ccr(0);
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
                           elsif bfree then
                              case w1(15 downto 8) is
                                 when x"60" | x"70" => bval(bitn) := '1';
                                 when x"61" | x"71" => bval(bitn) := not bval(bitn);
                                 when x"62" | x"72" => bval(bitn) := '0';
                                 when x"67" => if w1(7) = '0' then bval(bitn) := c; else bval(bitn) := not c; end if;
                                 when others => bad;
                              end case;
                              wr_bus(false, D_BIT, true); done;
                           end if;
                        end if;

                     -------------------------------------------------------------- 68-6F, 78 mov.b / mov.w with memory
                     when x"68" | x"69" | x"6A" | x"6B" | x"6C" | x"6D" | x"6E" | x"6F" | x"78" =>
                        -- size: 68 6A 6C 6E byte, 69 6B 6D 6F word; 78: the second word's 6A / 6B
                        if hi = x"78" then w := w1; else w := w0; end if;
                        if w(8) = '0' then sz := SZB; else sz := SZW; end if;
                        ld := w(7) = '0';
                        if (hi = x"6A" or hi = x"6B") and not (w0(7 downto 4) = x"0" or w0(7 downto 4) = x"8" or
                                                              w0(7 downto 4) = x"2" or w0(7 downto 4) = x"A") then
                           bad;
                        elsif step = 0 then
                           if bfree then
                              if hi = x"6C" or hi = x"6D" then regw(ixs, SZL, W_EA); end if;
                              if ld then
                                 -- @ERs+ loads read at ERs; the adder gives ERs + size for the write-back
                                 rd_bus(hi = x"6C" or hi = x"6D", sz = SZB, 1, false, S_EXEC);
                              else                                       -- store: flags from the register
                                 if sz = SZB then wr_bus(false, D_D8, true); else wr_bus(false, D_D16, false); end if;
                                 alu_do(ALU_NZV, sz, false, B_D, false, true); done;
                              end if;
                           end if;
                        else
                           alu_do(ALU_NZV, sz, false, B_MDR, true, true); done;
                        end if;

                     -------------------------------------------------------------- 79 / 7A immediate .w / .l
                     when x"79" | x"7A" =>
                        if hi = x"79" then sz := SZW; else sz := SZL; end if;
                        if hi = x"7A" and w0(3) = '1' then bad;
                        else
                           case w0(7 downto 4) is
                              when x"0" => alu_do(ALU_NZV, sz, false, B_IMM, true, true); done;
                              when x"1" => alu_do(ALU_ADD, sz, true, B_IMM, true, true); done;
                              when x"2" => alu_do(ALU_SUB, sz, true, B_IMM, false, true); done;
                              when x"3" => alu_do(ALU_SUB, sz, true, B_IMM, true, true); done;
                              when x"4" => lop := 1; alu_do(ALU_NZV, sz, true, B_IMM, true, true); done;
                              when x"5" => lop := 2; alu_do(ALU_NZV, sz, true, B_IMM, true, true); done;
                              when x"6" => lop := 3; alu_do(ALU_NZV, sz, true, B_IMM, true, true); done;
                              when others => bad;
                           end case;
                        end if;

                     -------------------------------------------------------------- 7B eepmov.b / .w
                     when x"7B" =>
                        -- block move: R4L (.b) or R4 (.w) bytes from @ER5 to @ER6, both incremented
                        if w0(7 downto 0) = x"5C" then sz := SZB; else sz := SZW; end if;
                        case step is
                           when 0 =>
                              if unsigned(vsz(rD, ixd, sz)) = 0 then
                                 done;
                              elsif bfree then
                                 regw(ixs, SZL, W_EA); rd_bus(true, true, 1, true, S_EXEC);
                              end if;
                           when 1 =>
                              if bfree then regw(ixs, SZL, W_EA); wr_bus(true, D_MDR8, true); step <= 2; end if;
                           when others =>
                              alu_do(ALU_SUB, sz, true, B_IMM, true, false); step <= 0;
                        end case;

                     -------------------------------------------------------------- 8x-Fx byte immediate
                     when others =>
                        if hi(7) = '1' then
                           case hi(7 downto 4) is
                              when x"8" => alu_do(ALU_ADD,  SZB, true, B_IMM, true, true);
                              when x"9" => alu_do(ALU_ADDX, SZB, true, B_IMM, true, true);
                              when x"A" => alu_do(ALU_SUB,  SZB, true, B_IMM, false, true);
                              when x"B" => alu_do(ALU_SUBX, SZB, true, B_IMM, true, true);
                              when x"C" => lop := 1; alu_do(ALU_NZV, SZB, true, B_IMM, true, true);
                              when x"D" => lop := 2; alu_do(ALU_NZV, SZB, true, B_IMM, true, true);
                              when x"E" => lop := 3; alu_do(ALU_NZV, SZB, true, B_IMM, true, true);
                              when others => alu_do(ALU_NZV, SZB, false, B_IMM, true, true);
                           end case;
                           done;
                        else
                           bad;
                        end if;
                  end case;

                  -------------------------------------------------------------- divxu (51, 53), divxs (01 D0 51 / 53)
                  if hi = x"51" or hi = x"53" or (hi = x"01" and w0(7 downto 0) = x"D0" and
                                                  (w1(15 downto 8) = x"51" or w1(15 downto 8) = x"53")) then
                     mbyte := hi = x"51" or (hi = x"01" and w1(15 downto 8) = x"51");   -- (w1 is stale for 51 / 53)
                     if step = 0 then
                        -- dividend Rd (16 bits, .b) / ERd (32), divisor Rs (8 bits, .b) / Rs (16); divxs: both signed
                        if mbyte then
                           if msgn then dnd := sx16(v16(rD, ixd)); dsr := unsigned(resize(signed(v8(rS, ixs)), 16));
                           else dnd := resize(unsigned(v16(rD, ixd)), 32); dsr := resize(unsigned(v8(rS, ixs)), 16); end if;
                        else
                           dnd := rD; dsr := unsigned(v16(rS, ixs));
                        end if;
                        dneg := msgn and dnd(31) = '1';
                        sneg := msgn and ((mbyte and dsr(7) = '1') or (not mbyte and dsr(15) = '1'));
                        if dsr = 0 then ccr(2) <= '1'; else ccr(2) <= '0'; end if;
                        -- divxu: N from the divisor's sign bit (bit 7 / bit 15: the manual; MAME uses bit 7 for .w)
                        if msgn then ccr(3) <= '0';
                        elsif (mbyte and dsr(7) = '1') or (not mbyte and dsr(15) = '1') then ccr(3) <= '1';
                        else ccr(3) <= '0'; end if;
                        if dsr = 0 then
                           done;
                        else
                           if dneg then dv_q <= 0 - dnd; else dv_q <= dnd; end if;
                           if sneg then dv_d <= 0 - dsr; else dv_d <= dsr; end if;
                           dv_r <= (others => '0'); dv_n <= 32;
                           if dneg xor sneg then dv_qneg <= '1'; else dv_qneg <= '0'; end if;
                           if dneg then dv_rneg <= '1'; else dv_rneg <= '0'; end if;
                           step <= 1;
                        end if;
                     elsif dv_n /= 0 then
                        t17 := dv_r & dv_q(31);
                        if t17 >= ('0' & dv_d) then
                           t17 := t17 - ('0' & dv_d); dv_q <= dv_q(30 downto 0) & '1';
                        else
                           dv_q <= dv_q(30 downto 0) & '0';
                        end if;
                        dv_r <= t17(15 downto 0); dv_n <= dv_n - 1;
                     else
                        if dv_qneg = '1' then q32 := 0 - dv_q; else q32 := dv_q; end if;
                        if dv_rneg = '1' then r16 := 0 - dv_r; else r16 := dv_r; end if;
                        -- divxs: N from the (truncated, signed) quotient
                        if msgn then ccr(3) <= q32(31); end if;
                        if mbyte then divres := x"0000" & r16(7 downto 0) & q32(7 downto 0); regw(ixd, SZW, W_DIV);
                        else divres := r16 & q32(15 downto 0); regw(ixd, SZL, W_DIV); end if;
                        done;
                     end if;
                  end if;

               when S_HALT => null;
            end case;

            ------------------------------------------------------------------ ALU, logic unit, register write port
            if ago then
               if ad then aa := vsz(rD, ixd, asz); else aa := (others => '0'); end if;
               case bsel is
                  when B_S      => ab := vsz(rS, ixs, asz);
                  when B_D      => ab := vsz(rD, ixd, asz);
                  when B_NOTD   => ab := not vsz(rD, ixd, asz);
                  when B_IMM    => ab := imm;
                  when B_MDR    => ab := x"0000" & mdr;
                  when B_TMDR   => ab := std_logic_vector(tmp(31 downto 16)) & mdr;
                  when B_EXTU8  => ab := x"000000" & v16(rD, ixd)(7 downto 0);
                  when B_EXTU16 => ab := x"0000" & std_logic_vector(rD(15 downto 0));
                  when B_EXTS8  => ab := std_logic_vector(sx8(v16(rD, ixd)(7 downto 0)));
                  when B_EXTS16 => ab := std_logic_vector(sx16(std_logic_vector(rD(15 downto 0))));
                  when B_PROD   => ab := std_logic_vector(prod(31 downto 0));
                  when B_CCR    => ab := x"000000" & ccr;
                  when B_BIT    => ab := x"000000" & bval;
                  when others   => ab := (others => '0');
               end case;
               case lop is
                  when 1 => ab := aa or ab; aa := (others => '0');
                  when 2 => ab := aa xor ab; aa := (others => '0');
                  when 3 => ab := aa and ab; aa := (others => '0');
                  when others => null;
               end case;
               alu_calc(aop, asz, aa, ab, ccr, ares, accr);
               if aset then ccr <= accr; end if;
               if awb then regw(ixd, asz, W_ALU); end if;
            end if;
            if wen then
               case wsel is
                  when W_EA  => wdat := ea_v;
                  when W_DIV => wdat := divres;
                  when others => wdat := unsigned(ares);
               end case;
               i := to_integer(unsigned(widx(2 downto 0)));
               case wsz is
                  when "00" =>
                     if widx(3) = '1' then er(i)(7 downto 0) <= wdat(7 downto 0); else er(i)(15 downto 8) <= wdat(7 downto 0); end if;
                  when "01" =>
                     if widx(3) = '1' then er(i)(31 downto 16) <= wdat(15 downto 0); else er(i)(15 downto 0) <= wdat(15 downto 0); end if;
                  when others =>
                     er(i) <= wdat;
               end case;
            end if;

            ------------------------------------------------------------------ jump, end of instruction, data access
            case jsel is
               when J_S  => tgt := rS(23 downto 0);
               when J_TM => tgt := tmp(23 downto 16) & unsigned(mdr);
               when J_T  => tgt := tmp(23 downto 0);
               when others => tgt := ea_v(23 downto 0);
            end case;
            if fin then
               if flush then ipc <= tgt; else ipc <= dpc; end if;
               if irq = '1' then
                  st <= S_IRQ; step <= 0; vecn <= unsigned(irq_vec); trap <= '0';
               else
                  st <= S_DEC; nf <= 0; dbg_start <= '1';
               end if;
            end if;
            if badv then illegal <= '1'; st <= S_HALT; end if;
            if bq /= 0 then
               if bqs then ba := rS(23 downto 0); else ba := ea_v(23 downto 0); end if;
               if bqbyte then
                  b_addr <= ba;
                  if ba(0) = '0' then b_be <= "10"; else b_be <= "01"; end if;
               else
                  b_addr <= ba(23 downto 1) & '0'; b_be <= "11";
               end if;
               b_fetch <= '0';
               if bq = 1 then
                  b_rd <= '1';
                  if bqhold then b_hold <= '1'; else b_hold <= '0'; end if;
                  ret_st <= bqback; ret_step <= bqk; st <= S_WAIT;
               else
                  b_wr <= '1'; b_hold <= '0';
                  case bqd is
                     when D_D8   => b_wdata <= v8(rD, ixd) & v8(rD, ixd);
                     when D_D16  => b_wdata <= v16(rD, ixd);
                     when D_DHI  => b_wdata <= std_logic_vector(rD(31 downto 16));
                     when D_TLO  => b_wdata <= std_logic_vector(tmp(15 downto 0));
                     when D_CCR  => b_wdata <= ccr & ccr;
                     when D_PCLO => b_wdata <= std_logic_vector(ipc(15 downto 0));
                     when D_PCHI => b_wdata <= ccr & std_logic_vector(ipc(23 downto 16));
                     when D_RHI  => b_wdata <= x"00" & std_logic_vector(dpc(23 downto 16));
                     when D_RLO  => b_wdata <= std_logic_vector(dpc(15 downto 0));
                     when D_MDR8 => b_wdata <= mdr(7 downto 0) & mdr(7 downto 0);
                     when others => b_wdata <= bval & bval;
                  end case;
               end if;
            end if;

            ------------------------------------------------------------------ prefetch
            if flush then                                         -- a taken branch: the queue restarts at the target
               fc := 0; dpc <= tgt;
               if b_rd = '1' and b_fetch = '1' and bus_ack = '0' then b_disc <= '1'; end if;
            end if;
            if bq = 0 and bfree and fc <= 1 and not (st = S_WAIT and b_hold = '1') and st /= S_HALT then
               if flush then
                  b_addr <= tgt; fpc <= tgt + 2;
               else
                  b_addr <= fpc; fpc <= fpc + 2;
               end if;
               b_be <= "11"; b_rd <= '1'; b_fetch <= '1';
            elsif flush then
               fpc <= tgt;
            end if;
            fq <= fqv; fcnt <= fc;
         end if;
      end if;
   end process;
end architecture;
