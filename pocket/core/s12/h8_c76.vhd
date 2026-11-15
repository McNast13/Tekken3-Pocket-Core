-- The real H8/3002 in the C76's place for Tekken 3 (System 12): architecture h8 of the System 11 core's c76 entity.
-- synth/pocket_probe/variants/t3_h8.apply appends it to rtl/c76.vhd (see its docstring); tests/h8/c76 simulates it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

architecture h8 of c76 is
   signal bus_addr : std_logic_vector(23 downto 0);
   signal bus_wdata, bus_rdata, per_q, mem_q : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_rd, bus_wr, bus_ack, per_ack, mem_ack, per_sel, irq, irq_ack, syscr_ue, illegal : std_logic;
   signal bus_be : std_logic_vector(1 downto 0);
   signal irq_vec, irq_ack_vec : std_logic_vector(5 downto 0);
   signal ccr : std_logic_vector(7 downto 0);
   signal cpu_pc : std_logic_vector(23 downto 0);
   signal irq_in : std_logic_vector(5 downto 0);
   signal pb_in : std_logic_vector(7 downto 0);

   -- memories (inferred block RAM): private RAM 24K x 16, on-chip RAM 256 x 16, ROM cache 4K x 16 + 512 tags
   type r8_t is array (natural range <>) of std_logic_vector(7 downto 0);
   signal pr_hi, pr_lo : r8_t(0 to 24575);
   signal oc_hi, oc_lo : r8_t(0 to 255);
   signal rc_hi, rc_lo : r8_t(0 to 4095);
   type tag_t is array (0 to 511) of std_logic_vector(6 downto 0);    -- valid & addr(18 downto 13)
   signal rtag : tag_t;
   signal pr_a : integer range 0 to 24575 := 0;
   signal oc_a : integer range 0 to 255 := 0;
   signal rc_a : integer range 0 to 4095 := 0;
   signal tg_a : integer range 0 to 511 := 0;
   signal pr_q, oc_q, rc_q : std_logic_vector(15 downto 0);
   signal tg_q : std_logic_vector(6 downto 0);
   signal pr_we_hi, pr_we_lo, oc_we_hi, oc_we_lo, rc_we_hi, rc_we_lo, tg_we : std_logic := '0';
   signal pr_d, oc_d, rc_d : std_logic_vector(15 downto 0) := (others => '0');
   signal tg_d : std_logic_vector(6 downto 0) := (others => '0');

   type st_t is (IDLE, RAMWAIT, PRIV, ONCHIP, ROMLOOK, FILL, EXTB, DONE);
   signal st, st_next : st_t := IDLE;   -- RAMWAIT: the block RAM reads, then st_next
   signal xb : integer range 0 to 15 := 0;        -- byte of a fill / of an outside word
   signal xhi : std_logic_vector(7 downto 0) := (others => '0');
   signal ea : std_logic_vector(23 downto 0) := (others => '0');
   signal erd, ewr : std_logic := '0';
   signal edo : std_logic_vector(7 downto 0) := (others => '0');
