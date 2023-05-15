!bloss #include <misc.h>
!bloss #include <params.h>

subroutine radcswmx(lchnk   ,ncol    ,                            &
                    E_pint    ,E_pmid    ,E_h2ommr  ,E_rh      ,E_o3mmr   , &
                    E_aermmr  ,E_cld     ,E_cicewp  ,E_cliqwp  ,E_csnowp  ,E_rel     , &
                    E_rei     ,E_res     ,eccf_in   ,E_coszrs  ,scon_in    ,solin   , &
                    E_asdir   ,E_asdif   ,E_aldir   ,E_aldif   ,nmxrgn  , &
                    pmxrgn  ,qrs     ,fsnt    ,fsntc   ,fsntoa  , &
                    fsntoac ,fsnirtoa,fsnrtoac,fsnrtoaq,fsns    , &
                    fsnsc   ,fsdsc   ,fsds    ,sols    ,soll    , &
                    solsd   ,solld   ,frc_day ,                   &
                    aertau  ,aerssa  ,aerasm  ,aerfwd  ,fns     , &
                    fcns    ,fsu     ,fsd     )
!-----------------------------------------------------------------------
! 
! Purpose: 
! Solar radiation code
! 
! Method: 
! Basic method is Delta-Eddington as described in:
! 
! Briegleb, Bruce P., 1992: Delta-Eddington
! Approximation for Solar Radiation in the NCAR Community Climate Model,
! Journal of Geophysical Research, Vol 97, D7, pp7603-7612).
! 
! Five changes to the basic method described above are:
! (1) addition of sulfate aerosols (Kiehl and Briegleb, 1993)
! (2) the distinction between liquid and ice particle clouds 
! (Kiehl et al, 1996);
! (3) provision for calculating TOA fluxes with spectral response to
! match Nimbus-7 visible/near-IR radiometers (Collins, 1998);
! (4) max-random overlap (Collins, 2001)
! (5) The near-IR absorption by H2O was updated in 2003 by Collins, 
!     Lee-Taylor, and Edwards for consistency with the new line data in
!     Hitran 2000 and the H2O continuum version CKD 2.4.  Modifications
!     were optimized by reducing RMS errors in heating rates relative
!     to a series of benchmark calculations for the 5 standard AFGL 
!     atmospheres.  The benchmarks were performed using DISORT2 combined
!     with GENLN3.  The near-IR scattering optical depths for Rayleigh
!     scattering were also adjusted, as well as the correction for
!     stratospheric heating by H2O.
!
! The treatment of maximum-random overlap is described in the
! comment block "INDEX CALCULATIONS FOR MAX OVERLAP".
! 
! Divides solar spectrum into 19 intervals from 0.2-5.0 micro-meters.
! solar flux fractions specified for each interval. allows for
! seasonally and diurnally varying solar input.  Includes molecular,
! cloud, aerosol, and surface scattering, along with h2o,o3,co2,o2,cloud, 
! and surface absorption. Computes delta-eddington reflections and
! transmissions assuming homogeneously mixed layers. Adds the layers 
! assuming scattering between layers to be isotropic, and distinguishes 
! direct solar beam from scattered radiation.
! 
! Longitude loops are broken into 1 or 2 sections, so that only daylight
! (i.e. coszrs > 0) computations are done.
! 
! Note that an extra layer above the model top layer is added.
! 
! cgs units are used.
! 
! Special diagnostic calculation of the clear sky surface and total column
! absorbed flux is also done for cloud forcing diagnostics.
! 
!-----------------------------------------------------------------------
!
! D. Parks (NEC) 09/11/03
! Restructuring of routine to support SX vector architecture.
!
! Possible improvements:
!
! 1. Look at vectorizing index calculations for maximum overlap.
!
! 2. Consider making innermost loop in flux computations the number
!    of spectral intervals.  Given that NS is fixed at 19, the trade-off
!    will be stride one memory accesses of length 19 versus indirect
!    addressing (list vector - gather/scatter) with potential vector
!    lenghts of the number of day light points.  Vectorizing on the number
!    of spectral intervals seems worthwhile for low resolution models (T42),
!    but might be inefficient with higher resolutions.
!
! 3. Move the linearization of daylight points (compression/expansion) out
!    of radcswmx and into d_p_coupling.  This would eliminate the cost of
!    routines CmpDayNite and ExpDayNite.
!
! 4. Look at expliciting computing all streams in upward propagation of
!    radiation. There would be additional floating point operations in
!    exchange for the elimination of indirect addressing.
!
! P. Blossey (UW) 2016-02-08
! Added snow water path and snow effective radius as input arguments.
! Ice optical properties are combined between cloud ice and snow, using
! weighted averages (e.g., the optical-depth-weighted single scattering
! albedo).
!-----------------------------------------------------------------------
   use shr_kind_mod, only: r4 => shr_kind_r4
   use ppgrid
!bloss   use ghg_surfvals, only: ghg_surfvals_get_co2mmr
!bloss   use prescribed_aerosols, only: idxBG, idxSUL, idxSSLT, idxOCPHO, idxBCPHO, idxOCPHI, idxBCPHI, &
!bloss     idxDUSTfirst, numDUST, idxVOLC, naer_all
   use aer_optics, only: nrh, ndstsz, ksul, wsul, gsul, &
     ksslt, wsslt, gsslt, kcphil, wcphil, gcphil, kcphob, wcphob, gcphob, &
     kcb, wcb, gcb, kdst, wdst, gdst, kbg, wbg, gbg, kvolc, wvolc, gvolc
   use abortutils, only: endrun
   use quicksort, only: quick_sort
!bloss   use cmparray_mod, only: CmpDayNite, ExpDayNite

   implicit none

   integer nspint            ! Num of spctrl intervals across solar spectrum
   integer naer_groups       ! Num of aerosol groups for optical diagnostics

   parameter ( nspint = 19 )
   parameter ( naer_groups = 7 )    ! current groupings are sul, sslt, all carbons, all dust, and all aerosols
!-----------------------Constants for new band (640-700 nm)-------------
   real(r4) v_raytau_35
   real(r4) v_raytau_64
   real(r4) v_abo3_35
   real(r4) v_abo3_64
   parameter( &
        v_raytau_35 = 0.155208, &
        v_raytau_64 = 0.0392, &
        v_abo3_35 = 2.4058030e+01, &  
        v_abo3_64 = 2.210e+01 &
        )


!-------------Parameters for accelerating max-random solution-------------
! 
! The solution time scales like prod(j:1->N) (1 + n_j) where 
! N   = number of max-overlap regions (nmxrgn)
! n_j = number of unique cloud amounts in region j
! 
! Therefore the solution cost can be reduced by decreasing n_j.
! cldmin reduces n_j by treating cloud amounts < cldmin as clear sky.
! cldeps reduces n_j by treating cloud amounts identical to log(1/cldeps)
! decimal places as identical
! 
! areamin reduces the cost by dropping configurations that occupy
! a surface area < areamin of the model grid box.  The surface area
! for a configuration C(j,k_j), where j is the region number and k_j is the
! index for a unique cloud amount (in descending order from biggest to
! smallest clouds) in region j, is
! 
! A = prod(j:1->N) [C(j,k_j) - C(j,k_j+1)]
! 
! where C(j,0) = 1.0 and C(j,n_j+1) = 0.0.
! 
! nconfgmax reduces the cost and improves load balancing by setting an upper
! bound on the number of cloud configurations in the solution.  If the number
! of configurations exceeds nconfgmax, the nconfgmax configurations with the
! largest area are retained, and the fluxes are normalized by the total area
! of these nconfgmax configurations.  For the current max/random overlap 
! assumption (see subroutine cldovrlap), 30 levels, and cloud-amount 
! parameterization, the mean and RMS number of configurations are 
! both roughly 5.  nconfgmax has been set to the mean+2*RMS number, or 15.
! 
! Minimum cloud amount (as a fraction of the grid-box area) to 
! distinguish from clear sky
! 
   real(r4) cldmin
   parameter (cldmin = 1.0e-30_r4)
! 
! Minimimum horizontal area (as a fraction of the grid-box area) to retain 
! for a unique cloud configuration in the max-random solution
! 
   real(r4) areamin
   parameter (areamin = 0.01_r4)
! 
! Decimal precision of cloud amount (0 -> preserve full resolution;
! 10^-n -> preserve n digits of cloud amount)
! 
   real(r4) cldeps
   parameter (cldeps = 0.0_r4)
! 
! Maximum number of configurations to include in solution
! 
   integer nconfgmax
   parameter (nconfgmax = 15)
!------------------------------Commons----------------------------------
!bloss#include <crdcon.h>
! 
! Input arguments
! 
   integer, intent(in) :: lchnk             ! chunk identifier
   integer, intent(in) :: ncol              ! number of atmospheric columns


   real(r4), intent(in) :: E_pmid(pcols,pver) ! Level pressure
   real(r4), intent(in) :: E_pint(pcols,pverp) ! Interface pressure
   real(r4), intent(in) :: E_h2ommr(pcols,pver) ! Specific humidity (h2o mass mix ratio)
   real(r4), intent(in) :: E_o3mmr(pcols,pver) ! Ozone mass mixing ratio
   real(r4), intent(in) :: E_aermmr(pcols,pver,naer_all) ! Aerosol mass mixing ratio
   real(r4), intent(in) :: E_rh(pcols,pver)   ! Relative humidity (fraction)
! 
   real(r4), intent(in) :: E_cld(pcols,pver)  ! Fractional cloud cover
   real(r4), intent(in) :: E_cicewp(pcols,pver) ! in-cloud cloud ice water path
   real(r4), intent(in) :: E_cliqwp(pcols,pver) ! in-cloud cloud liquid water path
   real(r4), intent(in) :: E_csnowp(pcols,pver) ! in-cloud snow water path -- bloss(2016-02-08)
   real(r4), intent(in) :: E_rel(pcols,pver)  ! Liquid effective drop size (microns)
   real(r4), intent(in) :: E_rei(pcols,pver)  ! Ice effective drop size (microns)
   real(r4), intent(in) :: E_res(pcols,pver)  ! Snow effective drop size (microns) -- bloss(2016-02-08)
! 
   real(r4), intent(in) :: eccf_in             ! Eccentricity factor (1./earth-sun dist^2)
   real(r4), intent(in) :: E_coszrs(pcols)    ! Cosine solar zenith angle
   real(r4), intent(in) :: E_asdir(pcols)     ! 0.2-0.7 micro-meter srfc alb: direct rad
   real(r4), intent(in) :: E_aldir(pcols)     ! 0.7-5.0 micro-meter srfc alb: direct rad
   real(r4), intent(in) :: E_asdif(pcols)     ! 0.2-0.7 micro-meter srfc alb: diffuse rad
   real(r4), intent(in) :: E_aldif(pcols)     ! 0.7-5.0 micro-meter srfc alb: diffuse rad



   real(r4), intent(in) :: scon_in             ! solar constant 
! 
! IN/OUT arguments
! 
   real(r4), intent(inout) :: pmxrgn(pcols,pverp) ! Maximum values of pressure for each
!                                                 !    maximally overlapped region. 
!                                                 !    0->pmxrgn(i,1) is range of pressure for
!                                                 !    1st region,pmxrgn(i,1)->pmxrgn(i,2) for
!                                                 !    2nd region, etc
   integer, intent(inout) ::  nmxrgn(pcols)    ! Number of maximally overlapped regions
! 
! Output arguments
! 

   real(r4), intent(out) :: solin(pcols)     ! Incident solar flux
   real(r4), intent(out) :: qrs(pcols,pver)  ! Solar heating rate
   real(r4), intent(out) :: fsns(pcols)      ! Surface absorbed solar flux
   real(r4), intent(out) :: fsnt(pcols)      ! Total column absorbed solar flux
   real(r4), intent(out) :: fsntoa(pcols)    ! Net solar flux at TOA
   real(r4), intent(out) :: fsds(pcols)      ! Flux shortwave downwelling surface
! 
   real(r4), intent(out) :: fsnsc(pcols)     ! Clear sky surface absorbed solar flux
   real(r4), intent(out) :: fsdsc(pcols)     ! Clear sky surface downwelling solar flux
   real(r4), intent(out) :: fsntc(pcols)     ! Clear sky total column absorbed solar flx
   real(r4), intent(out) :: fsntoac(pcols)   ! Clear sky net solar flx at TOA
   real(r4), intent(out) :: sols(pcols)      ! Direct solar rad on surface (< 0.7)
   real(r4), intent(out) :: soll(pcols)      ! Direct solar rad on surface (>= 0.7)
   real(r4), intent(out) :: solsd(pcols)     ! Diffuse solar rad on surface (< 0.7)
   real(r4), intent(out) :: solld(pcols)     ! Diffuse solar rad on surface (>= 0.7)
   real(r4), intent(out) :: fsnirtoa(pcols)  ! Near-IR flux absorbed at toa
   real(r4), intent(out) :: fsnrtoac(pcols)  ! Clear sky near-IR flux absorbed at toa
   real(r4), intent(out) :: fsnrtoaq(pcols)  ! Net near-IR flux at toa >= 0.7 microns

   real(r4) , intent(out) :: frc_day(pcols) ! = 1 for daylight, =0 for night columns
   real(r4) :: aertau(pcols,nspint,naer_groups) ! Aerosol column optical depth
   real(r4) :: aerssa(pcols,nspint,naer_groups) ! Aerosol column averaged single scattering albedo
   real(r4) :: aerasm(pcols,nspint,naer_groups) ! Aerosol column averaged asymmetry parameter
   real(r4) :: aerfwd(pcols,nspint,naer_groups) ! Aerosol column averaged forward scattering
!  real(r4), intent(out) :: aertau(pcols,nspint,naer_groups) ! Aerosol column optical depth
!  real(r4), intent(out) :: aerssa(pcols,nspint,naer_groups) ! Aerosol column averaged single scattering albedo
!  real(r4), intent(out) :: aerasm(pcols,nspint,naer_groups) ! Aerosol column averaged asymmetry parameter
!  real(r4), intent(out) :: aerfwd(pcols,nspint,naer_groups) ! Aerosol column averaged forward scattering
   real(r4), intent(out) :: fns(pcols,pverp)   ! net flux at interfaces
   real(r4), intent(out) :: fcns(pcols,pverp)  ! net clear-sky flux at interfaces
