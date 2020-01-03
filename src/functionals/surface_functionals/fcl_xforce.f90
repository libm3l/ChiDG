module fcl_xforce
#include <messenger.h>
    use mod_kinds,                  only: ik, rk
    use type_evaluator,             only: evaluator_t
    use type_chidg_worker,          only: chidg_worker_t
    use mod_fluid,                  only: Rgas,cp, gam
    use mod_constants,              only: HALF, ONE, ZERO
    use type_functional_cache,      only: functional_cache_t
    use type_chidg_vector,          only: chidg_vector_t
    use mod_functional_operators
    use DNAD_D
    implicit none



    !>  This functional computes the X-force generated by a given surface 
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/11/2017
    !!
    !!  Restructured functional computation
    !!
    !!  @author Matteo Ugolotti
    !!  @date   3/7/2019
    !!
    !------------------------------------------------------------------------------------------
    type,  extends(evaluator_t), public   :: xforce_t
   
        ! Quantities needed for the computation
        ! Used to check completeness of information provided
        integer(ik)     :: min_ref_geom = 1
        integer(ik)     :: min_aux_geom = 0
        integer(ik)     :: max_ref_geom = 100
        integer(ik)     :: max_aux_geom = 0

        ! Read from parameter.nml, 0 by default
        real(rk)        :: AoA = ZERO

    contains

        procedure, public   :: init
        procedure, public   :: check
        procedure, public   :: compute_functional
        procedure, public   :: store_value
        procedure, public   :: store_deriv

    end type xforce_t
    !******************************************************************************************



