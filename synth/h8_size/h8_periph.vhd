-- H8/3002 peripheral sizing model (docs/STUDY.md, fit). NOT working peripherals: the blocks Tekken 3 uses
-- (out/h8_io.log), with their registers, counters, comparators and flags at full width, so the fit report gives a real
-- ALM count before they exist. Register offsets are the H8/3002's (0xFFFFxx page); bit details are approximate.
--   ITU channels 0-3: TCNT, GRA, GRB, TCR (clock select, counter clear), TIOR, TIER, TSR (IMFA, IMFB, OVF);
--     TSTR, TSNC, TMDR. No PWM, buffer or phase-counting modes and no timer pins (none are wired on System 12).
--   SCI1, clocked synchronous: SMR, BRR (baud generator), SCR, TDR, SSR, RDR, transmit and receive shift registers.
--   Ports 7 (input), 8, 9, A, B: data and direction registers.
--   A/D: ADDRA-D, ADCSR (ADF, ADIE, ADST, channel), ADCR; a conversion timer; 4 input channels.
--   Interrupt controller: IRQ0-5 (ISCR edge/level, IER, ISR), IPRA/IPRB priorities, and the vector encoder over
--     IRQ0-5, the ITU (IMIA/IMIB/OVI x 4), SCI1 (ERI/RXI/TXI/TEI) and ADI.
--   Bus controller: ABWCR (8/16-bit areas), ASTCR, WCR (wait states), BRCR, area decode from A23-A21 and a wait counter.
--   SYSCR. The 512 B on-chip RAM (block RAM).
-- Left out (Tekken 3 never touches them): DMA controller, watchdog, DRAM refresh, SCI0 (JVS).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity h8_periph is
   port (
      clk       : in  std_logic;
      ce        : in  std_logic;                        -- H8 system clock (phi) enable
      reset     : in  std_logic;
      -- CPU side
      addr      : in  std_logic_vector(23 downto 0);
      din       : in  std_logic_vector(15 downto 0);
      dout      : out std_logic_vector(15 downto 0);
      rd        : in  std_logic;
      wr        : in  std_logic;
      be        : in  std_logic_vector(1 downto 0);
      wait_req  : out std_logic;                        -- external bus wait states
      bus16     : out std_logic;                        -- current area is 16-bit
      irq       : out std_logic;
      irq_vec   : out std_logic_vector(5 downto 0);
      irq_lvl   : out std_logic;
      irq_ack   : in  std_logic;
      -- pins
      irq_pin   : in  std_logic_vector(5 downto 0);
      p7_in     : in  std_logic_vector(7 downto 0);
      p8_in     : in  std_logic_vector(4 downto 0);
      p9_in     : in  std_logic_vector(5 downto 0);
      pa_in     : in  std_logic_vector(7 downto 0);
      pb_in     : in  std_logic_vector(7 downto 0);
      port_out  : out std_logic_vector(34 downto 0);
      sci_sck   : out std_logic;
      sci_txd   : out std_logic;
      sci_rxd   : in  std_logic;
      adc_in0   : in  std_logic_vector(9 downto 0);
      adc_in1   : in  std_logic_vector(9 downto 0);
      adc_in2   : in  std_logic_vector(9 downto 0);
      adc_in3   : in  std_logic_vector(9 downto 0)
   );
end entity;

