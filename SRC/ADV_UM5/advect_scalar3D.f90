subroutine advect_scalar3D( f, u, v, w, rho, rhow, flux )

! Three dimensional 5th order ULTIMATE-MACHO scheme

	use grid
	use advect_um_lib
	use params, only: dowallx, dowally
	implicit none
	
	! input & output
	real, dimension(dimx1_s:dimx2_s, dimy1_s:dimy2_s, nzm), intent(inout) :: f
	real, dimension(dimx1_u:dimx2_u, dimy1_u:dimy2_u, nzm), intent(inout) :: u
	real, dimension(dimx1_v:dimx2_v, dimy1_v:dimy2_v, nzm), intent(inout) :: v
	real, dimension(dimx1_w:dimx2_w, dimy1_w:dimy2_w, nz ), intent(in) :: w
	real, dimension(nzm), intent(in) :: rho
	real, dimension(nz), intent(in) :: rhow
	real, dimension(nz), intent(out) :: flux
	
	! local
	integer :: macho_order, i, j, k
	
	! Convert mass-weighted courant number to non-mass weighted
	! Inverse of rho, adz
!@ TAK 2014/05: This does not work with ncycle_max > 4
!@	if ( ( nstep > nstep_adv ).and.( .not.updated_cn(icycle) ) ) then
!@		!!if (masterproc) print*,'cn updated'
!@		updated_cn(icycle) = .true. ! skip for same icycle if updated
!@		if (icycle == ncycle) then ! skip at ncycle if updated
!@			nstep_adv = nstep
!@			updated_cn(:) = .false.
!@		endif
		
	if ( ( nstep > nstep_adv ).and.( icycle > icycle_adv ) ) then
		
		! TAK 2014/05: Adjustment for ncycle_max
		!!if (masterproc) print*,'cn updated', icycle
		icycle_adv = icycle ! skip for same icycle
		if (icycle == ncycle) then
			nstep_adv = nstep ! skip for ncycle
			icycle_adv = 0 ! prepare for icycle=1 in nstep+1
		endif
		
		! Inverse of rho, adz, adzw
		do k = 1, nzm
			irho(k)  = 1. / rho(k)
			iadz(k)  = 1. / adz(k)
			iadzw(k) = 1. / adzw(k)
		enddo
		
		! x direction
		do k = 1, nzm
			do j = -3, nyp4
				do i = -1, nxp3
					cu(i,j,k) = u(i,j,k) * irho(k)
				enddo
			enddo
		enddo
		
		! y direction
		do k = 1, nzm
			do j = -1, nyp3
				do i = -3, nxp4
					cv(i,j,k) = v(i,j,k) * irho(k)
				enddo
			enddo
		enddo
		
		! z direction
		cw(:,:,nz) = 0. ! non-mass weighted and adz adjusted
		cw(:,:,1) = 0.
		do k = 2, nzm
			irhow(k) = 1. / ( rhow(k) * adz(k) ) ! adz adjustment here
			do j = -3, nyp4
				do i = -3, nxp4
					cw(i,j,k) = w(i,j,k) * irhow(k)
				enddo
			enddo
		enddo
	endif
	
	! Top and bottom boundaries for fz
	fz(:,:,nz) = 0.
	fz(:,:,1) = 0.
	
	! Face values
	fadv(:,:,:) = f(:,:,:)
	macho_order = mod(nstep-1,6)
	
	! macho_order and operating sequence
	! operating sequence is constructed
	! 1) x => y then y => x for next macho_order so x and y operation is 2D macho if w = 0
	! 2) rotate x, y, and z for the first advective-form update
	! MO : Operating sequence
	! 0  : z => x => y
	! 1  : y => z => x
	! 2  : x => y => z
	! 3  : z => y => x
	! 4  : x => z => y
	! 5  : y => x => z
	
	select case (macho_order)
	case(0) ! z => x => y
		
		! z-direction
		call face_z_5th( -3, nxp4, -3, nyp4 )
		call adv_form_update_z( -3, nxp4, -3, nyp4 )
		! x-direction
		call face_x_5th( 0, nxp2, -3, nyp4 )
		call adv_form_update_x( 0, nxp1, -3, nyp4 )
		! y direction
		call face_y_5th( 0, nxp1, 0, nyp2 )
		
	case(1) ! y => z => x
		
		! y-directioin
		call face_y_5th( -3, nxp4, 0, nyp2 )
		call adv_form_update_y( -3, nxp4, 0, nyp1 )
		! z-direction
		call face_z_5th( -3, nxp4, 0, nyp1 )
		call adv_form_update_z( -3, nxp4, 0, nyp1 )
		! x direction
		call face_x_5th( 0, nxp2, 0, nyp1 )
		
	case(2) ! x => y => z
		
		! x-direction
		call face_x_5th( 0, nxp2, -3, nyp4 )
		call adv_form_update_x( 0, nxp1, -3, nyp4 )
		! y-direction
		call face_y_5th( 0, nxp1, 0, nyp2 )
		call adv_form_update_y( 0, nxp1, 0, nyp1 )
		! z-direction
		call face_z_5th( 0, nxp1, 0, nyp1 )
		
	case(3) ! z => y => x
		
		! z-direction
		call face_z_5th( -3, nxp4, -3, nyp4 )
		call adv_form_update_z( -3, nxp4, -3, nyp4 )
		! y-direction
		call face_y_5th( -3, nxp4, 0, nyp2 )
		call adv_form_update_y( -3, nxp4, 0, nyp1 )
		! x direction
		call face_x_5th( 0, nxp2, 0, nyp1 )
		
	case(4) ! x => z => y
		
		! x-direction
		call face_x_5th( 0, nxp2, -3, nyp4 )
		call adv_form_update_x( 0, nxp1, -3, nyp4 )
		! z-direction
		call face_z_5th( 0, nxp1, -3, nyp4 )
		call adv_form_update_z( 0, nxp1, -3, nyp4 )
		! y direction
		call face_y_5th( 0, nxp1, 0, nyp2 )
		
	case(5) ! y => x => z
		
		! y-directioin
		call face_y_5th( -3, nxp4, 0, nyp2 )
		call adv_form_update_y( -3, nxp4, 0, nyp1 )
		! x-direction
		call face_x_5th( 0, nxp2, 0, nyp1 )
		call adv_form_update_x( 0, nxp1, 0, nyp1 )
		! z-direction
		call face_z_5th( 0, nxp1, 0, nyp1 )
		
	end select
	
	! FCT to ensure positive definite or monotonicity
	if (fct) then
		call fct3D( f, u, v, w, flux )
	else
		! In case...
		!fz(:,:,nz) = 0.
		!fz(:,:,1) = 0.
		
		! Flux-form update
		flux = 0.
		do k = 1, nzm
			do j = 1, ny
				do i = 1, nx
					f(i,j,k) = max(0.,f(i,j,k) &
						+ ( u(i,j,k) * fx(i,j,k) - u(i+1,j,k) * fx(i+1,j,k) &
						+   v(i,j,k) * fy(i,j,k) - v(i,j+1,k) * fy(i,j+1,k) &
						+ ( w(i,j,k) * fz(i,j,k) - w(i,j,k+1) * fz(i,j,k+1) ) * iadz(k) ) * irho(k))
					flux(k) = flux(k) + w(i,j,k) * fz(i,j,k)
				enddo
			enddo
		enddo
	endif
	
end subroutine advect_scalar3D
