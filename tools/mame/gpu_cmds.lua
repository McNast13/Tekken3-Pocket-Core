-- Which GPU commands Tekken 3 sends (fit gate: which GPU blocks the core can drop). Run from the repo root:
--   GPU_OUT=$PWD/out mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 300 \
--        -autoboot_script tools/mame/gpu_cmds.lua
-- Parses every GP0 word: CPU writes to 0x1f801810 and DMA channel 2 (linked list: walks the list in RAM when the DMA starts;
-- block mode: the words from MADR). Counts each command opcode, groups them by the core's GPU block (gpu_poly, gpu_line,
-- gpu_rect, gpu_fillVram, gpu_vram2vram, gpu_cpu2vram, gpu_vram2cpu), counts draw attributes (textured, semi-transparent,
-- raw texture, Gouraud) and draw-mode settings (texture depth, blend mode, dither, texture window, mask bits), and writes
-- $GPU_OUT/gpu_cmds.log. A per-second line goes to the console (lines and VRAM reads are the ones to watch).
-- GPU_COIN=frame inserts a coin and presses P1 start from that frame, to get past attract into a real fight (optional).
local out = os.getenv("GPU_OUT") or "."
local f = 0
local taps = {}
local sp
local ops, fe = {}, {}          -- opcode counts; E1-E6 settings seen
local rem, mode, poly_g, a0wh = 0, nil, false, 0
local persec = { line = 0, vram2cpu = 0, poly = 0, rect = 0 }
local words, lists, blocks, nodes, desync = 0, 0, 0, 0, 0

local function cmdlen(op)
  if op >= 0x20 and op <= 0x3f then
    local nv = (op & 0x08) ~= 0 and 4 or 3
    return 1 + nv + (((op & 0x04) ~= 0) and nv or 0) + (((op & 0x10) ~= 0) and (nv - 1) or 0)
  elseif op >= 0x40 and op <= 0x5f then
    return ((op & 0x10) ~= 0) and 4 or 3
  elseif op >= 0x60 and op <= 0x7f then
    return 2 + (((op & 0x04) ~= 0) and 1 or 0) + ((((op >> 3) & 3) == 0) and 1 or 0)
  elseif op == 0x02 or (op >= 0xc0 and op <= 0xdf) then return 3
  elseif op >= 0x80 and op <= 0x9f then return 4
  elseif op >= 0xa0 and op <= 0xbf then return 3
  end
  return 1
end

local function feed(w)
  words = words + 1
  if mode == "poly" then                                     -- polyline: vertices (and colours) until the terminator
    if (w & 0xf000f000) == 0x50005000 then mode = nil end
    return
  elseif mode == "a0hdr" then
    rem = rem - 1
    if rem == 0 then
      local wd, ht = w & 0xffff, w >> 16
      if wd == 0 then wd = 1024 end
      if ht == 0 then ht = 512 end
      rem = (wd * ht + 1) // 2; mode = rem > 0 and "a0data" or nil
    end
    return
  elseif rem > 0 then
    rem = rem - 1
    if rem == 0 then mode = nil end
    return
  end
  local op = w >> 24
  ops[op] = (ops[op] or 0) + 1
  if op >= 0xe1 and op <= 0xe6 then
    local k
    if op == 0xe1 then k = string.format("E1 depth=%d blend=%d dither=%d", (w >> 7) & 3, (w >> 5) & 3, (w >> 9) & 1)
    elseif op == 0xe2 then k = (w & 0xfffff) == 0 and "E2 texture window off" or "E2 texture window ON"
    elseif op == 0xe6 then k = string.format("E6 mask set=%d check=%d", w & 1, (w >> 1) & 1)
    end
    if k then fe[k] = (fe[k] or 0) + 1 end
  end
  if op >= 0x20 and op <= 0x3f then persec.poly = persec.poly + 1
  elseif op >= 0x40 and op <= 0x5f then persec.line = persec.line + 1
  elseif op >= 0x60 and op <= 0x7f then persec.rect = persec.rect + 1
  elseif op >= 0xc0 and op <= 0xdf then persec.vram2cpu = persec.vram2cpu + 1 end
  if op >= 0x48 and op <= 0x4f or op >= 0x58 and op <= 0x5f then
    mode = "poly"; rem = 0
    return
  end
  if op >= 0xa0 and op <= 0xbf then mode = "a0hdr"; rem = 2; return end
  rem = cmdlen(op) - 1
end