architecture arch of h8_periph is
   type u16a is array (0 to 3) of unsigned(15 downto 0);
   type u8a  is array (0 to 3) of std_logic_vector(7 downto 0);
   signal tcnt, gra, grb : u16a := (others => (others => '0'));
   signal tcr, tior, tier, tsr : u8a := (others => (others => '0'));
   signal tstr, tsnc, tmdr : std_logic_vector(7 downto 0) := (others => '0');
   signal presc : unsigned(2 downto 0) := (others => '0');

   signal smr, brr, scr, tdr, ssr, rdr : std_logic_vector(7 downto 0) := (others => '0');
   signal brg : unsigned(7 downto 0) := (others => '0');
   signal brg_div : unsigned(6 downto 0) := (others => '0');
   signal tsr_sh, rsr_sh : std_logic_vector(7 downto 0) := (others => '0');
   signal sci_bit : unsigned(3 downto 0) := (others => '0');
   signal sck_r, sci_busy : std_logic := '0';

   type pr_t is array (0 to 4) of std_logic_vector(7 downto 0);
   signal pdr, pddr : pr_t := (others => (others => '0'));

   type adr_t is array (0 to 3) of std_logic_vector(9 downto 0);
   signal addr_r : adr_t := (others => (others => '0'));
   signal adcsr, adcr : std_logic_vector(7 downto 0) := (others => '0');
   signal adc_t : unsigned(8 downto 0) := (others => '0');
   signal adc_ch : unsigned(1 downto 0) := (others => '0');

   signal iscr, ier, isr, ipra, iprb, syscr : std_logic_vector(7 downto 0) := (others => '0');
   signal irq_d : std_logic_vector(5 downto 0) := (others => '0');

   signal abwcr : std_logic_vector(7 downto 0) := x"FF";
   signal astcr : std_logic_vector(7 downto 0) := x"FF";
   signal wcr   : std_logic_vector(7 downto 0) := x"F3";
   signal brcr  : std_logic_vector(7 downto 0) := (others => '0');
   signal wcnt  : unsigned(1 downto 0) := (others => '0');

   type ram_t is array (0 to 255) of std_logic_vector(15 downto 0);
   signal iram : ram_t;
   signal iram_q : std_logic_vector(15 downto 0);

   signal reg_q : std_logic_vector(7 downto 0);
   signal io_sel, ram_sel : std_logic;
   signal a8 : unsigned(7 downto 0);
   signal wd : std_logic_vector(7 downto 0);
   signal sci_tick : std_logic;
   signal area : integer range 0 to 7;
   signal irq_vec_r : std_logic_vector(5 downto 0);
