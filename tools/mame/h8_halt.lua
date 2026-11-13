-- Does Tekken 3 run without its H8? Stops the H8/3002 (sound and inputs) from running any of its program, then hands over
-- to gpu_cmds.lua (same env: GPU_OUT, GPU_SNAP, GPU_INPUTS) to see how far the main CPU gets. Run from the repo root:
--   GPU_OUT=$PWD/out GPU_SNAP=600 mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 200 \
--        -autoboot_script tools/mame/h8_halt.lua
-- How: the H8's reset vector is pointed at 0x7FFF0 (unused, 0xFF, at the top of its 512 KB ROM), where "bra ." (40 FE)
-- loops forever; then a soft reset restarts the whole board with the H8 parked there (the ROM region keeps the patch). H8_HALT=0 leaves the H8 alone
-- (same script, for an A/B run). Every 600 frames the H8 PC and main CPU PC are printed.
-- H8_FAKE=1 stands in for the parked H8's handshakes: when the main CPU writes 0x3163 to shared RAM 0x3002, the
-- reply 0x7601 is written back the next frame, and 0x30F0, 0x306A, 0x3078 (command flags) are cleared every frame, as the
-- real H8 does (tools/mame/h8_handshake.lua).
local halt = os.getenv("H8_HALT") ~= "0"
local fake = os.getenv("H8_FAKE") == "1"
local f = 0
local reply_at, fake_tap
emu.register_frame_done(function()
   f = f + 1
   local m = manager.machine.devices[":maincpu"].spaces["program"]
   if fake and not fake_tap then
      fake_tap = m:install_write_tap(0x1f083000, 0x1f083003, "h8fake", function(o, d, k)
         if (k & 0xffff0000) ~= 0 and (d >> 16) == 0x3163 then reply_at = f + 1 end
      end)
   end
   if reply_at and f >= reply_at then
      reply_at = nil
      m:write_u16(0x1f083002, 0x7601)
      print(string.format("f%d fake H8: 0x3002 <- 7601", f))
   end
   if fake then                                         -- acknowledge commands: the H8 clears these once it has read them
      for _, a in ipairs({ 0x1f0830f0, 0x1f08306a, 0x1f083078 }) do
         if m:read_u16(a) ~= 0 then m:write_u16(a, 0) end
      end
   end
   local r = manager.machine.memory.regions[":sub"]
   if f == 1 and halt and r:read_u8(0x7fff0) ~= 0x40 then   -- the script runs again after the reset: patch only once
      r:write_u8(0x7fff0, 0x40); r:write_u8(0x7fff1, 0xfe)              -- bra .
      r:write_u8(0, 0x00); r:write_u8(1, 0x07); r:write_u8(2, 0xff); r:write_u8(3, 0xf0)
      print(string.format("H8 reset vector now %08X", r:read_u32(0)))
      manager.machine:soft_reset()
   end
   if f % 600 == 0 then
      local d = manager.machine.devices
      print(string.format("f%d H8 PC %06X  MIPS PC %08X", f, d[":sub"].state["CURPC"].value, d[":maincpu"].state["CURPC"].value))
   end
end)
dofile("tools/mame/gpu_cmds.lua")