begin
   cpu : entity work.h8_cpu
      port map (clk => clk, ce => '1', reset => reset, bus_addr => bus_addr, bus_wdata => bus_wdata, bus_rdata => bus_rdata,
                bus_rd => bus_rd, bus_wr => bus_wr, bus_be => bus_be, bus_ack => bus_ack, irq => irq, irq_vec => irq_vec,
                irq_ack => irq_ack, irq_ack_vec => irq_ack_vec, syscr_ue => syscr_ue, ccr_o => ccr,
                dbg_start => open, dbg_pc => cpu_pc, dbg_ccr => open, dbg_er => open, dbg_illegal => illegal);

   per_sel <= '1' when unsigned(bus_addr) >= 16#FFFF1C# else '0';
   irq_in <= "0000" & irq0 & '0';
   pb_in <= irq0 & "1111111";
   per : entity work.h8_periph
      port map (clk => clk, reset => reset, phi_ce => ce,
                sel => per_sel, rd => bus_rd, wr => bus_wr, a8 => bus_addr(7 downto 0), be => bus_be, wdata => bus_wdata,
                rdata => per_q, ack => per_ack,
                ccr => ccr, irq => irq, irq_vec => irq_vec, irq_ack => irq_ack, irq_ack_vec => irq_ack_vec,
                syscr_ue => syscr_ue,
                irq_in => irq_in, adtrg => irq0,
                adc_in => (others => '0'),                         -- MAME namcos12 ADC_0-3: unused, 0
                p4_in => x"FF", p6_in => x"FF", p7_in => in_adc4, p8_in => x"EF", p9_in => x"FF", pa_in => x"FF", pb_in => pb_in,
                p4_out => open, p6_out => open, p8_out => open, p9_out => open, pa_out => open, pb_out => open,
                sci1_txd => open, sci1_sck => open, sci1_rxd => '1');
   bus_ack <= per_ack or mem_ack;
   bus_rdata <= per_q when per_sel = '1' else mem_q;

   -- block RAMs: registered address, one clock to read
   process (clk)
   begin
      if rising_edge(clk) then
         if pr_we_hi = '1' then pr_hi(pr_a) <= pr_d(15 downto 8); end if;
         if pr_we_lo = '1' then pr_lo(pr_a) <= pr_d(7 downto 0); end if;
         pr_q <= pr_hi(pr_a) & pr_lo(pr_a);
         if oc_we_hi = '1' then oc_hi(oc_a) <= oc_d(15 downto 8); end if;
         if oc_we_lo = '1' then oc_lo(oc_a) <= oc_d(7 downto 0); end if;
         oc_q <= oc_hi(oc_a) & oc_lo(oc_a);
         if rc_we_hi = '1' then rc_hi(rc_a) <= rc_d(15 downto 8); end if;
         if rc_we_lo = '1' then rc_lo(rc_a) <= rc_d(7 downto 0); end if;
         rc_q <= rc_hi(rc_a) & rc_lo(rc_a);
         if tg_we = '1' then rtag(tg_a) <= tg_d; end if;
         tg_q <= rtag(tg_a);
      end if;
   end process;

   -- bus: memories, the ROM cache and the C76 bus
   process (clk)
      variable a : unsigned(23 downto 0);
   begin
      if rising_edge(clk) then
         mem_ack <= '0';
         pr_we_hi <= '0'; pr_we_lo <= '0'; oc_we_hi <= '0'; oc_we_lo <= '0'; rc_we_hi <= '0'; rc_we_lo <= '0'; tg_we <= '0';
         a := unsigned(bus_addr);
         if reset = '1' then
            st <= IDLE; erd <= '0'; ewr <= '0';
         else
            case st is
               when IDLE =>
                  if (bus_rd = '1' or bus_wr = '1') and per_sel = '0' and mem_ack = '0' then
                     if a >= 16#084000# and a <= 16#08FFFF# then
                        pr_a <= to_integer(a(15 downto 1)) - 16#2000#; pr_d <= bus_wdata;
                        pr_we_hi <= bus_wr and bus_be(1); pr_we_lo <= bus_wr and bus_be(0); st <= RAMWAIT; st_next <= PRIV;
                     elsif a >= 16#FFFD10# and a <= 16#FFFF0F# then
                        oc_a <= to_integer((a - 16#FFFD10#) / 2); oc_d <= bus_wdata;
                        oc_we_hi <= bus_wr and bus_be(1); oc_we_lo <= bus_wr and bus_be(0); st <= RAMWAIT; st_next <= ONCHIP;
                     elsif a < 16#080000# then
                        if bus_wr = '1' then mem_ack <= '1';
                        elsif a >= 16#040000# then mem_q <= x"FFFF"; mem_ack <= '1';   -- the program's 0xFF tail
                        else rc_a <= to_integer(a(12 downto 1)); tg_a <= to_integer(a(12 downto 4)); st <= RAMWAIT; st_next <= ROMLOOK; end if;
                     elsif (a >= 16#080000# and a <= 16#083FFF#) or (a >= 16#280000# and a <= 16#287FFF#) then
                        xb <= 0; st <= EXTB;
                     elsif a >= 16#300000# and a <= 16#300003# then
                        -- the inputs (MAME namcos12 in_r, JAMMA): 0 P2, 1 P1, 2 service / test / coins, 3 kicks; t3_h8.apply
                        -- brings the four bytes in on in_adc0-3 (a byte read takes its lane)
                        if a(1) = '0' then mem_q <= in_adc0 & in_adc1; else mem_q <= in_adc2 & in_adc3; end if;
                        mem_ack <= '1';
                     else
                        mem_q <= x"0000"; mem_ack <= '1';                 -- wait-state writes, unmapped
                     end if;
                  end if;
               when RAMWAIT => st <= st_next;
               when PRIV => mem_q <= pr_q; mem_ack <= '1'; st <= DONE;
               when ONCHIP => mem_q <= oc_q; mem_ack <= '1'; st <= DONE;
               when ROMLOOK =>
                  if tg_q = '1' & bus_addr(18 downto 13) then
                     mem_q <= rc_q; mem_ack <= '1'; st <= DONE;
                  else
                     xb <= 0; st <= FILL;
                  end if;
               when FILL =>                                              -- 16 bytes from the SPROG window
                  -- rd stays high for the whole line, the address stepping a byte at a time: SYSTEM11.sv's reader keeps
                  -- a fetched word while rd is held, so a line is 4 SDRAM reads (dropping rd between bytes made it 16)
                  if erd = '0' then
                     ea <= x"2" & '0' & bus_addr(18 downto 4) & std_logic_vector(to_unsigned(xb, 4));
                     erd <= '1';
                  elsif ce = '1' and ext_ready = '1' then
                     if xb /= 15 then
                        ea <= x"2" & '0' & bus_addr(18 downto 4) & std_logic_vector(to_unsigned(xb + 1, 4));
                     else
                        erd <= '0';
                     end if;
                     if xb mod 2 = 0 then
                        xhi <= ext_din;
                     else
                        rc_a <= to_integer(unsigned(bus_addr(12 downto 4))) * 8 + xb / 2;
                        rc_d <= xhi & ext_din; rc_we_hi <= '1'; rc_we_lo <= '1';
                     end if;
                     if xb = 15 then
                        tg_a <= to_integer(unsigned(bus_addr(12 downto 4))); tg_d <= '1' & bus_addr(18 downto 13); tg_we <= '1';
                        st <= DONE;                                        -- the CPU still asks: looked up again
                     else
                        xb <= xb + 1;
                     end if;
                  end if;
               when EXTB =>                                              -- outside: one or two byte cycles
                  if erd = '0' and ewr = '0' then
                     if a >= 16#280000# then
                        ea <= x"002" & std_logic_vector(a(11 downto 1)) & not (bus_addr(0) xor std_logic(to_unsigned(xb, 1)(0)));
                     else
                        ea <= x"00" & std_logic_vector("01" & a(13 downto 1)) & not (bus_addr(0) xor std_logic(to_unsigned(xb, 1)(0)));
                     end if;
                     if bus_be = "11" and xb = 0 then edo <= bus_wdata(15 downto 8);
                     elsif bus_be = "11" or bus_be = "01" then edo <= bus_wdata(7 downto 0);
                     else edo <= bus_wdata(15 downto 8); end if;
                     erd <= bus_rd; ewr <= bus_wr;
                  elsif ce = '1' and ext_ready = '1' then
                     erd <= '0'; ewr <= '0';
                     if bus_be = "11" and xb = 0 then
                        xhi <= ext_din; xb <= 1;
                     else
                        if bus_be = "11" then mem_q <= xhi & ext_din; else mem_q <= ext_din & ext_din; end if;
                        mem_ack <= '1'; st <= DONE;
                     end if;
                  end if;
               when DONE => st <= IDLE;                                  -- the CPU drops its request
            end case;
         end if;
      end if;
   end process;

   ext_addr <= ea;
   ext_dout <= edo;
   ext_rd   <= erd;
   ext_wr   <= ewr;

   dbg_pc     <= cpu_pc;
   dbg_opcode <= ccr;
   dbg_valid  <= illegal;
   dbg_halted <= illegal;
   dbg_x      <= (others => '0');
   dbg_ram80  <= (others => '0');
   dbg_ram83  <= (others => '0');
end architecture;
