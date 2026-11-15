-- Checks pocket/core/s12/h8_alu.vhd against MAME's flag rules: every line of the vector file (make_vectors.py) gives
-- op, size, a, b, CCR and the result and CCR the generated MAME model produces. Run: tests/h8/alu/run.sh
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_h8_alu is
   generic (VECTORS : string := "vectors.txt");
end entity;

architecture tb of tb_h8_alu is
   signal op      : unsigned(4 downto 0);
   signal sz      : std_logic_vector(1 downto 0);
   signal a, b    : std_logic_vector(31 downto 0);
   signal ccr_in  : std_logic_vector(7 downto 0);
   signal res     : std_logic_vector(31 downto 0);
   signal ccr_out : std_logic_vector(7 downto 0);
begin
   dut : entity work.h8_alu port map (op => op, sz => sz, a => a, b => b, ccr_in => ccr_in, res => res, ccr_out => ccr_out);

   process
      file f : text open read_mode is VECTORS;
      variable l : line;
      variable iop, isz, n, errors : integer := 0;
      variable va, vb, er : std_logic_vector(31 downto 0);
      variable vc, ec : std_logic_vector(7 downto 0);
      type cnt_t is array (0 to 18) of integer;
      variable bad : cnt_t := (others => 0);
   begin
      while not endfile(f) loop
         readline(f, l);
         read(l, iop); read(l, isz); hread(l, va); hread(l, vb); hread(l, vc); hread(l, er); hread(l, ec);
         op <= to_unsigned(iop, 5); sz <= std_logic_vector(to_unsigned(isz, 2));
         a <= va; b <= vb; ccr_in <= vc;
         wait for 1 ns;
         if res /= er or ccr_out /= ec then
            if bad(iop) < 3 then
               report "op " & integer'image(iop) & " sz " & integer'image(isz) & " a " & to_hstring(va) & " b " &
                      to_hstring(vb) & " ccr " & to_hstring(vc) & ": got " & to_hstring(res) & " " & to_hstring(ccr_out) &
                      ", MAME " & to_hstring(er) & " " & to_hstring(ec) severity error;
            end if;
            bad(iop) := bad(iop) + 1;
            errors := errors + 1;
         end if;
         n := n + 1;
      end loop;
      report "tb_h8_alu: " & integer'image(n) & " cases, " & integer'image(errors) & " errors" severity note;
      assert errors = 0 report "FAILED" severity failure;
      wait;
   end process;
end architecture;
