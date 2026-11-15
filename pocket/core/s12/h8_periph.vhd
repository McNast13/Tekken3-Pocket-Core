-- H8/3002 on-chip peripherals for Tekken 3's H8 (docs/H8.md): the register page 0xFFFF1C-0xFFFFFF. Behaviour follows
-- MAME 0.289 (tools/h8model/mame: h83002.cpp map, h8_timer16, h8_intc, h8_adc, h8_sci, h8_port), which the reference
-- recordings come from. What Tekken 3 uses (MAME taps, docs/H8.md):
--   16-bit timer (ITU) channels 0-3: TCR, TIER, TSR, TCNT, GRA, GRB; TSTR. Clocks phi/1/2/4/8, counter clear on GRA /
--     GRB match, compare-match and overflow flags and interrupts. Channels 0 and 1 overflow at 120 Hz (the tempo),
--     2 and 3 run free as time-outs. Not here: channel 4, PWM / buffer / sync modes, timer pins, external clocks.
--   Interrupt controller: IRQ0-5 (ISCR edge / level, IER, ISR), IPRA / IPRB priorities, the CCR I / UI masks
--     (SYSCR.UE), fixed order by vector number. IRQ1 is vblank on System 12.
--   A/D: single mode, started by ADST or by the ADTRG pin (falling edge, ADCR.TRGE): 266 states (134 with CKS),
--     ADF, ADI; ADDRA-D take channels mod 4 (MAME's H8/3337-type converter). Not here: scan mode (taken as single).
--   SCI1, clocked synchronous with the internal clock (the RTC / settings link): TDR -> TSR, TDRE / TEND, receive with
--     RDRF / ORER, TXI / RXI / TEI / ERI. SCI0 (JVS, unused by Tekken 3): registers only, SSR reads TDRE | TEND.
--   Ports 4, 6, 7, 8, 9, A, B: data and direction registers; a pin reads as DR where DDR = 1, else the input; MAME's
--     per-port fixed bits. SYSCR (UE out).
-- Register access: sel with rd / wr for one request, held until ack (one clock); a8 = the byte address in the page,
-- be as the CPU's bus ("11" word at an even address, "10" even byte, "01" odd byte); read data on both lanes for a
-- byte. phi_ce: the H8 system clock phi (16.9344 MHz on System 12) as a clock enable.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity h8_periph is
   port (
      clk, reset : in  std_logic;
      phi_ce     : in  std_logic;
      -- CPU bus (register page)
      sel        : in  std_logic;
      rd, wr     : in  std_logic;
      a8         : in  std_logic_vector(7 downto 0);
      be         : in  std_logic_vector(1 downto 0);
      wdata      : in  std_logic_vector(15 downto 0);
      rdata      : out std_logic_vector(15 downto 0);
      ack        : out std_logic;
      -- CPU interrupt
      ccr        : in  std_logic_vector(7 downto 0);
      irq        : out std_logic;
      irq_vec    : out std_logic_vector(5 downto 0);
      irq_ack    : in  std_logic;                        -- the CPU reads the vector of ...
      irq_ack_vec : in std_logic_vector(5 downto 0);     -- ... this interrupt
      syscr_ue   : out std_logic;
      -- pins
      irq_in     : in  std_logic_vector(5 downto 0);     -- IRQ0-5, 1 = asserted (the pins are active low)
      adtrg      : in  std_logic;                        -- 1 = asserted; a conversion starts as it is released
      adc_in     : in  std_logic_vector(79 downto 0);    -- AN0-7, 10 bits each (AN0 in 9-0)
      p4_in, p6_in, p7_in, p8_in, p9_in, pa_in, pb_in : in std_logic_vector(7 downto 0);
      p4_out, p6_out, p8_out, p9_out, pa_out, pb_out : out std_logic_vector(7 downto 0);   -- undriven bits read 1
      sci1_txd   : out std_logic;
      sci1_sck   : out std_logic;
      sci1_rxd   : in  std_logic
   );
end entity;

architecture rtl of h8_periph is
   type u16a is array (0 to 3) of unsigned(15 downto 0);
   type u8a  is array (0 to 3) of std_logic_vector(7 downto 0);
   -- ITU
   signal tstr : std_logic_vector(7 downto 0) := (others => '0');
   signal tcnt, gra, grb : u16a := (others => (others => '0'));
   signal tcr, tier : u8a := (others => (others => '0'));
   signal imfa, imfb, ovf : std_logic_vector(3 downto 0) := (others => '0');
   signal pcnt : unsigned(2 downto 0) := (others => '0');            -- phi prescaler
   -- interrupt controller, SYSCR
   signal iscr, ier, isr, ipra, iprb : std_logic_vector(7 downto 0) := (others => '0');
   signal syscr : std_logic_vector(7 downto 0) := x"09";
   signal irq_d : std_logic_vector(5 downto 0) := (others => '0');
   -- A/D
   type adr_t is array (0 to 3) of std_logic_vector(9 downto 0);
   signal addr_r : adr_t := (others => (others => '0'));
   signal adcsr, adcr : std_logic_vector(7 downto 0) := (others => '0');
   signal adc_t : unsigned(8 downto 0) := (others => '0');            -- states left in the conversion
   signal adc_busy, adtrg_d : std_logic := '0';
   -- SCI0 (registers), SCI1
   signal smr0, scr0, tdr0, smr1, scr1, tdr1, rdr1 : std_logic_vector(7 downto 0) := (others => '0');
   signal brr0, brr1 : std_logic_vector(7 downto 0) := x"FF";
   signal ssr1      : std_logic_vector(7 downto 0) := x"84";
   signal ssr1_read : std_logic_vector(7 downto 0) := (others => '0'); -- flags seen as 1 by a read (MAME m_ssr_read)
   signal tsr1, rsr1 : std_logic_vector(7 downto 0) := (others => '0');
   signal tx_on, rx_on : std_logic := '0';
   signal tx_bit, rx_bit : unsigned(2 downto 0) := (others => '0');
   signal sck_div : unsigned(15 downto 0) := (others => '0');           -- phi count to the next SCK edge
   signal sck : std_logic := '1';
   -- ports
   type pa_t is array (0 to 6) of std_logic_vector(7 downto 0);     -- 4, 6, 8, 9, A, B (index 0-5); 6 unused
   signal pdr  : pa_t := (others => (others => '0'));
   signal pddr : pa_t := (0 => x"00", 1 => x"80", 2 => x"F0", others => (others => '0'));
   signal ack_r : std_logic := '0';
   signal rq : std_logic_vector(15 downto 0) := (others => '0');

   constant SSR_TDRE : integer := 7;
   constant SSR_RDRF : integer := 6;
   constant SSR_ORER : integer := 5;
   constant SSR_FER  : integer := 4;
   constant SSR_PER  : integer := 3;
   constant SSR_TEND : integer := 2;
   constant SSR_MPBT : integer := 0;
   -- ports: index in pdr / pddr, MAME's fixed bits (read 1, never driven)
   constant P4 : integer := 0;
   constant P6 : integer := 1;
   constant P8 : integer := 2;
   constant P9 : integer := 3;
   constant PA : integer := 4;
   constant PB : integer := 5;
   type m_t is array (0 to 5) of std_logic_vector(7 downto 0);
   constant PMASK : m_t := (x"00", x"80", x"E0", x"C0", x"00", x"00");

   function prd(dr, ddr, pin : std_logic_vector(7 downto 0); m : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      return m or (dr and ddr) or (pin and not ddr);
   end function;
   function pout(dr, ddr : std_logic_vector(7 downto 0); m : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      return (dr or not ddr) or m;
   end function;
   -- interrupt sources by vector (H8/3002): IRQ0-5 12-17, ADI 60 (MAME's wiring), IMIA/IMIB/OVI n 24+4n..26+4n,
   -- SCI0 ERI/RXI/TXI/TEI 52-55, SCI1 56-59
begin
   p4_out <= pout(pdr(P4), pddr(P4), PMASK(P4));
   p6_out <= pout(pdr(P6), pddr(P6), PMASK(P6));
   p8_out <= pout(pdr(P8), pddr(P8), PMASK(P8));
   p9_out <= pout(pdr(P9), pddr(P9), PMASK(P9));
   pa_out <= pout(pdr(PA), pddr(PA), PMASK(PA));
   pb_out <= pout(pdr(PB), pddr(PB), PMASK(PB));
   sci1_sck <= sck;
   sci1_txd <= tsr1(0) when tx_on = '1' else '1';
   syscr_ue <= syscr(3);
   ack <= ack_r;
   rdata <= rq;

   ------------------------------------------------------------------ interrupt request: priority, then the lowest vector
   process (all)
      variable best_v : integer range 0 to 63;
      variable best_l : integer range -1 to 1;
      variable lvl    : integer range 0 to 1;
      variable ok     : boolean;
      procedure cand(v : integer; req : std_logic; pri : std_logic) is
      begin
         if pri = '1' then lvl := 1; else lvl := 0; end if;
         -- masks (h83002 update_irq_filter): UE = 1: I masks all; UE = 0: I and UI mask all, I alone masks level 0
         if syscr(3) = '1' then ok := ccr(7) = '0';
         elsif ccr(7) = '1' and ccr(6) = '1' then ok := false;
         elsif ccr(7) = '1' then ok := lvl = 1;
         else ok := true; end if;
         if req = '1' and ok and lvl > best_l then best_v := v; best_l := lvl; end if;
      end procedure;
   begin
      best_v := 0; best_l := -1; lvl := 0; ok := false;
      -- in vector order, so that at equal priority the lowest vector stays
      cand(12, isr(0) and ier(0), ipra(7));
      cand(13, isr(1) and ier(1), ipra(6));
      cand(14, isr(2) and ier(2), ipra(5));
      cand(15, isr(3) and ier(3), ipra(5));
      cand(16, isr(4) and ier(4), ipra(4));
      cand(17, isr(5) and ier(5), ipra(4));
      for c in 0 to 3 loop
         if c < 3 then
            cand(24 + 4 * c, imfa(c) and tier(c)(0), ipra(2 - c));
            cand(25 + 4 * c, imfb(c) and tier(c)(1), ipra(2 - c));
            cand(26 + 4 * c, ovf(c) and tier(c)(2), ipra(2 - c));
         else
            cand(36, imfa(3) and tier(3)(0), iprb(7));
            cand(37, imfb(3) and tier(3)(1), iprb(7));
            cand(38, ovf(3) and tier(3)(2), iprb(7));
         end if;
      end loop;
      cand(56, (ssr1(SSR_ORER) or ssr1(SSR_FER) or ssr1(SSR_PER)) and scr1(6), iprb(2));   -- ERI1
      cand(57, ssr1(SSR_RDRF) and scr1(6), iprb(2));                                        -- RXI1
      cand(58, ssr1(SSR_TDRE) and scr1(7), iprb(2));                                        -- TXI1
      cand(59, ssr1(SSR_TEND) and scr1(2), iprb(2));                                        -- TEI1
      cand(60, adcsr(7) and adcsr(6), iprb(1));                                             -- ADI
      if best_l >= 0 then irq <= '1'; else irq <= '0'; end if;
      irq_vec <= std_logic_vector(to_unsigned(best_v, 6));
   end process;

   process (clk)
      variable a, ae : unsigned(7 downto 0);
      variable tick, sck_rise : boolean;
      variable inc : boolean;
      variable ch : integer range 0 to 7;
      variable rd_lane : std_logic_vector(7 downto 0);
      -- registers that both the CPU and the hardware change: the CPU's access first, the hardware's after (a flag
      -- that sets in the same clock as the CPU clears it stays set; a TCNT write takes that clock's count)
      variable vssr, vssr_read, vadcsr, visr : std_logic_vector(7 downto 0);
      variable vimfa, vimfb, vovf : std_logic_vector(3 downto 0);
      variable vtcnt : u16a;
      variable tw : std_logic_vector(3 downto 0);              -- TCNT written by the CPU this clock
      variable adc_go : boolean;

      -- byte read of the register page (no side effects)
      impure function rreg(ad : unsigned(7 downto 0)) return std_logic_vector is
         variable k, off : integer range 0 to 15;
         variable r : std_logic_vector(7 downto 0);
      begin
         r := x"00";
         if ad >= x"64" and ad < x"8C" then                    -- ITU channels 0-3
            if ad < x"6E" then k := 0; off := to_integer(ad - x"64");
            elsif ad < x"78" then k := 1; off := to_integer(ad - x"6E");
            elsif ad < x"82" then k := 2; off := to_integer(ad - x"78");
            else k := 3; off := to_integer(ad - x"82"); end if;
            case off is
               when 0 => r := tcr(k);
               when 1 => r := x"00";                                                           -- TIOR (MAME: 0)
               when 2 => r := tier(k) or x"F8";
               when 3 => r := "11111" & ovf(k) & imfb(k) & imfa(k);
               when 4 => r := std_logic_vector(tcnt(k)(15 downto 8));
               when 5 => r := std_logic_vector(tcnt(k)(7 downto 0));
               when 6 => r := std_logic_vector(gra(k)(15 downto 8));
               when 7 => r := std_logic_vector(gra(k)(7 downto 0));
               when 8 => r := std_logic_vector(grb(k)(15 downto 8));
               when others => r := std_logic_vector(grb(k)(7 downto 0));
            end case;
         else
            case to_integer(ad) is
               when 16#60# => r := tstr;
               when 16#B0# => r := smr0;
               when 16#B1# => r := brr0;
               when 16#B2# => r := scr0;
               when 16#B3# => r := tdr0;
               when 16#B4# => r := x"84";                                                      -- SSR0: TDRE, TEND
               when 16#B8# => r := smr1;
               when 16#B9# => r := brr1;
               when 16#BA# => r := scr1;
               when 16#BB# => r := tdr1;
               when 16#BC# => r := ssr1;
               when 16#BD# => r := rdr1;
               when 16#C5# | 16#C9# | 16#CD# | 16#D0# | 16#D1# | 16#D4# => r := x"FF";        -- DDRs read 1s
               when 16#C7# => r := prd(pdr(P4), pddr(P4), p4_in, PMASK(P4));
               when 16#CB# => r := prd(pdr(P6), pddr(P6), p6_in, PMASK(P6));
               when 16#CE# => r := p7_in;
               when 16#CF# => r := prd(pdr(P8), pddr(P8), p8_in, PMASK(P8));
               when 16#D2# => r := prd(pdr(P9), pddr(P9), p9_in, PMASK(P9));
               when 16#D3# => r := prd(pdr(PA), pddr(PA), pa_in, PMASK(PA));
               when 16#D6# => r := prd(pdr(PB), pddr(PB), pb_in, PMASK(PB));
               when 16#E0# | 16#E2# | 16#E4# | 16#E6# => r := addr_r(to_integer(ad(2 downto 1)))(9 downto 2);
               when 16#E1# | 16#E3# | 16#E5# | 16#E7# => r := addr_r(to_integer(ad(2 downto 1)))(1 downto 0) & "000000";
               when 16#E8# => r := adcsr;
               when 16#E9# => r := adcr;
               when 16#F2# => r := syscr;
               when 16#F4# => r := iscr;
               when 16#F5# => r := ier;
               when 16#F6# => r := isr;
               when 16#F8# => r := ipra;
               when 16#F9# => r := iprb;
               when others => r := x"00";
            end case;
         end if;
         return r;
      end function;

      -- byte write of the register page
      procedure wreg(ad : unsigned(7 downto 0); d : std_logic_vector(7 downto 0)) is
         variable k, off : integer range 0 to 15;
      begin
         if ad >= x"64" and ad < x"8C" then
            if ad < x"6E" then k := 0; off := to_integer(ad - x"64");
            elsif ad < x"78" then k := 1; off := to_integer(ad - x"6E");
            elsif ad < x"82" then k := 2; off := to_integer(ad - x"78");
            else k := 3; off := to_integer(ad - x"82"); end if;
            case off is
               when 0 => tcr(k) <= d;
               when 2 => tier(k) <= d;
               when 3 =>                                       -- TSR: a 0 clears the flag (h8h isr_update)
                  if d(0) = '0' then vimfa(k) := '0'; end if;
                  if d(1) = '0' then vimfb(k) := '0'; end if;
                  if d(2) = '0' then vovf(k) := '0'; end if;
               when 4 => vtcnt(k)(15 downto 8) := unsigned(d); tw(k) := '1';
               when 5 => vtcnt(k)(7 downto 0) := unsigned(d); tw(k) := '1';
               when 6 => gra(k)(15 downto 8) <= unsigned(d);
               when 7 => gra(k)(7 downto 0) <= unsigned(d);
               when 8 => grb(k)(15 downto 8) <= unsigned(d);
               when 9 => grb(k)(7 downto 0) <= unsigned(d);
               when others => null;
            end case;
         else
            case to_integer(ad) is
               when 16#60# => tstr <= d;
               when 16#B0# => smr0 <= d;
               when 16#B1# => brr0 <= d;
               when 16#B2# => scr0 <= d;
               when 16#B3# => tdr0 <= d;
               when 16#B8# => smr1 <= d;
               when 16#B9# => brr1 <= d;
               when 16#BA# =>
                  scr1 <= d;
                  if d(4) = '0' then rx_on <= '0'; end if;   -- RE off stops a receive
               when 16#BB# => tdr1 <= d;
               when 16#BC# =>                                  -- SSR1 (h8_sci ssr_w)
                  if scr1(5) = '1' and vssr(SSR_TDRE) = '1' and vssr_read(SSR_TDRE) = '1' and d(SSR_TDRE) = '0' then
                     vssr(SSR_TDRE) := '0'; vssr(SSR_TEND) := '0';
                  end if;
                  for b in 3 to 6 loop                         -- RDRF, ORER, FER, PER: a 0 clears them once read as 1
                     if vssr_read(b) = '1' and d(b) = '0' then vssr(b) := '0'; end if;
                  end loop;
                  vssr(SSR_MPBT) := d(SSR_MPBT);
                  vssr_read := vssr_read and vssr;
               when 16#C5# => pddr(P4) <= d;
               when 16#C7# => pdr(P4) <= d;
               when 16#C9# => pddr(P6) <= d;
               when 16#CB# => pdr(P6) <= d;
               when 16#CD# => pddr(P8) <= d;
               when 16#CF# => pdr(P8) <= d;
               when 16#D0# => pddr(P9) <= d;
               when 16#D1# => pddr(PA) <= d;
               when 16#D2# => pdr(P9) <= d;
               when 16#D3# => pdr(PA) <= d;
               when 16#D4# => pddr(PB) <= d;
               when 16#D6# => pdr(PB) <= d;
               when 16#E8# =>                                  -- ADCSR: ADF kept only if written 1; ADST starts
                  if vadcsr(5) = '0' and d(5) = '1' then adc_go := true; end if;
                  vadcsr := (vadcsr(7) and d(7)) & d(6 downto 0);
               when 16#E9# => adcr <= d;
               when 16#F2# => syscr <= d;
               when 16#F4# => iscr <= d;
               when 16#F5# => ier <= d;
               when 16#F6# => visr := visr and d;
               when 16#F8# => ipra <= d;
               when 16#F9# => iprb <= d;
               when others => null;
            end case;
         end if;
      end procedure;
   begin
      if rising_edge(clk) then
         if reset = '1' then
            tstr <= (others => '0'); tcnt <= (others => (others => '0')); tcr <= (others => (others => '0'));
            tier <= (others => (others => '0')); imfa <= (others => '0'); imfb <= (others => '0'); ovf <= (others => '0');
            gra <= (others => x"FFFF"); grb <= (others => x"FFFF");
            iscr <= (others => '0'); ier <= (others => '0'); isr <= (others => '0'); ipra <= (others => '0');
            iprb <= (others => '0'); syscr <= x"09"; irq_d <= (others => '0');
            adcsr <= (others => '0'); adcr <= (others => '0'); adc_busy <= '0'; adtrg_d <= '0';
            smr1 <= (others => '0'); scr1 <= (others => '0'); ssr1 <= x"84"; ssr1_read <= (others => '0');
            tx_on <= '0'; rx_on <= '0'; sck <= '1';
            pdr <= (others => (others => '0'));
            pddr <= (0 => x"00", 1 => x"80", 2 => x"F0", others => (others => '0'));
            ack_r <= '0';
         else
            vssr := ssr1; vssr_read := ssr1_read; vadcsr := adcsr; visr := isr;
            vimfa := imfa; vimfb := imfb; vovf := ovf; vtcnt := tcnt; tw := "0000"; adc_go := false;

            ------------------------------------------------------------ register access (reads see the clock's start)
            ack_r <= '0';
            if sel = '1' and (rd = '1' or wr = '1') and ack_r = '0' then
               ack_r <= '1';
               a := unsigned(a8);
               ae := a(7 downto 1) & '0';
               if rd = '1' then
                  if be = "11" then rq <= rreg(ae) & rreg(ae + 1);
                  else rd_lane := rreg(a); rq <= rd_lane & rd_lane; end if;
                  -- SSR1 read: the flags it saw may be cleared by a later write of 0
                  if (be = "11" and ae = x"BC") or (be /= "11" and a = x"BC") then vssr_read := ssr1; end if;
               else
                  if be(1) = '1' then wreg(ae, wdata(15 downto 8)); end if;
                  if be(0) = '1' then wreg(ae + 1, wdata(7 downto 0)); end if;
               end if;
            end if;

            ------------------------------------------------------------ IRQ0-5: edge (ISCR = 1) or level
            for n in 0 to 5 loop
               if iscr(n) = '1' then
                  if irq_in(n) = '1' and irq_d(n) = '0' then visr(n) := '1'; end if;
               elsif irq_in(n) = '1' then
                  visr(n) := '1';
               end if;
            end loop;
            irq_d <= irq_in;
            if irq_ack = '1' and unsigned(irq_ack_vec) >= 12 and unsigned(irq_ack_vec) <= 17 then
               ch := to_integer(unsigned(irq_ack_vec)) - 12;
               if iscr(ch) = '1' or irq_in(ch) = '0' then visr(ch) := '0'; end if;
            end if;

            ------------------------------------------------------------ ITU: count at phi / 1, 2, 4, 8
            if phi_ce = '1' then
               pcnt <= pcnt + 1;
               for k in 0 to 3 loop
                  case tcr(k)(2 downto 0) is
                     when "000" => tick := true;
                     when "001" => tick := pcnt(0) = '1';
                     when "010" => tick := pcnt(1 downto 0) = "11";
                     when "011" => tick := pcnt = "111";
                     when others => tick := false;                    -- external clocks: not wired
                  end case;
                  if tstr(k) = '1' and tick and tw(k) = '0' then
                     inc := true;
                     if vtcnt(k) = gra(k) then
                        vimfa(k) := '1';
                        if tcr(k)(6 downto 5) = "01" then vtcnt(k) := (others => '0'); inc := false; end if;
                     end if;
                     if inc and vtcnt(k) = grb(k) then
                        vimfb(k) := '1';
                        if tcr(k)(6 downto 5) = "10" then vtcnt(k) := (others => '0'); inc := false; end if;
                     end if;
                     if inc then
                        if vtcnt(k) = x"FFFF" then vovf(k) := '1'; end if;
                        vtcnt(k) := vtcnt(k) + 1;
                     end if;
                  end if;
               end loop;
            end if;

            ------------------------------------------------------------ A/D
            adtrg_d <= adtrg;
            if adtrg = '0' and adtrg_d = '1' and adcr(7) = '1' and vadcsr(5) = '0' then
               vadcsr(5) := '1'; adc_go := true;
            end if;
            if adc_go then
               adc_busy <= '1';
               if vadcsr(3) = '1' then adc_t <= to_unsigned(134, 9); else adc_t <= to_unsigned(266, 9); end if;
            elsif adc_busy = '1' and phi_ce = '1' then
               if adc_t = 0 then
                  ch := to_integer(unsigned(vadcsr(2 downto 0)));
                  addr_r(ch mod 4) <= adc_in(10 * ch + 9 downto 10 * ch);
                  vadcsr(7) := '1'; vadcsr(5) := '0'; adc_busy <= '0';
               else
                  adc_t <= adc_t - 1;
               end if;
            end if;

            ------------------------------------------------------------ SCI1, clocked synchronous, internal clock
            -- SCK half period = (2 << 2 CKS) * (BRR + 1) phi (h8_sci clock_update, INTERNAL_SYNC_OUT); the next bit goes
            -- out and the received bit comes in on each rising edge; LSB first
            sck_rise := false;
            if tx_on = '0' and rx_on = '0' then
               sck <= '1'; sck_div <= (others => '0');
            elsif phi_ce = '1' then
               if sck_div = 0 then
                  sck_div <= shift_left(resize(unsigned(brr1), 16) + 1, 1 + 2 * to_integer(unsigned(smr1(1 downto 0)))) - 1;
                  sck <= not sck;
                  sck_rise := sck = '0';
               else
                  sck_div <= sck_div - 1;
               end if;
            end if;
            if sck_rise then
               if tx_on = '1' then tsr1 <= '1' & tsr1(7 downto 1); end if;
               if rx_on = '1' then rsr1 <= sci1_rxd & rsr1(7 downto 1); end if;
               tx_bit <= tx_bit + 1;
               if tx_bit = 7 then                                     -- a byte done
                  if rx_on = '1' then
                     if vssr(SSR_RDRF) = '1' then vssr(SSR_ORER) := '1'; rx_on <= '0';
                     else rdr1 <= sci1_rxd & rsr1(7 downto 1); vssr(SSR_RDRF) := '1'; end if;
                  end if;
                  if tx_on = '1' then
                     if vssr(SSR_TDRE) = '0' then                    -- the next byte is waiting
                        tsr1 <= tdr1; vssr(SSR_TDRE) := '1';
                     else
                        tx_on <= '0'; vssr(SSR_TEND) := '1';
                     end if;
                  end if;
               end if;
            elsif tx_on = '0' and vssr(SSR_TDRE) = '0' and scr1(5) = '1' then
               -- transmit start: TDRE cleared (TDR written) while idle with TE
               tx_on <= '1'; tsr1 <= tdr1; vssr(SSR_TDRE) := '1'; tx_bit <= (others => '0');
            elsif rx_on = '0' and tx_on = '0' and smr1(7) = '1' and scr1(4) = '1' and scr1(5) = '0' and
                  (vssr(SSR_ORER) or vssr(SSR_FER) or vssr(SSR_PER)) = '0' then
               -- receive runs while RE and not TE (h8_sci sync_rx_start)
               rx_on <= '1'; tx_bit <= (others => '0');
            end if;

            ssr1 <= vssr; ssr1_read <= vssr_read and vssr; adcsr <= vadcsr; isr <= visr;
            imfa <= vimfa; imfb <= vimfb; ovf <= vovf; tcnt <= vtcnt;
         end if;
      end if;
   end process;
end architecture;