local function walk_list(addr)
  local n = 0
  while n < 100000 do
    addr = addr & 0x3ffffc
    local hdr = sp:read_u32(addr)
    local cnt = hdr >> 24
    rem, mode = 0, nil                                       -- each node holds whole commands: resync
    for i = 1, cnt do feed(sp:read_u32(addr + 4 * i)) end
    if rem > 0 or mode then desync = desync + 1; rem, mode = 0, nil end
    nodes = nodes + 1
    n = n + 1
    local nxt = hdr & 0xffffff
    if (nxt & 0x800000) ~= 0 then break end
    addr = nxt
  end
end

emu.register_frame_done(function()
  f = f + 1
  if f == 1 then
    sp = manager.machine.devices[":maincpu"].spaces["program"]
    taps[1] = sp:install_write_tap(0x1f801810, 0x1f801813, "gp0", function(o, v, m) feed(v) end)
    taps[2] = sp:install_write_tap(0x1f8010a8, 0x1f8010ab, "dma2", function(o, v, m)
      if (v & 0x01000000) == 0 or (v & 1) == 0 then return end           -- start bit, RAM -> GPU only
      local madr = sp:read_u32(0x1f8010a0) & 0xffffff
      local sync = (v >> 9) & 3
      if sync == 2 then lists = lists + 1; walk_list(madr)
      elseif sync == 1 or sync == 0 then
        blocks = blocks + 1
        local bcr = sp:read_u32(0x1f8010a4)
        local bs, bc = bcr & 0xffff, bcr >> 16
        if bs == 0 then bs = 0x10000 end
        local n = sync == 1 and bs * math.max(1, bc) or bs
        for i = 0, n - 1 do feed(sp:read_u32((madr + 4 * i) & 0x3ffffc)) end
      end
    end)
  end
  local coin = tonumber(os.getenv("GPU_COIN") or "0")
  if coin > 0 and (f == coin or f == coin + 120) then
    local p = manager.machine.ioport
    for _, port in pairs(p.ports) do
      for name, fld in pairs(port.fields) do
        if (f == coin and name == "Coin 1") or (f == coin + 120 and name == "1 Player Start") then fld:set_value(1) end
      end
    end
  elseif coin > 0 and (f == coin + 6 or f == coin + 126) then
    for _, port in pairs(manager.machine.ioport.ports) do
      for name, fld in pairs(port.fields) do if name == "Coin 1" or name == "1 Player Start" then fld:set_value(0) end end
    end
  end
  if f % 60 == 0 then
    print(string.format("f%d poly=%d rect=%d line=%d vram2cpu=%d", f, persec.poly, persec.rect, persec.line, persec.vram2cpu))
    persec = { line = 0, vram2cpu = 0, poly = 0, rect = 0 }
  end
end)

local function group(op)
  if op >= 0x20 and op <= 0x3f then return "gpu_poly"
  elseif op >= 0x40 and op <= 0x5f then return "gpu_line"
  elseif op >= 0x60 and op <= 0x7f then return "gpu_rect"
  elseif op == 0x02 then return "gpu_fillVram"
  elseif op >= 0x80 and op <= 0x9f then return "gpu_vram2vram"
  elseif op >= 0xa0 and op <= 0xbf then return "gpu_cpu2vram"
  elseif op >= 0xc0 and op <= 0xdf then return "gpu_vram2cpu"
  elseif op >= 0xe1 and op <= 0xe6 then return "draw settings"
  end
  return "other"
end

stop_sub = emu.add_machine_stop_notifier(function()
  local fh = io.open(out .. "/gpu_cmds.log", "w")
  fh:write(string.format("%d frames, %d GP0 words, %d linked-list DMAs (%d nodes, %d ended mid-command), %d block DMAs\n\nopcode  count       block\n",
    f, words, lists, nodes, desync, blocks))
  local keys, tot = {}, {}
  for op, n in pairs(ops) do keys[#keys + 1] = op; tot[group(op)] = (tot[group(op)] or 0) + n end
  table.sort(keys)
  for _, op in ipairs(keys) do fh:write(string.format("%02X  %10d   %s\n", op, ops[op], group(op))) end
  fh:write("\nper block:\n")
  for _, g in ipairs({ "gpu_poly", "gpu_line", "gpu_rect", "gpu_fillVram", "gpu_vram2vram", "gpu_cpu2vram", "gpu_vram2cpu",
                       "draw settings", "other" }) do
    fh:write(string.format("  %-14s %d\n", g, tot[g] or 0))
  end
  fh:write("\ndraw settings seen:\n")
  local ks = {}
  for k in pairs(fe) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do fh:write(string.format("  %-36s %d\n", k, fe[k])) end
  fh:close()
end)