contains



    !>  Initialize the functional
    !!
    !!  @author Matteo Ugolotti
    !!  @date   03/11/2018
    !!
    !------------------------------------------------------------------------------------------
    subroutine init(self)
        class(xforce_t), intent(inout)   :: self

        ! Start defining the evaluator information
        call self%set_name("X-force")
        call self%set_eval_type("Functional")
        call self%set_int_type("FACE INTEGRAL")

    end subroutine init
    !******************************************************************************************





    !>  This procedure checks that all the information have been provided by the user to fully 
    !!  compute the functional
    !!
    !!  @author Matteo Ugolotti
    !!  @date   03/11/2018
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine check(self)
        class(xforce_t), intent(inout)   :: self

        integer(ik)                     :: aux_geoms, ref_geoms
        character(len=:), allocatable   :: usr_msg_r, usr_msg_a
        logical                         :: ref_geoms_exceed, aux_geoms_exceed

        ! Check that the functional has all the information needed
        ref_geoms = self%n_ref_geom()
        aux_geoms = self%n_aux_geom()

        ref_geoms_exceed = (ref_geoms < self%min_ref_geom .or. ref_geoms > self%max_ref_geom)
        aux_geoms_exceed = (aux_geoms < self%min_aux_geom .or. aux_geoms > self%max_aux_geom)

        usr_msg_r = "fcl_xforce: wrong number of reference geometries. The minimum number of reference geometries is 1."
        usr_msg_a = "fcl_xforce: wrong number of auxiliary geometries. The minimum number of auxiliary geometries is 1."

        if (ref_geoms_exceed) call chidg_signal(FATAL, usr_msg_r)
        if (aux_geoms_exceed) call chidg_signal(FATAL, usr_msg_a)

    end subroutine check 
    !******************************************************************************************






    !>  Computing the xforce 
    !!  Taken from mod_chidg_airfoil.f90
    !!
    !!  @author Matteo Ugolotti
    !!  @date   03/11/2018
    !!
    !!  Restructured functional computation
    !!
    !!  @author Matteo Ugolotti
    !!  @date   3/7/2019
    !!
    !!  param[inout]       worker
    !!  param[inout]       cache     cache contains the overall iintegrals value at this point,
    !!                               since the parallel communication already happened 
    !!
    !------------------------------------------------------------------------------------------
    subroutine compute_functional(self,worker,cache)
        class(xforce_t),                intent(inout)   :: self
        type(chidg_worker_t),           intent(inout)   :: worker
        type(functional_cache_t),       intent(inout)   :: cache

        type(AD_D), allocatable, dimension(:) :: pressure, tau_11, tau_22, tau_33,      &
                                                 tau_12, tau_13, tau_23, tau_21,        &
                                                 tau_31, tau_32, xforce_gq, stress_x,   &
                                                 stress_y, stress_z,                    &
                                                 norm_1, norm_2, norm_3,                &
                                                 unorm_1, unorm_2, unorm_3

        type(AD_D)                            :: xforce

        ! Get pressure
        pressure = worker%get_field('Pressure', 'value', 'face interior')


        ! Get shear stress tensor
        tau_11 = worker%get_field('Shear-11', 'value', 'face interior')
        tau_22 = worker%get_field('Shear-22', 'value', 'face interior')
        tau_33 = worker%get_field('Shear-33', 'value', 'face interior')
        tau_12 = worker%get_field('Shear-12', 'value', 'face interior')
        tau_13 = worker%get_field('Shear-13', 'value', 'face interior')
        tau_23 = worker%get_field('Shear-23', 'value', 'face interior')

        ! From symmetry
        tau_21 = tau_12
        tau_31 = tau_13
        tau_32 = tau_23

        
        ! Add pressure component
        tau_11 = tau_11 - pressure
        tau_22 = tau_22 - pressure
        tau_33 = tau_33 - pressure


        ! Get normal vectors and reverse, because we want outward-facing vector from
        ! the geometry.
        norm_1  = -worker%normal(1)
        norm_2  = -worker%normal(2)
        norm_3  = -worker%normal(3)

        unorm_1 = -worker%unit_normal(1)
        unorm_2 = -worker%unit_normal(2)
        unorm_3 = -worker%unit_normal(3)
        

        ! Compute \vector{n} dot \tensor{tau}
        !   : These should produce the same result since the tensor is 
        !   : symmetric. Not sure which is more correct.
        !
        !stress_x = unorm_1*tau_11 + unorm_2*tau_21 + unorm_3*tau_31
        !stress_y = unorm_1*tau_12 + unorm_2*tau_22 + unorm_3*tau_32
        !stress_z = unorm_1*tau_13 + unorm_2*tau_23 + unorm_3*tau_33
        stress_x = tau_11*unorm_1 + tau_12*unorm_2 + tau_13*unorm_3
        stress_y = tau_21*unorm_1 + tau_22*unorm_2 + tau_23*unorm_3
        stress_z = tau_31*unorm_1 + tau_32*unorm_2 + tau_33*unorm_3


        ! Compute xforce Force at quadrature nodes
        xforce_gq = stress_x !* dcos(self%AoA) + stress_y * dsin(self%AoA)
        
        ! Compute face integral over the element face
        xforce = integrate_surface(worker,xforce_gq)
        
        ! Store in cache 
        call cache%set_value(worker%mesh,xforce,'xforce','reference',worker%function_info) 

    end subroutine compute_functional
    !******************************************************************************************





    !>  Store the real value of the actual final functional integral 
    !!
    !!  @author Matteo Ugolotti
    !!  @date   3/7/2019
    !!
    !!  param[inout]       cache     Storage for integrals, this contains the overall 
    !!                               functional (ie after parallel communication).     
    !!
    !---------------------------------------------------------------------------------------------
    function store_value(self,cache) result(res) 
        class(xforce_t),                intent(inout)   :: self
        type(functional_cache_t),       intent(inout)   :: cache

        real(rk)          :: res

        res = cache%ref_cache%get_real('xforce')

    end function store_value
    !*********************************************************************************************



    
    
    !>  Store the derivatives of the actual final functional integral 
    !!
    !!  @author Matteo Ugolotti
    !!  @date   3/7/2019
    !!
    !!  param[inout]       cache     Storage for integrals, this contains the overall 
    !!                               functional (ie after parallel communication).     
    !!
    !---------------------------------------------------------------------------------------------
    function store_deriv(self,cache) result(res) 
        class(xforce_t),                intent(inout)   :: self
        type(functional_cache_t),       intent(inout)   :: cache

        type(chidg_vector_t)       :: res
        
        res = cache%ref_cache%get_deriv('xforce')

    end function store_deriv
    !*********************************************************************************************


end module fcl_xforce
