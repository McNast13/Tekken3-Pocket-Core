-- Size wrapper: the real H8 CPU and peripherals (pocket/core/s12) as they will sit in the core: the CPU's bus goes to
-- the peripheral page (0xFFFF1C up) or out (memories and the outside, acknowledged from outside); pins are ports.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity h8_sys_size is
   port (
      clk        : in  std_logic;
      reset      : in  std_logic;
      phi_ce     : in  std_logic;
      ext_addr   : out std_logic_vector(23 downto 0);
      ext_wdata  : out std_logic_vector(15 downto 0);
      ext_rdata  : in  std_logic_vector(15 downto 0);
      ext_rd     : out std_logic;
      ext_wr     : out std_logic;
      ext_be     : out std_logic_vector(1 downto 0);
      ext_ack    : in  std_logic;
      irq_in     : in  std_logic_vector(5 downto 0);
      adtrg      : in  std_logic;
      adc_in     : in  std_logic_vector(79 downto 0);
      p_in       : in  std_logic_vector(55 downto 0);
      p_out      : out std_logic_vector(47 downto 0);
      sci1_txd   : out std_logic;
      sci1_sck   : out std_logic;
      sci1_rxd   : in  std_logic
   );
end entity;

architecture rtl of h8_sys_size is
   signal bus_addr : std_logic_vector(23 downto 0);
   signal bus_wdata, bus_rdata, per_q : std_logic_vector(15 downto 0);
   signal bus_rd, bus_wr, bus_ack, per_ack, per_sel, irq, irq_ack, syscr_ue : std_logic;
   signal bus_be : std_logic_vector(1 downto 0);
   signal irq_vec, irq_ack_vec : std_logic_vector(5 downto 0);
   signal ccr : std_logic_vector(7 downto 0);
begin
   cpu : entity work.h8_cpu
      port map (clk => clk, ce => '1', reset => reset, bus_addr => bus_addr, bus_wdata => bus_wdata, bus_rdata => bus_rdata,
                bus_rd => bus_rd, bus_wr => bus_wr, bus_be => bus_be, bus_ack => bus_ack, irq => irq, irq_vec => irq_vec,
                irq_ack => irq_ack, irq_ack_vec => irq_ack_vec, syscr_ue => syscr_ue, ccr_o => ccr,
                dbg_start => open, dbg_pc => open, dbg_ccr => open, dbg_er => open, dbg_illegal => open);
   per_sel <= '1' when unsigned(bus_addr) >= 16#FFFF1C# else '0';
   per : entity work.h8_periph
      port map (clk => clk, reset => reset, phi_ce => phi_ce,
                sel => per_sel, rd => bus_rd, wr => bus_wr, a8 => bus_addr(7 downto 0), be => bus_be, wdata => bus_wdata,
                rdata => per_q, ack => per_ack,
                ccr => ccr, irq => irq, irq_vec => irq_vec, irq_ack => irq_ack, irq_ack_vec => irq_ack_vec,
                syscr_ue => syscr_ue, irq_in => irq_in, adtrg => adtrg, adc_in => adc_in,
                p4_in => p_in(7 downto 0), p6_in => p_in(15 downto 8), p7_in => p_in(23 downto 16),
                p8_in => p_in(31 downto 24), p9_in => p_in(39 downto 32), pa_in => p_in(47 downto 40),
                pb_in => p_in(55 downto 48),
                p4_out => p_out(7 downto 0), p6_out => p_out(15 downto 8), p8_out => p_out(23 downto 16),
                p9_out => p_out(31 downto 24), pa_out => p_out(39 downto 32), pb_out => p_out(47 downto 40),
                sci1_txd => sci1_txd, sci1_sck => sci1_sck, sci1_rxd => sci1_rxd);
   ext_addr  <= bus_addr;
   ext_wdata <= bus_wdata;
   ext_rd    <= bus_rd and not per_sel;
   ext_wr    <= bus_wr and not per_sel;
   ext_be    <= bus_be;
   bus_ack   <= per_ack or ext_ack;
   bus_rdata <= per_q when per_sel = '1' else ext_rdata;
end architecture;
