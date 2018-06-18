module bc_state_inlet_giles_quasi3d_unsteady_HB
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO, ONE, TWO, HALF, ME, CYLINDRICAL,    &
                                      XI_MIN, XI_MAX, ETA_MIN, ETA_MAX, ZETA_MIN, ZETA_MAX, PI
    use mod_fluid,              only: gam, Rgas, cp
    use mod_interpolation,      only: interpolate_linear, interpolate_linear_ad
    use mod_gridspace,          only: linspace
    use mod_dft,                only: idft_eval
    use mod_chimera,            only: find_gq_donor, find_gq_donor_parallel

    use type_point,             only: point_t
    use type_mesh,              only: mesh_t
    use type_bc_state,          only: bc_state_t
    use bc_giles_HB_base,       only: giles_HB_base_t
    use type_bc_patch,          only: bc_patch_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use type_face_info,         only: face_info_t, face_info_constructor
    use type_element_info,      only: element_info_t
    use mod_chidg_mpi,          only: IRANK
    use mod_interpolate,        only: interpolate_face_autodiff
    use mpi_f08,                only: MPI_REAL8, MPI_AllReduce, mpi_comm, MPI_INTEGER, MPI_BCast, MPI_MIN, MPI_MAX
    use ieee_arithmetic,        only: ieee_is_nan
    use DNAD_D
    implicit none



    !>  Name: inlet - 3D Giles
    !!
    !!  Options:
    !!      : Average Pressure
    !!
    !!  Behavior:
    !!      
    !!  References:
    !!              
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !---------------------------------------------------------------------------------
    type, public, extends(giles_HB_base_t) :: inlet_giles_quasi3d_unsteady_HB_t

    contains

        procedure   :: init                 ! Set-up bc state with options/name etc.
        procedure   :: compute_bc_state     ! boundary condition function implementation

        procedure   :: get_q_exterior

    end type inlet_giles_quasi3d_unsteady_HB_t
    !*********************************************************************************




