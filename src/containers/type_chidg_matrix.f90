module type_chidg_matrix
#include <messenger.h>
#include "petsc/finclude/petscmat.h"
    use petscmat,               only: PETSC_DECIDE, MatCreate, MatSetType, MatSetSizes, MatSetUp, &
                                      MatSetValues, tMat, ADD_VALUES, MatAssemblyBegin, MatAssemblyEnd, &
                                      MAT_FINAL_ASSEMBLY, MatZeroEntries, MatSeqAIJSetPreallocation,    &
                                      MatMPIAIJSetPreallocation, PETSC_NULL_INTEGER, MatSetOption,      &
                                      MAT_NEW_NONZERO_ALLOCATION_ERR, PETSC_FALSE, MatDestroy

    use mod_kinds,              only: rk, ik
    use mod_constants,          only: NO_ID, ZERO
    use mod_chidg_mpi,          only: IRANK, ChiDG_COMM
    use mpi_f08,                only: MPI_AllReduce, MPI_SUM, MPI_INTEGER4, MPI_INTEGER8
    use type_densematrix,       only: densematrix_t
    use type_domain_matrix,     only: domain_matrix_t
    use type_mesh,              only: mesh_t
    use type_element_info,      only: element_info_t
    use type_seed,              only: seed_t
    use type_chidg_vector,      only: chidg_vector_t
    use DNAD_D
    implicit none


    private chidg_store, chidg_store_chimera, chidg_store_bc, chidg_store_hb, chidg_clear
    public chidg_matrix_t, chidg_matrix


    !>  ChiDG matrix type. Contains an array of domain_matrix_t types, each corresponding to a 
    !!  domain.
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !!  TODO: TEST self%stamp component and behavior
    !!
    !------------------------------------------------------------------------------------------
    type, public :: chidg_matrix_t

        ! PETSC
        Mat         :: petsc_matrix
        logical     :: petsc_matrix_created = .false.

        ! ChiDG
        type(domain_matrix_t), allocatable    :: dom(:) ! Array of domain-matrices. One for each domain
        logical     :: local_initialized = .false.      ! Has the matrix processor-local data been initialized
        logical     :: recv_initialized  = .false.      ! Has matrix been initialized with information about chidg_vector%recv


        ! backend dynamic procedures
        !procedure(init_interface),     pointer, pass :: init          => chidg_init
        !procedure(store_interface),    pointer, pass :: store         => chidg_store
        !procedure(store_interface),    pointer, pass :: store_chimera => chidg_store_chimera
        !procedure(store_interface),    pointer, pass :: store_bc      => chidg_store_bc
        !procedure(store_interface),    pointer, pass :: store_hb      => chidg_store_hb
        !procedure(clear_interface),    pointer, pass :: clear         => chidg_clear
        !procedure(clear_interface),    pointer, pass :: assemble      => chidg_assemble
        !procedure(init_recv_interface) pointer, pass :: init_recv     => chidg_init_recv

        procedure(init_interface),      pointer, pass :: init          => petsc_init
        procedure(store_interface),     pointer, pass :: store         => petsc_store
        procedure(store_interface),     pointer, pass :: store_chimera => petsc_store
        procedure(store_interface),     pointer, pass :: store_bc      => petsc_store
        procedure(store_interface),     pointer, pass :: store_hb      => petsc_store
        procedure(clear_interface),     pointer, pass :: clear         => petsc_clear
        procedure(clear_interface),     pointer, pass :: assemble      => petsc_assemble
        procedure(init_recv_interface), pointer, pass :: init_recv     => petsc_init_recv


        ! Stamp for uniqueness
        integer     :: stamp(8) = NO_ID                 ! Stamp from date_and_time that gets updated when store routines are called

    contains

        ! Processors
        procedure   :: restrict

        procedure   :: get_ntime
        procedure   :: ndomains
        procedure   :: to_file                          ! Write matrix to file
        procedure   :: to_real                          ! Return the matrix stored as real

        procedure   :: release
        final       :: destructor

    end type chidg_matrix_t
    !*****************************************************************************************




    interface 
        subroutine init_interface(self,mesh,mtype)
            import chidg_matrix_t
            import mesh_t
            class(chidg_matrix_t),  intent(inout)   :: self
            type(mesh_t),           intent(in)      :: mesh
            character(*),           intent(in)      :: mtype
        end subroutine init_interface
    end interface


    interface 
        subroutine init_recv_interface(self,x)
            import chidg_matrix_t
            import chidg_vector_t
            class(chidg_matrix_t),  intent(inout)   :: self
            type(chidg_vector_t),   intent(in)      :: x
        end subroutine init_recv_interface
    end interface


    interface 
        subroutine store_interface(self,integral,element_info,seed,ivar,itime)
            import chidg_matrix_t
            import AD_D
            import element_info_t
            import seed_t
            import ik
            class(chidg_matrix_t),  intent(inout)   :: self
            type(AD_D),             intent(in)      :: integral(:)
            type(element_info_t),   intent(in)      :: element_info
            type(seed_t),           intent(in)      :: seed
            integer(ik),            intent(in)      :: ivar 
            integer(ik),            intent(in)      :: itime
        end subroutine store_interface
    end interface

    interface 
        subroutine clear_interface(self)
            import chidg_matrix_t
            class(chidg_matrix_t),  intent(inout)   :: self
        end subroutine clear_interface
    end interface

    interface chidg_matrix
        module procedure new_chidg_matrix
    end interface


    private
