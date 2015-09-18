module LA_volume_advective_flux
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: NFACES,ZERO,ONE,TWO,HALF, &
                                      XI_MIN,XI_MAX,ETA_MIN,ETA_MAX,ZETA_MIN,ZETA_MAX,DIAG

    use type_mesh,              only: mesh_t
    use atype_volume_flux,      only: volume_flux_t
    use atype_solverdata,       only: solverdata_t
    use type_properties,        only: properties_t
    use mod_interpolate,        only: interpolate
    use mod_integrate,          only: integrate_volume_flux
    use mod_DNAD_tools,         only: compute_neighbor_face, compute_seed_element
    use DNAD_D

    use LA_properties,          only: LA_properties_t
    implicit none
    private

    !
    !
    !----------------------------------------------------------------
    type, extends(volume_flux_t), public :: LA_volume_advective_flux_t


    contains
        procedure   :: compute

    end type LA_volume_advective_flux_t

contains


    !
    !
    !
    !
    !---------------------------------------------------------------
    subroutine compute(self,mesh,sdata,ielem,iblk,prop)
        class(LA_volume_advective_flux_t),  intent(in)      :: self
        class(mesh_t),                      intent(in)      :: mesh
        class(solverdata_t),                intent(inout)   :: sdata
        integer(ik),                        intent(in)      :: ielem, iblk
        class(properties_t),                intent(inout)   :: prop



        type(AD_D), allocatable :: u(:), flux_x(:), flux_y(:), flux_z(:)
        real(rk)                :: cx, cy, cz
        integer(ik)             :: nnodes, ierr, iseed
        integer(ik)             :: ivar_u, i


        associate (elem => mesh%elems(ielem), q => sdata%q)


            !
            ! Get variable index from equation set
            !
            ivar_u = prop%get_eqn_index('u')


            !
            ! Get equation set properties
            !
            select type(prop)
                type is (LA_properties_t)
                    cx = prop%c(1)
                    cy = prop%c(2)
                    cz = prop%c(3)
            end select


            !
            ! Allocate storage for variable values at quadrature points
            !
            nnodes = elem%gq%nnodes_v
            allocate(u(nnodes),         &
                     flux_x(nnodes),    &
                     flux_y(nnodes),    &
                     flux_z(nnodes),    stat = ierr)
            if (ierr /= 0) call AllocationError


            !
            ! Get seed element for derivatives
            !
            iseed   = compute_seed_element(mesh,ielem,iblk)


            !
            ! Interpolate solution to quadrature nodes
            !
            call interpolate(mesh%elems,q,ielem,ivar_u,u,iseed)


            !
            ! Compute volume flux at quadrature nodes
            !
            flux_x = cx  *  u 
            flux_y = cy  *  u
            flux_z = cz  *  u


            !
            ! Integrate volume flux
            !
            call integrate_volume_flux(elem,sdata,ivar_u,iblk,flux_x,flux_y,flux_z)

        end associate

    end subroutine






end module LA_volume_advective_flux