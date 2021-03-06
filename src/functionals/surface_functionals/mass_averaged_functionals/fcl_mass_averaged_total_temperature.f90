module fcl_mass_averaged_total_temperature
#include <messenger.h>
    use mod_kinds,                  only: ik, rk
    use type_evaluator,             only: evaluator_t
    use type_chidg_worker,          only: chidg_worker_t
    use mod_fluid,                  only: Rgas,cp, gam
    use mod_constants,              only: HALF, ONE
    use type_functional_cache,      only: functional_cache_t
    use type_chidg_vector,          only: chidg_vector_t
    use mod_functional_operators
    use DNAD_D
    implicit none



    !>  This functional computes the mass-averaged total_temperature:
    !!      - reference geom
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/29/2019
    !!
    !!
    !------------------------------------------------------------------------------------------
    type,  extends(evaluator_t), public   :: mass_averaged_total_temperature_t
   
        ! Quantities needed for the computation
        ! Used to check completeness of information provided
        integer(ik)     :: min_ref_geom = 1
        integer(ik)     :: min_aux_geom = 0
        integer(ik)     :: max_ref_geom = 100
        integer(ik)     :: max_aux_geom = 0

    contains

        procedure, public   :: init
        procedure, public   :: check
        procedure, public   :: compute_functional
        procedure, public   :: finalize_functional
        procedure, public   :: store_value
        procedure, public   :: store_deriv

    end type mass_averaged_total_temperature_t
    !******************************************************************************************
    


contains




    !>  Initialize the functional
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/29/2019
    !!
    !------------------------------------------------------------------------------------------
    subroutine init(self)
        class(mass_averaged_total_temperature_t), intent(inout)   :: self

        call self%set_name("MA Total Temperature")
        call self%set_eval_type("Functional")
        call self%set_int_type("FACE INTEGRAL")

        call self%add_integral("temperature flux")
        call self%add_integral("mass flux")
        call self%add_integral("MA total temperature")

    end subroutine init
    !******************************************************************************************






    !>  This procedure checks that all the information have been provided by the user to fully 
    !!  compute the functional
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/29/2019
    !!
    !------------------------------------------------------------------------------------------
    subroutine check(self)
        class(mass_averaged_total_temperature_t), intent(inout)   :: self

        integer(ik)                     :: aux_geoms, ref_geoms
        character(len=:), allocatable   :: usr_msg_r, usr_msg_a
        logical                         :: ref_geoms_exceed, aux_geoms_exceed

        ref_geoms = self%n_ref_geom()
        aux_geoms = self%n_aux_geom()

        ref_geoms_exceed = (ref_geoms < self%min_ref_geom .or. ref_geoms > self%max_ref_geom)
        aux_geoms_exceed = (aux_geoms < self%min_aux_geom .or. aux_geoms > self%max_aux_geom)

        usr_msg_r = "fcl_mass_average_total_temperature: wrong number of reference geometries. The minimum number of reference geometries is 1."
        usr_msg_a = "fcl_mass_average_total_temperature: wrong number of auxiliary geometries. The minimum number of auxiliary geometries is 1."

        if (ref_geoms_exceed) call chidg_signal(FATAL, usr_msg_r)
        if (aux_geoms_exceed) call chidg_signal(FATAL, usr_msg_a)

    end subroutine check 
    !******************************************************************************************






    !>  This subroutine is meant to compute the total temperature integral.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/29/2019
    !!
    !!  param[inout]       worker
    !!  param[inout]       cache        ! Storage for functional integrals
    !!
    !------------------------------------------------------------------------------------------
    subroutine compute_functional(self,worker,cache)
        class(mass_averaged_total_temperature_t),   intent(inout)   :: self
        type(chidg_worker_t),                       intent(inout)   :: worker
        type(functional_cache_t),                   intent(inout)   :: cache
        
        type(AD_D), allocatable, dimension(:) :: temperature, tot_temperature,  &
                                                 density, mom_1, mom_2, mom_3,  &
                                                 u_1, u_2, u_3, umag, c, mach, r 
        type(AD_D)                            :: temperature_flux, mass_flux
        
        
        ! Get primary fields
        density     = worker%get_field('Density'   ,'value','face interior')
        mom_1       = worker%get_field('Momentum-1','value','face interior')
        mom_2       = worker%get_field('Momentum-2','value','face interior')
        mom_3       = worker%get_field('Momentum-3','value','face interior')

        ! Account for cylindrical coordinates
        r = worker%coordinate('1','face interior')
        if (worker%coordinate_system() == 'Cylindrical') then
            mom_2 = mom_2/r
