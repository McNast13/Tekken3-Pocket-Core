-- Reference recording of Tekken 3's H8/3002 (sound and inputs) from power-on, for checking the core's H8 against.
-- Run from the repo root (-debug is needed for the instruction trace; -debugger none keeps it headless):
--   H8_OUT=$PWD/out mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 60 \
--        -debug -debugger none -autoboot_script tools/mame/h8_ref.lua
-- Writes to $H8_OUT:
--   h8_trace.log   every H8 instruction of the first H8_TRACE_FRAMES frames (default 30), with ER0-ER7 and CCR before it
--   h8_events.log  the H8's accesses to the outside, in order (the first H8_EVENTS, default 2000000): frame, H8 PC,
--                  read/write, address, value. A read is logged only when it returns a new value for its address (the H8
--                  polls shared RAM in tight loops); h8_summary.log counts them all. C352 0x280000-0x287FFF, shared RAM 0x080000-0x08FFFF, inputs
--                  0x300000-0x300003, and writes to the on-chip registers 0xFFFF00-0xFFFFFF (on-chip reads and the wait-state
--                  writes to 0x300010/0x300030 are only counted in the summary)
--   h8_summary.log per address: reads, writes, first frame, last value; and C352 writes per second
--   h8_ram.bin     for replaying the trace: the H8's RAM at the end of frame 2, where the trace's registers begin
--                  (0x080000-0x08FFFF, 64 KB, then the on-chip RAM 0xFFFD10-0xFFFF0F, 512 bytes)
--   h8_reads.log   for replaying the trace: from that point to the trace's end, every read the H8 makes of what it does
--                  not hold itself (shared RAM 0x080000-0x083FFF, C352, 0x300000-0x30FFFF, on-chip registers
--                  0xFFFF10-0xFFFFFF), in order: H8 PC, address, value, mask. Everything else it reads is ROM or its own RAM
local out = os.getenv("H8_OUT") or "."
local trace_frames = tonumber(os.getenv("H8_TRACE_FRAMES") or "30")
local max_events = tonumber(os.getenv("H8_EVENTS") or "2000000")
local f, nev = 0, 0
local lastread = {}
local replay, dumping, rd = false, false, nil
local taps, stat, order = {}, {}, {}
local c352_sec, c352_n = {}, 0
local ev, cpu, dbg

local function note(rw, a, d, k, quiet)
   if dumping then return end
   if replay and rw == "R" and (a < 0xffff00 or a >= 0xffff10) then
      rd:write(string.format("%06X %06X %08X %08X\n", cpu.state["CURPC"].value, a, d, k))
   end
   local key = string.format("%s %06X", rw, a)
   local s = stat[key]
   if not s then s = { n = 0, first = f }; stat[key] = s; order[#order + 1] = key end
   s.n = s.n + 1; s.last = d
   if quiet then return end
   if rw == "R" then
      if lastread[a] == d then return end
      lastread[a] = d
   end
   if nev < max_events then
      ev:write(string.format("f%-5d pc %06X %s %06X = %08X mask %08X\n", f, cpu.state["CURPC"].value, rw, a, d, k))
      nev = nev + 1
   end
end

local function region(sp, lo, hi, name, reads, quiet, quiet_reads)
   taps[#taps + 1] = sp:install_write_tap(lo, hi, name .. "w", function(o, d, k)
      note("W", o, d, k, quiet)
      if lo == 0x280000 then c352_n = c352_n + 1 end
   end)
   if reads then
      taps[#taps + 1] = sp:install_read_tap(lo, hi, name .. "r", function(o, d, k) note("R", o, d, k, quiet_reads) end)
   end
end

emu.register_frame_done(function()
   f = f + 1
   if f == 1 then
      cpu = manager.machine.devices[":sub"]
      dbg = manager.machine.debugger
      ev = io.open(out .. "/h8_events.log", "w")
      local sp = cpu.spaces["program"]
      region(sp, 0x280000, 0x287fff, "c352", true)
      region(sp, 0x080000, 0x083fff, "shared", true)   -- the part the main CPU sees; above it is the H8's own RAM and stack
      region(sp, 0x300000, 0x300003, "inputs", true)
      region(sp, 0x300010, 0x300011, "ws10", false, true)   -- wait-state writes: counted, not logged one by one
      region(sp, 0x300030, 0x300031, "ws30", false, true)
      region(sp, 0xffff00, 0xffffff, "onchip", true, false, true)   -- on-chip reads (timer counters) only counted
      dbg.visible_cpu = cpu                                -- register names in the trace action are the H8's
      dbg:command(string.format('trace %s/h8_trace.log,:sub,noloop,{tracelog "ER0=%%08X ER1=%%08X ER2=%%08X ER3=%%08X ER4=%%08X ER5=%%08X ER6=%%08X ER7=%%08X CCR=%%02X ",er0,er1,er2,er3,er4,er5,er6,er7,ccr}', out))
   end
   if f <= trace_frames then dbg.visible_cpu = cpu end   -- MAME resets it as the H8 leaves reset; re-assert each frame
   if f == 2 then                                       -- the trace's registers start here: snapshot the H8's RAM
      local sp, b = cpu.spaces["program"], {}
      dumping = true
      for a = 0x080000, 0x08ffff do b[#b + 1] = string.char(sp:read_u8(a)) end
      for a = 0xfffd10, 0xffff0f do b[#b + 1] = string.char(sp:read_u8(a)) end
      dumping = false
      local fh = io.open(out .. "/h8_ram.bin", "wb"); fh:write(table.concat(b)); fh:close()
      rd = io.open(out .. "/h8_reads.log", "w")
      replay = true
   end
   if f == trace_frames + 1 and rd then replay = false; rd:close(); rd = nil end
   if f == trace_frames + 1 then dbg:command("trace off,:sub") end
   if f % 60 == 0 then c352_sec[#c352_sec + 1] = c352_n; c352_n = 0 end
end)

h8_ref_stop = emu.add_machine_stop_notifier(function()   -- global: a local subscription is garbage-collected
   if ev then ev:close() end
   local fh = io.open(out .. "/h8_summary.log", "w")
   fh:write(string.format("%d frames, %d events logged (of the first %d)\n\n", f, nev, max_events))
   table.sort(order)
   for _, k in ipairs(order) do
      local s = stat[k]
      fh:write(string.format("%s  n=%-9d first f%-5d last %08X\n", k, s.n, s.first, s.last))
   end
   fh:write("\nC352 writes per second: " .. table.concat(c352_sec, " ") .. "\n")
   fh:close()
end)
