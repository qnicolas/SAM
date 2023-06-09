
subroutine coriolis

use vars
use params, only: docoriolisz

implicit none
	
real u_av, v_av, w_av
integer i,j,k,ib,ic,jb,jc,kc
! NCT
real u_av_on_w
integer kb
! Hing Ong, 23 Aug 2020
	
if(RUN3D) then

do k=1,nzm
 kc=k+1
 do j=1,ny
  jb=j-1
  jc=j+1
  do i=1,nx
   ib=i-1
   ic=i+1
    v_av=0.25*(v(i,j,k)+v(i,jc,k)+v(ib,j,k)+v(ib,jc,k))
    w_av=0.25*(w(i,j,kc)+w(ib,j,kc)+w(i,j,k)+w(ib,j,k))
    dudt(i,j,k,na)=dudt(i,j,k,na)+fcory(j)*(v_av-vg0(k))-fcorzy(j)*w_av
    u_av=0.25*(u(i,j,k)+u(ic,j,k)+u(i,jb,k)+u(ic,jb,k))
    dvdt(i,j,k,na)=dvdt(i,j,k,na)-0.5*(fcory(j)+fcory(jb))*(u_av-ug0(k))
  end do ! i
 end do ! j
end do ! k

! NCT
 ! Hing Ong, 23 Aug 2020
if(docoriolisz) then
 do k=2,nzm
  kb=k-1
  do j=1,ny
   do i=1,nx
    ic=i+1
     u_av_on_w=0.25*(u(i,j,k)+u(ic,j,k)+u(i,j,kb)+u(ic,j,kb))
     dwdt(i,j,k,na)=dwdt(i,j,k,na)+fcorzy(j)*u_av_on_w
   end do ! i
  end do ! j
 end do ! k
end if

else

do k=1,nzm
 kc=k+1
 do j=1,ny
  do i=1,nx
   ib=i-1
   ic=i+1
   w_av=0.25*(w(i,j,kc)+w(ib,j,kc)+w(i,j,k)+w(ib,j,k))
   dudt(i,j,k,na)=dudt(i,j,k,na)+fcory(j)*(v(i,j,k)-vg0(k))-fcorzy(j)*w_av
   dvdt(i,j,k,na)=dvdt(i,j,k,na)-fcory(j)*(u(i,j,k)-ug0(k))
  end do ! i
 end do ! i
end do ! k

! NCT
! Hing Ong, 23 Aug 2020
if(docoriolisz) then
 do k=2,nzm
  kb=k-1
  do j=1,ny
   do i=1,nx
    ic=i+1
     u_av_on_w=0.25*(u(i,j,k)+u(ic,j,k)+u(i,j,kb)+u(ic,j,kb))
     dwdt(i,j,k,na)=dwdt(i,j,k,na)+fcorzy(j)*u_av_on_w
   end do ! i
  end do ! j
 end do ! k
end if

endif
	
!bloss: accumulate coriolis accelerations for statistics
if(dostatis) then

   utendcor(:) = 0.
   vtendcor(:) = 0.

   if(RUN3D) then

      do k=1,nzm
         kc=k+1
         do j=1,ny
            jb=j-1
            jc=j+1
            do i=1,nx
               ib=i-1
               ic=i+1
               v_av=0.25*(v(i,j,k)+v(i,jc,k)+v(ib,j,k)+v(ib,jc,k))
               w_av=0.25*(w(i,j,kc)+w(ib,j,kc)+w(i,j,k)+w(ib,j,k))
               utendcor(k)=utendcor(k)+fcory(j)*(v_av-vg0(k))-fcorzy(j)*w_av
               u_av=0.25*(u(i,j,k)+u(ic,j,k)+u(i,jb,k)+u(ic,jb,k))
               vtendcor(k)=vtendcor(k)-0.5*(fcory(j)+fcory(jb))*(u_av-ug0(k))
            end do ! i
         end do ! j
      end do ! k

   else


      do k=1,nzm
         kc=k+1
         do j=1,ny
            do i=1,nx
               ib=i-1
               ic=i+1
               w_av=0.25*(w(i,j,kc)+w(ib,j,kc)+w(i,j,k)+w(ib,j,k))
               utendcor(k)=utendcor(k)+fcory(j)*(v(i,j,k)-vg0(k))-fcorzy(j)*w_av
               vtendcor(k)=vtendcor(k)-fcory(j)*(u(i,j,k)-ug0(k))
            end do ! i
         end do ! i
      end do ! k

   endif !if(RUN3D)

end if !if(dostatis)

end subroutine coriolis