!bloss: added upward/downward shortwave fluxes as outputs.
   real(r4), intent(out) :: fsu(pcols,pverp)   !  upward shortwave flux at interfaces
   real(r4), intent(out) :: fsd(pcols,pverp)   !  downward shortwave flux at interfaces
! 
!---------------------------Local variables-----------------------------
!
! Local and reordered copies of the intent(in) variables
!
   real(r4) :: pmid(pcols,pver) ! Level pressure
   real(r4) :: pint(pcols,pverp) ! Interface pressure
   real(r4) :: h2ommr(pcols,pver) ! Specific humidity (h2o mass mix ratio)
   real(r4) :: o3mmr(pcols,pver) ! Ozone mass mixing ratio
   real(r4) :: aermmr(pcols,pver,naer_all) ! Aerosol mass mixing ratio
   real(r4) :: rh(pcols,pver)   ! Relative humidity (fraction)
! 
   real(r4) :: cld(pcols,pver)  ! Fractional cloud cover
   real(r4) :: cicewp(pcols,pver) ! in-cloud cloud ice water path
   real(r4) :: cliqwp(pcols,pver) ! in-cloud cloud liquid water path
   real(r4) :: csnowp(pcols,pver) ! in-cloud snow water path -- bloss(2016-02-08)
   real(r4) :: rel(pcols,pver)  ! Liquid effective drop size (microns)
   real(r4) :: rei(pcols,pver)  ! Ice effective drop size (microns)
   real(r4) :: res(pcols,pver)  ! Snow effective drop size (microns) -- bloss(2016-02-08)
! 
   real(r4) :: coszrs(pcols)    ! Cosine solar zenith angle
   real(r4) :: asdir(pcols)     ! 0.2-0.7 micro-meter srfc alb: direct rad
   real(r4) :: aldir(pcols)     ! 0.7-5.0 micro-meter srfc alb: direct rad
   real(r4) :: asdif(pcols)     ! 0.2-0.7 micro-meter srfc alb: diffuse rad
   real(r4) :: aldif(pcols)     ! 0.7-5.0 micro-meter srfc alb: diffuse rad


! 
! Max/random overlap variables
! 
   real(r4) asort(pverp)     ! 1 - cloud amounts to be sorted for max ovrlp.
   real(r4) atmp             ! Temporary storage for sort when nxs = 2
   real(r4) cld0             ! 1 - (cld amt) used to make wstr, cstr, nstr
   real(r4) totwgt(pcols)    ! Total of xwgts = total fractional area of 
!   grid-box covered by cloud configurations
!   included in solution to fluxes

   real(r4) wgtv(nconfgmax)  ! Weights for fluxes
!   1st index is configuration number
   real(r4) wstr(pverp,pverp) ! area weighting factors for streams
!   1st index is for stream #, 
!   2nd index is for region #

   real(r4) xexpt            ! solar direct beam trans. for layer above
   real(r4) xrdnd            ! diffuse reflectivity for layer above
   real(r4) xrupd            ! diffuse reflectivity for layer below
   real(r4) xrups            ! direct-beam reflectivity for layer below
   real(r4) xtdnt            ! total trans for layers above

   real(r4) xwgt             ! product of cloud amounts

   real(r4) yexpt            ! solar direct beam trans. for layer above
   real(r4) yrdnd            ! diffuse reflectivity for layer above
   real(r4) yrupd            ! diffuse reflectivity for layer below
   real(r4) ytdnd            ! dif-beam transmission for layers above
   real(r4) ytupd            ! dif-beam transmission for layers below

   real(r4) zexpt            ! solar direct beam trans. for layer above
   real(r4) zrdnd            ! diffuse reflectivity for layer above
   real(r4) zrupd            ! diffuse reflectivity for layer below
   real(r4) zrups            ! direct-beam reflectivity for layer below
   real(r4) ztdnt            ! total trans for layers above

   logical new_term          ! Flag for configurations to include in fluxes
   logical region_found      ! flag for identifying regions

   integer ccon(nconfgmax,0:pverp,pcols)                                
! flags for presence of clouds
!   1st index is for level # (including 
!    layer above top of model and at surface)
!   2nd index is for configuration #
   integer cstr(0:pverp,pverp)                                
! flags for presence of clouds
!   1st index is for level # (including 
!    layer above top of model and at surface)
!   2nd index is for stream #
   integer icond(nconfgmax,0:pverp,pcols)
! Indices for copying rad. properties from
!     one identical downward cld config.
!     to another in adding method (step 2)
!   1st index is for interface # (including 
!     layer above top of model and at surface)
!   2nd index is for configuration # range
   integer iconu(nconfgmax,0:pverp,pcols)
! Indices for copying rad. properties from
!     one identical upward configuration
!     to another in adding method (step 2)
!   1st index is for interface # (including 
!     layer above top of model and at surface)
!   2nd index is for configuration # range
   integer iconfig           ! Counter for random-ovrlap configurations
   integer irgn              ! Index for max-overlap regions
   integer is0               ! Lower end of stream index range
   integer is1               ! Upper end of stream index range
   integer isn               ! Stream index
   integer istr(pverp+1)     ! index for stream #s during flux calculation
   integer istrtd(0:nconfgmax+1,0:pverp,pcols)
! indices into icond 
!   1st index is for interface # (including 
!     layer above top of model and at surface)
!   2nd index is for configuration # range
   integer istrtu(0:nconfgmax+1,0:pverp,pcols)
! indices into iconu 
!   1st index is for interface # (including 
!     layer above top of model and at surface)
!   2nd index is for configuration # range
   integer j                 ! Configuration index
   integer jj                ! Configuration index
   integer k1                ! Level index
   integer k2                ! Level index
   integer ksort(pverp)      ! Level indices of cloud amounts to be sorted
   integer ktmp              ! Temporary storage for sort when nxs = 2
   integer kx1(0:pverp)      ! Level index for top of max-overlap region
   integer kx2(0:pverp)      ! Level index for bottom of max-overlap region
   integer l                 ! Index 
   integer l0                ! Index
   integer mrgn              ! Counter for nrgn
   integer mstr              ! Counter for nstr
   integer n0                ! Number of configurations with ccon(:,k,:)==0
   integer n1                ! Number of configurations with ccon(:,k,:)==1
   integer nconfig(pcols)    ! Number of random-ovrlap configurations
   integer nconfigm          ! Value of config before testing for areamin,
!    nconfgmax
   integer npasses           ! number of passes over the indexing loop
   integer nrgn              ! Number of max overlap regions at current 
!    longitude
   integer nstr(pverp)       ! Number of unique cloud configurations
!   ("streams") in a max-overlapped region
!   1st index is for region #
   integer nuniq             ! # of unique cloud configurations
   integer nuniqd(0:pverp,pcols)   ! # of unique cloud configurations: TOA 
!   to level k
   integer nuniqu(0:pverp,pcols)   ! # of unique cloud configurations: surface
!   to level k 
   integer nxs               ! Number of cloudy layers between k1 and k2 
   integer ptr0(nconfgmax)   ! Indices of configurations with ccon(:,k,:)==0
   integer ptr1(nconfgmax)   ! Indices of configurations with ccon(:,k,:)==1
   integer ptrc(nconfgmax)   ! Pointer for configurations sorted by wgtv
   integer, dimension(1) :: min_idx  ! required for return val of func minloc

! 
! Other
! 
   integer ns                ! Spectral loop index
   integer i                 ! Longitude loop index
   integer k                 ! Level loop index
   integer km1               ! k - 1
   integer kp1               ! k + 1
   integer n                 ! Loop index for daylight
   integer indxsl            ! Index for cloud particle properties
   integer ksz               ! dust size bin index
   integer krh               ! relative humidity bin index
   integer kaer              ! aerosol group index
   real(r4) wrh              ! weight for linear interpolation between lut points
   real(r4) :: rhtrunc       ! rh, truncated for the purposes of extrapolating
                             ! aerosol optical properties
! 
! A. Slingo's data for cloud particle radiative properties (from 'A GCM
! Parameterization for the Shortwave Properties of Water Clouds' JAS
! vol. 46 may 1989 pp 1419-1427)
! 
   real(r4) abarl(4)         ! A coefficient for extinction optical depth
   real(r4) bbarl(4)         ! B coefficient for extinction optical depth
   real(r4) cbarl(4)         ! C coefficient for single scat albedo
   real(r4) dbarl(4)         ! D coefficient for single  scat albedo
   real(r4) ebarl(4)         ! E coefficient for asymmetry parameter
   real(r4) fbarl(4)         ! F coefficient for asymmetry parameter

   save abarl, bbarl, cbarl, dbarl, ebarl, fbarl

   data abarl/ 2.817e-02, 2.682e-02,2.264e-02,1.281e-02/
   data bbarl/ 1.305    , 1.346    ,1.454    ,1.641    /
   data cbarl/-5.62e-08 ,-6.94e-06 ,4.64e-04 ,0.201    /
   data dbarl/ 1.63e-07 , 2.35e-05 ,1.24e-03 ,7.56e-03 /
   data ebarl/ 0.829    , 0.794    ,0.754    ,0.826    /
   data fbarl/ 2.482e-03, 4.226e-03,6.560e-03,4.353e-03/

   real(r4) abarli           ! A coefficient for current spectral band
   real(r4) bbarli           ! B coefficient for current spectral band
   real(r4) cbarli           ! C coefficient for current spectral band
   real(r4) dbarli           ! D coefficient for current spectral band
   real(r4) ebarli           ! E coefficient for current spectral band
   real(r4) fbarli           ! F coefficient for current spectral band
! 
! Caution... A. Slingo recommends no less than 4.0 micro-meters nor
! greater than 20 micro-meters
! 
! ice water coefficients (Ebert and Curry,1992, JGR, 97, 3831-3836)
! 
   real(r4) abari(4)         ! a coefficient for extinction optical depth
   real(r4) bbari(4)         ! b coefficient for extinction optical depth
   real(r4) cbari(4)         ! c coefficient for single scat albedo
   real(r4) dbari(4)         ! d coefficient for single scat albedo
   real(r4) ebari(4)         ! e coefficient for asymmetry parameter
   real(r4) fbari(4)         ! f coefficient for asymmetry parameter

   save abari, bbari, cbari, dbari, ebari, fbari

   data abari/ 3.448e-03, 3.448e-03,3.448e-03,3.448e-03/
   data bbari/ 2.431    , 2.431    ,2.431    ,2.431    /
   data cbari/ 1.00e-05 , 1.10e-04 ,1.861e-02,.46658   /
   data dbari/ 0.0      , 1.405e-05,8.328e-04,2.05e-05 /
   data ebari/ 0.7661   , 0.7730   ,0.794    ,0.9595   /
   data fbari/ 5.851e-04, 5.665e-04,7.267e-04,1.076e-04/

   real(r4) abarii           ! A coefficient for current spectral band
   real(r4) bbarii           ! B coefficient for current spectral band
   real(r4) cbarii           ! C coefficient for current spectral band
   real(r4) dbarii           ! D coefficient for current spectral band
   real(r4) ebarii           ! E coefficient for current spectral band
   real(r4) fbarii           ! F coefficient for current spectral band
! 
   real(r4) delta            ! Pressure (in atm) for stratos. h2o limit
   real(r4) o2mmr            ! O2 mass mixing ratio:

   save delta, o2mmr

!bloss(2016-02-09): Variables for totaling the ice optical properties
!   between cloud ice and snow
   real(r4) tauxcs  ! snow optical depth in current layer
   real(r4) wcs     ! snow single scattering albedo
   real(r4) gcs     ! snow asymmetry parameter
   real(r4) fcs     ! snow forward scattering factor
   
   real(r4) tautot        ! total cloud ice + snow optical depth
   real(r4) tauwcitot     ! total cloud ice + snow (optical depth) times (SSA)
   real(r4) tauwcigcitot  ! total cloud ice + snow (optical depth) times (SSA) times (ASYMMETRY)
   real(r4) tauwcifcitot  ! total cloud ice + snow (optical depth) times (SSA) times (FSF)
!
! UPDATE TO H2O NEAR-IR: Delta optimized for Hitran 2K and CKD 2.4
!
   data delta / 0.0014257179260883 /
!
! END UPDATE
!
   data o2mmr / .23143 /

   real(r4) albdir(pcols,nspint) ! Current spc intrvl srf alb to direct rad
   real(r4) albdif(pcols,nspint) ! Current spc intrvl srf alb to diffuse rad
! 
! Next series depends on spectral interval
! 
   real(r4) frcsol(nspint)   ! Fraction of solar flux in spectral interval
   real(r4) wavmin(nspint)   ! Min wavelength (micro-meters) of interval
   real(r4) wavmax(nspint)   ! Max wavelength (micro-meters) of interval
   real(r4) raytau(nspint)   ! Rayleigh scattering optical depth
   real(r4) abh2o(nspint)    ! Absorption coefficiant for h2o (cm2/g)
   real(r4) abo3 (nspint)    ! Absorption coefficiant for o3  (cm2/g)
   real(r4) abco2(nspint)    ! Absorption coefficiant for co2 (cm2/g)
   real(r4) abo2 (nspint)    ! Absorption coefficiant for o2  (cm2/g)
   real(r4) ph2o(nspint)     ! Weight of h2o in spectral interval
   real(r4) pco2(nspint)     ! Weight of co2 in spectral interval
   real(r4) po2 (nspint)     ! Weight of o2  in spectral interval
   real(r4) nirwgt(nspint)   ! Spectral Weights to simulate Nimbus-7 filter
   real(r4) wgtint           ! Weight for specific spectral interval

   save frcsol ,wavmin ,wavmax ,raytau ,abh2o ,abo3 , &
        abco2  ,abo2   ,ph2o   ,pco2   ,po2   ,nirwgt

   data frcsol / .001488, .001389, .001290, .001686, .002877, &
                 .003869, .026336, .360739, .065392, .526861, &
                 .526861, .526861, .526861, .526861, .526861, &
                 .526861, .006239, .001834, .001834/
