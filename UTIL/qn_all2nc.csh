#! /bin/csh -fe

set dirname = /pscratch/sd/q/qnicolas/SAMdata
set simname = RCE_128x128x64_ref_rce
set simsuffix = _128
set N1 = 360
set N2 = 4320
set NN = 360

# 2Dcom
set f = $dirname/OUT_2D/$simname$simsuffix.2Dcom
./2Dcom2nc  $f

# stat
set f = $dirname/OUT_STAT/$simname.stat
./qn_stat2nc  $f

# com3D
set filename = $dirname/OUT_3D/$simname$simsuffix"_00000"

while ($N1 <= $N2)

 echo $N1
 set M = ""
 if($N1 < 10) then
  set M = "0000"
 else if($N1 < 100) then
  set M = "000"
 else if($N1 < 1000) then
  set M = "00"
 else if($N1 < 10000) then
  set M = "0"
 endif

echo $M

set f = $filename$M$N1.com3D

./com3D2nc  $f

@ N1 = $N1 + $NN

end