!        else if (worker%coordinate_system() == 'Cartesian') then
!
!        else
!            call chidg_signal(FATAL,'bad coordinate system')
        end if

        ! Get necessary models
        temperature = worker%get_field('Temperature','value','face interior')
        
        ! Compute velocities
        u_1 = mom_1/density
        u_2 = mom_2/density
        u_3 = mom_3/density
        umag = sqrt(u_1*u_1 + u_2*u_2 + u_3*u_3)
        
        ! Compute Mach number
        c = sqrt( gam * Rgas * temperature)
        mach = umag/c
        
        ! Compute total temperature and total temperature
        tot_temperature = temperature * (ONE + (gam - ONE)*HALF*mach*mach)

        ! Send the total temperature and temperature to the averaging subroutine
        temperature_flux = integrate_surface_mass_weighted(worker,tot_temperature)
        
        ! Call the averaging subroutine for computing pure mass flux through the face
        mass_flux = integrate_surface_mass_weighted(worker)
     
        ! Store in cache 
        call cache%set_entity_value(worker%mesh,temperature_flux,'temperature flux','reference',worker%function_info) 
        call cache%set_entity_value(worker%mesh,mass_flux,       'mass flux',       'reference',worker%function_info) 
    
    end subroutine compute_functional
    !******************************************************************************************

    
    
    
    
    
    
    !>  This subroutine compute the final total temperature and total temperature mass-average
    !!  on the reference boundary.
    !! 
    !!  The quantities stored are:
    !!      - T0aux = T0_flux/mass_flux
    !!
    !!  NOTE: here the integral contribution from each process has been shared and summed.
    !!        Therefore, we are dealing here with integrals over the entire geometry.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/29/2019
    !!
    !!  param[inout]       cache     cache contains the overall iintegrals value at this point,
    !!                               since the parallel communication already happened 
    !!                               
    !---------------------------------------------------------------------------------------------
    subroutine finalize_functional(self,worker,cache)
        class(mass_averaged_total_temperature_t),   intent(inout)   :: self
        type(chidg_worker_t),                       intent(in)      :: worker
        type(functional_cache_t),                   intent(inout)   :: cache

        type(AD_D)        :: temperature_flux, mass_flux
        
        temperature_flux = cache%get_global_value(worker%mesh,'temperature flux','reference')
        mass_flux        = cache%get_global_value(worker%mesh,'mass flux',    'reference')

        call cache%set_global_value(worker%mesh,temperature_flux/mass_flux,'MA total temperature','reference')

    end subroutine finalize_functional
    !*********************************************************************************************



    
    
    
    !>  Store the real value of the actual final functional integral 
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/29/2019
    !!
    !!  param[inout]       cache     Storage for integrals, this contains the overall 
    !!                               functional (ie after parallel communication).     
    !!
    !---------------------------------------------------------------------------------------------
    function store_value(self,cache) result(res) 
        class(mass_averaged_total_temperature_t),   intent(inout)   :: self
        type(functional_cache_t),                   intent(inout)   :: cache

        real(rk)          :: res

        res = cache%ref_cache%get_real('MA total temperature')

    end function store_value
    !*********************************************************************************************



    
    
    !>  Store the derivatives of the actual final functional integral 
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/29/2019
    !!
    !!  param[inout]       cache     Storage for integrals, this contains the overall 
    !!                               functional (ie after parallel communication).     
    !!
    !---------------------------------------------------------------------------------------------
    function store_deriv(self,cache) result(res) 
        class(mass_averaged_total_temperature_t),   intent(inout)   :: self
        type(functional_cache_t),                   intent(inout)   :: cache

        type(chidg_vector_t)       :: res
        
        res = cache%ref_cache%get_deriv('MA total temperature')

    end function store_deriv
    !*********************************************************************************************



end module fcl_mass_averaged_total_temperature