contains


    !>
    !!
    !!
    !!
    !!
    !-----------------------------------------------------------------------------------
    function new_chidg_matrix(storage) result(mat)
        character(*),   intent(in)  :: storage

        type(chidg_matrix_t)    :: mat

        select case(storage)
            case('native')
                call matrix_assign_pointers_chidg(mat)
            case('petsc')
                call matrix_assign_pointers_petsc(mat)
            case default
                call chidg_signal_one(FATAL,"new_chidg_matrix: invalid parameter for 'storage'.",trim(storage))
        end select

    end function new_chidg_matrix
    !***********************************************************************************











    !>  Subroutine for initializing chidg_matrix_t using chidg native backend storage.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_init(self,mesh,mtype)
        class(chidg_matrix_t),  intent(inout)   :: self
        type(mesh_t),           intent(in)      :: mesh
        character(*),           intent(in)      :: mtype

        integer(ik) :: ierr, ndomains, idom

        ! Deallocate storage if necessary in case this is being called as a 
        ! reinitialization routine.
        if (allocated(self%dom)) deallocate(self%dom)

        ! Allocate domain_matrix_t for each domain
        ndomains = mesh%ndomains()
        allocate(self%dom(ndomains), stat=ierr)
        if (ierr /= 0) call AllocationError

        ! Call initialization procedure for each domain_matrix_t
        do idom = 1,ndomains
             call self%dom(idom)%init(mesh,idom,mtype=mtype)
        end do

        ! Set initialization to true
        self%local_initialized = .true.

    end subroutine chidg_init
    !******************************************************************************************





    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   7/1/2016
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_init_recv(self,x)
        class(chidg_matrix_t),   intent(inout)   :: self
        type(chidg_vector_t),    intent(in)      :: x

        integer(ik) :: idom, ielem, iblk, itime, matrix_proc, vector_proc, comm_proc
        integer(ik) :: dparent_g, eparent_g, parent_proc, icomm, idom_recv, ielem_recv, &
                       drecv_g, erecv_g, recv_domain, recv_elem, imat
        logical     :: local_multiply, parallel_multiply, match_found

        
        !
        ! Loop through INTERIOR coupling and look for parallel multiply
        !
        do idom = 1,size(self%dom)
            do ielem = 1,size(self%dom(idom)%lblks,1)
                do itime = 1,size(self%dom(idom)%lblks,2)
                    do imat = 1,self%dom(idom)%lblks(ielem,itime)%size()

                        matrix_proc = IRANK
                        vector_proc = self%dom(idom)%lblks(ielem,itime)%parent_proc(imat)

                        local_multiply    = ( matrix_proc == vector_proc )
                        parallel_multiply = ( matrix_proc /= vector_proc )


                        if ( parallel_multiply ) then
                            !
                            ! Get information about element we need to multiply with
                            !
                            dparent_g   = self%dom(idom)%lblks(ielem,itime)%dparent_g(imat)
                            eparent_g   = self%dom(idom)%lblks(ielem,itime)%eparent_g(imat)
                            parent_proc = self%dom(idom)%lblks(ielem,itime)%parent_proc(imat)



                            !
                            ! Loop through chidg_vector%recv to find match
                            !
                            match_found = .false.
                            do icomm = 1,size(x%recv%comm)

                                comm_proc = x%recv%comm(icomm)%proc

                                if ( comm_proc == parent_proc ) then
                                    do idom_recv = 1,size(x%recv%comm(icomm)%dom)
                                        do ielem_recv = 1,size(x%recv%comm(icomm)%dom(idom_recv)%vecs)

                                            ! Get recv element indices
                                            drecv_g = x%recv%comm(icomm)%dom(idom_recv)%vecs(ielem_recv)%dparent_g()
                                            erecv_g = x%recv%comm(icomm)%dom(idom_recv)%vecs(ielem_recv)%eparent_g()

                                            ! If they match the domain_matrix, set the recv indices so chidg_mv knows how to compute matrix-vector product
                                            if ( (drecv_g == dparent_g) .and. (erecv_g == eparent_g) ) then
                                                call self%dom(idom)%lblks(ielem,itime)%set_recv_comm(imat,icomm)
                                                call self%dom(idom)%lblks(ielem,itime)%set_recv_domain(imat,idom_recv)
                                                call self%dom(idom)%lblks(ielem,itime)%set_recv_element(imat,ielem_recv)
                                                match_found = .true.
                                            end if

                                        end do !ielem_recv
                                    end do !idom_recv
                                end if

                            end do ! icomm

                            if (.not. match_found) call chidg_signal(FATAL,"chidg_matrix%init_recv: no matching recv element found in vector")



                        end if



                    end do !imat
                end do !itime
            end do !ielem
        end do ! idom









        !
        ! Loop through CHIMERA coupling and look for parallel multiply
        !
        do idom = 1,size(self%dom)

            if (allocated(self%dom(idom)%chi_blks)) then
                do ielem = 1,size(self%dom(idom)%chi_blks,1)
                    do itime = 1,size(self%dom(idom)%chi_blks,2)
                        do imat = 1,self%dom(idom)%chi_blks(ielem,itime)%size()
                        
                            matrix_proc = IRANK
                            vector_proc = self%dom(idom)%chi_blks(ielem,itime)%parent_proc(imat)

                            local_multiply    = ( matrix_proc == vector_proc )
                            parallel_multiply = ( matrix_proc /= vector_proc )


                            if ( parallel_multiply ) then
                                !
                                ! Get information about element we need to multiply with
                                !
                                dparent_g   = self%dom(idom)%chi_blks(ielem,itime)%dparent_g(imat)
                                eparent_g   = self%dom(idom)%chi_blks(ielem,itime)%eparent_g(imat)
                                parent_proc = self%dom(idom)%chi_blks(ielem,itime)%parent_proc(imat)



                                !
                                ! Loop through chidg_vector%recv to find match
                                !
                                match_found = .false.
                                do icomm = 1,size(x%recv%comm)

                                    comm_proc = x%recv%comm(icomm)%proc

                                    if ( comm_proc == parent_proc ) then
                                        do idom_recv = 1,size(x%recv%comm(icomm)%dom)
                                            
                                            recv_domain = x%recv%comm(icomm)%dom(idom_recv)%vecs(1)%dparent_g()
                                            if ( recv_domain == dparent_g ) then

                                            do ielem_recv = 1,size(x%recv%comm(icomm)%dom(idom_recv)%vecs)

                                                ! Get recv element indices
                                                recv_elem = x%recv%comm(icomm)%dom(idom_recv)%vecs(ielem_recv)%eparent_g()

                                    

                                                ! If they match the domain_matrix, set the recv indices so chidg_mv knows how to compute matrix-vector product
                                                if ( recv_elem == eparent_g )  then
                                                    call self%dom(idom)%chi_blks(ielem,itime)%set_recv_comm(imat,icomm)
                                                    call self%dom(idom)%chi_blks(ielem,itime)%set_recv_domain(imat,idom_recv)
                                                    call self%dom(idom)%chi_blks(ielem,itime)%set_recv_element(imat,ielem_recv)
                                                    match_found = .true.
                                                    exit
                                                end if

                                            end do !ielem_recv

                                            end if ! recv_domain == dparent

                                            if (match_found) exit
                                        end do !idom_recv
                                    end if

                                    if (match_found) exit

                                end do ! icomm

                                if (.not. match_found) call chidg_signal(FATAL,"chidg_matrix%init_recv: no matching recv element found in vector")

                            end if


                        end do !imat
                    end do !itime
                end do !ielem
            end if

        end do ! idom






        !
        ! Loop through BOUNDARY coupling and look for parallel multiply
        !
        do idom = 1,size(self%dom)

            if (allocated(self%dom(idom)%bc_blks)) then
                do ielem = 1,size(self%dom(idom)%bc_blks,1)
                    do itime = 1,size(self%dom(idom)%bc_blks,2)
                        do imat = 1,self%dom(idom)%bc_blks(ielem,itime)%size()
                        
                            matrix_proc = IRANK
                            vector_proc = self%dom(idom)%bc_blks(ielem,itime)%parent_proc(imat)

                            local_multiply    = ( matrix_proc == vector_proc )
                            parallel_multiply = ( matrix_proc /= vector_proc )


                            if ( parallel_multiply ) then
                                !
                                ! Get information about element we need to multiply with
                                !
                                dparent_g   = self%dom(idom)%bc_blks(ielem,itime)%dparent_g(imat)
                                eparent_g   = self%dom(idom)%bc_blks(ielem,itime)%eparent_g(imat)
                                parent_proc = self%dom(idom)%bc_blks(ielem,itime)%parent_proc(imat)



                                !
                                ! Loop through chidg_vector%recv to find match
                                !
                                match_found = .false.
                                do icomm = 1,size(x%recv%comm)

                                    comm_proc = x%recv%comm(icomm)%proc

                                    if ( comm_proc == parent_proc ) then
                                        do idom_recv = 1,size(x%recv%comm(icomm)%dom)
                                            
                                            recv_domain = x%recv%comm(icomm)%dom(idom_recv)%vecs(1)%dparent_g()
                                            if ( recv_domain == dparent_g ) then

                                            do ielem_recv = 1,size(x%recv%comm(icomm)%dom(idom_recv)%vecs)

                                                ! Get recv element indices
                                                recv_elem = x%recv%comm(icomm)%dom(idom_recv)%vecs(ielem_recv)%eparent_g()

                                    

                                                ! If they match the domain_matrix, set the recv indices so chidg_mv can compute m-v product
                                                if ( recv_elem == eparent_g )  then
                                                    call self%dom(idom)%bc_blks(ielem,itime)%set_recv_comm(imat,icomm)
                                                    call self%dom(idom)%bc_blks(ielem,itime)%set_recv_domain(imat,idom_recv)
                                                    call self%dom(idom)%bc_blks(ielem,itime)%set_recv_element(imat,ielem_recv)
                                                    match_found = .true.
                                                    exit
                                                end if

                                            end do !ielem_recv

                                            end if ! recv_domain == dparent

                                            if (match_found) exit
                                        end do !idom_recv
                                    end if

                                    if (match_found) exit

                                end do ! icomm

                                if (.not. match_found) call chidg_signal(FATAL,"chidg_matrix%init_recv: no matching recv element found in vector")

                            end if


                        end do !imat
                    end do !itime
                end do !ielem
            end if

        end do ! idom



        !
        ! Loop through Harmonic Balance coupling and look for parallel multiply
        !
        do idom = 1,size(self%dom)

            if (allocated(self%dom(idom)%hb_blks)) then
                do ielem = 1,size(self%dom(idom)%hb_blks,1)
                    do itime = 1,size(self%dom(idom)%hb_blks,2)
                        do imat = 1,self%dom(idom)%hb_blks(ielem,itime)%size()
                        
                            matrix_proc = IRANK
                            vector_proc = self%dom(idom)%hb_blks(ielem,itime)%parent_proc(imat)

                            local_multiply    = ( matrix_proc == vector_proc )
                            parallel_multiply = ( matrix_proc /= vector_proc )

                            if ( parallel_multiply ) then
                                !
                                ! Get information about element we need to multiply with
                                !
                                dparent_g   = self%dom(idom)%hb_blks(ielem,itime)%dparent_g(imat)
                                eparent_g   = self%dom(idom)%hb_blks(ielem,itime)%eparent_g(imat)
                                parent_proc = self%dom(idom)%hb_blks(ielem,itime)%parent_proc(imat)


                                !
                                ! Loop through chidg_vector%recv to find match
                                !
                                match_found = .false.
                                do icomm = 1,size(x%recv%comm)
                                    comm_proc = x%recv%comm(icomm)%proc
                                    if ( comm_proc == parent_proc ) then
                                        do idom_recv = 1,size(x%recv%comm(icomm)%dom)
                                            recv_domain = x%recv%comm(icomm)%dom(idom_recv)%vecs(1)%dparent_g()
                                            if ( recv_domain == dparent_g ) then
                                                do ielem_recv = 1,size(x%recv%comm(icomm)%dom(idom_recv)%vecs)

                                                    ! Get recv element indices
                                                    recv_elem = x%recv%comm(icomm)%dom(idom_recv)%vecs(ielem_recv)%eparent_g()

                                                    ! If they match the domain_matrix, set the recv indices so chidg_mv can compute m-v product
                                                    if ( recv_elem == eparent_g )  then
                                                        call self%dom(idom)%hb_blks(ielem,itime)%set_recv_comm(imat,icomm)
                                                        call self%dom(idom)%hb_blks(ielem,itime)%set_recv_domain(imat,idom_recv)
                                                        call self%dom(idom)%hb_blks(ielem,itime)%set_recv_element(imat,ielem_recv)
                                                        match_found = .true.
                                                        exit
                                                    end if

                                                end do !ielem_recv
                                            end if ! recv_domain == dparent
                                            if (match_found) exit
                                        end do !idom_recv
                                    end if
                                    if (match_found) exit
                                end do ! icomm

                                if (.not. match_found) call chidg_signal(FATAL,"chidg_matrix%init_recv: no matching recv element found in vector")

                            end if

                        end do !imat
                    end do !itime
                end do !ielem
            end if
        end do ! idom



        ! Set recv initialization to true
        self%recv_initialized = .true.

    end subroutine chidg_init_recv
    !*******************************************************************************************







    !> Procedure for storing linearization information
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !!  @param[in]  integral    Array of modes from the spatial scheme, with embedded partial 
    !!                          derivatives for the linearization matrix.
    !!  @param[in]  element_info   Information about where the coupling was computed and whom it
    !!                          was computed with respect to.
    !!  @param[in]  ivar        Index of the variable, for which the linearization was computed.
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_store(self,integral,element_info,seed,ifield,itime)
        class(chidg_matrix_t),  intent(inout)   :: self
        type(AD_D),             intent(in)      :: integral(:)
        type(element_info_t),   intent(in)      :: element_info
        type(seed_t),           intent(in)      :: seed
        integer(ik),            intent(in)      :: ifield
        integer(ik),            intent(in)      :: itime

        integer(ik) :: idomain_l

        idomain_l = element_info%idomain_l

        ! Store linearization in associated domain domain_matrix_t
        call self%dom(idomain_l)%store(integral,element_info,seed,ifield,itime)

        ! Update stamp
        call date_and_time(values=self%stamp)

    end subroutine chidg_store
    !*******************************************************************************************








    !> Procedure for stiring linearization information for Chimera faces
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !!  @param[in]  integral    Array of modes from the spatial scheme, with embedded partial 
    !!                          derivatives for the linearization matrix
    !!  @param[in]  face        element_info_t containing the indices defining the Chimera face
    !!  @param[in]  seed        seed_t containing the indices defining the element against 
    !!                          which the Chimera face was linearized
    !!  @param[in]  ivar        Index of the variable, for which the linearization was computed
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_store_chimera(self,integral,element_info,seed,ivar,itime)
        class(chidg_matrix_t),      intent(inout)   :: self
        type(AD_D),                 intent(in)      :: integral(:)
        type(element_info_t),       intent(in)      :: element_info
        type(seed_t),               intent(in)      :: seed
        integer(ik),                intent(in)      :: ivar 
        integer(ik),                intent(in)      :: itime

        integer(ik) :: idomain_l

        idomain_l = element_info%idomain_l

        ! Store linearization in associated domain domain_matrix_t
        call self%dom(idomain_l)%store_chimera(integral,element_info,seed,ivar,itime)

        ! Update stamp
        call date_and_time(values=self%stamp)

    end subroutine chidg_store_chimera
    !******************************************************************************************









    !>  Procedure for storing linearization information for boundary condition faces
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !!  @param[in]  integral    Array of modes from the spatial scheme, with embedded partial
    !!                          derivatives for the linearization matrix
    !!  @param[in]  face        element_info_t containing the indices defining the Chimera face
    !!  @param[in]  seed        seed_t containing the indices defining the element against 
    !!                          which the Chimera face was linearized
    !!  @param[in]  ivar        Index of the variable, for which the linearization was computed
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_store_bc(self,integral,element_info,seed,ivar,itime)
        class(chidg_matrix_t),      intent(inout)   :: self
        type(AD_D),                 intent(in)      :: integral(:)
        type(element_info_t),       intent(in)      :: element_info
        type(seed_t),               intent(in)      :: seed
        integer(ik),                intent(in)      :: ivar 
        integer(ik),                intent(in)      :: itime

        integer(ik) :: idomain_l

        idomain_l = element_info%idomain_l

        ! Store linearization in associated domain domain_matrix_t
        call self%dom(idomain_l)%store_bc(integral,element_info,seed,ivar,itime)

        ! Update stamp
        call date_and_time(values=self%stamp)

    end subroutine chidg_store_bc
    !*******************************************************************************************





    !>  Procedure for storing linearization information for harmonic-balance cross-timelevel
    !!  coupling.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   4/18/2018
    !!
    !!  @param[in]  integral    Array of modes from the spatial scheme, with embedded partial
    !!                          derivatives for the linearization matrix
    !!  @param[in]  face        element_info_t containing the indices defining the Chimera face
    !!  @param[in]  seed        seed_t containing the indices defining the element against 
    !!                          which the Chimera face was linearized
    !!  @param[in]  ivar        Index of the variable, for which the linearization was computed
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_store_hb(self,integral,element_info,seed,ivar,itime)
        class(chidg_matrix_t),      intent(inout)   :: self
        type(AD_D),                 intent(in)      :: integral(:)
        type(element_info_t),       intent(in)      :: element_info
        type(seed_t),               intent(in)      :: seed
        integer(ik),                intent(in)      :: ivar 
        integer(ik),                intent(in)      :: itime

        integer(ik) :: idomain_l

        idomain_l = element_info%idomain_l

        ! Store linearization in associated domain domain_matrix_t
        call self%dom(idomain_l)%store_hb(integral,element_info,seed,ivar,itime)

        ! Update stamp
        call date_and_time(values=self%stamp)

    end subroutine chidg_store_hb
    !*******************************************************************************************






    !> Set all chidg_matrix matrix-values to zero
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !! 
    !----------------------------------------------------------------------------------
    subroutine chidg_clear(self)
        class(chidg_matrix_t),   intent(inout)   :: self

        integer(ik) :: idom
    
        ! Call domain_matrix_t%clear() on all matrices
        do idom = 1,size(self%dom)
           call self%dom(idom)%clear() 
        end do
    
    end subroutine chidg_clear
    !**********************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   7/1/2016
    !!
    !------------------------------------------------------------------------------------------
    subroutine chidg_assemble(self)
        class(chidg_matrix_t),   intent(inout)   :: self

    end subroutine chidg_assemble
    !*******************************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   7/23/2017
    !!
    !!
    !----------------------------------------------------------------------------------
    function restrict(self,nterms_r) result(restricted)
        class(chidg_matrix_t),  intent(in)  :: self
        integer(ik),            intent(in)  :: nterms_r

        type(chidg_matrix_t)    :: restricted
        integer(ik)             :: ierr, idom

        ! Allocate storage
        allocate(restricted%dom(size(self%dom)), stat=ierr)
        if (ierr /= 0) call AllocationError

        ! Copy restricted versions of domain_matrix_t's
        do idom = 1,size(self%dom)
            restricted%dom(idom) = self%dom(idom)%restrict(nterms_r)
        end do !idom

        restricted%local_initialized = self%local_initialized
        restricted%recv_initialized  = self%recv_initialized
        restricted%stamp             = self%stamp

    end function restrict
    !**********************************************************************************







    !>  Subroutine for initializing chidg_matrix_t using PETSc as backend storage container.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/24/2019
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine petsc_init(self,mesh,mtype)
        class(chidg_matrix_t),  intent(inout)   :: self
        type(mesh_t),           intent(in)      :: mesh
        character(*),           intent(in)      :: mtype

        integer(ik)     :: ndomains, idom, ielem
        PetscErrorCode  :: ierr
        PetscInt        :: nlocal_rows, nlocal_cols, nglobal_rows, nglobal_cols, dof_per_element, nlocal_coupling, nparallel_coupling


        ! Create matrix object
        call MatCreate(ChiDG_COMM%mpi_val, self%petsc_matrix, ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error creating PETSc matrix.')
        self%petsc_matrix_created = .true.



        !
        ! Set matrix size
        !
        !---------------------------------------------

        ! Compute proc-local degress-of-freedom
        nlocal_rows = 0
        do idom = 1,mesh%ndomains()
            do ielem = 1,mesh%domain(idom)%nelements()
                nlocal_rows = nlocal_rows + mesh%domain(idom)%elems(ielem)%nterms_s * mesh%domain(idom)%elems(ielem)%neqns
            end do !ielem
        end do !idom

        ! Compute global degrees-of-freedom via reduction
        call MPI_AllReduce(nlocal_rows,nglobal_rows,1,MPI_INTEGER4,MPI_SUM,ChiDG_COMM,ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error reducing global degrees-of-freedom.')
        

        nlocal_cols  = PETSC_DECIDE
        nglobal_cols = nglobal_rows
        call MatSetSizes(self%petsc_matrix,nlocal_rows,nlocal_cols,nglobal_rows,nglobal_cols,ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error setting up PETSc matrix sizes.')
        !---------------------------------------------



        ! Set matrix type
!        call MatSetType(self%petsc_matrix, 'aij', ierr)
        call MatSetType(self%petsc_matrix, 'baij', ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error setting PETSc matrix type.')




        ! Preallocation
        dof_per_element = mesh%domain(1)%elems(1)%nterms_s * mesh%domain(1)%elems(1)%neqns
        nlocal_coupling = 8
        nparallel_coupling = 3


        ! WARNING! might need to change preallocation approach for AIJ. currently set for BAIJ
!        call MatMPIAIJSetPreallocation(self%petsc_matrix,nnonzeros_per_row,PETSC_NULL_INTEGER,nnonzeros_per_row,PETSC_NULL_INTEGER,ierr)
!        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error calling MatMPIAIJSetPreallocation.')
!        call MatSeqAIJSetPreallocation(self%petsc_matrix,nnonzeros_per_row,PETSC_NULL_INTEGER,ierr)
!        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error calling MatSeqAIJSetPreallocation.')


        call MatMPIBAIJSetPreallocation(self%petsc_matrix,dof_per_element,nlocal_coupling,PETSC_NULL_INTEGER,nparallel_coupling,PETSC_NULL_INTEGER,ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error calling MatMPIBAIJSetPreallocation.')
        call MatSeqBAIJSetPreallocation(self%petsc_matrix,dof_per_element,nlocal_coupling,PETSC_NULL_INTEGER,ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error calling MatSeqBAIJSetPreallocation.')


        call MatSetBlockSize(self%petsc_matrix, dof_per_element, ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_init: error calling MatSetBlockSize.')


        call self%clear()


        ! Set initialization to true
        self%local_initialized = .true.

    end subroutine petsc_init
    !******************************************************************************************









    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   7/1/2016
    !!
    !------------------------------------------------------------------------------------------
    subroutine petsc_init_recv(self,x)
        class(chidg_matrix_t),   intent(inout)   :: self
        type(chidg_vector_t),    intent(in)      :: x

        ! Set recv initialization to true
        self%recv_initialized = .true.

    end subroutine petsc_init_recv
    !*******************************************************************************************







    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   7/1/2016
    !!
    !------------------------------------------------------------------------------------------
    subroutine petsc_assemble(self)
        class(chidg_matrix_t),   intent(inout)   :: self

        PetscErrorCode :: perr

        call MatAssemblyBegin(self%petsc_matrix,MAT_FINAL_ASSEMBLY,perr)
        call MatAssemblyEnd(self%petsc_matrix,MAT_FINAL_ASSEMBLY,perr)

    end subroutine petsc_assemble
    !*******************************************************************************************










    !>
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine petsc_store(self,integral,element_info,seed,ifield,itime)
        class(chidg_matrix_t),  intent(inout)   :: self
        type(AD_D),             intent(in)      :: integral(:)
        type(element_info_t),   intent(in)      :: element_info
        type(seed_t),           intent(in)      :: seed
        integer(ik),            intent(in)      :: ifield
        integer(ik),            intent(in)      :: itime

        integer(ik) :: iarray, i

        PetscErrorCode          :: ierr
        PetscInt                :: nrows, ncols, row_index_start, col_index_start
        PetscInt, allocatable   :: col_indices(:)
        
        row_index_start = element_info%dof_start + (ifield-1)*element_info%nterms_s + (element_info%nfields*element_info%nterms_s)*(itime-1)
        col_index_start = seed%dof_start
        col_indices = [(i, i=col_index_start,(col_index_start+seed%neqns*seed%nterms_s-1),1)]

        nrows = 1
        ncols = size(integral(1)%xp_ad_)
        do iarray = 1,size(integral)
            ! subtract 1 from indices since petsc is 0-based
            call MatSetValues(self%petsc_matrix,nrows,[row_index_start + (iarray-1) - 1],ncols,col_indices-1,integral(iarray)%xp_ad_,ADD_VALUES,ierr)
            if (ierr /= 0) call chidg_signal(FATAL,"chidg_matrix%petsc_store: error calling MatSetValues.")
        end do 

        ! Update stamp
        call date_and_time(values=self%stamp)

    end subroutine petsc_store
    !******************************************************************************************








    !> Set all chidg_matrix matrix-values to zero
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/27/2019
    !! 
    !----------------------------------------------------------------------------------
    subroutine petsc_clear(self)
        class(chidg_matrix_t),   intent(inout)   :: self

        PetscErrorCode :: perr

        call MatZeroEntries(self%petsc_matrix,perr)
        if (perr /= 0) call chidg_signal(FATAL,'chidg_matrix%petsc_clear: error calling MatZeroEntries.')
    
    end subroutine petsc_clear
    !**********************************************************************************










    !>
    !!
    !!  @author Mayank Sharma
    !!  @date   10/05/2017
    !!
    !!  TODO: Put in checks for ntime with relation to different blocks
    !!
    !----------------------------------------------------------------------------------
    function get_ntime(self) result(ntime)
        class(chidg_matrix_t),  intent(in)  :: self

        integer(ik)         :: ntime

        ! Get ntime from densematrix vector array of the 1st domain
        ntime = size(self%dom(1)%lblks,2)

    end function get_ntime
    !**********************************************************************************







    !>  Return matrix as a single real allocation.
    !!
    !!  *** WARNING ***
    !!  only use this for matrices that are known to be small. Calling this for a large system
    !!  will results in very large memory usage.
    !!  *** WARNING ***
    !!
    !!  WARNING: 
    !!      - ASSUMES 1 DOMAIN
    !!      - ASSUMES ALL ELEMENT HAVE SAME ORDER AND NUMBER OF FIELDS.
    !!      - ASSUMES 1 TIME INSTANCE
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/23/2018
    !!
    !-----------------------------------------------------------------------------------------
    subroutine to_real(self,real_matrix)
        class(chidg_matrix_t),      intent(in)      :: self
        real(rk),   allocatable,    intent(inout)   :: real_matrix(:,:)

        type(densematrix_t)     :: dmat
        integer(ik)             :: idom, itime, ielem, iblk, handle, idomain_g, ielement_g, irow, icol, &
                                   nelements, row_offset, col_offset, irow_start, icol_start, block_size, nblk, ierr, ndof


        if (allocated(self%dom)) then

        ! Compute total number of dof's
        ndof = 0
        do idom = 1,self%ndomains()
            do itime = 1,self%dom(idom)%ntime()
                do ielem = 1,self%dom(idom)%nelements()
                    dmat = self%dom(idom)%lblks(ielem,itime)%at(1)
                    ndof = ndof + size(dmat%mat,1)
                end do
            end do
        end do


        ! Allocate storage for LHS matrix
        allocate(real_matrix(ndof,ndof), stat=ierr)
        if (ierr /= 0) call AllocationError


        ! Store matrix entries in LHS
        real_matrix = ZERO
        do idom = 1,self%ndomains()
            do itime = 1,self%dom(idom)%ntime()
                do ielem = 1,self%dom(idom)%nelements()
                    do iblk = 1,self%dom(idom)%lblks(ielem,itime)%size()

                        nblk = self%dom(idom)%lblks(ielem,itime)%size()
                        dmat = self%dom(idom)%lblks(ielem,itime)%at(iblk)
                        block_size = size(dmat%mat,1)


                        ! Coupled element
                        idomain_g  = dmat%dparent_g()
                        ielement_g = dmat%eparent_g()

                        
                        ! Compute global indices for the current block index (1,1)
                        irow_start = 1  +  block_size*(ielem-1)
                        icol_start = 1  +  block_size*(ielement_g-1)

                        
                        ! Compute offset indices
                        do col_offset = 1,block_size
                            do row_offset = 1,block_size

                                irow = irow_start + (row_offset-1)
                                icol = icol_start + (col_offset-1)
                                real_matrix(irow,icol) = dmat%mat(row_offset,col_offset)

                            end do
                        end do 

                    end do !iblk
                end do !ielem
            end do !itime
        end do !idom

        end if !allocated

    end subroutine to_real
    !**************************************************************************






    !>  Write matrix to file.
    !!
    !!  WARNING: 
    !!      - ASSUMES 1 DOMAIN
    !!      - ASSUMES ALL ELEMENT HAVE SAME ORDER AND NUMBER OF FIELDS.
    !!      - ASSUMES 1 TIME INSTANCE
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/27/2017
    !!
    !-----------------------------------------------------------------------------------------
    subroutine to_file(self,filename)
        class(chidg_matrix_t),  intent(in)  :: self
        character(*),           intent(in)  :: filename

        type(densematrix_t)     :: dmat
        integer(ik)             :: idom, itime, ielem, iblk, handle, idomain_g, ielement_g, irow, icol, &
                                   nelements, row_offset, col_offset, irow_start, icol_start, block_size, nblk

        ! Open file
        open(newunit=handle, file=trim(filename))

        ! Write format
        call write_line('(irow, icol, nblk, value)')


        do idom = 1,self%ndomains()
            do itime = 1,self%dom(idom)%ntime()
                do ielem = 1,self%dom(idom)%nelements()
                    do iblk = 1,self%dom(idom)%lblks(ielem,itime)%size()

                        nblk = self%dom(idom)%lblks(ielem,itime)%size()
                        dmat = self%dom(idom)%lblks(ielem,itime)%at(iblk)
                        block_size = size(dmat%mat,1)


                        ! Coupled element
                        idomain_g  = dmat%dparent_g()
                        ielement_g = dmat%eparent_g()

                        
                        ! Compute global indices for the current block index (1,1)
                        irow_start = 1  +  block_size*(ielem-1)
                        icol_start = 1  +  block_size*(ielement_g-1)

                        
                        ! Compute offset indices
                        do col_offset = 1,block_size
                            do row_offset = 1,block_size

                                irow = irow_start + (row_offset-1)
                                icol = icol_start + (col_offset-1)
                                call write_line(irow,icol,nblk,dmat%mat(row_offset,col_offset), columns=.true., column_width=25, delimiter=',', ltrim=.true., handle=handle)

                            end do
                        end do 

                    end do !iblk
                end do !ielem
            end do !itime
        end do !idom



        ! Close file
        close(handle)

    end subroutine to_file
    !**************************************************************************






    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/27/2017
    !!
    !------------------------------------------------------------------------------
    function ndomains(self) result(ndomains_)
       class(chidg_matrix_t),   intent(in)  :: self
       
       integer(ik)  :: ndomains_
       
       ndomains_ = size(self%dom) 

    end function ndomains
    !******************************************************************************








    !>  Release allocated resources.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/3/2017
    !!
    !----------------------------------------------------------------------------------
    subroutine release(self)
        class(chidg_matrix_t),  intent(inout)   :: self

        PetscErrorCode :: ierr

        if (allocated(self%dom)) deallocate(self%dom)


        if (self%petsc_matrix_created) then
            call MatDestroy(self%petsc_matrix,ierr)
            if (ierr /= 0) call chidg_signal(FATAL,'chidg_matrix%release: error calling MatDestroy.')
            self%petsc_matrix_created = .false.
        end if


    end subroutine release
    !**********************************************************************************





    !>  chidg_matrix destructor.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !---------------------------------------------------------------------------------
    subroutine destructor(self)
        type(chidg_matrix_t),    intent(inout)   :: self

        PetscErrorCode :: perr

        if (self%petsc_matrix_created) then
            call MatDestroy(self%petsc_matrix,perr)
            if (perr /= 0) call chidg_signal(FATAL,'chidg_matrix%destructor: error calling MatDestroy.')
            self%petsc_matrix_created = .false.
        end if

    end subroutine destructor
    !*********************************************************************************






    subroutine matrix_assign_pointers_chidg(mat)
        type(chidg_matrix_t),   intent(inout)   :: mat

        mat%init          => chidg_init
        mat%init_recv     => chidg_init_recv
        mat%store         => chidg_store
        mat%store_chimera => chidg_store_chimera
        mat%store_bc      => chidg_store_bc
        mat%store_hb      => chidg_store_hb
        mat%clear         => chidg_clear
        mat%assemble      => chidg_assemble

    end subroutine matrix_assign_pointers_chidg

    subroutine matrix_assign_pointers_petsc(mat)
        type(chidg_matrix_t),   intent(inout)   :: mat

        mat%init          => petsc_init
        mat%init_recv     => petsc_init_recv
        mat%store         => petsc_store
        mat%store_chimera => petsc_store
        mat%store_bc      => petsc_store
        mat%store_hb      => petsc_store
        mat%clear         => petsc_clear
        mat%assemble      => petsc_assemble

    end subroutine matrix_assign_pointers_petsc
















end module type_chidg_matrix