! 
! weight for 0.64 - 0.7 microns  appropriate to clear skies over oceans
! 
   data nirwgt /  0.0,   0.0,   0.0,      0.0,   0.0, &
                  0.0,   0.0,   0.0, 0.320518,   1.0,  1.0, &
                  1.0,   1.0,   1.0,      1.0,   1.0, &
                  1.0,   1.0,   1.0 /

   data wavmin / .200,  .245,  .265,  .275,  .285, &
                 .295,  .305,  .350,  .640,  .700,  .701, &
                 .701,  .701,  .701,  .702,  .702, &
                 2.630, 4.160, 4.160/

   data wavmax / .245,  .265,  .275,  .285,  .295, &
                 .305,  .350,  .640,  .700, 5.000, 5.000, &
                 5.000, 5.000, 5.000, 5.000, 5.000, &
                 2.860, 4.550, 4.550/

!
! UPDATE TO H2O NEAR-IR: Rayleigh scattering optimized for Hitran 2K & CKD 2.4
!
   data raytau / 4.020, 2.180, 1.700, 1.450, 1.250, &
                  1.085, 0.730, v_raytau_35, v_raytau_64, &
                  0.02899756, 0.01356763, 0.00537341, &
                  0.00228515, 0.00105028, 0.00046631, &
                  0.00025734, &
                 .0001, .0001, .0001/
!
! END UPDATE
!

! 
! Absorption coefficients
! 
!
! UPDATE TO H2O NEAR-IR: abh2o optimized for Hitran 2K and CKD 2.4
!
   data abh2o /    .000,     .000,    .000,    .000,    .000, &
                   .000,     .000,    .000,    .000,    &
                   0.00256608,  0.06310504,   0.42287445, 2.45397941, &
                  11.20070807, 47.66091389, 240.19010243, &
                   .000,    .000,    .000/
!
! END UPDATE
!

   data abo3  /5.370e+04, 13.080e+04,  9.292e+04, 4.530e+04, 1.616e+04, &
               4.441e+03,  1.775e+02, v_abo3_35, v_abo3_64,      .000, &
               .000,   .000    ,   .000   ,   .000   ,      .000, &
               .000,   .000    ,   .000   ,   .000    /

   data abco2  /   .000,     .000,    .000,    .000,    .000, &
                   .000,     .000,    .000,    .000,    .000, &
                   .000,     .000,    .000,    .000,    .000, &
                   .000,     .094,    .196,   1.963/

   data abo2  /    .000,     .000,    .000,    .000,    .000, &
                   .000,     .000,    .000,1.11e-05,6.69e-05, &
                   .000,     .000,    .000,    .000,    .000, &  
                   .000,     .000,    .000,    .000/
! 
! Spectral interval weights
! 
   data ph2o  /    .000,     .000,    .000,    .000,    .000, &
        .000,     .000,    .000,    .000,    .505,     &
        .210,     .120,    .070,    .048,    .029,     &
        .018,     .000,    .000,    .000/

   data pco2  /    .000,     .000,    .000,    .000,    .000, &
        .000,     .000,    .000,    .000,    .000,     &
        .000,     .000,    .000,    .000,    .000,     &
        .000,    1.000,    .640,    .360/

   data po2   /    .000,     .000,    .000,    .000,    .000, &
        .000,     .000,    .000,   1.000,   1.000,     &
        .000,     .000,    .000,    .000,    .000,     &
        .000,     .000,    .000,    .000/
! 
! Diagnostic and accumulation arrays; note that sfltot, fswup, and
! fswdn are not used in the computation,but are retained for future use.
! 
   real(r4) solflx(pcols)    ! Solar flux in current interval
   real(r4) sfltot(pcols)    ! Spectrally summed total solar flux
   real(r4) totfld(pcols,0:pver)   ! Spectrally summed flux divergence
   real(r4) fswup(pcols,0:pverp)   ! Spectrally summed up flux
   real(r4) fswdn(pcols,0:pverp)   ! Spectrally summed down flux
! 
! Cloud radiative property arrays
! 
   real(r4) tauxcl(pcols,0:pver) ! water cloud extinction optical depth
   real(r4) tauxci(pcols,0:pver) ! ice cloud extinction optical depth
   real(r4) wcl(pcols,0:pver) ! liquid cloud single scattering albedo
   real(r4) gcl(pcols,0:pver) ! liquid cloud asymmetry parameter
   real(r4) fcl(pcols,0:pver) ! liquid cloud forward scattered fraction
   real(r4) wci(pcols,0:pver) ! ice cloud single scattering albedo
   real(r4) gci(pcols,0:pver) ! ice cloud asymmetry parameter
   real(r4) fci(pcols,0:pver) ! ice cloud forward scattered fraction
!
! Aerosol mass paths by species
!
  real(r4) usul(pcols,pver)   ! sulfate (SO4)
  real(r4) ubg(pcols,pver)    ! background aerosol
  real(r4) usslt(pcols,pver)  ! sea-salt (SSLT)
  real(r4) ucphil(pcols,pver) ! hydrophilic organic carbon (OCPHI)
  real(r4) ucphob(pcols,pver) ! hydrophobic organic carbon (OCPHO)
  real(r4) ucb(pcols,pver)    ! black carbon (BCPHI + BCPHO)
  real(r4) uvolc(pcols,pver) ! volcanic mass
  real(r4) udst(pcols,ndstsz,pver) ! dust

!
! local variables used for the external mixing of aerosol species
!
  real(r4) tau_sul             ! optical depth, sulfate
  real(r4) tau_bg              ! optical depth, background aerosol
  real(r4) tau_sslt            ! optical depth, sea-salt
  real(r4) tau_cphil           ! optical depth, hydrophilic carbon
  real(r4) tau_cphob           ! optical depth, hydrophobic carbon
  real(r4) tau_cb              ! optical depth, black carbon
  real(r4) tau_volc            ! optical depth, volcanic
  real(r4) tau_dst(ndstsz)     ! optical depth, dust, by size category
  real(r4) tau_dst_tot         ! optical depth, total dust
  real(r4) tau_tot             ! optical depth, total aerosol

  real(r4) tau_w_sul           ! optical depth * single scattering albedo, sulfate
  real(r4) tau_w_bg            ! optical depth * single scattering albedo, background aerosol
  real(r4) tau_w_sslt          ! optical depth * single scattering albedo, sea-salt
  real(r4) tau_w_cphil         ! optical depth * single scattering albedo, hydrophilic carbon
  real(r4) tau_w_cphob         ! optical depth * single scattering albedo, hydrophobic carbon
  real(r4) tau_w_cb            ! optical depth * single scattering albedo, black carbon
  real(r4) tau_w_volc          ! optical depth * single scattering albedo, volcanic
  real(r4) tau_w_dst(ndstsz)   ! optical depth * single scattering albedo, dust, by size
  real(r4) tau_w_dst_tot       ! optical depth * single scattering albedo, total dust
  real(r4) tau_w_tot           ! optical depth * single scattering albedo, total aerosol

  real(r4) tau_w_g_sul         ! optical depth * single scattering albedo * asymmetry parameter, sulfate
  real(r4) tau_w_g_bg          ! optical depth * single scattering albedo * asymmetry parameter, background aerosol
  real(r4) tau_w_g_sslt        ! optical depth * single scattering albedo * asymmetry parameter, sea-salt
  real(r4) tau_w_g_cphil       ! optical depth * single scattering albedo * asymmetry parameter, hydrophilic carbon
  real(r4) tau_w_g_cphob       ! optical depth * single scattering albedo * asymmetry parameter, hydrophobic carbon
  real(r4) tau_w_g_cb          ! optical depth * single scattering albedo * asymmetry parameter, black carbon
  real(r4) tau_w_g_volc        ! optical depth * single scattering albedo * asymmetry parameter, volcanic
  real(r4) tau_w_g_dst(ndstsz) ! optical depth * single scattering albedo * asymmetry parameter, dust, by size
  real(r4) tau_w_g_dst_tot     ! optical depth * single scattering albedo * asymmetry parameter, total dust
  real(r4) tau_w_g_tot         ! optical depth * single scattering albedo * asymmetry parameter, total aerosol

  real(r4) f_sul               ! forward scattering fraction, sulfate
  real(r4) f_bg                ! forward scattering fraction, background aerosol
  real(r4) f_sslt              ! forward scattering fraction, sea-salt
  real(r4) f_cphil             ! forward scattering fraction, hydrophilic carbon
  real(r4) f_cphob             ! forward scattering fraction, hydrophobic carbon
  real(r4) f_cb                ! forward scattering fraction, black carbon
  real(r4) f_volc              ! forward scattering fraction, volcanic
  real(r4) f_dst(ndstsz)       ! forward scattering fraction, dust, by size
  real(r4) f_dst_tot           ! forward scattering fraction, total dust
  real(r4) f_tot               ! forward scattering fraction, total aerosol

  real(r4) tau_w_f_sul         ! optical depth * forward scattering fraction * single scattering albedo, sulfate
  real(r4) tau_w_f_bg          ! optical depth * forward scattering fraction * single scattering albedo, background
  real(r4) tau_w_f_sslt        ! optical depth * forward scattering fraction * single scattering albedo, sea-salt
  real(r4) tau_w_f_cphil       ! optical depth * forward scattering fraction * single scattering albedo, hydrophilic C
  real(r4) tau_w_f_cphob       ! optical depth * forward scattering fraction * single scattering albedo, hydrophobic C
  real(r4) tau_w_f_cb          ! optical depth * forward scattering fraction * single scattering albedo, black C
  real(r4) tau_w_f_volc        ! optical depth * forward scattering fraction * single scattering albedo, volcanic
  real(r4) tau_w_f_dst(ndstsz) ! optical depth * forward scattering fraction * single scattering albedo, dust, by size
  real(r4) tau_w_f_dst_tot     ! optical depth * forward scattering fraction * single scattering albedo, total dust
  real(r4) tau_w_f_tot         ! optical depth * forward scattering fraction * single scattering albedo, total aerosol
  real(r4) w_dst_tot           ! single scattering albedo, total dust
  real(r4) w_tot               ! single scattering albedo, total aerosol
  real(r4) g_dst_tot           ! asymmetry parameter, total dust
  real(r4) g_tot               ! asymmetry parameter, total aerosol
  real(r4) ksuli               ! specific extinction interpolated between rh look-up-table points, sulfate
  real(r4) ksslti              ! specific extinction interpolated between rh look-up-table points, sea-salt
  real(r4) kcphili             ! specific extinction interpolated between rh look-up-table points, hydrophilic carbon
  real(r4) wsuli               ! single scattering albedo interpolated between rh look-up-table points, sulfate
  real(r4) wsslti              ! single scattering albedo interpolated between rh look-up-table points, sea-salt
  real(r4) wcphili             ! single scattering albedo interpolated between rh look-up-table points, hydrophilic carbon
  real(r4) gsuli               ! asymmetry parameter interpolated between rh look-up-table points, sulfate
  real(r4) gsslti              ! asymmetry parameter interpolated between rh look-up-table points, sea-salt
  real(r4) gcphili             ! asymmetry parameter interpolated between rh look-up-table points, hydrophilic carbon
! 
! Aerosol radiative property arrays
! 
   real(r4) tauxar(pcols,0:pver) ! aerosol extinction optical depth
   real(r4) wa(pcols,0:pver) ! aerosol single scattering albedo
   real(r4) ga(pcols,0:pver) ! aerosol assymetry parameter
   real(r4) fa(pcols,0:pver) ! aerosol forward scattered fraction

! 
! Various arrays and other constants:
! 
   real(r4) pflx(pcols,0:pverp) ! Interface press, including extra layer
   real(r4) zenfac(pcols)    ! Square root of cos solar zenith angle
   real(r4) sqrco2           ! Square root of the co2 mass mixg ratio
   real(r4) tmp1             ! Temporary constant array
   real(r4) tmp2             ! Temporary constant array
   real(r4) pdel             ! Pressure difference across layer
   real(r4) path             ! Mass path of layer
   real(r4) ptop             ! Lower interface pressure of extra layer
   real(r4) ptho2            ! Used to compute mass path of o2
   real(r4) ptho3            ! Used to compute mass path of o3
   real(r4) pthco2           ! Used to compute mass path of co2
   real(r4) pthh2o           ! Used to compute mass path of h2o
   real(r4) h2ostr           ! Inverse sq. root h2o mass mixing ratio

!bloss#ifdef JPE_VMATH
!bloss   real(r4) v_h2ostr(pcols,pver)           ! Inverse sq. root h2o mass mixing ratio

!bloss   real(r4) v_rtotwgt(pcols)           ! recipricle totwgt
!bloss#endif

   real(r4) wavmid(nspint)   ! Spectral interval middle wavelength
   real(r4) trayoslp         ! Rayleigh optical depth/standard pressure
   real(r4) tmp1l            ! Temporary constant array
   real(r4) tmp2l            ! Temporary constant array
   real(r4) tmp3l            ! Temporary constant array
   real(r4) tmp1i            ! Temporary constant array
   real(r4) tmp2i            ! Temporary constant array
   real(r4) tmp3i            ! Temporary constant array
   real(r4) rdenom           ! Multiple scattering term
   real(r4) rdirexp          ! layer direct ref times exp transmission
   real(r4) tdnmexp          ! total transmission - exp transmission
   real(r4) psf(nspint)      ! Frac of solar flux in spect interval
! 
! Layer absorber amounts; note that 0 refers to the extra layer added
! above the top model layer
! 
   real(r4) uh2o(pcols,0:pver) ! Layer absorber amount of h2o
   real(r4) uo3(pcols,0:pver) ! Layer absorber amount of  o3
   real(r4) uco2(pcols,0:pver) ! Layer absorber amount of co2
   real(r4) uo2(pcols,0:pver) ! Layer absorber amount of  o2
   real(r4) uaer(pcols,0:pver) ! Layer aerosol amount 
