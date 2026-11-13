-- H8/3002 sizing model: the CPU model (h8_size) and the peripheral model (h8_periph) wired together, so the fit report
-- gives the whole H8's ALMs and timing. Not a working H8.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity h8_top is
   port (
      clk        : in  std_logic;
      ce         : in  std_logic;
      reset      : in  std_logic;
      ucode_we   : in  std_logic;
      ucode_sel  : in  std_logic;
      ucode_addr : in  std_logic_vector(11 downto 0);
      ucode_data : in  std_logic_vector(71 downto 0);
      -- external bus (program ROM, shared RAM, C352, inputs)
      ext_addr   : out std_logic_vector(23 downto 0);
      ext_dout   : out std_logic_vector(15 downto 0);
      ext_din    : in  std_logic_vector(15 downto 0);
      ext_rd     : out std_logic;
      ext_wr     : out std_logic;
      ext_be     : out std_logic_vector(1 downto 0);
      ext_ready  : in  std_logic;
      ext_bus16  : out std_logic;
      -- pins
      irq_pin    : in  std_logic_vector(5 downto 0);
      p7_in      : in  std_logic_vector(7 downto 0);
      p8_in      : in  std_logic_vector(4 downto 0);
      p9_in      : in  std_logic_vector(5 downto 0);
      pa_in      : in  std_logic_vector(7 downto 0);
      pb_in      : in  std_logic_vector(7 downto 0);
      port_out   : out std_logic_vector(34 downto 0);
      sci_sck    : out std_logic;
      sci_txd    : out std_logic;
      sci_rxd    : in  std_logic;
      adc_in0    : in  std_logic_vector(9 downto 0);
      adc_in1    : in  std_logic_vector(9 downto 0);
      adc_in2    : in  std_logic_vector(9 downto 0);
      adc_in3    : in  std_logic_vector(9 downto 0)
   );
end entity;

architecture arch of h8_top is
   signal addr : std_logic_vector(23 downto 0);
   signal dout, din, pdout : std_logic_vector(15 downto 0);
   signal rd, wr, ready, irq, ack, wait_req, onchip : std_logic;
   signal be : std_logic_vector(1 downto 0);
   signal vec : std_logic_vector(5 downto 0);
begin
   cpu : entity work.h8_size
   port map (
      clk => clk, ce => ce, reset => reset,
      ucode_we => ucode_we, ucode_sel => ucode_sel, ucode_addr => ucode_addr, ucode_data => ucode_data,
      bus_addr => addr, bus_dout => dout, bus_din => din, bus_rd => rd, bus_wr => wr, bus_be => be, bus_ready => ready,
      irq => irq, irq_vec => vec, irq_ack => ack
   );

   per : entity work.h8_periph
   port map (
      clk => clk, ce => ce, reset => reset,
      addr => addr, din => dout, dout => pdout, rd => rd, wr => wr, be => be,
      wait_req => wait_req, bus16 => ext_bus16,
      irq => irq, irq_vec => vec, irq_lvl => open, irq_ack => ack,
      irq_pin => irq_pin, p7_in => p7_in, p8_in => p8_in, p9_in => p9_in, pa_in => pa_in, pb_in => pb_in,
      port_out => port_out, sci_sck => sci_sck, sci_txd => sci_txd, sci_rxd => sci_rxd,
      adc_in0 => adc_in0, adc_in1 => adc_in1, adc_in2 => adc_in2, adc_in3 => adc_in3
   );

   -- 0xFFFD10-0xFFFFFF is on chip (RAM and registers); everything else is the external bus
   onchip <= '1' when unsigned(addr) >= x"FFFD10" else '0';
   din    <= pdout when onchip = '1' else ext_din;
   ready  <= '1' when onchip = '1' else (ext_ready and not wait_req);
   ext_addr <= addr;
   ext_dout <= dout;
   ext_rd   <= rd and not onchip;
   ext_wr   <= wr and not onchip;
   ext_be   <= be;
end architecture;
