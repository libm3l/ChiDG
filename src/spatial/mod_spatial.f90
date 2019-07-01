module mod_spatial
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: NFACES, DIAG, CHIMERA, INTERIOR, NO_ID, ZERO
    use mod_chidg_mpi,          only: IRANK, NRANK, ChiDG_COMM, GLOBAL_MASTER
    use mod_io,                 only: verbosity
    use mpi_f08,                only: MPI_Barrier
    use DNAD_D

    use type_chidg_data,        only: chidg_data_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_chidg_cache,       only: chidg_cache_t
    use type_cache_handler,     only: cache_handler_t
    use type_element_info,      only: element_info_t, element_info
    use type_timer,             only: timer_t
    implicit none

    type(chidg_cache_t)         :: cache
    type(cache_handler_t)       :: cache_handler

contains





    !>  Spatial loop through domains, elements, and faces. Functions get called for each 
    !!  element/face.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/15/2016
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/16/2016
    !!  @note   Improved layout, added computation of diffusion terms.
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine update_space(data,differentiate,timing)
        type(chidg_data_t), intent(inout),  target      :: data
        logical,            intent(in)                  :: differentiate
        real(rk),           intent(inout),  optional    :: timing

        integer(ik)                 :: idom, ielem, iface, idiff, ierr, &
                                       diff_min, diff_max, eqn_ID, nelem_total, &
                                       loop_status
        real(rk)                    :: percent_complete, percent_report
        type(timer_t)               :: total_timer, comm_timer, cache_timer, function_timer

        type(element_info_t)        :: elem_info
        type(chidg_worker_t)        :: worker


        ! Initialize Chidg Worker references
        call worker%init(data%mesh, data%eqnset(:)%prop, data%sdata, data%time_manager, cache)


        ! Start timer on spatial discretization update
        call total_timer%start()

    

        ! Clear function_status data. This tracks if a function has already been called. So, 
        ! in this way we can compute a function on a face and apply it to both elements. 
        ! The function is just registered as computed for both. So we need to reset all of 
        ! that data here. This is only tracked for the interior discretization. Boundary condition 
        ! evaluations and Chimera faces are not tracked.
        call data%sdata%function_status%clear()



        ! Communicate solution vector
        call comm_timer%start()
        call data%sdata%q%assemble()
        call comm_timer%stop()


        ! Loop through given element compute the residual functions and also the 
        ! linearization of those functions.
        call write_line('-  Updating spatial residual', io_proc=GLOBAL_MASTER, silence=(verbosity < 3))


        ! Clear function_status data. This tracks if a function has already been called. So, in this way
        ! we can compute a function on a face and apply it to both elements. The function is just registered
        ! as computed for both. So we need to reset all of that data here. This is only tracked for the interior 
        ! discretization. Boundary condition evaluations and Chimera faces are not tracked.
        call data%sdata%function_status%clear()



        ! Set time info on chidg_worker
        worker%itime = data%time_manager%itime
        worker%t     = data%time_manager%t
        nelem_total  = data%mesh%nelements()


        loop_status = 0
        percent_complete = ZERO
        percent_report = 20.
        do idom = 1,data%mesh%ndomains()
            do ielem = 1,data%mesh%domain(idom)%nelements()
                eqn_ID = worker%mesh%domain(idom)%elems(ielem)%eqn_ID
                associate ( domain => data%mesh%domain(idom), eqnset => data%eqnset(eqn_ID) )


                elem_info = element_info(idomain_g       = domain%elems(ielem)%idomain_g,       &
                                         idomain_l       = domain%elems(ielem)%idomain_l,       &
                                         ielement_g      = domain%elems(ielem)%ielement_g,      &
                                         ielement_l      = domain%elems(ielem)%ielement_l,      &
                                         iproc           = domain%elems(ielem)%iproc,           &
                                         pelem_ID        = NO_ID,                               &
                                         eqn_ID          = domain%elems(ielem)%eqn_ID,          &
                                         nfields         = domain%elems(ielem)%nfields,         &
                                         ntime           = domain%elems(ielem)%ntime,           &
                                         nterms_s        = domain%elems(ielem)%nterms_s,        &
                                         nterms_c        = domain%elems(ielem)%nterms_c,        &
                                         dof_start       = domain%elems(ielem)%dof_start,       &
                                         dof_local_start = domain%elems(ielem)%dof_local_start, &
                                         recv_comm       = domain%elems(ielem)%recv_comm,       &
                                         recv_domain     = domain%elems(ielem)%recv_domain,     &
                                         recv_element    = domain%elems(ielem)%recv_element,    &
                                         recv_dof        = domain%elems(ielem)%recv_dof)

                call worker%set_element(elem_info)


                ! Update the element cache
                call cache_timer%start()
                call cache_handler%update(worker,data%eqnset, data%bc_state_group, components    = 'all',           &
                                                                                   face          = NO_ID,           &
                                                                                   differentiate = differentiate,   &
                                                                                   lift          = .true.)
                call cache_timer%stop()


                ! Faces loop. For the current element, compute the 
                ! contributions from boundary integrals.
                call function_timer%start()
                do iface = 1,NFACES

                    call worker%set_face(iface)

                    call eqnset%compute_boundary_advective_operators(worker, differentiate)
                    call eqnset%compute_boundary_diffusive_operators(worker, differentiate)
                    call eqnset%compute_bc_operators(worker,data%bc_state_group, differentiate)

                end do  ! faces loop

                
                ! Compute contributions from volume integrals
                call eqnset%compute_volume_advective_operators(worker, differentiate)
                call eqnset%compute_volume_diffusive_operators(worker, differentiate)
                call function_timer%stop()




                end associate

                ! Report every x-percent
                loop_status = loop_status + 1 
                if (real(loop_status,rk)/real(nelem_total,rk)*100. > percent_report) then
                    percent_complete = percent_complete + percent_report
                    loop_status = 0
                    call write_line('-',nint(percent_complete),'percent complete...',ltrim=.true.,io_proc=GLOBAL_MASTER,silence=(verbosity<4))
                end if



            end do  ! ielem
        end do  ! idom


        call data%sdata%rhs%assemble()
        if (differentiate) call data%sdata%lhs%assemble()


        ! Synchronize
        call MPI_Barrier(ChiDG_COMM,ierr)
        call total_timer%stop()


        ! Timing IO
        call write_line('- total time: ',    total_timer%elapsed(),                  delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('- comm time: ',     comm_timer%elapsed(),                   delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('- cache time: ',    cache_timer%elapsed(),                  delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('-- resize time: ',   cache_handler%timer_resize%elapsed(),  delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('-- primary time: ',  cache_handler%timer_primary%elapsed(), delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('-- model time: ',    cache_handler%timer_model%elapsed(),   delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('-- gradient time: ', cache_handler%timer_lift%elapsed(),    delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('--- model grad compute time: ', cache_handler%timer_model_grad_compute%elapsed(),    delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))
        call write_line('- function time: ', function_timer%elapsed(),               delimiter='', io_proc=GLOBAL_MASTER, silence=(verbosity<3))

        if (present(timing)) then
            timing = total_timer%elapsed()
        end if


    end subroutine update_space
    !****************************************************************************************















end module mod_spatial
