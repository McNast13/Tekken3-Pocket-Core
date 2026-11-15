MAME reference recordings of Tekken 3's H8/3002. Not in git: they are derived from the ROMs. Regenerate with:

    H8_OUT=$PWD/tests/h8/ref mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 60 \
         -debug -debugger none -autoboot_script tools/mame/h8_ref.lua
    gzip tests/h8/ref/h8_*.log
    python3 tests/h8/make_replay.py

For the system test (tests/h8/sys): first an initialised NVRAM (one 40 s run, so the boot is the normal one with the
attract music at about 10 s), then the recording from a copy of it:

    mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 40 -cfg_directory /tmp/t3cfg \
         -nvram_directory tests/h8/ref/nvram
    cp -R tests/h8/ref/nvram /tmp/t3nv
    H8_OUT=$PWD/tests/h8/ref mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 16 \
         -cfg_directory /tmp/t3cfg -nvram_directory /tmp/t3nv -autoboot_script tools/mame/h8_shared.lua

(main_shared.log, c352.log, c352_reads.log; tests/h8/sys/run.sh makes c352_ends.log from the last.)