begin
   io_sel  <= '1' when addr(23 downto 8) = x"FFFF" and unsigned(addr(7 downto 0)) >= x"1C" else '0';
   ram_sel <= '1' when unsigned(addr) >= x"FFFD10" and unsigned(addr) < x"FFFF10" else '0';
   a8 <= unsigned(addr(7 downto 0));
   wd <= din(15 downto 8) when addr(0) = '0' else din(7 downto 0);
   area <= to_integer(unsigned(addr(23 downto 21)));

   -- on-chip RAM
   process (clk)
   begin
      if rising_edge(clk) then
         if ram_sel = '1' and wr = '1' then
            iram(to_integer(unsigned(addr(8 downto 1)))) <= din;
         end if;
         iram_q <= iram(to_integer(unsigned(addr(8 downto 1))));
      end if;
   end process;

   -- bus controller: 8/16-bit areas and programmable wait states (external areas only)
   bus16 <= abwcr(area);
   process (clk)
   begin
      if rising_edge(clk) then
         if ce = '1' then
            if (rd = '1' or wr = '1') and io_sel = '0' and ram_sel = '0' and astcr(area) = '1' and wcnt = 0 then
               wcnt <= unsigned(wcr(1 downto 0));
            elsif wcnt /= 0 then
               wcnt <= wcnt - 1;
            end if;
         end if;
      end if;
   end process;
   wait_req <= '1' when wcnt /= 0 else '0';

   -- register reads
   process (all)
      variable c : integer range 0 to 3;
      variable o : unsigned(7 downto 0);
   begin
      reg_q <= x"FF";
      if a8 >= x"64" and a8 < x"8C" then
         if a8 < x"78" then
            if a8 < x"6E" then c := 0; o := a8 - x"64"; else c := 1; o := a8 - x"6E"; end if;
         else
            if a8 < x"82" then c := 2; o := a8 - x"78"; else c := 3; o := a8 - x"82"; end if;
         end if;
         case to_integer(o) is
            when 0 => reg_q <= tcr(c);
            when 1 => reg_q <= tior(c);
            when 2 => reg_q <= tier(c);
            when 3 => reg_q <= tsr(c);
            when 4 => reg_q <= std_logic_vector(tcnt(c)(15 downto 8));
            when 5 => reg_q <= std_logic_vector(tcnt(c)(7 downto 0));
            when 6 => reg_q <= std_logic_vector(gra(c)(15 downto 8));
            when 7 => reg_q <= std_logic_vector(gra(c)(7 downto 0));
            when 8 => reg_q <= std_logic_vector(grb(c)(15 downto 8));
            when 9 => reg_q <= std_logic_vector(grb(c)(7 downto 0));
            when others => null;
         end case;
      end if;
      case to_integer(a8) is
         when 16#60# => reg_q <= tstr;
         when 16#61# => reg_q <= tsnc;
         when 16#62# => reg_q <= tmdr;
         when 16#B8# => reg_q <= smr;
         when 16#B9# => reg_q <= brr;
         when 16#BA# => reg_q <= scr;
         when 16#BB# => reg_q <= tdr;
         when 16#BC# => reg_q <= ssr;
         when 16#BD# => reg_q <= rdr;
         when 16#C0# => reg_q <= pddr(0);
         when 16#C1# => reg_q <= pddr(1);
         when 16#C4# => reg_q <= pddr(2);
         when 16#C5# => reg_q <= pddr(3);
         when 16#C8# => reg_q <= pddr(4);
         when 16#CE# => reg_q <= p7_in;
         when 16#CF# => reg_q <= (pdr(0)(7 downto 5) and pddr(0)(7 downto 5)) & (p8_in or (pdr(0)(4 downto 0) and pddr(0)(4 downto 0)));
         when 16#D0# => reg_q <= pdr(1)(7 downto 6) & (p9_in or (pdr(1)(5 downto 0) and pddr(1)(5 downto 0)));
         when 16#D3# => reg_q <= (pa_in and not pddr(2)) or (pdr(2) and pddr(2));
         when 16#D6# => reg_q <= (pb_in and not pddr(3)) or (pdr(3) and pddr(3));
         when 16#E0# => reg_q <= addr_r(0)(9 downto 2);
         when 16#E1# => reg_q <= addr_r(0)(1 downto 0) & "000000";
         when 16#E2# => reg_q <= addr_r(1)(9 downto 2);
         when 16#E3# => reg_q <= addr_r(1)(1 downto 0) & "000000";
         when 16#E4# => reg_q <= addr_r(2)(9 downto 2);
         when 16#E5# => reg_q <= addr_r(2)(1 downto 0) & "000000";
         when 16#E6# => reg_q <= addr_r(3)(9 downto 2);
         when 16#E7# => reg_q <= addr_r(3)(1 downto 0) & "000000";
         when 16#E8# => reg_q <= adcsr;
         when 16#E9# => reg_q <= adcr;
         when 16#EC# => reg_q <= abwcr;
         when 16#ED# => reg_q <= astcr;
         when 16#EE# => reg_q <= wcr;
         when 16#F3# => reg_q <= brcr;
         when 16#F2# => reg_q <= syscr;
         when 16#F4# => reg_q <= iscr;
         when 16#F5# => reg_q <= ier;
         when 16#F6# => reg_q <= isr;
         when 16#F8# => reg_q <= ipra;
         when 16#F9# => reg_q <= iprb;
         when others => null;
      end case;
   end process;
   dout <= iram_q when ram_sel = '1' else reg_q & reg_q;

   -- ITU, SCI, A/D, ports, interrupt flags: one clocked process (registers written by the CPU, updated by phi)
   sci_tick <= '1' when brg = 0 and brg_div = 0 else '0';
   process (clk)
      variable c : integer range 0 to 3;
      variable o : unsigned(7 downto 0);
      variable tick : std_logic;
   begin
      if rising_edge(clk) then
         if reset = '1' then
            tstr <= (others => '0'); tsr <= (others => (others => '0')); ssr <= x"84"; adcsr <= (others => '0');
            isr <= (others => '0'); ier <= (others => '0');
         else
            if ce = '1' then
               presc <= presc + 1;
               -- ITU counters: clock select phi/1, /2, /4, /8; clear on compare A or B; flags
               for i in 0 to 3 loop
                  case tcr(i)(1 downto 0) is
                     when "00"   => tick := '1';
                     when "01"   => tick := presc(0);
                     when "10"   => tick := presc(1) and presc(0);
                     when others => tick := presc(2) and presc(1) and presc(0);
                  end case;
                  if tstr(i) = '1' and tick = '1' then
                     if (tcr(i)(6 downto 5) = "01" and tcnt(i) = gra(i)) or (tcr(i)(6 downto 5) = "10" and tcnt(i) = grb(i)) then
                        tcnt(i) <= (others => '0');
                     else
                        tcnt(i) <= tcnt(i) + 1;
                     end if;
                     if tcnt(i) = gra(i) then tsr(i)(0) <= '1'; end if;
                     if tcnt(i) = grb(i) then tsr(i)(1) <= '1'; end if;
                     if tcnt(i) = x"FFFF" then tsr(i)(2) <= '1'; end if;
                  end if;
               end loop;

               -- SCI1 clocked synchronous: baud generator, then 8 bits out and in, LSB first
               if brg_div = 0 then
                  brg_div <= unsigned(smr(1 downto 0)) & "11111";
                  if brg = 0 then brg <= unsigned(brr); else brg <= brg - 1; end if;
               else
                  brg_div <= brg_div - 1;
               end if;
               if sci_busy = '0' and scr(5) = '1' and ssr(7) = '0' then
                  tsr_sh <= tdr; ssr(7) <= '1'; sci_busy <= '1'; sci_bit <= (others => '0');
               elsif sci_busy = '1' and sci_tick = '1' then
                  sck_r <= not sck_r;
                  if sck_r = '1' then
                     tsr_sh <= '1' & tsr_sh(7 downto 1);
                     rsr_sh <= sci_rxd & rsr_sh(7 downto 1);
                     sci_bit <= sci_bit + 1;
                     if sci_bit = 7 then
                        sci_busy <= '0'; ssr(2) <= '1';
                        if scr(4) = '1' then
                           if ssr(6) = '1' then ssr(5) <= '1'; end if;
                           rdr <= sci_rxd & rsr_sh(7 downto 1); ssr(6) <= '1';
                        end if;
                     end if;
                  end if;
               end if;

               -- A/D: one conversion per channel per 134 states, single or scan mode over AN0-3
               if adcsr(5) = '1' then
                  if adc_t = 133 then
                     adc_t <= (others => '0');
                     case adc_ch is
                        when "00"   => addr_r(0) <= adc_in0;
                        when "01"   => addr_r(1) <= adc_in1;
                        when "10"   => addr_r(2) <= adc_in2;
                        when others => addr_r(3) <= adc_in3;
                     end case;
                     if adcsr(4) = '1' and adc_ch /= unsigned(adcsr(1 downto 0)) then
                        adc_ch <= adc_ch + 1;
                     else
                        adcsr(7) <= '1';
                        if adcsr(4) = '0' then adcsr(5) <= '0'; else adc_ch <= (others => '0'); end if;
                     end if;
                  else
                     adc_t <= adc_t + 1;
                  end if;
               end if;

               -- IRQ0-5: edge (ISCR=1) or level
               irq_d <= irq_pin;
               for i in 0 to 5 loop
                  if (iscr(i) = '1' and irq_pin(i) = '0' and irq_d(i) = '1') or (iscr(i) = '0' and irq_pin(i) = '0') then
                     isr(i) <= '1';
                  end if;
               end loop;
            end if;

            -- CPU writes
            if wr = '1' and io_sel = '1' then
               if a8 >= x"64" and a8 < x"8C" then
                  if a8 < x"78" then
                     if a8 < x"6E" then c := 0; o := a8 - x"64"; else c := 1; o := a8 - x"6E"; end if;
                  else
                     if a8 < x"82" then c := 2; o := a8 - x"78"; else c := 3; o := a8 - x"82"; end if;
                  end if;
                  case to_integer(o) is
                     when 0 => tcr(c) <= wd;
                     when 1 => tior(c) <= wd;
                     when 2 => tier(c) <= wd;
                     when 3 => tsr(c) <= tsr(c) and wd;                    -- flags clear by writing 0
                     when 4 => tcnt(c)(15 downto 8) <= unsigned(wd);
                     when 5 => tcnt(c)(7 downto 0) <= unsigned(wd);
                     when 6 => gra(c)(15 downto 8) <= unsigned(wd);
                     when 7 => gra(c)(7 downto 0) <= unsigned(wd);
                     when 8 => grb(c)(15 downto 8) <= unsigned(wd);
                     when 9 => grb(c)(7 downto 0) <= unsigned(wd);
                     when others => null;
                  end case;
               end if;
               case to_integer(a8) is
                  when 16#60# => tstr <= wd;
                  when 16#61# => tsnc <= wd;
                  when 16#62# => tmdr <= wd;
                  when 16#B8# => smr <= wd;
                  when 16#B9# => brr <= wd;
                  when 16#BA# => scr <= wd;
                  when 16#BB# => tdr <= wd;
                  when 16#BC# => ssr(7 downto 3) <= ssr(7 downto 3) and wd(7 downto 3);
                  when 16#C0# => pddr(0) <= wd;
                  when 16#C1# => pddr(1) <= wd;
                  when 16#C4# => pddr(2) <= wd;
                  when 16#C5# => pddr(3) <= wd;
                  when 16#C8# => pddr(4) <= wd;
                  when 16#CF# => pdr(0) <= wd;
                  when 16#D0# => pdr(1) <= wd;
                  when 16#D3# => pdr(2) <= wd;
                  when 16#D6# => pdr(3) <= wd;
                  when 16#D9# => pdr(4) <= wd;
                  when 16#E8# => adcsr <= (adcsr(7) and wd(7)) & wd(6 downto 0);
                                 if wd(5) = '1' then adc_ch <= (others => '0'); adc_t <= (others => '0'); end if;
                  when 16#E9# => adcr <= wd;
                  when 16#EC# => abwcr <= wd;
                  when 16#ED# => astcr <= wd;
                  when 16#EE# => wcr <= wd;
                  when 16#F3# => brcr <= wd;
                  when 16#F2# => syscr <= wd;
                  when 16#F4# => iscr <= wd;
                  when 16#F5# => ier <= wd;
                  when 16#F6# => isr <= isr and wd;
                  when 16#F8# => ipra <= wd;
                  when 16#F9# => iprb <= wd;
                  when others => null;
               end case;
            end if;
            -- a read of SSR followed by clearing; TDR write clears TDRE
            if wr = '1' and io_sel = '1' and a8 = x"BB" then ssr(7) <= '0'; ssr(2) <= '0'; end if;
            -- IRQ0-5 acknowledged in edge mode: the CPU's ack clears the flag of the vector being taken
            if irq_ack = '1' and unsigned(irq_vec_r) >= 12 and unsigned(irq_vec_r) <= 17 then
               isr(to_integer(unsigned(irq_vec_r)) - 12) <= '0';
            end if;
         end if;
      end if;
   end process;

   sci_sck <= sck_r;
   sci_txd <= tsr_sh(0);
   port_out <= pdr(0)(7 downto 5) & (pdr(0)(4 downto 0) and pddr(0)(4 downto 0)) & (pdr(1)(5 downto 0) and pddr(1)(5 downto 0))
               & (pdr(2) and pddr(2)) & (pdr(3) and pddr(3)) & tmdr(0) & tsnc(0) & syscr(0) & brcr(0) & adcr(0);

   -- interrupt controller: highest-priority pending enabled source -> vector (H8/3002 vector numbers);
   -- priority level from IPRA/IPRB, lower vector number wins within a level
   process (all)
      type src_t is record v : integer range 0 to 63; p : std_logic; e : std_logic; end record;
      type srcs_t is array (0 to 22) of src_t;
      variable s : srcs_t;
      variable best_v : integer range 0 to 63;
      variable best_l, found : std_logic;
      variable lvl : std_logic_vector(0 to 22);
   begin
      for i in 0 to 5 loop
         s(i) := (12 + i, isr(i), ier(i));
      end loop;
      for i in 0 to 3 loop
         s(6 + 3 * i)     := (24 + 4 * i, tsr(i)(0), tier(i)(0));
         s(6 + 3 * i + 1) := (25 + 4 * i, tsr(i)(1), tier(i)(1));
         s(6 + 3 * i + 2) := (26 + 4 * i, tsr(i)(2), tier(i)(2));
      end loop;
      s(18) := (56, ssr(5) or ssr(4) or ssr(3), scr(6));   -- ERI1
      s(19) := (57, ssr(6), scr(6));                        -- RXI1
      s(20) := (58, ssr(7), scr(7));                        -- TXI1
      s(21) := (59, ssr(2), scr(2));                        -- TEI1
      s(22) := (60, adcsr(7), adcsr(6));                    -- ADI
      -- priority bits: IRQ0, IRQ1, IRQ2-3, IRQ4-5 = IPRA7-4; ITU channels 0-3 = IPRA3-0; SCI1 = IPRB6; A/D = IPRB5
      lvl := (ipra(7), ipra(6), ipra(5), ipra(5), ipra(4), ipra(4),
              ipra(3), ipra(3), ipra(3), ipra(2), ipra(2), ipra(2), ipra(1), ipra(1), ipra(1), ipra(0), ipra(0), ipra(0),
              iprb(6), iprb(6), iprb(6), iprb(6), iprb(5));
      found := '0'; best_v := 0; best_l := '0';
      for pass in 1 downto 0 loop                           -- priority level 1 sources first, then level 0
         for i in 0 to 22 loop
            if found = '0' and s(i).p = '1' and s(i).e = '1' and ((lvl(i) = '1') = (pass = 1)) then
               found := '1'; best_v := s(i).v; best_l := lvl(i);
            end if;
         end loop;
      end loop;
      irq <= found;
      irq_vec_r <= std_logic_vector(to_unsigned(best_v, 6));
      irq_lvl <= best_l;
   end process;
   irq_vec <= irq_vec_r;
end architecture;
