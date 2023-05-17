#! /bin/csh -fe

set dirname = /pscratch/sd/q/qnicolas/SAMdata
set simname = MOUNTAINWAVE_128x128x64_mtnwave_k1e-4_h50_U10_real
#RCE_128x128x64_ref_rce
set simsuffix = _128

# 2Dcom
set f = $dirname/OUT_2D/$simname$simsuffix.2Dcom
./2Dcom2nc  $f

# stat
set f = $dirname/OUT_STAT/$simname.stat
./qn_stat2nc  $f

