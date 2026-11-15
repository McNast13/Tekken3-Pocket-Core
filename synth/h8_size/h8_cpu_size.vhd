-- Size wrapper: the real h8_cpu (pocket/core/s12) as it will sit in the core - load/debug ports unused.
library ieee;
use ieee.std_logic_1164.all;

entity h8_cpu_size is
   port (
      clk        : in  std_logic;
      ce, reset  : in  std_logic;
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
      ccr_o      : out std_logic_vector(7 downto 0)
   );
end entity;

architecture rtl of h8_cpu_size is
begin
   cpu : entity work.h8_cpu
      port map (clk => clk, ce => ce, reset => reset,
                bus_addr => bus_addr, bus_wdata => bus_wdata, bus_rdata => bus_rdata,
                bus_rd => bus_rd, bus_wr => bus_wr, bus_be => bus_be, bus_ack => bus_ack,
                irq => irq, irq_vec => irq_vec, irq_ack => irq_ack,
                syscr_ue => syscr_ue, ccr_o => ccr_o,
                dbg_start => open, dbg_pc => open, dbg_ccr => open, dbg_er => open, dbg_illegal => open);
end architecture;
