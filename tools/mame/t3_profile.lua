-- Tekken 3 profile (docs/PLAN.md step 2). Run from the repo root:
--   T3_OUT=$PWD/out T3_TRACE=1800 mame tekken3 -rompath roms -video none -sound none -nothrottle -debug -debugger none \
--        -seconds_to_run 120 -autoboot_script tools/mame/t3_profile.lua
-- Logs once a second: MDEC register accesses (0x1f801820-0x1f801827), MDEC DMA starts (channels 0/1 CHCR with the start bit;
-- games feed MDEC by DMA), bank-select writes (0x1f000000), CPU reads of the bank window,
-- ROM DMA offset writes (0x1f700000-0x1f70ffff) and ROM -> RAM DMA (channel 5) starts and KB moved.
-- T3_SHOT=n saves a snapshot every n frames (needs -snapshot_directory).
-- Traces the main CPU for 3 frames from frame T3_TRACE into $T3_OUT/trace.log (find the vsync wait loop with
-- tools/hot_pcs.sh).
local f = 0
local out = os.getenv("T3_OUT") or "."
local tf = tonumber(os.getenv("T3_TRACE") or "0")
local taps = {}
local mdec, mdma, bank, banks, dmao = 0, 0, 0, {}, 0
local rdma, rwords, bankr = 0, 0, 0
local shot = tonumber(os.getenv("T3_SHOT") or "0")
emu.register_frame_done(function()
  f = f + 1
  local d = manager.machine.debugger
  if f == 1 then
    local sp = manager.machine.devices[":maincpu"].spaces["program"]
    taps[1] = sp:install_read_tap(0x1f801820, 0x1f801827, "mdec_r", function(o, v, m) mdec = mdec + 1 end)
    taps[2] = sp:install_write_tap(0x1f801820, 0x1f801827, "mdec_w", function(o, v, m) mdec = mdec + 1 end)
    taps[4] = sp:install_write_tap(0x1f801080, 0x1f80109f, "mdec_dma", function(o, v, m)
      if (o & 0xf) == 0x8 and (v & 0x01000000) ~= 0 then mdma = mdma + 1 end end)
    taps[5] = sp:install_write_tap(0x1f700000, 0x1f70ffff, "dmaoff_w", function(o, v, m) dmao = dmao + 1 end)
    -- ROM -> RAM DMA (channel 5, MAME namcos12_rom_read): count starts and words moved
    taps[6] = sp:install_write_tap(0x1f8010d8, 0x1f8010db, "dma5", function(o, v, m)
      if (v & 0x01000000) ~= 0 then
        local bcr = sp:read_u32(0x1f8010d4)
        rdma = rdma + 1; rwords = rwords + (bcr & 0xffff) * math.max(1, bcr >> 16)
      end end)
    taps[7] = sp:install_read_tap(0x1fa00000, 0x1fbfffff, "bankr", function(o, v, m) bankr = bankr + 1 end)
    taps[3] = sp:install_write_tap(0x1f000000, 0x1f000003, "bank_w", function(o, v, m)
      bank = bank + 1; banks[v & 0xffff] = (banks[v & 0xffff] or 0) + 1 end)
    if d then d:command("focus maincpu"); d:command("go") end
  end
  if d and tf > 0 and f == tf then d:command("trace " .. out .. "/trace.log,maincpu,noloop"); d:command("go") end
  if d and tf > 0 and f == tf + 3 then d:command("trace off") end
  if f % 60 == 0 then
    local b = {}
    for k, n in pairs(banks) do b[#b + 1] = string.format("%04X:%d", k, n) end
    print(string.format("f%d mdec=%d mdec_dma=%d bankw=%d %s bankr=%d dmaoffw=%d romdma=%d romKB=%d", f, mdec, mdma, bank,
      table.concat(b, " "), bankr, dmao, rdma, rwords * 4 // 1024))
    mdec, mdma, bank, banks, dmao, rdma, rwords, bankr = 0, 0, 0, {}, 0, 0, 0, 0
  end
  if shot > 0 and f % shot == 0 then manager.machine.video:snapshot()
  end
end)
