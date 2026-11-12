-- Traces the H8/3002 (sound/IO CPU) for H8_FRAMES frames from frame H8_TRACE into $H8_OUT/h8_trace.log, to count which
-- instructions Tekken 3's sound program runs (docs/STUDY.md). Run from the repo root:
--   H8_OUT=$PWD/out H8_TRACE=4900 H8_FRAMES=30 mame tekken3 -rompath roms -video none -sound none -nothrottle -debug \
--        -debugger none -seconds_to_run 90 -autoboot_script tools/mame/h8_trace.lua
local f = 0
local out = os.getenv("H8_OUT") or "."
local tf = tonumber(os.getenv("H8_TRACE") or "4900")
local n = tonumber(os.getenv("H8_FRAMES") or "30")
emu.register_frame_done(function()
  f = f + 1
  local d = manager.machine.debugger
  if f == 1 then d:command("go") end
  if f == tf then d:command("trace " .. out .. "/h8_trace.log,sub,noloop"); d:command("go") end
  if f == tf + n then d:command("trace off,sub"); d:command("go") end
end)