! 
! Total column absorber amounts:
! 
   real(r4) uth2o(pcols)     ! Total column  absorber amount of  h2o
   real(r4) uto3(pcols)      ! Total column  absorber amount of  o3
   real(r4) utco2(pcols)     ! Total column  absorber amount of  co2
   real(r4) uto2(pcols)      ! Total column  absorber amount of  o2
! 
! These arrays are defined for pver model layers; 0 refers to the extra
! layer on top:
! 
   real(r4) rdir(nspint,pcols,0:pver) ! Layer reflectivity to direct rad
   real(r4) rdif(nspint,pcols,0:pver) ! Layer reflectivity to diffuse rad
   real(r4) tdir(nspint,pcols,0:pver) ! Layer transmission to direct rad
   real(r4) tdif(nspint,pcols,0:pver) ! Layer transmission to diffuse rad
   real(r4) explay(nspint,pcols,0:pver) ! Solar beam exp trans. for layer

   real(r4) rdirc(nspint,pcols,0:pver) ! Clear Layer reflec. to direct rad
   real(r4) rdifc(nspint,pcols,0:pver) ! Clear Layer reflec. to diffuse rad
   real(r4) tdirc(nspint,pcols,0:pver) ! Clear Layer trans. to direct rad
   real(r4) tdifc(nspint,pcols,0:pver) ! Clear Layer trans. to diffuse rad
   real(r4) explayc(nspint,pcols,0:pver) ! Solar beam exp trans. clear layer

   real(r4) flxdiv           ! Flux divergence for layer

!
! Temporary arrays for either clear or cloudy values.
!
   real(r4), dimension(nspint) :: Trdir
   real(r4), dimension(nspint) :: Trdif
   real(r4), dimension(nspint) :: Ttdir
   real(r4), dimension(nspint) :: Ttdif
   real(r4), dimension(nspint) :: Texplay