contains



    !>
    !!
    !!  @author Nathan A. average_pressure 
    !!  @date   2/8/2017
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(inlet_giles_quasi3d_unsteady_HB_t),   intent(inout) :: self

        ! Set name, family
        call self%set_name('Inlet - Giles Quasi3D Unsteady HB')
        call self%set_family('Inlet')

        ! Add functions
        call self%bcproperties%add('Total Pressure',       'Required')
        call self%bcproperties%add('Total Temperature',    'Required')

        call self%bcproperties%add('Normal-1', 'Required')
        call self%bcproperties%add('Normal-2', 'Required')
        call self%bcproperties%add('Normal-3', 'Required')

        ! Add functions
        call self%bcproperties%add('Pitch',               'Required')
        call self%bcproperties%add('Spatial Periodicity', 'Required')

        ! Set default values
        call self%set_fcn_option('Total Pressure',    'val', 110000._rk)
        call self%set_fcn_option('Total Temperature', 'val', 300._rk)
        call self%set_fcn_option('Normal-1', 'val', 1._rk)
        call self%set_fcn_option('Normal-2', 'val', 0._rk)
        call self%set_fcn_option('Normal-3', 'val', 0._rk)

    end subroutine init
    !********************************************************************************





    !>  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !!  @param[in]      worker  Interface for geometry, cache, integration, etc.
    !!  @param[inout]   prop    properties_t object containing equations and material_t objects
    !!
    !-------------------------------------------------------------------------------------------
    subroutine compute_bc_state(self,worker,prop,bc_comm)
        class(inlet_giles_quasi3d_unsteady_HB_t),  intent(inout)   :: self
        type(chidg_worker_t),                       intent(inout)   :: worker
        class(properties_t),                        intent(inout)   :: prop
        type(mpi_comm),                             intent(in)      :: bc_comm


        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:)   ::                                                      &
            density_bc, mom1_bc, mom2_bc, mom3_bc, energy_bc, pressure_bc, vel1_bc, vel2_bc, vel3_bc,   &
            density_p, pressure_p, vel1_p, vel2_p, vel3_p,   &
            density_bc_tmp, vel1_bc_tmp, vel2_bc_tmp, vel3_bc_tmp, pressure_bc_tmp,                     &
            grad1_density_m, grad1_mom1_m, grad1_mom2_m, grad1_mom3_m, grad1_energy_m,                  &
            grad2_density_m, grad2_mom1_m, grad2_mom2_m, grad2_mom3_m, grad2_energy_m,                  &
            grad3_density_m, grad3_mom1_m, grad3_mom2_m, grad3_mom3_m, grad3_energy_m, expect_zero

        type(AD_D), allocatable, dimension(:,:) ::                                  &
            density_t_real, vel1_t_real, vel2_t_real, vel3_t_real, pressure_t_real, &
            density_t_imag, vel1_t_imag, vel2_t_imag, vel3_t_imag, pressure_t_imag

        type(AD_D), allocatable, dimension(:)   ::          &
            density_bar, vel1_bar, vel2_bar, vel3_bar, pressure_bar, c_bar

        type(AD_D)  :: pressure_avg, vel1_avg, vel2_avg, vel3_avg, density_avg, c_avg, T_avg, vmag


        type(AD_D), allocatable, dimension(:,:,:) ::                                            &
            density_Ft_real_m, vel1_Ft_real_m, vel2_Ft_real_m, vel3_Ft_real_m, pressure_Ft_real_m, c_Ft_real_m,        &
            density_Ft_imag_m, vel1_Ft_imag_m, vel2_Ft_imag_m, vel3_Ft_imag_m, pressure_Ft_imag_m, c_Ft_imag_m,       &
            density_Fts_real_m, vel1_Fts_real_m, vel2_Fts_real_m, vel3_Fts_real_m, pressure_Fts_real_m, c_Fts_real_m,    &
            density_Fts_imag_m, vel1_Fts_imag_m, vel2_Fts_imag_m, vel3_Fts_imag_m, pressure_Fts_imag_m, c_Fts_imag_m,   &
            density_Ft_real_p, vel1_Ft_real_p, vel2_Ft_real_p, vel3_Ft_real_p, pressure_Ft_real_p, c_Ft_real_p,        &
            density_Ft_imag_p, vel1_Ft_imag_p, vel2_Ft_imag_p, vel3_Ft_imag_p, pressure_Ft_imag_p, c_Ft_imag_p,       &
            density_Fts_real_p, vel1_Fts_real_p, vel2_Fts_real_p, vel3_Fts_real_p, pressure_Fts_real_p, c_Fts_real_p,   &
            density_Fts_imag_p, vel1_Fts_imag_p, vel2_Fts_imag_p, vel3_Fts_imag_p, pressure_Fts_imag_p, c_Fts_imag_p,  &
            density_Fts_real_abs, vel1_Fts_real_abs, vel2_Fts_real_abs, vel3_Fts_real_abs, pressure_Fts_real_abs,   &
            density_Fts_imag_abs, vel1_Fts_imag_abs, vel2_Fts_imag_abs, vel3_Fts_imag_abs, pressure_Fts_imag_abs,   &
            density_Fts_real_gq, vel1_Fts_real_gq, vel2_Fts_real_gq, vel3_Fts_real_gq, pressure_Fts_real_gq,   &
            density_Fts_imag_gq, vel1_Fts_imag_gq, vel2_Fts_imag_gq, vel3_Fts_imag_gq, pressure_Fts_imag_gq,    &
            density_grid_m, vel1_grid_m, vel2_grid_m, vel3_grid_m, pressure_grid_m, c_grid_m, &
            density_grid_p, vel1_grid_p, vel2_grid_p, vel3_grid_p, pressure_grid_p, c_grid_p


        real(rk),       allocatable, dimension(:)   :: r, pitch
        real(rk)                                    :: theta_offset
        type(point_t),  allocatable                 :: coords(:)
        integer                                     :: i, ngq, ivec, imode, itheta, itime, iradius, nmodes, ierr, igq
        real(rk),       allocatable, dimension(:)   :: PT, TT, n1, n2, n3, nmag


        ! Get back pressure from function.
        pitch  = self%bcproperties%compute('Pitch', worker%time(),worker%coords())

        ! Interpolate interior solution to face quadrature nodes
        grad1_density_m = worker%get_field('Density'   , 'grad1', 'face interior')
        grad2_density_m = worker%get_field('Density'   , 'grad2', 'face interior')
        grad3_density_m = worker%get_field('Density'   , 'grad3', 'face interior')

        grad1_mom1_m    = worker%get_field('Momentum-1', 'grad1', 'face interior')
        grad2_mom1_m    = worker%get_field('Momentum-1', 'grad2', 'face interior')
        grad3_mom1_m    = worker%get_field('Momentum-1', 'grad3', 'face interior')

        grad1_mom2_m    = worker%get_field('Momentum-2', 'grad1', 'face interior')
        grad2_mom2_m    = worker%get_field('Momentum-2', 'grad2', 'face interior')
        grad3_mom2_m    = worker%get_field('Momentum-2', 'grad3', 'face interior')

        grad1_mom3_m    = worker%get_field('Momentum-3', 'grad1', 'face interior')
        grad2_mom3_m    = worker%get_field('Momentum-3', 'grad2', 'face interior')
        grad3_mom3_m    = worker%get_field('Momentum-3', 'grad3', 'face interior')
        
        grad1_energy_m  = worker%get_field('Energy'    , 'grad1', 'face interior')
        grad2_energy_m  = worker%get_field('Energy'    , 'grad2', 'face interior')
        grad3_energy_m  = worker%get_field('Energy'    , 'grad3', 'face interior')


        ! Store boundary gradient state. Grad(Q_bc). Do this here, before we
        ! compute any transformations for cylindrical.
        call worker%store_bc_state('Density'   , grad1_density_m, 'grad1')
        call worker%store_bc_state('Density'   , grad2_density_m, 'grad2')
        call worker%store_bc_state('Density'   , grad3_density_m, 'grad3')
                                                
        call worker%store_bc_state('Momentum-1', grad1_mom1_m,    'grad1')
        call worker%store_bc_state('Momentum-1', grad2_mom1_m,    'grad2')
        call worker%store_bc_state('Momentum-1', grad3_mom1_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-2', grad1_mom2_m,    'grad1')
        call worker%store_bc_state('Momentum-2', grad2_mom2_m,    'grad2')
        call worker%store_bc_state('Momentum-2', grad3_mom2_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-3', grad1_mom3_m,    'grad1')
        call worker%store_bc_state('Momentum-3', grad2_mom3_m,    'grad2')
        call worker%store_bc_state('Momentum-3', grad3_mom3_m,    'grad3')
                                                
        call worker%store_bc_state('Energy'    , grad1_energy_m,  'grad1')
        call worker%store_bc_state('Energy'    , grad2_energy_m,  'grad2')
        call worker%store_bc_state('Energy'    , grad3_energy_m,  'grad3')


        ! Get primitive variables at (radius,theta,time) grid.
        call self%get_q_interior(worker,bc_comm,  &
                                 density_grid_m,    &
                                 vel1_grid_m,       &
                                 vel2_grid_m,       &
                                 vel3_grid_m,       &
                                 pressure_grid_m)
        c_grid_m = sqrt(gam*pressure_grid_m/density_grid_m)

        ! Compute Fourier decomposition of temporal data at points
        ! on the spatial transform grid.
        !   : U_Ft(nradius,ntheta,ntime)
        call self%compute_temporal_dft(worker,bc_comm,                          &
                                       density_grid_m,                          &
                                       vel1_grid_m,                             &
                                       vel2_grid_m,                             &
                                       vel3_grid_m,                             &
                                       pressure_grid_m,                         &
                                       c_grid_m,                                &
                                       density_Ft_real_m,  density_Ft_imag_m,   &
                                       vel1_Ft_real_m,     vel1_Ft_imag_m,      &
                                       vel2_Ft_real_m,     vel2_Ft_imag_m,      &
                                       vel3_Ft_real_m,     vel3_Ft_imag_m,      &
                                       pressure_Ft_real_m, pressure_Ft_imag_m,  &
                                       c_Ft_real_m,        c_Ft_imag_m)

        ! Compute Fourier decomposition in theta at set of radial 
        ! stations for each temporal mode:
        !   : U_Fts(nradius,ntheta,ntime)
        call self%compute_spatial_dft(worker,bc_comm,                               &
                                      density_Ft_real_m,   density_Ft_imag_m,       &
                                      vel1_Ft_real_m,      vel1_Ft_imag_m,          &
                                      vel2_Ft_real_m,      vel2_Ft_imag_m,          &
                                      vel3_Ft_real_m,      vel3_Ft_imag_m,          &
                                      pressure_Ft_real_m,  pressure_Ft_imag_m,      &
                                      c_Ft_real_m,         c_Ft_imag_m,             &
                                      density_Fts_real_m,  density_Fts_imag_m,      &
                                      vel1_Fts_real_m,     vel1_Fts_imag_m,         &
                                      vel2_Fts_real_m,     vel2_Fts_imag_m,         &
                                      vel3_Fts_real_m,     vel3_Fts_imag_m,         &
                                      pressure_Fts_real_m, pressure_Fts_imag_m,     &
                                      c_Fts_real_m,        c_Fts_imag_m)




        ! Get spatio-temporal average at radial stations
        density_bar  = density_Fts_real_m(:,1,1)
        vel1_bar     = vel1_Fts_real_m(:,1,1)
        vel2_bar     = vel2_Fts_real_m(:,1,1)
        vel3_bar     = vel3_Fts_real_m(:,1,1)
        pressure_bar = pressure_Fts_real_m(:,1,1)
        c_bar        = c_Fts_real_m(:,1,1)


        ! Compute spatio-temporal average over entire surface
        call self%compute_boundary_average(worker,bc_comm,density_bar,vel1_bar,vel2_bar,vel3_bar,pressure_bar,c_bar, &
                                                          density_avg,vel1_avg,vel2_avg,vel3_avg,pressure_avg,c_avg)
        !c_avg = sqrt(gam*pressure_avg/density_avg)



        ! Get boundary condition Total Temperature, Total Pressure, and normal vector
        PT   = self%bcproperties%compute('Total Pressure',   worker%time(),worker%coords())
        TT   = self%bcproperties%compute('Total Temperature',worker%time(),worker%coords())

        ! Get user-input normal vector and normalize
        n1 = self%bcproperties%compute('Normal-1', worker%time(), worker%coords())
        n2 = self%bcproperties%compute('Normal-2', worker%time(), worker%coords())
        n3 = self%bcproperties%compute('Normal-3', worker%time(), worker%coords())

        !   Explicit allocation to handle GCC bug:
        !       GCC/GFortran Bugzilla Bug 52162 
        allocate(nmag(size(n1)), stat=ierr)
        if (ierr /= 0) call AllocationError

        nmag = sqrt(n1*n1 + n2*n2 + n3*n3)
        n1 = n1/nmag
        n2 = n2/nmag
        n3 = n3/nmag


        ! Override spatio-temporal mean according to specified total conditions
        T_avg = TT(1)*(pressure_avg/PT(1))**((gam-ONE)/gam)
        density_avg = pressure_avg/(T_avg*Rgas)
        vmag = sqrt(TWO*cp*(TT(1)-T_avg))
        vel1_avg = n1(1)*vmag
        vel2_avg = n2(1)*vmag
        vel3_avg = n3(1)*vmag

!        density_real_abs(:,1,1)  = density_avg
!        vel1_real_abs(:,1,1)     = vel1_avg
!        vel2_real_abs(:,1,1)     = vel2_avg
!        vel3_real_abs(:,1,1)     = vel3_avg
!        pressure_real_abs(:,1,1) = pressure_avg






        ! Get exterior perturbation
        call self%get_q_exterior(worker,bc_comm,    &
                                 density_grid_p,    &
                                 vel1_grid_p,       &
                                 vel2_grid_p,       &
                                 vel3_grid_p,       &
                                 pressure_grid_p)


        ! Add space-time average
        density_grid_p  = density_grid_p  + density_avg
        vel1_grid_p     = vel1_grid_p     + vel1_avg
        vel2_grid_p     = vel2_grid_p     + vel2_avg
        vel3_grid_p     = vel3_grid_p     + vel3_avg
        pressure_grid_p = pressure_grid_p + pressure_avg
        c_grid_p = sqrt(gam*pressure_grid_p/density_grid_p)


        ! Compute Fourier decomposition of temporal data at points
        ! on the spatial transform grid.
        !   : U_Ft(nradius,ntheta,ntime)
        call self%compute_temporal_dft(worker,bc_comm,                          &
                                       density_grid_p,                          &
                                       vel1_grid_p,                             &
                                       vel2_grid_p,                             &
                                       vel3_grid_p,                             &
                                       pressure_grid_p,                         &
                                       c_grid_p,                                &
                                       density_Ft_real_p,  density_Ft_imag_p,   &
                                       vel1_Ft_real_p,     vel1_Ft_imag_p,      &
                                       vel2_Ft_real_p,     vel2_Ft_imag_p,      &
                                       vel3_Ft_real_p,     vel3_Ft_imag_p,      &
                                       pressure_Ft_real_p, pressure_Ft_imag_p,  &
                                       c_Ft_real_p,        c_Ft_imag_p)



        ! Compute Fourier decomposition in theta at set of radial 
        ! stations for each temporal mode:
        !   : U_Fts(nradius,ntheta,ntime)
        call self%compute_spatial_dft(worker,bc_comm,                               &
                                      density_Ft_real_p,   density_Ft_imag_p,       &
                                      vel1_Ft_real_p,      vel1_Ft_imag_p,          &
                                      vel2_Ft_real_p,      vel2_Ft_imag_p,          &
                                      vel3_Ft_real_p,      vel3_Ft_imag_p,          &
                                      pressure_Ft_real_p,  pressure_Ft_imag_p,      &
                                      c_Ft_real_p,         c_Ft_imag_p,             &
                                      density_Fts_real_p,  density_Fts_imag_p,      &
                                      vel1_Fts_real_p,     vel1_Fts_imag_p,         &
                                      vel2_Fts_real_p,     vel2_Fts_imag_p,         &
                                      vel3_Fts_real_p,     vel3_Fts_imag_p,         &
                                      pressure_Fts_real_p, pressure_Fts_imag_p,     &
                                      c_Fts_real_p,        c_Fts_imag_p)





        ! Compute q_abs
        call self%compute_absorbing_inlet(worker,bc_comm,                               &
                                          density_Fts_real_m,    density_Fts_imag_m,    &
                                          vel1_Fts_real_m,       vel1_Fts_imag_m,       &
                                          vel2_Fts_real_m,       vel2_Fts_imag_m,       &
                                          vel3_Fts_real_m,       vel3_Fts_imag_m,       &
                                          pressure_Fts_real_m,   pressure_Fts_imag_m,   &
                                          c_Fts_real_m,          c_Fts_imag_m,          &
                                          density_Fts_real_p,    density_Fts_imag_p,    &
                                          vel1_Fts_real_p,       vel1_Fts_imag_p,       &
                                          vel2_Fts_real_p,       vel2_Fts_imag_p,       &
                                          vel3_Fts_real_p,       vel3_Fts_imag_p,       &
                                          pressure_Fts_real_p,   pressure_Fts_imag_p,   &
                                          c_Fts_real_p,          c_Fts_imag_p,          &
                                          density_Fts_real_abs,  density_Fts_imag_abs,  &
                                          vel1_Fts_real_abs,     vel1_Fts_imag_abs,     &
                                          vel2_Fts_real_abs,     vel2_Fts_imag_abs,     &
                                          vel3_Fts_real_abs,     vel3_Fts_imag_abs,     &
                                          pressure_Fts_real_abs, pressure_Fts_imag_abs)



        ! Interpolate spatio-temporal Fourier coefficients to quadrature nodes
        ! linear interpolation between radial coordinates.
        coords = worker%coords()
        allocate(density_Fts_real_gq( size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 density_Fts_imag_gq( size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 vel1_Fts_real_gq(    size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 vel1_Fts_imag_gq(    size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 vel2_Fts_real_gq(    size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 vel2_Fts_imag_gq(    size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 vel3_Fts_real_gq(    size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 vel3_Fts_imag_gq(    size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 pressure_Fts_real_gq(size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 pressure_Fts_imag_gq(size(coords),size(density_Fts_real_abs,2),size(density_Fts_real_abs,3)), &
                 stat=ierr)
        if (ierr /= 0) call AllocationError
        density_Fts_real_gq  = ZERO*density_Fts_real_abs(1,1,1)
        density_Fts_imag_gq  = ZERO*density_Fts_real_abs(1,1,1)
        vel1_Fts_real_gq     = ZERO*density_Fts_real_abs(1,1,1)
        vel1_Fts_imag_gq     = ZERO*density_Fts_real_abs(1,1,1)
        vel2_Fts_real_gq     = ZERO*density_Fts_real_abs(1,1,1)
        vel2_Fts_imag_gq     = ZERO*density_Fts_real_abs(1,1,1)
        vel3_Fts_real_gq     = ZERO*density_Fts_real_abs(1,1,1)
        vel3_Fts_imag_gq     = ZERO*density_Fts_real_abs(1,1,1)
        pressure_Fts_real_gq = ZERO*density_Fts_real_abs(1,1,1)
        pressure_Fts_imag_gq = ZERO*density_Fts_real_abs(1,1,1)
        do igq = 1,size(coords)
            do itheta = 1,size(density_Fts_real_abs,2)
                do itime = 1,size(density_Fts_real_abs,3)
                    density_Fts_real_gq( igq,itheta,itime) = interpolate_linear_ad(self%r,density_Fts_real_abs(:,itheta,itime), coords(igq)%c1_)
                    density_Fts_imag_gq( igq,itheta,itime) = interpolate_linear_ad(self%r,density_Fts_imag_abs(:,itheta,itime), coords(igq)%c1_)
                    vel1_Fts_real_gq(    igq,itheta,itime) = interpolate_linear_ad(self%r,vel1_Fts_real_abs(:,itheta,itime),    coords(igq)%c1_)
                    vel1_Fts_imag_gq(    igq,itheta,itime) = interpolate_linear_ad(self%r,vel1_Fts_imag_abs(:,itheta,itime),    coords(igq)%c1_)
                    vel2_Fts_real_gq(    igq,itheta,itime) = interpolate_linear_ad(self%r,vel2_Fts_real_abs(:,itheta,itime),    coords(igq)%c1_)
                    vel2_Fts_imag_gq(    igq,itheta,itime) = interpolate_linear_ad(self%r,vel2_Fts_imag_abs(:,itheta,itime),    coords(igq)%c1_)
                    vel3_Fts_real_gq(    igq,itheta,itime) = interpolate_linear_ad(self%r,vel3_Fts_real_abs(:,itheta,itime),    coords(igq)%c1_)
                    vel3_Fts_imag_gq(    igq,itheta,itime) = interpolate_linear_ad(self%r,vel3_Fts_imag_abs(:,itheta,itime),    coords(igq)%c1_)
                    pressure_Fts_real_gq(igq,itheta,itime) = interpolate_linear_ad(self%r,pressure_Fts_real_abs(:,itheta,itime),coords(igq)%c1_)
                    pressure_Fts_imag_gq(igq,itheta,itime) = interpolate_linear_ad(self%r,pressure_Fts_imag_abs(:,itheta,itime),coords(igq)%c1_)
                end do !itime
            end do !itheta
        end do !igq



        ! Zero space-time avg
        density_Fts_real_gq(:,1,1) = ZERO
        vel1_Fts_real_gq(:,1,1) = ZERO
        vel2_Fts_real_gq(:,1,1) = ZERO
        vel3_Fts_real_gq(:,1,1) = ZERO
        pressure_Fts_real_gq(:,1,1) = ZERO


        ! Reconstruct primitive variables at quadrature nodes from absorbing Fourier modes
        ! via inverse transform.

        ! Inverse DFT of spatio-temporal Fourier modes to give temporal Fourier
        ! modes at quadrature nodes.
        expect_zero = [AD_D(1)]
        density_t_real  = ZERO*density_Fts_real_gq(:,1,:)
        vel1_t_real     = ZERO*density_Fts_real_gq(:,1,:)
        vel2_t_real     = ZERO*density_Fts_real_gq(:,1,:)
        vel3_t_real     = ZERO*density_Fts_real_gq(:,1,:)
        pressure_t_real = ZERO*density_Fts_real_gq(:,1,:)
        density_t_imag  = ZERO*density_Fts_real_gq(:,1,:)
        vel1_t_imag     = ZERO*density_Fts_real_gq(:,1,:)
        vel2_t_imag     = ZERO*density_Fts_real_gq(:,1,:)
        vel3_t_imag     = ZERO*density_Fts_real_gq(:,1,:)
        pressure_t_imag = ZERO*density_Fts_real_gq(:,1,:)
        do igq = 1,size(coords)
            do itime = 1,size(density_Fts_real_gq,3)
                !theta_offset = coords(igq)%c2_ - self%theta_ref
                theta_offset = coords(igq)%c2_ - self%theta(1,1)
                ! **** WARNING: probably want ipdft_eval here ****
                call idft_eval(density_Fts_real_gq(igq,:,itime),    &
                               density_Fts_imag_gq(igq,:,itime),    &
                               [theta_offset]/pitch(1),             &
                               density_t_real(igq:igq,itime),       &
                               density_t_imag(igq:igq,itime),negate=.true.)

                call idft_eval(vel1_Fts_real_gq(igq,:,itime),   &
                               vel1_Fts_imag_gq(igq,:,itime),   &
                               [theta_offset]/pitch(1),         &
                               vel1_t_real(igq:igq,itime),      &
                               vel1_t_imag(igq:igq,itime),negate=.true.)

                call idft_eval(vel2_Fts_real_gq(igq,:,itime),   &
                               vel2_Fts_imag_gq(igq,:,itime),   &
                               [theta_offset]/pitch(1),         &
                               vel2_t_real(igq:igq,itime),      &
                               vel2_t_imag(igq:igq,itime),negate=.true.)

                call idft_eval(vel3_Fts_real_gq(igq,:,itime),   &
                               vel3_Fts_imag_gq(igq,:,itime),   &
                               [theta_offset]/pitch(1),         &
                               vel3_t_real(igq:igq,itime),      &
                               vel3_t_imag(igq:igq,itime),negate=.true.)

                call idft_eval(pressure_Fts_real_gq(igq,:,itime),   &
                               pressure_Fts_imag_gq(igq,:,itime),   &
                               [theta_offset]/pitch(1),             &
                               pressure_t_real(igq:igq,itime),      &
                               pressure_t_imag(igq:igq,itime),negate=.true.)
            end do !itime
        end do !igq


        ! Allocate storage for boundary state
        density_p  = ZERO*density_Fts_real_gq(:,1,1)
        vel1_p     = ZERO*density_Fts_real_gq(:,1,1)
        vel2_p     = ZERO*density_Fts_real_gq(:,1,1)
        vel3_p     = ZERO*density_Fts_real_gq(:,1,1)
        pressure_p = ZERO*density_Fts_real_gq(:,1,1)
        density_bc  = ZERO*density_Fts_real_gq(:,1,1)
        vel1_bc     = ZERO*density_Fts_real_gq(:,1,1)
        vel2_bc     = ZERO*density_Fts_real_gq(:,1,1)
        vel3_bc     = ZERO*density_Fts_real_gq(:,1,1)
        pressure_bc = ZERO*density_Fts_real_gq(:,1,1)
        mom1_bc     = ZERO*density_Fts_real_gq(:,1,1)
        mom2_bc     = ZERO*density_Fts_real_gq(:,1,1)
        mom3_bc     = ZERO*density_Fts_real_gq(:,1,1)
        energy_bc   = ZERO*density_Fts_real_gq(:,1,1)



        ! Inverse DFT of temporal Fourier modes to give primitive variables
        ! at quarature nodes for the current time instance.
        density_bc_tmp  = [ZERO*density_Fts_real_gq(1,1,1)]
        vel1_bc_tmp     = [ZERO*density_Fts_real_gq(1,1,1)]
        vel2_bc_tmp     = [ZERO*density_Fts_real_gq(1,1,1)]
        vel3_bc_tmp     = [ZERO*density_Fts_real_gq(1,1,1)]
        pressure_bc_tmp = [ZERO*density_Fts_real_gq(1,1,1)]
        do igq = 1,size(coords)
            ! **** WARNING: probably want ipdft_eval here ****
            call idft_eval(density_t_real(igq,:),   &
                           density_t_imag(igq,:),   &
                           [real(worker%itime-1,rk)/real(worker%time_manager%ntime,rk)],    &
                           density_bc_tmp,          &
                           expect_zero,symmetric=.true.)
            if (abs(expect_zero(1)) > 0.0000001) print*, 'WARNING: inverse transform returning complex values.'

            call idft_eval(vel1_t_real(igq,:),      &
                           vel1_t_imag(igq,:),      &
                           [real(worker%itime-1,rk)/real(worker%time_manager%ntime,rk)],    &
                           vel1_bc_tmp,        &
                           expect_zero,symmetric=.true.)
            if (abs(expect_zero(1)) > 0.0000001) print*, 'WARNING: inverse transform returning complex values.'

            call idft_eval(vel2_t_real(igq,:),      &
                           vel2_t_imag(igq,:),      &
                           [real(worker%itime-1,rk)/real(worker%time_manager%ntime,rk)],    &
                           vel2_bc_tmp,        &
                           expect_zero,symmetric=.true.)
            if (abs(expect_zero(1)) > 0.0000001) print*, 'WARNING: inverse transform returning complex values.'

            call idft_eval(vel3_t_real(igq,:),      &
                           vel3_t_imag(igq,:),      &
                           [real(worker%itime-1,rk)/real(worker%time_manager%ntime,rk)],    &
                           vel3_bc_tmp,        &
                           expect_zero,symmetric=.true.)
            if (abs(expect_zero(1)) > 0.0000001) print*, 'WARNING: inverse transform returning complex values.'

            call idft_eval(pressure_t_real(igq,:),  &
                           pressure_t_imag(igq,:),  &
                           [real(worker%itime-1,rk)/real(worker%time_manager%ntime,rk)],    &
                           pressure_bc_tmp,    &
                           expect_zero,symmetric=.true.)
            if (abs(expect_zero(1)) > 0.0000001) print*, 'WARNING: inverse transform returning complex values.'

            ! Accumulate contribution from unsteady modes
            density_p(igq)  = density_p(igq)  + density_bc_tmp(1)
            vel1_p(igq)     = vel1_p(igq)     + vel1_bc_tmp(1)
            vel2_p(igq)     = vel2_p(igq)     + vel2_bc_tmp(1)
            vel3_p(igq)     = vel3_p(igq)     + vel3_bc_tmp(1)
            pressure_p(igq) = pressure_p(igq) + pressure_bc_tmp(1)
        end do



        !
        ! Form conserved variables
        !
        !density_bc = density_bc
        !mom1_bc    = density_bc*vel1_bc
        !mom2_bc    = density_bc*vel2_bc
        !mom3_bc    = density_bc*vel3_bc
        !energy_bc  = pressure_bc/(gam - ONE)  + HALF*(mom1_bc*mom1_bc + mom2_bc*mom2_bc + mom3_bc*mom3_bc)/density_bc

        density_bc(:) = density_avg
        mom1_bc(:)    = density_avg*vel1_avg
        mom2_bc(:)    = density_avg*vel2_avg
        mom3_bc(:)    = density_avg*vel3_avg
        energy_bc(:)  = pressure_avg/(gam - ONE)  + HALF*density_avg*(vel1_avg*vel1_avg + vel2_avg*vel2_avg + vel3_avg*vel3_avg)
        do igq = 1,size(density_bc)
            density_bc(igq) = density_bc(igq) + (density_p(igq))
            mom1_bc(igq)    = mom1_bc(igq)    + (density_p(igq)*vel1_avg + density_avg*vel1_p(igq))
            mom2_bc(igq)    = mom2_bc(igq)    + (density_p(igq)*vel2_avg + density_avg*vel2_p(igq))
            mom3_bc(igq)    = mom3_bc(igq)    + (density_p(igq)*vel3_avg + density_avg*vel3_p(igq))
            energy_bc(igq)  = energy_bc(igq)  + &
                         HALF*(vel1_avg*vel1_avg + vel2_avg*vel2_avg + vel3_avg*vel3_avg)*density_p(igq) + &
                         density_avg*vel1_avg*vel1_p(igq) + &
                         density_avg*vel2_avg*vel2_p(igq) + &
                         density_avg*vel3_avg*vel3_p(igq) + &
                         (ONE/(gam-ONE))*pressure_p(igq)
        end do


        !
        ! Account for cylindrical. Convert tangential momentum back to angular momentum.
        !
        if (worker%coordinate_system() == 'Cylindrical') then
            r = worker%coordinate('1','boundary')
            mom2_bc = mom2_bc * r
        end if


        !
        ! Store boundary condition state. Q_bc
        !
        call worker%store_bc_state('Density'   , density_bc, 'value')
        call worker%store_bc_state('Momentum-1', mom1_bc,    'value')
        call worker%store_bc_state('Momentum-2', mom2_bc,    'value')
        call worker%store_bc_state('Momentum-3', mom3_bc,    'value')
        call worker%store_bc_state('Energy'    , energy_bc,  'value')



    end subroutine compute_bc_state
    !*********************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   4/25/2018
    !!
    !------------------------------------------------------------------------------------
    subroutine get_q_exterior(self,worker,bc_comm,    &
                              density,                &
                              vel1,                   &
                              vel2,                   &
                              vel3,                   &
                              pressure)
        class(inlet_giles_quasi3d_unsteady_HB_t),  intent(inout)   :: self
        type(chidg_worker_t),           intent(inout)   :: worker
        type(mpi_comm),                 intent(in)      :: bc_comm
        type(AD_D),     allocatable,    intent(inout)   :: density(:,:,:)
        type(AD_D),     allocatable,    intent(inout)   :: vel1(:,:,:)
        type(AD_D),     allocatable,    intent(inout)   :: vel2(:,:,:)
        type(AD_D),     allocatable,    intent(inout)   :: vel3(:,:,:)
        type(AD_D),     allocatable,    intent(inout)   :: pressure(:,:,:)

        type(AD_D), allocatable, dimension(:,:,:) ::  &
            mom1, mom2, mom3, energy

        integer(ik) :: iradius, itime, nradius, ntheta, ntime, ierr


        ! Define Fourier space discretization to determine
        ! number of theta-samples are being taken
        nradius = size(self%r)
        ntheta  = size(self%theta,2)
        ntime   = worker%time_manager%ntime

        ! Allocate storage for discrete time instances
        allocate(density( nradius,ntheta,ntime),  &
                 mom1(    nradius,ntheta,ntime),  &
                 mom2(    nradius,ntheta,ntime),  &
                 mom3(    nradius,ntheta,ntime),  &
                 vel1(    nradius,ntheta,ntime),  &
                 vel2(    nradius,ntheta,ntime),  &
                 vel3(    nradius,ntheta,ntime),  &
                 energy(  nradius,ntheta,ntime),  &
                 pressure(nradius,ntheta,ntime), stat=ierr)
        if (ierr /= 0) call AllocationError


        ! Perform Fourier decomposition at each radial station.
        do iradius = 1,nradius
            do itime = 1,ntime
                ! Interpolate solution to physical_nodes at current radial station: [ntheta]
                density(iradius,:,itime) = worker%interpolate_field_general('Density',    donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                mom1(iradius,:,itime)    = worker%interpolate_field_general('Momentum-1', donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                mom2(iradius,:,itime)    = worker%interpolate_field_general('Momentum-2', donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                mom3(iradius,:,itime)    = worker%interpolate_field_general('Momentum-3', donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                energy(iradius,:,itime)  = worker%interpolate_field_general('Energy',     donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)

                if (worker%coordinate_system() == 'Cylindrical') then
                    mom2(iradius,:,itime) = mom2(iradius,:,itime)/self%r(iradius)  ! convert to tangential momentum
                end if
            end do
        end do

        ! Compute velocities and pressure at each time
        vel1 = mom1/density
        vel2 = mom2/density
        vel3 = mom3/density
        pressure = (gam-ONE)*(energy - HALF*(mom1*mom1 + mom2*mom2 + mom3*mom3)/density)


        density  = ZERO
        vel1     = ZERO
        vel2     = ZERO
        vel3     = ZERO
        pressure = ZERO

        do itime = 1,ntime
            density(:,:,itime) = 0.001_rk*sin(-TWO*PI*self%theta + worker%time_manager%freqs(1)*worker%time_manager%times(itime))
            !pressure(:,:,itime) = 100000._rk + 10._rk*sin(TWO*PI*self%theta + worker%time_manager%freqs(1)*worker%time_manager%times(itime))
        end do



    end subroutine get_q_exterior
    !************************************************************************************












end module bc_state_inlet_giles_quasi3d_unsteady_HB
