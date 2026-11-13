-- What does Tekken 3's main CPU wait for from the H8 at start-up? Logs, per shared-RAM address (main CPU 0x1F080000-
-- 0x1F083FFF), the main CPU's reads and writes and the last value, over the first frames; with H8_HALT=1 (default) the H8 is
-- parked as in h8_halt.lua, with H8_HALT=0 it runs normally (A/B). Also lists the H8's writes to the same RAM (H8 side
-- 0x080000-0x083FFF) when it runs. Run from the repo root:
--   HS_OUT=$PWD/out HS_FRAMES=1500 mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 40 \
--        -autoboot_script tools/mame/h8_handshake.lua
local halt = os.getenv("H8_HALT") ~= "0"
local out = os.getenv("HS_OUT") or "."
local last = tonumber(os.getenv("HS_FRAMES") or "1500")
local f = 0
local taps, log, order = {}, {}, {}
local seq = {}                                   -- first 400 accesses in order: frame, side, rw, addr, value

local function note(side, rw, a, v)
   local k = string.format("%s %s %06X", side, rw, a)
   local e = log[k]
   if not e then e = { n = 0, first = f }; log[k] = e; order[#order + 1] = k end
   e.n = e.n + 1; e.last = v
   if #seq < 400 then seq[#seq + 1] = string.format("f%-5d %s %s %06X = %08X  MIPS PC %08X", f, side, rw, a, v,
      manager.machine.devices[":maincpu"].state["CURPC"].value) end
end

emu.register_frame_done(function()
   f = f + 1
   local r = manager.machine.memory.regions[":sub"]
   if f == 1 and halt and r:read_u8(0x7fff0) ~= 0x40 then
      r:write_u8(0x7fff0, 0x40); r:write_u8(0x7fff1, 0xfe)
      r:write_u8(0, 0x00); r:write_u8(1, 0x07); r:write_u8(2, 0xff); r:write_u8(3, 0xf0)
      manager.machine:soft_reset()
      return
   end
   if f == 2 and #taps == 0 then
      local m = manager.machine.devices[":maincpu"].spaces["program"]
      taps[#taps + 1] = m:install_read_tap(0x1f080000, 0x1f083fff, "hs_mr", function(o, d, k) note("MIPS", "rd", o & 0x3fff, d) end)
      taps[#taps + 1] = m:install_write_tap(0x1f080000, 0x1f083fff, "hs_mw", function(o, d, k) note("MIPS", "wr", o & 0x3fff, d) end)
      if not halt then
         local h = manager.machine.devices[":sub"].spaces["program"]
         taps[#taps + 1] = h:install_write_tap(0x080000, 0x083fff, "hs_hw", function(o, d, k) note("H8  ", "wr", o & 0x3fff, d) end)
      end
   end
   if f == last then
      local fh = io.open(out .. "/h8_handshake.log", "w")
      fh:write(string.format("H8 %s, frames 2-%d; MIPS PC now %08X\n\naddress (shared RAM offset)   count  first frame  last value\n",
         halt and "parked" or "running", last, manager.machine.devices[":maincpu"].state["CURPC"].value))
      for _, k in ipairs(order) do
         local e = log[k]
         fh:write(string.format("%s  %8d  f%-6d  %08X\n", k, e.n, e.first, e.last))
      end
      fh:write("\nfirst accesses in order:\n" .. table.concat(seq, "\n") .. "\n")
      fh:close()
      manager.machine:exit()
   end
end)
