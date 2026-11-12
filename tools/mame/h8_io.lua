-- Which H8/3002 on-chip peripherals Tekken 3's sound/IO program uses (docs/STUDY.md). Run from the repo root:
--   H8_OUT=$PWD/out mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 170 \
--        -autoboot_script tools/mame/h8_io.lua
-- Counts the H8's reads and writes of each on-chip register (0xffff20-0xffffff), of the C352, the RAM shared with the
-- MIPS and the JAMMA inputs, and writes $H8_OUT/h8_io.log (one line per register touched, then the totals per block).
local out = os.getenv("H8_OUT") or "."
local f = 0
local taps = {}
local rd, wr, wv = {}, {}, {}
local ext = { c352 = 0, shram = 0, inputs = 0 }
local shpage = {}   -- 1 KB pages of the shared RAM the H8 touches
local blocks = {
  { 0xff20, 0xff3f, "DMA controller" }, { 0xff60, 0xff9f, "ITU (16-bit timers)" }, { 0xffa8, 0xffab, "watchdog" },
  { 0xffad, 0xffaf, "refresh controller" }, { 0xffb0, 0xffb5, "SCI0 (JVS)" }, { 0xffb8, 0xffbd, "SCI1 (RTC, settings)" },
  { 0xffc0, 0xffdf, "I/O ports" }, { 0xffe0, 0xffe9, "A/D converter" }, { 0xffea, 0xffff, "system, interrupt controller" },
}
local function block(a)
  for _, b in ipairs(blocks) do if a >= b[1] and a <= b[2] then return b[3] end end
  return "other"
end
local function count(t, o, m)
  -- one count per byte lane the access touches (the H8's bus is 16 bits)
  local a = o & 0xfffe
  if (m & 0xff00) ~= 0 then t[a] = (t[a] or 0) + 1 end
  if (m & 0x00ff) ~= 0 then t[a + 1] = (t[a + 1] or 0) + 1 end
end
emu.register_frame_done(function()
  f = f + 1
  if f == 1 then
    local sp = manager.machine.devices[":sub"].spaces["program"]
    taps[1] = sp:install_read_tap(0xffff20, 0xffffff, "h8io_r", function(o, v, m) count(rd, o, m) end)
    taps[2] = sp:install_write_tap(0xffff20, 0xffffff, "h8io_w", function(o, v, m)
      count(wr, o, m); local a = o & 0xfffe
      if (m & 0xff00) ~= 0 then wv[a] = (v >> 8) & 0xff end
      if (m & 0x00ff) ~= 0 then wv[a + 1] = v & 0xff end end)
    taps[3] = sp:install_read_tap(0x280000, 0x287fff, "c352_r", function() ext.c352 = ext.c352 + 1 end)
    taps[4] = sp:install_write_tap(0x280000, 0x287fff, "c352_w", function() ext.c352 = ext.c352 + 1 end)
    taps[5] = sp:install_read_tap(0x080000, 0x08ffff, "sh_r", function(o) ext.shram = ext.shram + 1; shpage[(o - 0x080000) >> 10] = true end)
    taps[6] = sp:install_write_tap(0x080000, 0x08ffff, "sh_w", function(o) ext.shram = ext.shram + 1; shpage[(o - 0x080000) >> 10] = true end)
    taps[7] = sp:install_read_tap(0x300000, 0x300003, "in_r", function() ext.inputs = ext.inputs + 1 end)
  end
end)
stop_sub = emu.add_machine_stop_notifier(function()
  local fh = io.open(out .. "/h8_io.log", "w")
  local addrs, seen, tot = {}, {}, {}
  for a in pairs(rd) do seen[a] = true end
  for a in pairs(wr) do seen[a] = true end
  for a in pairs(seen) do addrs[#addrs + 1] = a end
  table.sort(addrs)
  fh:write(string.format("%d frames\naddr    block                          reads    writes  last write\n", f))
  for _, a in ipairs(addrs) do
    local b = block(a)
    fh:write(string.format("ff%04x  %-28s %8d  %8d  %s\n", a, b, rd[a] or 0, wr[a] or 0,
      wv[a] and string.format("%02x", wv[a]) or "-"))
    tot[b] = (tot[b] or 0) + (rd[a] or 0) + (wr[a] or 0)
  end
  fh:write("\nper block (accesses):\n")
  for _, b in ipairs(blocks) do fh:write(string.format("  %-30s %d\n", b[3], tot[b[3]] or 0)) end
  fh:write(string.format("\nC352 %d, shared RAM %d, JAMMA inputs %d\n", ext.c352, ext.shram, ext.inputs))
  local pages = {}
  for p in pairs(shpage) do pages[#pages + 1] = p end
  table.sort(pages)
  fh:write(string.format("shared RAM: %d of 64 1 KB pages touched, highest page %d\n", #pages, pages[#pages] or -1))
  fh:close()
end)
