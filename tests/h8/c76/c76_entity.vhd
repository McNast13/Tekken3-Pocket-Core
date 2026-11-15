-- The System 11 core's c76 entity (from the core tree's rtl/c76.vhd), for tests/h8/c76: architecture h8 is
-- pocket/core/s12/h8_c76.vhd.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c76 is
   port (
      clk        : in  std_logic;
      ce         : in  std_logic;
      reset      : in  std_logic;

      -- C76 internal BIOS download port (ioctl index 8, byte stream)
      bios_wr    : in  std_logic := '0';
      bios_addr  : in  std_logic_vector(13 downto 0) := (others => '0');
      bios_din   : in  std_logic_vector(7 downto 0) := (others => '0');

      -- interrupt request lines (driven by the substrate; 60 Hz IRQ0/IRQ2 first cut)
      irq0       : in  std_logic;
      irq1       : in  std_logic;
      irq2       : in  std_logic;

      -- 2026-07-06: analog inputs (Tekken P1 kicks ride ADC ch1/ch2; idle = 0xFF)
      -- 2026-07-13: AN0 added — Pocket Racer's steering wheel (PADDLE, centre 0x80,
      -- legal range 0x38-0xC8 per MAME); AN1 doubles as its pedal (idle 0x00).
      -- 2026-07-26: AN3-AN7 added for PLAYER 3. In MAME's BASE namcos11 port set the WHOLE of
      -- player 3 arrives through the A-D converter (AN0/1/2 = BUTTON3/2/1, AN3=RIGHT AN4=LEFT
      -- AN5=DOWN AN6=UP, AN7=START3); only the four base-layout titles use them (Dunk Mania,
      -- Dancing Eyes, Star Sweep, Xevious 3D-G) -- every other port set overrides them UNUSED.
      -- Until now they fell through to the 0x20-0x2F catch-all (0xFF = permanently unpressed),
      -- so player 3 could never press anything.
      in_adc0    : in  std_logic_vector(7 downto 0) := x"FF";
      in_adc1    : in  std_logic_vector(7 downto 0) := x"FF";
      in_adc2    : in  std_logic_vector(7 downto 0) := x"FF";
      in_adc3    : in  std_logic_vector(7 downto 0) := x"FF";
      in_adc4    : in  std_logic_vector(7 downto 0) := x"FF";
      in_adc5    : in  std_logic_vector(7 downto 0) := x"FF";
      in_adc6    : in  std_logic_vector(7 downto 0) := x"FF";
      in_adc7    : in  std_logic_vector(7 downto 0) := x"FF";

      -- external bus to the System 11 substrate (input ports, C352, shared RAM, SPROG)
      ext_addr   : out std_logic_vector(23 downto 0);
      ext_dout   : out std_logic_vector(7 downto 0);
      ext_din    : in  std_logic_vector(7 downto 0);
      ext_rd     : out std_logic;
      ext_wr     : out std_logic;
      ext_ready  : in  std_logic;

      -- debug / verification taps (passthrough from core)
      dbg_pc     : out std_logic_vector(23 downto 0);
      dbg_opcode : out std_logic_vector(7 downto 0);
      dbg_valid  : out std_logic;
      dbg_halted : out std_logic;
      dbg_x      : out std_logic_vector(15 downto 0);
      -- internal-RAM taps: 0x83 = the TB0 ISR's toggle byte the 0xC151 wait loop polls;
      -- 0x80 = the flag byte whose bit6 gates the toggle path (BBS #$40,$80 @0xC26D).
      dbg_ram80  : out std_logic_vector(7 downto 0);
      dbg_ram83  : out std_logic_vector(7 downto 0)
   );
end entity;
