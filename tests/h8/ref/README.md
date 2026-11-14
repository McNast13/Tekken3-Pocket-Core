MAME reference recordings of Tekken 3's H8/3002 (made by tools/mame/h8_ref.lua). Not in git: they are derived from the
ROMs. Regenerate with:

    H8_OUT=$PWD/tests/h8/ref mame tekken3 -rompath roms -video none -sound none -nothrottle -seconds_to_run 60 \
         -debug -debugger none -autoboot_script tools/mame/h8_ref.lua
    gzip tests/h8/ref/*.log
