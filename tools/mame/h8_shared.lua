-- Main CPU writes to the shared RAM (0x1F080000-0x1F083FFF, the H8's 0x080000-0x083FFF), by frame, for the H8 system
-- test (tests/h8/sys): the testbench plays them back at the same frames while the core's H8 runs the sound program.
-- Run from the repo root:
--   H8_OUT=$PWD/tests/h8/ref mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 16 \
--        -cfg_directory <scratch> -nvram_directory <scratch> -autoboot_script tools/mame/h8_shared.lua
-- Writes $H8_OUT/main_shared.log: frame, H8 address (word), value, byte mask (FF00 even byte, 00FF odd, FFFF word);
-- and, from the same run, $H8_OUT/c352.log: the H8's C352 writes (frame, address, value, mask), what the test compares;
-- $H8_OUT/c352_reads.log: what the H8 reads from the C352 (voice flags), each time it differs from the last read of
-- that address (frame, address, value), for the testbench to answer reads with.
-- H8_COIN=frame: insert a coin then, press P1 start 2 s later and from 5 s later keep pressing P1's buttons and
-- left / right (a coin-up fight, for the sound effects).
local out = os.getenv("H8_OUT") or "."
local fh = io.open(out .. "/main_shared.log", "w")
local ch = io.open(out .. "/c352.log", "w")
local cr = io.open(out .. "/c352_reads.log", "w")
local last = {}
local f = 0
local sp = manager.machine.devices[":maincpu"].spaces["program"]

local coin = tonumber(os.getenv("H8_COIN") or "0")
local fields = {}
for _, port in pairs(manager.machine.ioport.ports) do
   for name, fld in pairs(port.fields) do fields[name] = fld end
end
local mash = {"P1 Button 1", "P1 Button 2", "P1 Button 3", "P1 Button 4", "P1 Right", "P1 Left"}
local function set(n, v) if fields[n] then fields[n]:set_value(v) end end

emu.register_frame_done(function()
   f = f + 1
   if coin > 0 then
      set("Coin 1", (f >= coin and f < coin + 6) and 1 or 0)
      local st = (f >= coin + 120 and f < coin + 126) or (f >= coin + 300 and f % 240 < 4)
      set("1 Player Start", st and 1 or 0)
      if f >= coin + 300 then
         local k = (f // 8) % #mash + 1
         for i, n in ipairs(mash) do set(n, (i == k and f % 8 < 4) and 1 or 0) end
      end
   end
end)

h8_shared_tap = sp:install_write_tap(0x1f080000, 0x1f083fff, "main_shared", function(offset, data, mask)
   -- the main CPU's bus is 32-bit little-endian: each 16-bit half is one H8 word (same byte address)
   for lane = 0, 1 do
      local m = (mask >> (16 * lane)) & 0xffff
      if m ~= 0 then
         local v = (data >> (16 * lane)) & 0xffff
         local hm = ((m & 0x00ff) ~= 0 and 0x00ff or 0) | ((m & 0xff00) ~= 0 and 0xff00 or 0)
         fh:write(string.format("%d %06X %04X %04X\n", f, 0x080000 + (offset & 0x3ffc) + 2 * lane, v, hm))
      end
   end
   return data
end)

h8_c352_tap = manager.machine.devices[":sub"].spaces["program"]:install_write_tap(0x280000, 0x287fff, "c352",
   function(offset, data, mask)
      ch:write(string.format("%d %06X %04X %04X\n", f, offset, data & 0xffff, mask & 0xffff))
      return data
   end)

h8_c352_rtap = manager.machine.devices[":sub"].spaces["program"]:install_read_tap(0x280000, 0x287fff, "c352r",
   function(offset, data, mask)
      local v = data & 0xffff
      if last[offset] ~= v then
         last[offset] = v
         cr:write(string.format("%d %06X %04X\n", f, offset, v))
      end
      return data
   end)

h8_shared_stop = emu.add_machine_stop_notifier(function() fh:close(); ch:close(); cr:close() end)