!cdir vreg(Trdir)
!cdir vreg(Trdif)
!cdir vreg(Ttdir)
!cdir vreg(Ttdif)
!cdir vreg(Texplay)
! 
! 
! Radiative Properties:
! 
! There are 1 classes of properties:
! (1. All-sky bulk properties
! (2. Clear-sky properties
! 
! The first set of properties are generated during step 2 of the solution.
! 
! These arrays are defined at model interfaces; in 1st index (for level #),
! 0 is the top of the extra layer above the model top, and
! pverp is the earth surface.  2nd index is for cloud configuration
! defined over a whole column.
! 
   real(r4) exptdn(nspint,0:pverp,nconfgmax,pcols) ! Sol. beam trans from layers above
   real(r4) rdndif(nspint,0:pverp,nconfgmax,pcols) ! Ref to dif rad for layers above
   real(r4) rupdif(nspint,0:pverp,nconfgmax,pcols) ! Ref to dif rad for layers below
   real(r4) rupdir(nspint,0:pverp,nconfgmax,pcols) ! Ref to dir rad for layers below
   real(r4) tdntot(nspint,0:pverp,nconfgmax,pcols) ! Total trans for layers above
! 
! Bulk properties used during the clear-sky calculation.
! 
   real(r4) exptdnc(pcols,0:pverp) ! clr: Sol. beam trans from layers above
   real(r4) rdndifc(pcols,0:pverp) ! clr: Ref to dif rad for layers above
   real(r4) rupdifc(pcols,0:pverp) ! clr: Ref to dif rad for layers below
   real(r4) rupdirc(pcols,0:pverp) ! clr: Ref to dir rad for layers below
   real(r4) tdntotc(pcols,0:pverp) ! clr: Total trans for layers above

   real(r4) fluxup(nspint,0:pverp,pcols)  ! Up   flux at model interface
   real(r4) fluxdn(nspint,0:pverp,pcols)  ! Down flux at model interface
   real(r4) wexptdn(nspint,pcols)   ! Direct solar beam trans. to surface
!
! Scalars used in vectorization
!
  integer :: kk
  integer :: Nday                      ! Number of daylight columns
  integer :: Nnite                     ! Number of night columns
  integer, dimension(pcols) :: IdxDay  ! Indicies of daylight coumns
  integer, dimension(pcols) :: IdxNite ! Indicies of night coumns
!
! Arrays used in vectorization
!
  real(r4), dimension(pcols,ndstsz) :: v_tau_dst             ! optical depth, dust, by size category
  real(r4), dimension(pcols,ndstsz) :: v_tau_w_dst           ! optical depth * single scattering albedo, dust, by size
  real(r4), dimension(pcols,ndstsz) :: v_tau_w_g_dst         ! optical depth * single scattering albedo * asymmetry parameter, dust, by size
  real(r4), dimension(pcols,ndstsz) :: v_tau_w_f_dst         ! optical depth * forward scattering fraction * single scattering albedo, dust, by size
  real(r4), dimension(pcols)        :: v_tau_dst_tot         ! optical depth, total dust
  real(r4), dimension(pcols)        :: v_tau_w_dst_tot       ! optical depth * single scattering albedo, total dust
  real(r4), dimension(pcols)        :: v_tau_w_g_dst_tot     ! optical depth * single scattering albedo * asymmetry parameter, total dust
  real(r4), dimension(pcols)        :: v_tau_w_f_dst_tot     ! optical depth * forward scattering fraction * single scattering albedo, total dust

   real(r4) :: Tv_tau_dst
   real(r4) :: Tv_tau_w_dst
   real(r4) :: Tv_tau_w_g_dst
   real(r4) :: Tv_tau_w_f_dst

   real(r4) v_wgtv(nconfgmax,pcols)  ! Weights for fluxes

   logical :: lrhtrunc_lt0(pver)      ! Logical rhtrunc < 0.0_r4
   logical :: lg_tot_gt1(pver)        ! Logical g_tot > 1.0_r4
   logical :: lg_tot_ltm1(pver)       ! Logical g_tot < -1.0_r4
   logical :: lf_tot_gt1(pver)        ! Logical f_tot > 1.0_r4
   logical :: lf_tot_lt0(pver)        ! Logical f_tot < 0.0_r4

!   real(r4) :: rdiff, ro, rn
!   rdiff(ro,rn) = abs((ro-rn)/merge(ro,1.0_r4,ro /= 0.0_r4))

! 
!-----------------------------------------------------------------------
! START OF CALCULATION
!-----------------------------------------------------------------------
! 
!  write (6, '(a, x, i3)') 'radcswmx : chunk identifier', lchnk

! 
! Initialize output fields:
! 
   fsds(1:ncol)     = 0.0_r4

   fsnirtoa(1:ncol) = 0.0_r4
   fsnrtoac(1:ncol) = 0.0_r4
   fsnrtoaq(1:ncol) = 0.0_r4

   fsns(1:ncol)     = 0.0_r4
   fsnsc(1:ncol)    = 0.0_r4
   fsdsc(1:ncol)    = 0.0_r4

   fsnt(1:ncol)     = 0.0_r4
   fsntc(1:ncol)    = 0.0_r4
   fsntoa(1:ncol)   = 0.0_r4
   fsntoac(1:ncol)  = 0.0_r4

   solin(1:ncol)    = 0.0_r4

   sols(1:ncol)     = 0.0_r4
   soll(1:ncol)     = 0.0_r4
   solsd(1:ncol)    = 0.0_r4
   solld(1:ncol)    = 0.0_r4

   frc_day(1:ncol) = 0.0_r4

   qrs(1:ncol,1:pver) = 0.0_r4
   fns(1:ncol,1:pverp) = 0.0_r4
   fcns(1:ncol,1:pverp) = 0.0_r4

   fsu(1:ncol,1:pverp) = 0.0_r4
   fsd(1:ncol,1:pverp) = 0.0_r4

   ! initialize aerosol diagnostic fields to 0.0 
   ! Average can be obtained by dividing <aerod>/<frc_day>

   aertau(1:ncol,1:nspint,1:naer_groups) = 0.0_r4
   aerssa(1:ncol,1:nspint,1:naer_groups) = 0.0_r4
   aerasm(1:ncol,1:nspint,1:naer_groups) = 0.0_r4
   aerfwd(1:ncol,1:nspint,1:naer_groups) = 0.0_r4
! 
! Compute starting, ending daytime loop indices:
!  *** Note this logic assumes day and night points are contiguous so
!  *** will not work in general with chunked data structure.
! 

   Nday = 0
   Nnite = 0
   do i = 1, ncol
      if ( E_coszrs(i) > 0.0_r4 ) then
         Nday = Nday + 1
         IdxDay(Nday) = i
      else
         Nnite = Nnite + 1
         IdxNite(Nnite) = i
      end if
   end do
! 
! If night everywhere, return:
! 
   if ( Nday == 0 ) return
!
!bloss ! Rearrange input arrays
pmid = E_pmid
pint = E_pint
h2ommr = E_h2ommr
o3mmr = E_o3mmr
aermmr = E_aermmr
rh = E_rh
cld = E_cld
cicewp = E_cicewp
cliqwp = E_cliqwp
csnowp = E_csnowp !bloss
rel = E_rel
rei = E_rei
res = E_res !bloss
coszrs = E_coszrs
asdir = E_asdir
aldir = E_aldir
asdif = E_asdif
aldif = E_aldif

!bloss ! Rearrange input arrays
!bloss !
!bloss    call CmpDayNite(E_pmid, pmid,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_pint, pint,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pverp)
!bloss    call CmpDayNite(E_h2ommr, h2ommr,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_o3mmr, o3mmr,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_aermmr, aermmr,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver, 1, naer_all)
!bloss    call CmpDayNite(E_rh, rh,		Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_cld, cld,		Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_cicewp, cicewp,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_cliqwp, cliqwp,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_rel, rel, 		Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_rei, rei,		Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call CmpDayNite(E_coszrs, coszrs,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call CmpDayNite(E_asdir, asdir,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call CmpDayNite(E_aldir, aldir,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call CmpDayNite(E_asdif, asdif,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call CmpDayNite(E_aldif, aldif,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss 
!bloss    call CmpDayNite(pmxrgn,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pverp)
!bloss    call CmpDayNite(nmxrgn,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)

! 
! Perform other initializations
! 
   tmp1   = 0.5_r4/(gravit*sslp)
   tmp2   = delta/gravit

!bloss   sqrco2 = sqrt(ghg_surfvals_get_co2mmr())
   sqrco2 = sqrt(co2mmr)

   do k=1,pverp
      do i=1,Nday
         pflx(i,k) = pint(i,k)
      end do
   end do
!bloss#ifdef JPE_VMATH
!bloss   call vrsqrt(v_h2ostr,h2ommr,pver*pcols)
!bloss#endif
   do i=1,Nday
! 
! Define solar incident radiation and interface pressures:
! 
         solin(i)  = scon_in*eccf_in*coszrs(i)
         pflx(i,0) = 0._r4
! 
! Compute optical paths:
! 
         ptop      = pflx(i,1)
         ptho2     = o2mmr * ptop / gravit
         ptho3     = o3mmr(i,1) * ptop / gravit
         pthco2    = sqrco2 * (ptop / gravit)
!bloss#ifdef JPE_VMATH
!bloss         zenfac(i) = sqrt(coszrs(i))
!bloss         pthh2o    = ptop**2*tmp1 + (ptop*rga)* &
!bloss                    (v_h2ostr(i,1)*zenfac(i)*delta)
!bloss#else
         h2ostr    = sqrt( 1._r4 / h2ommr(i,1) )
         zenfac(i) = sqrt(coszrs(i))
         pthh2o    = ptop**2*tmp1 + (ptop*rga)* &
                    (h2ostr*zenfac(i)*delta)
!bloss#endif
         uh2o(i,0) = h2ommr(i,1)*pthh2o
         uco2(i,0) = zenfac(i)*pthco2
         uo2 (i,0) = zenfac(i)*ptho2
         uo3 (i,0) = ptho3
         uaer(i,0) = 0.0_r4
! 
! End  do i=1,Nday
! 
   end do

   do k=1,pver

!cdir nodep
      do i=1,Nday

         pdel      = pflx(i,k+1) - pflx(i,k)
         path      = pdel / gravit
         ptho2     = o2mmr * path
         ptho3     = o3mmr(i,k) * path
         pthco2    = sqrco2 * path
         h2ostr    = sqrt(1.0_r4/h2ommr(i,k))
         pthh2o    = (pflx(i,k+1)**2 - pflx(i,k)**2)*tmp1 + pdel*h2ostr*zenfac(i)*tmp2
         uh2o(i,k) = h2ommr(i,k)*pthh2o
         uco2(i,k) = zenfac(i)*pthco2
         uo2 (i,k) = zenfac(i)*ptho2
         uo3 (i,k) = ptho3
         usul(i,k) = aermmr(i,k,idxSUL) * path 
         ubg(i,k) = aermmr(i,k,idxBG) * path 
         usslt(i,k) = aermmr(i,k,idxSSLT) * path
         if (usslt(i,k) .lt. 0.0) then  ! usslt is sometimes small and negative, will be fixed
           usslt(i,k) = 0.0
         end if
         ucphil(i,k) = aermmr(i,k,idxOCPHI) * path
         ucphob(i,k) = aermmr(i,k,idxOCPHO) * path
         ucb(i,k) = ( aermmr(i,k,idxBCPHO) + aermmr(i,k,idxBCPHI) ) * path
         uvolc(i,k) =  aermmr(i,k,idxVOLC)

!cdir expand=ndstsz
         do ksz = 1, ndstsz
           udst(i,ksz,k) = aermmr(i,k,idxDUSTfirst-1+ksz) * path
         end do
! 
! End  do i=1,Nday
! 
      end do
! 
! End  k=1,pver
! 
   end do
! 
! Compute column absorber amounts for the clear sky computation:
! 
   do i=1,Nday

      uth2o(i) = 0.0_r4
      uto3(i)  = 0.0_r4
      utco2(i) = 0.0_r4
      uto2(i)  = 0.0_r4

!cdir expand=pver
      do k=1,pver
         uth2o(i) = uth2o(i) + uh2o(i,k)
         uto3(i)  = uto3(i)  + uo3(i,k)
         utco2(i) = utco2(i) + uco2(i,k)
         uto2(i)  = uto2(i)  + uo2(i,k)
! 
! End  k=1,pver
! 
      end do
! 
! End  do i=1,Nday
! 
   end do
! 
! Set cloud properties for top (0) layer; so long as tauxcl is zero,
! there is no cloud above top of model; the other cloud properties
! are arbitrary:
! 
      do i=1,Nday

         tauxcl(i,0)  = 0._r4
         wcl(i,0)     = 0.999999_r4
         gcl(i,0)     = 0.85_r4
         fcl(i,0)     = 0.725_r4
         tauxci(i,0)  = 0._r4
         wci(i,0)     = 0.999999_r4
         gci(i,0)     = 0.85_r4
         fci(i,0)     = 0.725_r4
! 
! Aerosol 
! 
         tauxar(i,0)  = 0._r4
         wa(i,0)      = 0.925_r4
         ga(i,0)      = 0.850_r4
         fa(i,0)      = 0.7225_r4
! 
! End  do i=1,Nday
! 
      end do
! 
! Begin spectral loop
! 
   do ns=1,nspint
! 
! Set index for cloud particle properties based on the wavelength,
! according to A. Slingo (1989) equations 1-3:
! Use index 1 (0.25 to 0.69 micrometers) for visible
! Use index 2 (0.69 - 1.19 micrometers) for near-infrared
! Use index 3 (1.19 to 2.38 micrometers) for near-infrared
! Use index 4 (2.38 to 4.00 micrometers) for near-infrared
! 
! Note that the minimum wavelength is encoded (with .001, .002, .003)
! in order to specify the index appropriate for the near-infrared
! cloud absorption properties
! 
      if(wavmax(ns) <= 0.7_r4) then
         indxsl = 1
      else if(wavmin(ns) == 0.700_r4) then
         indxsl = 2
      else if(wavmin(ns) == 0.701_r4) then
         indxsl = 3
      else if(wavmin(ns) == 0.702_r4 .or. wavmin(ns) > 2.38_r4) then
         indxsl = 4
      end if
! 
! Set cloud extinction optical depth, single scatter albedo,
! asymmetry parameter, and forward scattered fraction:
! 
      abarli = abarl(indxsl)
      bbarli = bbarl(indxsl)
      cbarli = cbarl(indxsl)
      dbarli = dbarl(indxsl)
      ebarli = ebarl(indxsl)
      fbarli = fbarl(indxsl)
! 
      abarii = abari(indxsl)
      bbarii = bbari(indxsl)
      cbarii = cbari(indxsl)
      dbarii = dbari(indxsl)
      ebarii = ebari(indxsl)
      fbarii = fbari(indxsl)
! 
! adjustfraction within spectral interval to allow for the possibility of
! sub-divisions within a particular interval:
! 
      psf(ns) = 1.0_r4
      if(ph2o(ns)/=0._r4) psf(ns) = psf(ns)*ph2o(ns)
      if(pco2(ns)/=0._r4) psf(ns) = psf(ns)*pco2(ns)
      if(po2 (ns)/=0._r4) psf(ns) = psf(ns)*po2 (ns)

!
! Compute tau_dst_tot, tau_w_dst_tot, tau_w_g_dst_tot, and, tau_w_f_dst_tot
!
      do i=1,Nday

         frc_day(i) = 1.0_r4
         do kaer = 1, naer_groups
            aertau(i,ns,kaer) = 0.0
            aerssa(i,ns,kaer) = 0.0
            aerasm(i,ns,kaer) = 0.0
            aerfwd(i,ns,kaer) = 0.0
         end do
! 
! End do i=1,Nday
! 
      end do

      f_cphob  = gcphob(ns) * gcphob(ns)
      f_cb     = gcb(ns) * gcb(ns)
      f_volc   = gvolc(ns) * gvolc(ns)
      f_bg     = gbg(ns) * gbg(ns)
      f_dst(:) = gdst(:,ns) * gdst(:,ns)

!CSD$ PARALLEL DO PRIVATE( v_tau_dst_tot ) &
!CSD$ PRIVATE( v_tau_w_dst_tot, v_tau_w_g_dst_tot, v_tau_w_f_dst_tot, Tv_tau_dst, Tv_tau_w_dst, Tv_tau_w_g_dst ) &
!CSD$ PRIVATE( Tv_tau_w_f_dst, tmp1l, tmp2l, tmp3l, tmp1i, tmp2i, tmp3i, rhtrunc, krh, wrh, ksuli, ksslti ) &
!CSD$ PRIVATE( kcphili, wsuli, wsslti, wcphili, gsuli, gsslti, gcphili, tau_sul, tau_sslt, tau_cphil, tau_cphob ) &
!CSD$ PRIVATE( tau_cb, tau_volc, tau_bg, tau_w_sul, tau_w_sslt, tau_w_cphil, tau_w_cphob, tau_w_cb, tau_w_volc, tau_w_bg ) &
!CSD$ PRIVATE( tau_w_g_sul, tau_w_g_sslt, tau_w_g_cphil, tau_w_g_cphob, tau_w_g_cb, tau_w_g_volc, tau_w_g_bg, f_sul,f_sslt ) &
!CSD$ PRIVATE(  f_cphil, tau_w_f_sul, tau_w_f_bg, tau_w_f_sslt, tau_w_f_cphil, tau_w_f_cphob, tau_w_f_cb, tau_w_f_volc ) &
!CSD$ PRIVATE( tau_dst_tot, tau_w_dst_tot, tau_w_g_dst_tot, tau_w_f_dst_tot, w_dst_tot, g_dst_tot, f_dst_tot, tau_tot ) &
!CSD$ PRIVATE( tau_w_tot, tau_w_g_tot, tau_w_f_tot, w_tot, g_tot, f_tot, k, i, kk )
      do k=1,pver

!
! The following logicals are used to check to see whether we have invalid
! values for rhtrunc, g_tot, and f_tot.
! The above values are checked for every level of K and column of I.
! However, since the out of bounds conditions are *extremely* rare (in fact
! we abort the run if we find any one), let's reduce the number of 'if' tests
! by 1/K, and only check for aborting the run after scanning all Ks and Is.
!
         lrhtrunc_lt0(k) = .false.
         lg_tot_gt1(k)   = .false.
         lg_tot_ltm1(k)  = .false.
         lf_tot_gt1(k)   = .false.
         lf_tot_lt0(k)   = .false.

         
         v_tau_dst_tot(1:Nday)     = 0.0_r4
         v_tau_w_dst_tot(1:Nday)   = 0.0_r4
         v_tau_w_g_dst_tot(1:Nday) = 0.0_r4
         v_tau_w_f_dst_tot(1:Nday) = 0.0_r4


         do i=1,Nday
!cdir expand
            do kk = 1, ndstsz

               Tv_tau_dst           = 1.e4 * kdst(kk,ns) * udst(i,kk,k)
               Tv_tau_w_dst         = Tv_tau_dst         * wdst(kk,ns)
               Tv_tau_w_g_dst       = Tv_tau_w_dst       * gdst(kk,ns)
               Tv_tau_w_f_dst       = Tv_tau_w_dst       * f_dst(kk)

               v_tau_dst_tot(i)     = v_tau_dst_tot(i)     + Tv_tau_dst
               v_tau_w_dst_tot(i)   = v_tau_w_dst_tot(i)   + Tv_tau_w_dst
               v_tau_w_g_dst_tot(i) = v_tau_w_g_dst_tot(i) + Tv_tau_w_g_dst
               v_tau_w_f_dst_tot(i) = v_tau_w_f_dst_tot(i) + Tv_tau_w_f_dst

            end do
!
! End do i=1,Nday
!
         end do

         do i=1,Nday

! 
! liquid
! 

               tmp2l = 1._r4 - cbarli - dbarli*rel(i,k)
               tmp3l = fbarli*rel(i,k)
! 
! ice
! 

               tmp2i = 1._r4 - cbarii - dbarii*rei(i,k)
               tmp3i = fbarii*rei(i,k)

               if (cld(i,k) >= cldmin .and. cld(i,k) >= cldeps) then
! liquid
                  tmp1l = abarli + bbarli/rel(i,k)
! ice
                  tmp1i = abarii + bbarii/rei(i,k)
                  tauxcl(i,k) = cliqwp(i,k)*tmp1l
                  tauxci(i,k) = cicewp(i,k)*tmp1i
               else
                  tauxcl(i,k) = 0.0
                  tauxci(i,k) = 0.0
               endif
! 
! Do not let single scatter albedo be 1.  Delta-eddington solution
! for non-conservative case has different analytic form from solution
! for conservative case, and raddedmx is written for non-conservative case.
! 
               wcl(i,k) = min(tmp2l,.999999_r4)
               gcl(i,k) = ebarli + tmp3l
               fcl(i,k) = gcl(i,k)*gcl(i,k)
! 
               wci(i,k) = min(tmp2i,.999999_r4)
               gci(i,k) = ebarii + tmp3i
               fci(i,k) = gci(i,k)*gci(i,k)
! 
!bloss(2016-02-08): Compute optical properties of snow using parameterizations 
!    for cloud ice.  Add snow to ice values, scaling the single-scattering albedo,
!    asymmetry parameter and forward-scattering
               if( (res(i,k).gt.0.0_r4) .AND. (csnowp(i,k).gt.0.0_r4) )then

                 ! snow optical depth
                 tmp1i = abarii + bbarii/res(i,k)
                 tauxcs = csnowp(i,k)*tmp1i

                 ! snow single scattering albedo
                 tmp2i = 1._r4 - cbarii - dbarii*res(i,k)
                 wcs = min(tmp2i,.999999_r4)

                 ! snow asymmetry parameter
                 tmp3i = fbarii*res(i,k)
                 gcs = ebarii + tmp3i

                 ! snow forward scattering factor
                 fcs = gcs*gcs

                 ! weighted totals of snow/cloud ice optical properties
                 tautot = tauxci(i,k) + tauxcs
                 tauwcitot = tauxci(i,k)*wci(i,k) + tauxcs*wcs
                 tauwcigcitot = tauxci(i,k)*wci(i,k)*gci(i,k) &
                      + tauxcs*wcs*gcs
                 tauwcifcitot = tauxci(i,k)*wci(i,k)*gci(i,k)*fci(i,k) &
                      + tauxcs*wcs*gcs*fcs

                 ! combined snow/cloud ice optical properties
                 tauxci(i,k) = tautot
                 wci(i,k) = MIN( .999999_r4, &
                      tauwcitot/(TINY(1.) + tautot) )
                 gci(i,k) = tauwcigcitot / (TINY(1.) + tauwcitot)
                 fci(i,k) = tauwcifcitot / (TINY(1.) + tauwcitot)
               end if

! Set aerosol properties
! Conversion factor to adjust aerosol extinction (m2/g)
! 
               rhtrunc = rh(i,k)
               rhtrunc = min(rh(i,k),1._r4)
               if ( rhtrunc < 0.0_r4 ) lrhtrunc_lt0(k) = .true.
               krh = min(floor( rhtrunc * nrh ) + 1, nrh - 1)
               wrh = rhtrunc * nrh - krh

               ! linear interpolation of optical properties between rh table points
               ksuli = ksul(krh + 1, ns) * (wrh + 1) - ksul(krh, ns) * wrh
               ksslti = ksslt(krh + 1, ns) * (wrh + 1) - ksslt(krh, ns) * wrh
               kcphili = kcphil(krh + 1, ns) * (wrh + 1) - kcphil(krh, ns) * wrh
               wsuli = wsul(krh + 1, ns) * (wrh + 1) - wsul(krh, ns) * wrh
               wsslti = wsslt(krh + 1, ns) * (wrh + 1) - wsslt(krh, ns) * wrh
               wcphili = wcphil(krh + 1, ns) * (wrh + 1) - wcphil(krh, ns) * wrh
               gsuli = gsul(krh + 1, ns) * (wrh + 1) - gsul(krh, ns) * wrh
               gsslti = gsslt(krh + 1, ns) * (wrh + 1) - gsslt(krh, ns) * wrh
               gcphili = gcphil(krh + 1, ns) * (wrh + 1) - gcphil(krh, ns) * wrh

               tau_sul = 1.e4 * ksuli * usul(i,k)
               tau_sslt = 1.e4 * ksslti * usslt(i,k)
               tau_cphil = 1.e4 * kcphili * ucphil(i,k)
               tau_cphob = 1.e4 * kcphob(ns) * ucphob(i,k)
               tau_cb = 1.e4 * kcb(ns) * ucb(i,k)
               tau_volc = 1.e3 * kvolc(ns) * uvolc(i,k)
               tau_bg = 1.e4 * kbg(ns) * ubg(i,k)

               tau_w_sul = tau_sul * wsuli
               tau_w_sslt = tau_sslt * wsslti
               tau_w_cphil = tau_cphil * wcphili
               tau_w_cphob = tau_cphob * wcphob(ns)
               tau_w_cb = tau_cb * wcb(ns)
               tau_w_volc = tau_volc * wvolc(ns)
               tau_w_bg = tau_bg * wbg(ns)

               tau_w_g_sul = tau_w_sul * gsuli
               tau_w_g_sslt = tau_w_sslt * gsslti
               tau_w_g_cphil = tau_w_cphil * gcphili
               tau_w_g_cphob = tau_w_cphob * gcphob(ns)
               tau_w_g_cb = tau_w_cb * gcb(ns)
               tau_w_g_volc = tau_w_volc * gvolc(ns)
               tau_w_g_bg = tau_w_bg * gbg(ns)

               f_sul = gsuli * gsuli
               f_sslt = gsslti * gsslti
               f_cphil = gcphili * gcphili

               tau_w_f_sul = tau_w_sul * f_sul
               tau_w_f_bg = tau_w_bg * f_bg
               tau_w_f_sslt = tau_w_sslt * f_sslt
               tau_w_f_cphil = tau_w_cphil * f_cphil
               tau_w_f_cphob = tau_w_cphob * f_cphob
               tau_w_f_cb = tau_w_cb * f_cb
               tau_w_f_volc = tau_w_volc * f_volc
!
! mix dust aerosol size bins
!   w_dst_tot, g_dst_tot, w_dst_tot are currently not used anywhere
!   but calculate them anyway for future use
!
               tau_dst_tot     = v_tau_dst_tot(i)
               tau_w_dst_tot   = v_tau_w_dst_tot(i)
               tau_w_g_dst_tot = v_tau_w_g_dst_tot(i)
               tau_w_f_dst_tot = v_tau_w_f_dst_tot(i)

               if (tau_dst_tot .gt. 0.0) then
                 w_dst_tot = tau_w_dst_tot / tau_dst_tot
               else
                 w_dst_tot = 0.0
               endif

               if (tau_w_dst_tot .gt. 0.0) then
                 g_dst_tot = tau_w_g_dst_tot / tau_w_dst_tot
                 f_dst_tot = tau_w_f_dst_tot / tau_w_dst_tot
               else
                 g_dst_tot = 0.0
                 f_dst_tot = 0.0
               endif
!
! mix aerosols
!
               tau_tot     = tau_sul + tau_sslt &
                           + tau_cphil + tau_cphob + tau_cb + tau_dst_tot
               tau_tot     = tau_tot + tau_bg + tau_volc

               tau_w_tot   = tau_w_sul + tau_w_sslt &
                           + tau_w_cphil + tau_w_cphob + tau_w_cb + tau_w_dst_tot
               tau_w_tot   = tau_w_tot + tau_w_bg + tau_w_volc

               tau_w_g_tot = tau_w_g_sul + tau_w_g_sslt &
                           + tau_w_g_cphil + tau_w_g_cphob + tau_w_g_cb + tau_w_g_dst_tot
               tau_w_g_tot = tau_w_g_tot + tau_w_g_bg + tau_w_g_volc

               tau_w_f_tot = tau_w_f_sul + tau_w_f_sslt &
                           + tau_w_f_cphil + tau_w_f_cphob + tau_w_f_cb + tau_w_f_dst_tot
               tau_w_f_tot = tau_w_f_tot + tau_w_f_bg + tau_w_f_volc

               if (tau_tot .gt. 0.0) then
                 w_tot = tau_w_tot / tau_tot
               else
                 w_tot = 0.0
               endif

               if (tau_w_tot .gt. 0.0) then
                 g_tot = tau_w_g_tot / tau_w_tot
                 f_tot = tau_w_f_tot / tau_w_tot
               else
                 g_tot = 0.0
                 f_tot = 0.0
               endif

               if ( g_tot > 1.0_r4 )  lg_tot_gt1(k)  = .true.
               if ( g_tot < -1.0_r4 ) lg_tot_ltm1(k) = .true.
               if ( f_tot > 1.0_r4 )  lf_tot_gt1(k)  = .true.
               if ( f_tot < 0.0_r4 )  lf_tot_lt0(k)  = .true.

               tauxar(i,k) = tau_tot
               wa(i,k)     = min(w_tot, 0.999999_r4)
               ga(i,k)     = g_tot
               fa(i,k)     = f_tot

               aertau(i,ns,1) = aertau(i,ns,1) + tau_sul
               aertau(i,ns,2) = aertau(i,ns,2) + tau_sslt
               aertau(i,ns,3) = aertau(i,ns,3) + tau_cphil + tau_cphob + tau_cb
               aertau(i,ns,4) = aertau(i,ns,4) + tau_dst_tot
               aertau(i,ns,5) = aertau(i,ns,5) + tau_bg
               aertau(i,ns,6) = aertau(i,ns,6) + tau_volc
               aertau(i,ns,7) = aertau(i,ns,7) + tau_tot

               aerssa(i,ns,1) = aerssa(i,ns,1) + tau_w_sul
               aerssa(i,ns,2) = aerssa(i,ns,2) + tau_w_sslt
               aerssa(i,ns,3) = aerssa(i,ns,3) + tau_w_cphil + tau_w_cphob + tau_w_cb
               aerssa(i,ns,4) = aerssa(i,ns,4) + tau_w_dst_tot
               aerssa(i,ns,5) = aerssa(i,ns,5) + tau_w_bg
               aerssa(i,ns,6) = aerssa(i,ns,6) + tau_w_volc
               aerssa(i,ns,7) = aerssa(i,ns,7) + tau_w_tot

               aerasm(i,ns,1) = aerasm(i,ns,1) + tau_w_g_sul
               aerasm(i,ns,2) = aerasm(i,ns,2) + tau_w_g_sslt
               aerasm(i,ns,3) = aerasm(i,ns,3) + tau_w_g_cphil + tau_w_g_cphob + tau_w_g_cb
               aerasm(i,ns,4) = aerasm(i,ns,4) + tau_w_g_dst_tot
               aerasm(i,ns,5) = aerasm(i,ns,5) + tau_w_g_bg
               aerasm(i,ns,6) = aerasm(i,ns,6) + tau_w_g_volc
               aerasm(i,ns,7) = aerasm(i,ns,7) + tau_w_g_tot

               aerfwd(i,ns,1) = aerfwd(i,ns,1) + tau_w_f_sul
               aerfwd(i,ns,2) = aerfwd(i,ns,2) + tau_w_f_sslt
               aerfwd(i,ns,3) = aerfwd(i,ns,3) + tau_w_f_cphil + tau_w_f_cphob + tau_w_f_cb
               aerfwd(i,ns,4) = aerfwd(i,ns,4) + tau_w_f_dst_tot
               aerfwd(i,ns,5) = aerfwd(i,ns,5) + tau_w_f_bg
               aerfwd(i,ns,6) = aerfwd(i,ns,6) + tau_w_f_volc
               aerfwd(i,ns,7) = aerfwd(i,ns,7) + tau_w_f_tot

! 
! End do i=1,Nday
! 
         end do
! 
! End do k=1,pver
! 
      end do
!CSD$ END PARALLEL 

      if (any( lrhtrunc_lt0(:) )) then
         write(6,*) "rhtrunc < 0.0"
         call endrun('RADCSWMX')
      end if
      if (any( lg_tot_gt1(:) )) then
         write(6,*) "g_tot > 1.0"
         call endrun('RADCSWMX')
      end if
      if (any( lg_tot_ltm1(:) )) then
         write(6,*) "g_tot < -1.0"
         call endrun('RADCSWMX')
      end if
      if (any( lf_tot_gt1(:) )) then
         write(6,*) "f_tot > 1.0"
         call endrun('RADCSWMX')
      end if
      if (any( lf_tot_lt0(:) )) then
         write(6,*) "f_tot < 0.0"
         call endrun('RADCSWMX')
      end if


         ! normalize aerosol optical diagnostic fields
      do kaer = 1, naer_groups

         do i=1,Nday


               if (aerssa(i,ns,kaer) .gt. 0.0) then   ! aerssa currently holds product of tau and ssa
                  aerasm(i,ns,kaer) = aerasm(i,ns,kaer) / aerssa(i,ns,kaer)
                  aerfwd(i,ns,kaer) = aerfwd(i,ns,kaer) / aerssa(i,ns,kaer)
               else
                  aerasm(i,ns,kaer) = 0.0_r4
                  aerfwd(i,ns,kaer) = 0.0_r4
               end if

               if (aertau(i,ns,kaer) .gt. 0.0) then
                  aerssa(i,ns,kaer) = aerssa(i,ns,kaer) / aertau(i,ns,kaer)
               else
                  aerssa(i,ns,kaer) = 0.0_r4
               end if

! 
! End do i=1,Nday
! 
         end do
!
! End do kaer = 1, naer_groups
!

      end do

! 
! Set reflectivities for surface based on mid-point wavelength
! 
      wavmid(ns) = 0.5_r4*(wavmin(ns) + wavmax(ns))
! 
! Wavelength less  than 0.7 micro-meter
! 
      if (wavmid(ns) < 0.7_r4 ) then
         do i=1,Nday
               albdir(i,ns) = asdir(i)
               albdif(i,ns) = asdif(i)
         end do
! 
! Wavelength greater than 0.7 micro-meter
! 
      else
         do i=1,Nday
               albdir(i,ns) = aldir(i)
               albdif(i,ns) = aldif(i)
         end do
      end if
      trayoslp = raytau(ns)/sslp
! 
! Layer input properties now completely specified; compute the
! delta-Eddington solution reflectivities and transmissivities
! for each layer
! 
      call raddedmx(coszrs   ,Nday    , &
              abh2o(ns),abo3(ns) ,abco2(ns),abo2(ns) , &
              uh2o     ,uo3      ,uco2     ,uo2      , &
              trayoslp ,pflx     ,ns       , &
              tauxcl   ,wcl      ,gcl      ,fcl      , &
              tauxci   ,wci      ,gci      ,fci      , &
              tauxar   ,wa       ,ga       ,fa       , &
              rdir     ,rdif     ,tdir     ,tdif     ,explay  , &
              rdirc    ,rdifc    ,tdirc    ,tdifc    ,explayc )
! 
! End spectral loop
! 
   end do
! 
!----------------------------------------------------------------------
! 
! Solution for max/random cloud overlap.  
! 
! Steps:
! (1. delta-Eddington solution for each layer (called above)
! 
! (2. The adding method is used to
! compute the reflectivity and transmissivity to direct and diffuse
! radiation from the top and bottom of the atmosphere for each
! cloud configuration.  This calculation is based upon the
! max-random overlap assumption.
! 
! (3. to solve for the fluxes, combine the
! bulk properties of the atmosphere above/below the region.
! 
! Index calculations for steps 2-3 are performed outside spectral
! loop to avoid redundant calculations.  Index calculations (with
! application of areamin & nconfgmax conditions) are performed 
! first to identify the minimum subset of terms for the configurations 
! satisfying the areamin & nconfgmax conditions. This minimum set is 
! used to identify the corresponding minimum subset of terms in 
! steps 2 and 3.
! 
   do iconfig = 1, nconfgmax
      ccon(iconfig,0,1:Nday)      = 0
      ccon(iconfig,pverp,1:Nday)  = 0

      icond(iconfig,0,1:Nday)     = iconfig
      iconu(iconfig,pverp,1:Nday) = iconfig
   end do
! 
! Construction of nuniqu/d, istrtu/d, iconu/d using binary tree 
! 
         nuniqd(0,1:Nday) = 1
         nuniqu(pverp,1:Nday) = 1

         istrtd(1,0,1:Nday) = 1
         istrtu(1,pverp,1:Nday) = 1


!CSD$ PARALLEL DO PRIVATE( npasses, kx2, mrgn, region_found, k1, k2, kx1, nxs, ksort, asort ) &
!CSD$ PRIVATE ( ktmp, atmp, cstr, mstr, nstr, cld0, wstr, nrgn, nconfigm, istr, new_term, xwgt ) &
!CSD$ PRIVATE ( j, ptrc, wgtv, km1, nuniq, is0, is1, n0, n1, ptr0, ptr1, kp1, i, irgn ) &
!CSD$ PRIVATE ( k, l, iconfig, l0, isn )
   do i=1,Nday

!----------------------------------------------------------------------
! INDEX CALCULATIONS FOR MAX OVERLAP
! 
! The column is divided into sets of adjacent layers, called regions, 
! in which the clouds are maximally overlapped.  The clouds are
! randomly overlapped between different regions.  The number of
! regions in a column is set by nmxrgn, and the range of pressures
! included in each region is set by pmxrgn.  
! 
! The following calculations determine the number of unique cloud 
! configurations (assuming maximum overlap), called "streams",
! within each region. Each stream consists of a vector of binary
! clouds (either 0 or 100% cloud cover).  Over the depth of the region, 
! each stream requires a separate calculation of radiative properties. These
! properties are generated using the adding method from
! the radiative properties for each layer calculated by raddedmx.
! 
! The upward and downward-propagating streams are treated
! separately.
! 
! We will refer to a particular configuration of binary clouds
! within a single max-overlapped region as a "stream".  We will 
! refer to a particular arrangement of binary clouds over the entire column
! as a "configuration".
! 
! This section of the code generates the following information:
! (1. nrgn    : the true number of max-overlap regions (need not = nmxrgn)
! (2. nstr    : the number of streams in a region (>=1)
! (3. cstr    : flags for presence of clouds at each layer in each stream
! (4. wstr    : the fractional horizontal area of a grid box covered
! by each stream
! (5. kx1,2   : level indices for top/bottom of each region
! 
! The max-overlap calculation proceeds in 3 stages:
! (1. compute layer radiative properties in raddedmx.
! (2. combine these properties between layers 
! (3. combine properties to compute fluxes at each interface.  
! 
! Most of the indexing information calculated here is used in steps 2-3
! after the call to raddedmx.
! 
! Initialize indices for layers to be max-overlapped
! 
! Loop to handle fix in totwgt=0. For original overlap config 
! from npasses = 0.
! 
         npasses = 0
         do
!cdir novector
            do irgn = 0, nmxrgn(i)
               kx2(irgn) = 0
            end do
            mrgn = 0
! 
! Outermost loop over regions (sets of adjacent layers) to be max overlapped
! 
            do irgn = 1, nmxrgn(i)
! 
! Calculate min/max layer indices inside region.  
! 
               region_found = .false.
               if (kx2(irgn-1) < pver) then
                  k1 = kx2(irgn-1)+1
                  kx1(irgn) = k1
                  kx2(irgn) = k1-1
!cdir novector
                  do k2 = pver, k1, -1
                     if (pmid(i,k2) <= pmxrgn(i,irgn)) then
                        kx2(irgn) = k2
                        mrgn = mrgn+1
                        region_found = .true.
                        exit
                     end if
                  end do
               else
                  exit
               endif

               if (region_found) then
! 
! Sort cloud areas and corresponding level indices.  
! 
                  nxs = 0
                  if (cldeps > 0) then 
                     do k = k1,k2
                        if (cld(i,k) >= cldmin .and. cld(i,k) >= cldeps) then
                           nxs = nxs+1
                           ksort(nxs) = k
! 
! We need indices for clouds in order of largest to smallest, so
! sort 1-cld in ascending order
! 
                           asort(nxs) = 1.0_r4-(floor(cld(i,k)/cldeps)*cldeps)
                        end if
                     end do
                  else
!cdir novector
                     do k = k1,k2
                        if (cld(i,k) >= cldmin) then
                           nxs = nxs+1
                           ksort(nxs) = k
! 
! We need indices for clouds in order of largest to smallest, so
! sort 1-cld in ascending order
! 
                           asort(nxs) = 1.0_r4-cld(i,k)
                        end if
                     end do
                  endif
! 
! If nxs eq 1, no need to sort. 
! If nxs eq 2, sort by swapping if necessary
! If nxs ge 3, sort using local sort routine
! 
                  if (nxs == 2) then
                     if (asort(2) < asort(1)) then
                        ktmp = ksort(1)
                        ksort(1) = ksort(2)
                        ksort(2) = ktmp

                        atmp = asort(1)
                        asort(1) = asort(2)
                        asort(2) = atmp
                     endif
                  else if (nxs >= 3) then
                     call quick_sort(asort(1:nxs),ksort(1:nxs))
                  endif
! 
! Construct wstr, cstr, nstr for this region
! 
!cdir novector
                  cstr(k1:k2,1:nxs+1) = 0
                  mstr = 1
                  cld0 = 0.0_r4
                  do l = 1, nxs
                     if (asort(l) /= cld0) then
                        wstr(mstr,mrgn) = asort(l) - cld0
                        cld0 = asort(l)
                        mstr = mstr + 1
                     endif
!cdir novector
                     cstr(ksort(l),mstr:nxs+1) = 1
                  end do
                  nstr(mrgn) = mstr
                  wstr(mstr,mrgn) = 1.0_r4 - cld0
! 
! End test of region_found = true
! 
               endif
! 
! End loop over regions irgn for max-overlap
! 
            end do
            nrgn = mrgn
! 
! Finish construction of cstr for additional top layer
! 
!cdir novector
            cstr(0,1:nstr(1)) = 0
! 
! INDEX COMPUTATIONS FOR STEP 2-3
! This section of the code generates the following information:
! (1. totwgt     step 3     total frac. area of configurations satisfying
! areamin & nconfgmax criteria
! (2. wgtv       step 3     frac. area of configurations 
! (3. ccon       step 2     binary flag for clouds in each configuration
! (4. nconfig    steps 2-3  number of configurations
! (5. nuniqu/d   step 2     Number of unique cloud configurations for
! up/downwelling rad. between surface/TOA
! and level k
! (6. istrtu/d   step 2     Indices into iconu/d
! (7. iconu/d    step 2     Cloud configurations which are identical
! for up/downwelling rad. between surface/TOA
! and level k
! 
! Number of configurations (all permutations of streams in each region)
! 
            nconfigm = product(nstr(1: nrgn))
! 
! Construction of totwgt, wgtv, ccon, nconfig
! 
!cdir novector
            istr(1: nrgn) = 1
            nconfig(i) = 0
            totwgt(i) = 0.0_r4
            new_term = .true.
            do iconfig = 1, nconfigm
               xwgt = 1.0_r4
!cdir novector
               do mrgn = 1,  nrgn
                  xwgt = xwgt * wstr(istr(mrgn),mrgn)
               end do
               if (xwgt >= areamin) then
                  nconfig(i) = nconfig(i) + 1
                  if (nconfig(i) <= nconfgmax) then
                     j = nconfig(i)
                     ptrc(nconfig(i)) = nconfig(i)
                  else
                     nconfig(i) = nconfgmax
                     if (new_term) then
                        min_idx = minloc(wgtv)
                        j = min_idx(1)
                     endif
                     if (wgtv(j) < xwgt) then
                        totwgt(i) = totwgt(i) - wgtv(j)
                        new_term = .true.
                     else
                        new_term = .false.
                     endif
                  endif
                  if (new_term) then
                     wgtv(j) = xwgt
                     totwgt(i) = totwgt(i) + xwgt
!cdir novector
                     do mrgn = 1, nrgn
!cdir novector
                        ccon(j,kx1(mrgn):kx2(mrgn),i) = cstr(kx1(mrgn):kx2(mrgn),istr(mrgn))
                     end do
                  endif
               endif

               mrgn =  nrgn
               istr(mrgn) = istr(mrgn) + 1
               do while (istr(mrgn) > nstr(mrgn) .and. mrgn > 1)
                  istr(mrgn) = 1
                  mrgn = mrgn - 1
                  istr(mrgn) = istr(mrgn) + 1
               end do
! 
! End do iconfig = 1, nconfigm
! 
            end do
! 
! If totwgt(i) = 0 implement maximum overlap and make another pass
! if totwgt(i) = 0 on this second pass then terminate.
! 
            if (totwgt(i) > 0.) then
               exit
            else
               npasses = npasses + 1
               if (npasses >= 2 ) then
                  write(6,*)'RADCSWMX: Maximum overlap of column ','failed'
                  call endrun('RADCSWMX')
               endif
               nmxrgn(i)=1
               pmxrgn(i,1)=1.0e30
            end if
!
! End npasses = 0, do
!
         end do
! 
! Finish construction of ccon
! 

         istrtd(2,0,i) = nconfig(i)+1
         istrtu(2,pverp,i) = nconfig(i)+1

         do k = 1, pverp
            km1 = k-1
            nuniq = 0
            istrtd(1,k,i) = 1
!cdir novector
            do l0 = 1, nuniqd(km1,i)
               is0 = istrtd(l0,km1,i)
               is1 = istrtd(l0+1,km1,i)-1
               n0 = 0
               n1 = 0
!cdir novector
               do isn = is0, is1
                  j = icond(isn,km1,i)
                  if (ccon(j,k,i) == 0) then
                     n0 = n0 + 1
                     ptr0(n0) = j
                  else       ! if (ccon(j,k,i) == 1) then
                     n1 = n1 + 1
                     ptr1(n1) = j
                  endif
               end do
               if (n0 > 0) then
                  nuniq = nuniq + 1
                  istrtd(nuniq+1,k,i) = istrtd(nuniq,k,i)+n0
!cdir novector
                  icond(istrtd(nuniq,k,i):istrtd(nuniq+1,k,i)-1,k,i) =  ptr0(1:n0)
               endif
               if (n1 > 0) then
                  nuniq = nuniq + 1
                  istrtd(nuniq+1,k,i) = istrtd(nuniq,k,i)+n1
!cdir novector
                  icond(istrtd(nuniq,k,i):istrtd(nuniq+1,k,i)-1,k,i) =  ptr1(1:n1)
               endif
            end do
            nuniqd(k,i) = nuniq
         end do
!
!  Find 'transition point' in downward configurations where the number
!  of 'configurations' changes from 1.  This is used to optimize the
!  construction of the upward configurations.
!  Note: k1 == transition point
!

         do k = pverp,0,-1
           if ( nuniqd(k,i) == 1) then
              k1 = k
              exit
           end if
         end do

         do k = pver, k1+1,-1
            kp1 = k+1
            nuniq = 0
            istrtu(1,k,i) = 1
!cdir novector
            do l0 = 1, nuniqu(kp1,i)
               is0 = istrtu(l0,kp1,i)
               is1 = istrtu(l0+1,kp1,i)-1
               n0 = 0
               n1 = 0
!cdir novector
               do isn = is0, is1
                  j = iconu(isn,kp1,i)
                  if (ccon(j,k,i) == 0) then
                     n0 = n0 + 1
                     ptr0(n0) = j
                  else       ! if (ccon(j,k,i) == 1) then
                     n1 = n1 + 1
                     ptr1(n1) = j
                  endif
               end do
               if (n0 > 0) then
                  nuniq = nuniq + 1
                  istrtu(nuniq+1,k,i) = istrtu(nuniq,k,i)+n0
!cdir novector
                  iconu(istrtu(nuniq,k,i):istrtu(nuniq+1,k,i)-1,k,i) =  ptr0(1:n0)
               endif
               if (n1 > 0) then
                  nuniq = nuniq + 1
                  istrtu(nuniq+1,k,i) = istrtu(nuniq,k,i)+n1
!cdir novector
                  iconu(istrtu(nuniq,k,i):istrtu(nuniq+1,k,i)-1,k,i) = ptr1(1:n1)
               endif
            end do
            nuniqu(k,i) = nuniq
         end do
!
!  Copy identical configurations from 'transition point' to surface.
!
         k1 = min(pverp-1,k1)
         nuniq = nuniqu(k1+1,i)
         do k = k1,0,-1
            nuniqu(k,i) = nuniq
!cdir novector
            iconu(1:nuniq,k,i) = iconu(1:nuniq,k1+1,i)
!cdir novector
            istrtu(1:nuniq+1,k,i) = istrtu(1:nuniq+1,k1+1,i)
         end do

!cdir novector
         v_wgtv(1:nconfig(i),i) = wgtv(1:nconfig(i))

! 
!----------------------------------------------------------------------
! End of index calculations
!----------------------------------------------------------------------
! 
! End do i=1,Nday
! 
   end do
!CSD$ END PARALLEL 

!----------------------------------------------------------------------
! Start of flux calculations
!----------------------------------------------------------------------
!
! Initialize spectrally integrated totals:
! 
         totfld(1:Nday,0:pver) = 0.0_r4
         fswup (1:Nday,0:pver) = 0.0_r4
         fswdn (1:Nday,0:pver) = 0.0_r4

         sfltot(1:Nday)        = 0.0_r4
         fswup (1:Nday,pverp)  = 0.0_r4
         fswdn (1:Nday,pverp)  = 0.0_r4
! 
! Start spectral interval
! 
!old   do ns = 1,nspint
!old     wgtint = nirwgt(ns)

     do i=1,Nday

!----------------------------------------------------------------------
! STEP 2
! 
! 
! Apply adding method to solve for radiative properties
! 
! first initialize the bulk properties at toa
! 

! nspint, 0:pverp, nconfgmax, pcols

            rdndif(:,0,1:nconfig(i),i) = 0.0_r4
            exptdn(:,0,1:nconfig(i),i) = 1.0_r4
            tdntot(:,0,1:nconfig(i),i) = 1.0_r4
! 
! End do i=1,Nday
! 
     end do
! 
! solve for properties involving downward propagation of radiation.
! the bulk properties are:
! 
! (1. exptdn   sol. beam dwn. trans from layers above
! (2. rdndif   ref to dif rad for layers above
! (3. tdntot   total trans for layers above
! 

!CSD$ PARALLEL DO PRIVATE( km1, is0, is1, j, jj, Ttdif, Trdif, Trdir, Ttdir, Texplay ) &
!CSD$ PRIVATE( xexpt, xrdnd, tdnmexp,  ytdnd, yrdnd, rdenom, rdirexp, zexpt, zrdnd, ztdnt ) &
!CSD$ PRIVATE( i, k, l0, ns, isn )
         do i = 1, Nday
            do k = 1, pverp
               km1 = k - 1
!cdir nodep
               do l0 = 1, nuniqd(km1,i)
                  is0 = istrtd(l0,km1,i)
                  is1 = istrtd(l0+1,km1,i)-1

                  j = icond(is0,km1,i)

! 
! If cloud in layer, use cloudy layer radiative properties (ccon == 1)
! If clear layer, use clear-sky layer radiative properties (ccon /= 1)
! 
                  if ( ccon(j,km1,i) == 1 ) then
                     Ttdif(:) = tdif(:,i,km1)
                     Trdif(:) = rdif(:,i,km1)
                     Trdir(:) = rdir(:,i,km1)
                     Ttdir(:) = tdir(:,i,km1)
                     Texplay(:) = explay(:,i,km1)
                  else
                     Ttdif(:) = tdifc(:,i,km1)
                     Trdif(:) = rdifc(:,i,km1)
                     Trdir(:) = rdirc(:,i,km1)
                     Ttdir(:) = tdirc(:,i,km1)
                     Texplay(:) = explayc(:,i,km1)
                  end if

                  do ns = 1, nspint
                  xexpt   = exptdn(ns,km1,j,i)
                  xrdnd   = rdndif(ns,km1,j,i)
                  tdnmexp = tdntot(ns,km1,j,i) - xexpt

                  ytdnd = Ttdif(ns)
                  yrdnd = Trdif(ns)

                  rdenom  = 1._r4/(1._r4-yrdnd*xrdnd)
                  rdirexp = Trdir(ns)*xexpt

                  zexpt = xexpt * Texplay(ns)
                  zrdnd = yrdnd + xrdnd*(ytdnd**2)*rdenom
                  ztdnt = xexpt*Ttdir(ns) + ytdnd* &
                          (tdnmexp + xrdnd*rdirexp)*rdenom

                  exptdn(ns,k,j,i) = zexpt
                  rdndif(ns,k,j,i) = zrdnd
                  tdntot(ns,k,j,i) = ztdnt
                  end do ! ns = 1, nspint
!
! If 2 or more configurations share identical properties at a given level k,
! the properties (at level k) are computed once and copied to
! all the configurations for efficiency.
!
                  do isn = is0+1, is1
                     jj = icond(isn,km1,i)
                     exptdn(:,k,jj,i) = exptdn(:,k,j,i)
                     rdndif(:,k,jj,i) = rdndif(:,k,j,i)
                     tdntot(:,k,jj,i) = tdntot(:,k,j,i)
                  end do

! 
! end do l0 = 1, nuniqd(k,i)
! 
               end do
! 
! end do k = 1, pverp
! 
            end do
! 
! end do i = 1, Nday
! 
         end do
!CSD$ END PARALLEL 
! 
! Solve for properties involving upward propagation of radiation.
! The bulk properties are:
! 
! (1. rupdif   Ref to dif rad for layers below
! (2. rupdir   Ref to dir rad for layers below
! 
! Specify surface boundary conditions (surface albedos)
! 

! nspint, 0:pverp, nconfgmax, pcols
   rupdir = 0._r4
   rupdif = 0._r4
   do i = 1, Nday
      do ns = 1, nspint
         rupdir(ns,pverp,1:nconfig(i),i) = albdir(i,ns)
         rupdif(ns,pverp,1:nconfig(i),i) = albdif(i,ns)
      end do
   end do

         do i = 1, Nday
            do k = pver, 0, -1
               do l0 = 1, nuniqu(k,i)
                  is0 = istrtu(l0,k,i)
                  is1 = istrtu(l0+1,k,i)-1

                  j = iconu(is0,k,i)

! 
! If cloud in layer, use cloudy layer radiative properties (ccon == 1)
! If clear layer, use clear-sky layer radiative properties (ccon /= 1)
! 
                  if ( ccon(j,k,i) == 1 ) then
                     Ttdif(:) = tdif(:,i,k)
                     Trdif(:) = rdif(:,i,k)
                     Trdir(:) = rdir(:,i,k)
                     Ttdir(:) = tdir(:,i,k)
                     Texplay(:) = explay(:,i,k)
                  else
                     Ttdif(:) = tdifc(:,i,k)
                     Trdif(:) = rdifc(:,i,k)
                     Trdir(:) = rdirc(:,i,k)
                     Ttdir(:) = tdirc(:,i,k)
                     Texplay(:) = explayc(:,i,k)
                  end if

                  do ns = 1, nspint
                  xrupd = rupdif(ns,k+1,j,i)
                  xrups = rupdir(ns,k+1,j,i)

! 
! If cloud in layer, use cloudy layer radiative properties (ccon == 1)
! If clear layer, use clear-sky layer radiative properties (ccon /= 1)
! 
                  yexpt = Texplay(ns)
                  yrupd = Trdif(ns)
                  ytupd = Ttdif(ns)

                  rdenom  = 1._r4/( 1._r4 - yrupd*xrupd)
                  tdnmexp = (Ttdir(ns)-yexpt)
                  rdirexp = xrups*yexpt

                  zrupd = yrupd + xrupd*(ytupd**2)*rdenom
                  zrups = Trdir(ns) + ytupd*(rdirexp + xrupd*tdnmexp)*rdenom

                  rupdif(ns,k,j,i) = zrupd
                  rupdir(ns,k,j,i) = zrups
                  end do ! ns = 1, nspint
!
! If 2 or more configurations share identical properties at a given level k,
! the properties (at level k) are computed once and copied to
! all the configurations for efficiency.
!
                  do isn = is0+1, is1
                     jj = iconu(isn,k,i)
                     rupdif(:,k,jj,i) = rupdif(:,k,j,i)
                     rupdir(:,k,jj,i) = rupdir(:,k,j,i)
                  end do

! 
! end do l0 = 1, nuniqu(k,i)
! 
               end do
! 
! end do k = pver,0,-1
! 
            end do
! 
! end do i = 1, Nday
! 
         end do
! 
!----------------------------------------------------------------------
! 
! STEP 3
! 
! Compute up and down fluxes for each interface k.  This requires
! adding up the contributions from all possible permutations
! of streams in all max-overlap regions, weighted by the
! product of the fractional areas of the streams in each region
! (the random overlap assumption).  The adding principle has been
! used in step 2 to combine the bulk radiative properties 
! above and below the interface.
! 

! 
! Initialize the fluxes
! 
            fluxup = 0.0_r4
            fluxdn = 0.0_r4

            do i = 1, Nday
!cdir novector
            do iconfig = 1, nconfig(i)
               xwgt = v_wgtv(iconfig,i)

!cdir collapse
               do k = 0, pverp
                  do ns = 1, nspint
                  xexpt = exptdn(ns,k,iconfig,i)
                  xtdnt = tdntot(ns,k,iconfig,i)
                  xrdnd = rdndif(ns,k,iconfig,i)
                  xrupd = rupdif(ns,k,iconfig,i)
                  xrups = rupdir(ns,k,iconfig,i)
! 
! Flux computation
! 
                  rdenom = 1._r4/(1._r4 - xrdnd * xrupd)

                  fluxup(ns,k,i) = fluxup(ns,k,i) + xwgt *  &
                              ((xexpt * xrups + (xtdnt - xexpt) * xrupd) * rdenom)
                  fluxdn(ns,k,i) = fluxdn(ns,k,i) + xwgt *  &
                              (xexpt + (xtdnt - xexpt + xexpt * xrups * xrdnd) * rdenom)
                  end do ! do ns = 1, nspint
               end do
! 
! End do iconfig = 1, nconfig(i)
! 
            end do
! 
! End do iconfig = 1, Nday
! 
            end do
! 
! Normalize by total area covered by cloud configurations included
! in solution
! 
!bloss#ifdef JPE_VMATH
!bloss            call vrec(v_rtotwgt,totwgt,Nday)
!bloss#endif
            do i = 1, Nday
            do k = 0, pverp
            do ns = 1, nspint
!bloss#ifdef JPE_VMATH
!bloss               fluxup(ns,k,i)=fluxup(ns,k,i) * v_rtotwgt(i)
!bloss               fluxdn(ns,k,i)=fluxdn(ns,k,i) * v_rtotwgt(i)
!bloss#else
               fluxup(ns,k,i)=fluxup(ns,k,i) / totwgt(i)
               fluxdn(ns,k,i)=fluxdn(ns,k,i) / totwgt(i)
!bloss#endif
            end do ! do i = 1, nday
            end do ! do k = 0, pverp
            end do ! do i = 1, nday


! 
! Initialize the direct-beam flux at surface
! 
            wexptdn(:,1:Nday) = 0.0_r4

   do ns = 1,nspint
     wgtint = nirwgt(ns)


            do i=1,Nday
            do iconfig = 1, nconfig(i)
!
! Note: exptdn can be directly indexed by iconfig at k=pverp.
!
               wexptdn(ns,i) =  wexptdn(ns,i) + v_wgtv(iconfig,i) * exptdn(ns,pverp,iconfig,i)
            end do
            end do

            do i=1,Nday
!bloss#ifdef JPE_VMATH
!bloss               wexptdn(ns,i) = wexptdn(ns,i) * v_rtotwgt(i)
!bloss#else
               wexptdn(ns,i) = wexptdn(ns,i) / totwgt(i)
!bloss#endif
! 
! Monochromatic computation completed; accumulate in totals
! 
            solflx(i)   = solin(i)*frcsol(ns)*psf(ns)
            fsnt(i)  = fsnt(i) + solflx(i)*(fluxdn(ns,1,i) - fluxup(ns,1,i))
            fsntoa(i)= fsntoa(i) + solflx(i)*(fluxdn(ns,0,i) - fluxup(ns,0,i))
            fsns(i)  = fsns(i) + solflx(i)*(fluxdn(ns,pverp,i)-fluxup(ns,pverp,i))
            sfltot(i)   = sfltot(i) + solflx(i)
            fswup(i,0) = fswup(i,0) + solflx(i)*fluxup(ns,0,i)
            fswdn(i,0) = fswdn(i,0) + solflx(i)*fluxdn(ns,0,i)
! 
! Down spectral fluxes need to be in mks; thus the .001 conversion factors
! 
            if (wavmid(ns) < 0.7_r4) then
               sols(i)  = sols(i) + wexptdn(ns,i)*solflx(i)*0.001_r4
               solsd(i) = solsd(i)+(fluxdn(ns,pverp,i)-wexptdn(ns,i))*solflx(i)*0.001_r4 
            else
               soll(i)  = soll(i) + wexptdn(ns,i)*solflx(i)*0.001_r4
               solld(i) = solld(i)+(fluxdn(ns,pverp,i)-wexptdn(ns,i))*solflx(i)*0.001_r4 
               fsnrtoaq(i) = fsnrtoaq(i) + solflx(i)*(fluxdn(ns,0,i) - fluxup(ns,0,i))
            end if
            fsnirtoa(i) = fsnirtoa(i) + wgtint*solflx(i)*(fluxdn(ns,0,i) - fluxup(ns,0,i))

! 
! End do i=1,Nday
! 
   end do


            do k=0,pver
            do i=1,Nday
! 
! Compute flux divergence in each layer using the interface up and down
! fluxes:
! 
               kp1 = k+1
               flxdiv = (fluxdn(ns,k,i) - fluxdn(ns,kp1,i)) + (fluxup(ns,kp1,i) - fluxup(ns,k,i))
               totfld(i,k)  = totfld(i,k)  + solflx(i)*flxdiv
               fswdn(i,kp1) = fswdn(i,kp1) + solflx(i)*fluxdn(ns,kp1,i)
               fswup(i,kp1) = fswup(i,kp1) + solflx(i)*fluxup(ns,kp1,i)
               fns(i,kp1)   = fswdn(i,kp1) - fswup(i,kp1)
            end do
            end do
! 
! Perform clear-sky calculation
! 

            exptdnc(1:Nday,0) =   1.0_r4
            rdndifc(1:Nday,0) =   0.0_r4
            tdntotc(1:Nday,0) =   1.0_r4
            rupdirc(1:Nday,pverp) = albdir(1:Nday,ns)
            rupdifc(1:Nday,pverp) = albdif(1:Nday,ns)


!cdir expand=pverp
            do k = 1, pverp
            do i=1,Nday
               km1 = k - 1
               xexpt = exptdnc(i,km1)
               xrdnd = rdndifc(i,km1)
               yrdnd = rdifc(ns,i,km1)
               ytdnd = tdifc(ns,i,km1)

               exptdnc(i,k) = xexpt*explayc(ns,i,km1)

               rdenom  = 1._r4/(1._r4 - yrdnd*xrdnd)
               rdirexp = rdirc(ns,i,km1)*xexpt
               tdnmexp = tdntotc(i,km1) - xexpt

               tdntotc(i,k) = xexpt*tdirc(ns,i,km1) + ytdnd*(tdnmexp + xrdnd*rdirexp)* &
                                rdenom
               rdndifc(i,k) = yrdnd + xrdnd*(ytdnd**2)*rdenom
! 
! End do i=1,Nday
! 
            end do
            end do

            do k=pver,0,-1
            do i=1,Nday
               xrupd = rupdifc(i,k+1)
               yexpt = explayc(ns,i,k)
               yrupd = rdifc(ns,i,k)
               ytupd = tdifc(ns,i,k)

               rdenom = 1._r4/( 1._r4 - yrupd*xrupd)

               rupdirc(i,k) = rdirc(ns,i,k) + ytupd*(rupdirc(i,k+1)*yexpt + &
                            xrupd*(tdirc(ns,i,k)-yexpt))*rdenom
               rupdifc(i,k) = yrupd + xrupd*ytupd**2*rdenom
! 
! End do i=1,Nday
! 
            end do
            end do

            do k=0,pverp
            do i=1,Nday
               rdenom    = 1._r4/(1._r4 - rdndifc(i,k)*rupdifc(i,k))
               fluxup(ns,k,i) = (exptdnc(i,k)*rupdirc(i,k) + (tdntotc(i,k)-exptdnc(i,k))*rupdifc(i,k))* &
                           rdenom
               fluxdn(ns,k,i) = exptdnc(i,k) + &
                           (tdntotc(i,k) - exptdnc(i,k) + exptdnc(i,k)*rupdirc(i,k)*rdndifc(i,k))* &
                           rdenom
! 
! End do i=1,Nday
! 
            end do
            end do

            do i=1,Nday
            fsntc(i)    = fsntc(i)+solflx(i)*(fluxdn(ns,1,i)-fluxup(ns,1,i))
            fsntoac(i)  = fsntoac(i)+solflx(i)*(fluxdn(ns,0,i)-fluxup(ns,0,i))
            fsnsc(i)    = fsnsc(i)+solflx(i)*(fluxdn(ns,pverp,i)-fluxup(ns,pverp,i))
            fsdsc(i)    = fsdsc(i)+solflx(i)*(fluxdn(ns,pverp,i))
            fsnrtoac(i) = fsnrtoac(i)+wgtint*solflx(i)*(fluxdn(ns,0,i)-fluxup(ns,0,i))
! 
! End do i=1,Nday
! 
            end do

            do k = 1,pverp
            do i=1,Nday
               fcns(i,k)=fcns(i,k) + solflx(i)*(fluxdn(ns,k,i)-fluxup(ns,k,i))
            enddo
            enddo
! 
! End of clear sky calculation
! 

! 
! End of spectral interval loop
! 
         end do

   do i=1,Nday

! 
! Compute solar heating rate (J/kg/s)
! 
!cdir expand=pver
         do k=1,pver
            qrs(i,k) = -1.E-4*gravit*totfld(i,k)/(pint(i,k) - pint(i,k+1))
         end do
! 
! Set the downwelling flux at the surface 
! 
         fsds(i) = fswdn(i,pverp)
! 
! End do i=1,Nday
! 
      end do
!
!bloss: save spectrally-summed shortwave fluxes for output
      fsu = fswup(:,1:pverp)
      fsd = fswdn(:,1:pverp)
!
!bloss ! Rearrange output arrays.
!bloss !
!bloss ! intent(inout)
!bloss !
!bloss    call ExpDayNite(pmxrgn,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pverp)
!bloss    call ExpDayNite(nmxrgn,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss !
!bloss ! intent(out)
!bloss !
!bloss    call ExpDayNite(solin,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(qrs,		Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pver)
!bloss    call ExpDayNite(fns,		Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pverp)
!bloss    call ExpDayNite(fcns,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, pverp)
!bloss    call ExpDayNite(fsns,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsnt,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsntoa,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsds,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsnsc,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsdsc,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsntc,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsntoac,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(sols,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(soll,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(solsd,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(solld,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsnirtoa,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsnrtoac,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(fsnrtoaq,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(frc_day,	Nday, IdxDay, Nnite, IdxNite, 1, pcols)
!bloss    call ExpDayNite(aertau,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, nspint, 1, naer_groups)
!bloss    call ExpDayNite(aerssa,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, nspint, 1, naer_groups)
!bloss    call ExpDayNite(aerasm,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, nspint, 1, naer_groups)
!bloss    call ExpDayNite(aerfwd,	Nday, IdxDay, Nnite, IdxNite, 1, pcols, 1, nspint, 1, naer_groups)
!bloss 
!bloss !  write (6, '(a, x, i3)') 'radcswmx : exiting, chunk identifier', lchnk

   return
end subroutine radcswmx
