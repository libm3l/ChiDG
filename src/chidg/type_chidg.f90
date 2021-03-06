module type_chidg
#include <messenger.h>
    use mod_constants,              only: NFACES, ZERO, ONE, TWO, NO_ID, OUTPUT_RES, dD_DIFF, dBC_DIFF, dX_DIFF
    use mod_equations,              only: register_equation_builders
    use mod_operators,              only: register_operators
    use mod_models,                 only: register_models
    use mod_bc,                     only: register_bcs
    use mod_function,               only: register_functions
    use mod_functional,             only: register_functionals
    use mod_prescribed_mesh_motion_function, only: register_prescribed_mesh_motion_functions
    use mod_radial_basis_function,  only: register_radial_basis_functions
    use mod_force,                  only: report_forces
    use mod_hole_cutting,           only: compute_iblank
    use mod_grid,                   only: initialize_grid
    use mod_string,                 only: get_file_extension, string_t, get_file_prefix
    use mod_time,                   only: time_manager_global
    use mod_chimera,                only: clear_donor_cache
    use mod_communication,          only: establish_neighbor_communication, &
                                          establish_chimera_communication
    use mod_chidg_mpi,              only: chidg_mpi_init, chidg_mpi_finalize,   &
                                          IRANK, NRANK, ChiDG_COMM
    use mod_tecio,                  only: write_tecio_file
    use mod_partitioners,           only: partition_connectivity, send_partitions, &
                                          recv_partition
    use mod_datafile_io,            only: write_functionals_file, write_BC_sensitivities_file
    use mod_spatial,                only: update_space
    use mod_update_functionals,     only: update_functionals
    use operator_chidg_mv,          only: chidg_mv
    use operator_chidg_dot,         only: dot_comm
    use mod_plot3dio,               only: write_x_sensitivities_plot3d
    use mod_hdfio
    use mod_hdf_utilities


    use type_chidg_data,            only: chidg_data_t
    use type_time_integrator,       only: time_integrator_t
    use type_linear_solver,         only: linear_solver_t
    use type_nonlinear_solver,      only: nonlinear_solver_t
    use type_preconditioner,        only: preconditioner_t
    use type_meshdata,              only: meshdata_t
    use type_domain_patch_data,     only: domain_patch_data_t
    use type_bc_state_group,        only: bc_state_group_t
    use type_bc_state,              only: bc_state_t
    use type_functional_group,      only: functional_group_t
    use type_dict,                  only: dict_t
    use type_domain_connectivity,   only: domain_connectivity_t
    use type_partition,             only: partition_t
    use type_svector,               only: svector_t
    use type_chidg_vector

    !use mod_time_integrators,       only: create_time_integrator
    use mod_time_integrators,       only: time_integrator_factory, register_time_integrators
    use mod_linear_solver,          only: create_linear_solver
    use mod_nonlinear_solver,       only: create_nonlinear_solver
    use mod_preconditioner,         only: create_preconditioner

    use mpi_f08
    use mod_io

    ! TODO: consider relocating these
    use type_mesh_motion_domain_data,   only: mesh_motion_domain_data_t
    use type_mesh_motion_group_wrapper, only: mesh_motion_group_wrapper_t
    implicit none





    !>  The ChiDG Environment container
    !!
    !!  Contains: 
    !!      - data: mesh, bcs, equations for each domain.
    !!      - a time integrator
    !!      - a nonlinear solver
    !!      - a linear solver
    !!      - a preconditioner
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !-----------------------------------------------------------------------------------------
    type, public :: chidg_t

        ! Auxiliary ChiDG environment that can be used to solve sub-problems
        type(chidg_t), pointer :: auxiliary_environment

        ! Number of terms in 3D/1D solution basis expansion
        integer(ik)     :: nterms_s     = 0
        integer(ik)     :: nterms_s_1d  = 0

        ! ChiDG Files
        character(:),   allocatable :: grid_file
        character(:),   allocatable :: solution_file_in
        !type(chidg_file_t)        :: solution_file_out

        ! Primary data container. Mesh, equations, bc's, vectors/matrices
        type(chidg_data_t)                          :: data
        
        ! Primary algorithms, selected at run-time
        class(time_integrator_t),   allocatable     :: time_integrator
        class(nonlinear_solver_t),  allocatable     :: nonlinear_solver
        class(linear_solver_t),     allocatable     :: linear_solver
        class(preconditioner_t),    allocatable     :: preconditioner


        ! Partition of the global problem that is owned by the present ChiDG instance.
        type(partition_t)                           :: partition

        logical :: envInitialized = .false.

    contains

        ! Open/Close
        procedure       :: start_up
        procedure       :: shut_down

        ! Initialization
        procedure       :: set
        procedure       :: init

        ! Run
        procedure       :: process
        procedure       :: run
        procedure       :: run_adjoint
        procedure       :: run_adjointx
        procedure       :: run_adjointbc

        ! IO
        procedure       :: read_mesh
        procedure       :: read_mesh_grids
        procedure       :: read_mesh_boundary_conditions
        procedure       :: read_mesh_motions
        procedure       :: record_mesh_size
        procedure       :: write_mesh
        procedure       :: read_fields
        procedure       :: write_fields
        procedure       :: write_primary_fields
        procedure       :: write_adjoint_fields
        procedure       :: read_auxiliary_field
        procedure       :: produce_visualization


        procedure       :: write_functionals
        procedure       :: read_functionals
        procedure       :: write_vol_sensitivities
        procedure       :: write_BC_sensitivities

        procedure       :: reporter

    end type chidg_t
    !*****************************************************************************************


    interface
        module subroutine auxiliary_driver(chidg,chidg_aux,case,solver_type,grid_file,aux_file)
            type(chidg_t),  intent(inout)   :: chidg
            type(chidg_t),  intent(inout)   :: chidg_aux
            character(*),   intent(in)      :: case
            character(*),   intent(in)      :: solver_type
            character(*),   intent(in)      :: grid_file
            character(*),   intent(in)      :: aux_file
        end subroutine auxiliary_driver
    end interface



contains



    !>  ChiDG Start-Up Activities.
    !!
    !!  activity:
    !!      - 'mpi'         :: Call MPI initialization for ChiDG. This would not be called in 
    !!                         a test, since pFUnit is calling init.
    !!      - 'core'        :: Start-up ChiDG framework. Register functions, equations, 
    !!                         operators, bcs, etc.
    !!      - 'namelist'    :: Start-up Namelist IO
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/18/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine start_up(self,activity,comm,header)
        class(chidg_t), intent(inout)           :: self
        character(*),   intent(in)              :: activity
        type(mpi_comm), intent(in), optional    :: comm
        logical,        intent(in), optional    :: header

        integer(ik) :: ierr, iread

        select case (trim(activity))

            ! Start up MPI
            case ('mpi')
                call chidg_mpi_init(comm)


            ! Start up ChiDG core
            case ('core')

                if (.not. log_initialized) call log_init(header)

                ! Call environment initialization routines by default on first init call
                if (.not. self%envInitialized ) then

                    ! Call environment initialization routines by default on first init call
                    ! Order matters here. Functions need to come first. Used by 
                    ! equations and bcs.
                    call initialize_input_dictionaries(noptions,loptions)
                    call register_functions()
                    call register_prescribed_mesh_motion_functions()
                    call register_operators()
                    call register_models()
                    call register_bcs()
                    call register_equation_builders()
                    call register_time_integrators()
                    call register_radial_basis_functions()
                    call register_functionals()
                    call initialize_grid()
                    self%envInitialized = .true.

                end if

                ! Allocate an auxiliary ChiDG environment if not already done
                if (.not. associated(self%auxiliary_environment)) then
                    allocate(self%auxiliary_environment, stat=ierr)
                    if (ierr /= 0) call AllocationError
                end if

                self%envInitialized = .true.
                call self%data%time_manager%init()

                ! Initialize global time_manager variable
                call time_manager_global%init()

                ! Initialize overset donor cache
                call clear_donor_cache()


            ! Start up Namelist
            case ('namelist')

                ! Read data from 'chidg.nml'
                do iread = 0,NRANK-1
                    if ( iread == IRANK ) then
                        call read_input()
                    end if
                    call MPI_Barrier(ChiDG_COMM,ierr)
                end do

                ! Assign from mod_io variables that were read from .nml
                self%grid_file        = gridfile
                self%solution_file_in = solutionfile_in


            case default
                call chidg_signal_one(WARN,'chidg%start_up: Invalid start-up string.',trim(activity))

        end select





    end subroutine start_up
    !*****************************************************************************************







    !>  Any activities that need performed before the program completely terminates.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine shut_down(self,selection)
        class(chidg_t), intent(inout)               :: self
        character(*),   intent(in),     optional    :: selection
        

        if ( present(selection) ) then 
            select case (selection)
                case ('log')
                    call log_finalize()
                case ('mpi')
                    call chidg_mpi_finalize()
                case ('core')   ! All except mpi
                    call close_hdf()

                    ! Tear down. Maybe things need deallocated from another library 
                    ! before we deallocate here. (e.g. petsc)
                    if (allocated(self%linear_solver))  call self%linear_solver%tear_down()
                    if (allocated(self%preconditioner)) call self%preconditioner%tear_down()

                    ! Deallocate algorithms
                    if (allocated(self%time_integrator))  deallocate(self%time_integrator)
                    if (allocated(self%preconditioner))   deallocate(self%preconditioner)
                    if (allocated(self%linear_solver))    deallocate(self%linear_solver)
                    if (allocated(self%nonlinear_solver)) deallocate(self%nonlinear_solver)

                    ! Release storage
                    call self%data%release()

                    call log_finalize()
                case default
                    call chidg_signal(FATAL,"chidg%shut_down: invalid shut_down string")
            end select


        else

            call log_finalize()
            call chidg_mpi_finalize()

        end if


    end subroutine shut_down
    !*****************************************************************************************






    !>  ChiDG initialization activities
    !!
    !!  activity:
    !!      - 'communication'   :: Establish local and parallel communication
    !!      - 'chimera'         :: Establish Chimera communication
    !!      - 'finalize'        :: 
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  activity   Initialization activity specification.
    !!
    !-----------------------------------------------------------------------------------------
    recursive subroutine init(self,activity,interpolation,level,storage)
        class(chidg_t), intent(inout)           :: self
        character(*),   intent(in)              :: activity
        character(*),   intent(in), optional    :: interpolation
        integer(ik),    intent(in), optional    :: level
        character(*),   intent(in), optional    :: storage

        character(:),   allocatable :: user_msg, storage_type
        character(:),   allocatable :: interpolation_in
        integer(ik)                 :: level_in, ierr


        ! Default interpolation set = 'Quadrature'
        if (present(interpolation)) then
            interpolation_in = interpolation
        else 
            interpolation_in = 'Quadrature'
        end if

        ! Default interpolation level = gq_rule  (from mod_io)
        if (present(level)) then
            level_in = level
        else
            level_in = gq_rule
        end if




        select case (trim(activity))

            ! Call all initialization routines.
            case ('all')

                ! geometry
                call self%init('domains',interpolation,level)

                ! communication
                call self%init('comm - bc')
                call self%init('comm - interior')
                call self%init('comm - chimera')

                ! specialized bc routines, might depend on coupling info previously setup
                call self%init('bc - postcomm')

                ! matrix/vector
                call self%init('storage',storage=storage)

            ! Initialize domain data that depend on the solution expansion
            case ('domains')

                user_msg = "chidg%init('domains'): It appears the 'Solution Order' was &
                            not set for the current ChiDG instance. Try calling &
                            'call chidg%set('Solution Order',integer_input=my_order)' &
                            where my_order=1-7 indicates the solution order-of-accuracy."
                if (self%nterms_s == 0) call chidg_signal(FATAL,user_msg)

                call self%data%initialize_solution_domains(interpolation_in,level_in,self%nterms_s)


            ! Initialize boundary condition space
            case ('comm - bc')
                call self%data%initialize_solution_bc()


            ! Execute boundary custom routins
            case ('bc - postcomm')
                call self%data%initialize_postcomm_bc()


            ! Initialize communication. Local face communication. Global parallel communication.
            case ('comm - interior')
                call establish_neighbor_communication(self%data%mesh,ChiDG_COMM)


            ! Initialize chimera
            case ('comm - chimera')
                call establish_chimera_communication(self%data%mesh,ChiDG_COMM)


            ! Initialize solver storage initialization: vectors, matrices, etc.
            case ('storage')
                
                if (present(storage)) then
                    storage_type = trim(storage)
                else
                    storage_type = 'primal storage'
                end if
                call self%data%initialize_solution_solver(trim(storage_type))


            ! Allocate components, based on input or default input data
            case ('algorithms')

                ! Test chidg necessary components have been allocated
                if (.not. allocated(self%time_integrator))  call chidg_signal(FATAL,"chidg%time_integrator component was not allocated")
                if (.not. allocated(self%nonlinear_solver)) call chidg_signal(FATAL,"chidg%nonlinear_solver component was not allocated")
                if (.not. allocated(self%linear_solver))    call chidg_signal(FATAL,"chidg%linear_solver component was not allocated")
                if (.not. allocated(self%preconditioner))   call chidg_signal(FATAL,"chidg%preconditioner component was not allocated")

                ! Initialize preconditioner
                call write_line("Initialize: preconditioner...", io_proc=GLOBAL_MASTER)
                call self%preconditioner%init(self%data)
                
                ! Initialize time_integrator
                !call write_line("Initialize: time integrator...", io_proc=GLOBAL_MASTER)
                !call self%time_integrator%init(self%data)


            case default
                call chidg_signal_one(FATAL,'chidg%init: Invalid initialization string',trim(activity))

        end select


    end subroutine init
    !*****************************************************************************************








    !>  Set ChiDG environment components
    !!
    !!      -   Set time-integrator
    !!      -   Set nonlinear solver
    !!      -   Set linear solver
    !!      -   Set preconditioner
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]    selector    Character string for selecting the chidg component for 
    !!                            initialization
    !!  @param[in]    selection   Character string for specializing the component being 
    !!                            initialized
    !!  @param[inout] options     Dictionary for initialization options
    !!
    !-----------------------------------------------------------------------------------------
    subroutine set(self,selector,algorithm,integer_input,real_input,options,cfl0,tol,rtol,nmax,nwrite,search)
        class(chidg_t),             intent(inout)   :: self
        character(*),               intent(in)      :: selector
        character(*),   optional,   intent(in)      :: algorithm
        integer(ik),    optional,   intent(in)      :: integer_input
        real(rk),       optional,   intent(in)      :: real_input
        type(dict_t),   optional,   intent(inout)   :: options 
        real(rk),       optional,   intent(in)      :: cfl0
        real(rk),       optional,   intent(in)      :: tol
        real(rk),       optional,   intent(in)      :: rtol
        integer(ik),    optional,   intent(in)      :: nmax 
        integer(ik),    optional,   intent(in)      :: nwrite
        character(*),   optional,   intent(in)      :: search

        character(:),   allocatable :: user_msg
        integer(ik)                 :: ierr

        ! Check options for the algorithm family of inputs
        select case (trim(selector))
            
            case ('Time Integrator', 'Nonlinear Solver', 'Linear Solver', 'Preconditioner')
                user_msg = "chidg%set: The component being set needs an algorithm string passed in &
                            along with it. Try 'call chidg%set('your component', algorithm='your algorithm string')"
                if (.not. present(algorithm)) call chidg_signal_one(FATAL,user_msg,trim(selector))

        end select


        ! Check options for integer family of inputs
        select case (trim(selector))

            case ('Solution Order')
                user_msg = "chidg%set: The component being set needs an integer passed in &
                            along with it. Try 'call chidg%set('your component', integer_input=my_int)"
                if (.not. present(integer_input)) call chidg_signal_one(FATAL,user_msg,trim(selector))

        end select




        ! Actually go in and call the specialized routine based on 'selector'
        select case (trim(selector))

            ! Allocation for time integrator
            case ('Time Integrator')
                if (allocated(self%time_integrator)) deallocate(self%time_integrator)
                allocate(self%time_integrator, source=time_integrator_factory%produce(algorithm), stat=ierr)
                if (ierr /= 0) call AllocationError


            ! Allocation for nonlinear solver
            case ('Nonlinear Solver')
                if (allocated(self%nonlinear_solver)) deallocate(self%nonlinear_solver)
                call create_nonlinear_solver(algorithm,self%nonlinear_solver,options)

                if (present(cfl0))   self%nonlinear_solver%cfl0   = cfl0
                if (present(tol))    self%nonlinear_solver%tol    = tol
                if (present(rtol))   self%nonlinear_solver%rtol   = rtol
                if (present(nmax))   self%nonlinear_solver%nmax   = nmax
                if (present(nwrite)) self%nonlinear_solver%nwrite = nwrite
                if (present(search)) self%nonlinear_solver%search = search


            ! Allocation for linear solver
            case ('Linear Solver')
                if (allocated(self%linear_solver)) deallocate(self%linear_solver)
                call create_linear_solver(algorithm,self%linear_solver,options)

                if (present(tol))  self%linear_solver%tol  = tol
                if (present(rtol)) self%linear_solver%rtol = rtol
                if (present(nmax)) self%linear_solver%nmax = nmax


            ! Allocation for preconditioner
            case ('Preconditioner')
                if (allocated(self%preconditioner)) deallocate(self%preconditioner)
                call create_preconditioner(algorithm,self%preconditioner)


            ! Set the 'solution order'. Order-of-accuracy, that is. Compute the number of terms
            ! in the 1D, 3D solution bases
            case ('Solution Order')
                self%nterms_s_1d = integer_input
                self%nterms_s    = self%nterms_s_1d * self%nterms_s_1d * self%nterms_s_1d
        

            case default
                user_msg = "chidg%set: component string was not recognized. Check spelling and that the component &
                            was registered as an option in the chidg%set routine"
                call chidg_signal_one(FATAL,user_msg,selector)

        end select


    end subroutine set
    !******************************************************************************************








    !>  Read grid from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  gridfile        String containing a grid file name, including extension.
    !!
    !!  @param[in]  equation_set    Optionally, override the equation set for all domains
    !!  
    !!  @param[in]  bc_wall         Optionally, override wall boundary functions
    !!  @param[in]  bc_inlet        Optionally, override inlet boundary functions
    !!  @param[in]  bc_outlet       Optionally, override outlet boundary functions
    !!  @param[in]  bc_symmetry     Optionally, override symmetry boundary functions
    !!  @param[in]  bc_farfield     Optionally, override farfield boundary functions
    !!  @param[in]  bc_periodic     Optionally, override periodic boundary functions
    !!
    !!  An example where overriding boundary condition is useful is computing wall distance
    !!  for a RANS calculation. First a PDE is solved using a poisson-like equation for 
    !!  wall distance and the boundary functions on walls get overridden from RANS
    !!  boundary functions to be scalar dirichlet boundary conditions. All other 
    !!  boundar functions are overridden with neumann boundary conditions.
    !!
    !------------------------------------------------------------------------------------------
    subroutine read_mesh(self,grid_file,storage,equation_set, bc_wall, bc_inlet, bc_outlet, bc_symmetry, bc_farfield, bc_periodic, partitions_in, interpolation, level,functionals)
        class(chidg_t),             intent(inout)           :: self
        character(*),               intent(in)              :: grid_file
        character(*),               intent(in), optional    :: storage
        character(*),               intent(in), optional    :: equation_set
        class(bc_state_t),          intent(in), optional    :: bc_wall
        class(bc_state_t),          intent(in), optional    :: bc_inlet
        class(bc_state_t),          intent(in), optional    :: bc_outlet
        class(bc_state_t),          intent(in), optional    :: bc_symmetry
        class(bc_state_t),          intent(in), optional    :: bc_farfield
        class(bc_state_t),          intent(in), optional    :: bc_periodic
        type(partition_t),          intent(in), optional    :: partitions_in(:)
        character(*),               intent(in), optional    :: interpolation
        integer(ik),                intent(in), optional    :: level
        type(functional_group_t),   intent(in), optional    :: functionals

        character(:), allocatable :: selected_storage

        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Reading mesh... ', io_proc=GLOBAL_MASTER)

        selected_storage = 'primal storage'
        if (present(storage)) selected_storage = trim(storage)

        ! Run pre-processor to compute iblank 
        call compute_iblank(grid_file,ChiDG_COMM)


        ! Read domain geometry. Also performs partitioning.
        call self%read_mesh_grids(grid_file,equation_set,partitions_in)


        ! Read boundary conditions.
        call self%read_mesh_boundary_conditions(grid_file, bc_wall,        &
                                                           bc_inlet,       &
                                                           bc_outlet,      &
                                                           bc_symmetry,    &
                                                           bc_farfield,    &
                                                           bc_periodic )


        ! Read mesh motion information.
        call self%read_mesh_motions(grid_file)

        ! Read functionals.
        call self%read_functionals(grid_file,functionals)

        ! Initialize data
        call self%init('all',interpolation,level,selected_storage)


        ! Mesh size fields + smoothing
        if (construct_smooth_mesh_fields) then
            call self%data%compute_area_weighted_h()
            call self%record_mesh_size()
            call self%data%perform_h_smoothing()
        end if

        call write_line('Done reading mesh.', io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,   io_proc=GLOBAL_MASTER)

    end subroutine read_mesh
    !*****************************************************************************************








    !>  Read volume grid portion of mesh from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  gridfile        String containing a grid file name, including extension.
    !!  @param[in]  spacedim        Number of spatial dimensions
    !!  @param[in]  equation_set    Optionally, specify the equation set to be initialized 
    !!                              instead of
    !!
    !!  Read npoints for each domain and store in mesh%npoints
    !!  @author Matteo Ugolotti
    !!  @date   8/28/2018
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_mesh_grids(self,grid_file,equation_set, partitions_in)
        class(chidg_t),     intent(inout)               :: self
        character(*),       intent(in)                  :: grid_file
        character(*),       intent(in),     optional    :: equation_set
        type(partition_t),  intent(in),     optional    :: partitions_in(:)


        type(domain_connectivity_t),    allocatable                 :: connectivities(:)
        real(rk),                       allocatable                 :: weights(:)
        type(partition_t),              allocatable, asynchronous   :: partitions(:)

        character(:),       allocatable     :: domain_equation_set
        type(meshdata_t),   allocatable     :: meshdata(:)
        integer(ik)                         :: idom, iread, ierr, ielem, eqn_ID, ii, ndoms, nelems, nnodes
        integer(ik),        allocatable     :: npoints(:,:)

        integer(ik), allocatable    :: nelems_per_domain(:),nnodes_per_domain(:)
        real(rk),    allocatable    :: rbf_radius_recv(:,:), rbf_center_recv(:,:),rbf_radius_sendv(:,:), rbf_center_sendv(:,:), global_nodes(:,:)

        integer(ik)         :: ifield
        type(svector_t)     :: auxiliary_fields_local
        type(string_t)      :: field_name
        logical             :: has_wall_distance, all_have_wall_distance

        call write_line(' ',                           ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('   Reading domain grids... ', ltrim=.false., io_proc=GLOBAL_MASTER)


        ! Partitions defined from user input
        if ( present(partitions_in) ) then

            self%partition = partitions_in(IRANK+1)

            ! Need connectivity for initializing number of domains/elements/global nodes. 
            if ( IRANK == GLOBAL_MASTER) then
                call read_global_connectivity_hdf(grid_file,connectivities)
            end if


        ! Partitions from partitioner tool
        else

            ! Master rank: Read connectivity, partition connectivity, distribute partitions
            call write_line("   partitioning...", ltrim=.false., io_proc=GLOBAL_MASTER)
            if ( IRANK == GLOBAL_MASTER ) then

                call read_global_connectivity_hdf(grid_file,connectivities)
                call read_weights_hdf(grid_file,weights)

                call partition_connectivity(connectivities, weights, partitions)
                call send_partitions(partitions,ChiDG_COMM)

            end if

            ! All ranks: Receive partition from GLOBAL_MASTER
            call write_line("   distributing partitions...", ltrim=.false., io_proc=GLOBAL_MASTER)
            call recv_partition(self%partition,ChiDG_COMM)

        end if ! partitions in from user



        !!!-------------------------  REVISIT  --------------------------------!!!
        if (IRANK == GLOBAL_MASTER) then

            call read_global_nodes_hdf(grid_file,global_nodes)
            nnodes = size(global_nodes(:,1))
            ndoms = size(connectivities)

            allocate(nelems_per_domain(size(connectivities)), &
                     nnodes_per_domain(size(connectivities)), stat=ierr)
            if (ierr /= 0) call AllocationError

            do idom = 1, size(connectivities)
                nelems_per_domain(idom) = connectivities(idom)%nelements
                nnodes_per_domain(idom) = connectivities(idom)%nnodes
            end do

        end if


        call MPI_Bcast(ndoms,  1, MPI_INTEGER4, GLOBAL_MASTER, ChiDG_COMM, ierr)
        call MPI_Bcast(nnodes, 1, MPI_INTEGER4, GLOBAL_MASTER, ChiDG_COMM, ierr)
        if (IRANK /= GLOBAL_MASTER) then
            allocate(nelems_per_domain(ndoms), &
                     nnodes_per_domain(ndoms), &
                     global_nodes(nnodes,3), stat=ierr)
            if (ierr /= 0) call AllocationError
        end if
        call MPI_Bcast(nelems_per_domain, ndoms,    MPI_INTEGER4, GLOBAL_MASTER, ChiDG_COMM, ierr)
        call MPI_Bcast(nnodes_per_domain, ndoms,    MPI_INTEGER4, GLOBAL_MASTER, ChiDG_COMM, ierr)
        call MPI_Bcast(global_nodes,      3*nnodes, MPI_REAL8,    GLOBAL_MASTER, ChiDG_COMM, ierr)

        call self%data%sdata%set_nelems_per_domain(nelems_per_domain)
        call self%data%sdata%set_nnodes_per_domain(nnodes_per_domain)
        call self%data%sdata%set_global_nodes(global_nodes)
        !!!-------------------------  REVISIT  --------------------------------!!!




        ! Read data from hdf file
        do iread = 0,NRANK-1
            if ( iread == IRANK ) then
                call read_equations_hdf(self%data, grid_file)
                call read_grids_hdf(grid_file,self%partition,meshdata)
            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do



        ! Add domains to ChiDG%data
        call write_line("   processing...", ltrim=.false., io_proc=GLOBAL_MASTER)
        do idom = 1,size(meshdata)

            ! Use equation_set if specified, else default to the grid file data
            if (present(equation_set)) then
                domain_equation_set = equation_set
                call self%data%add_equation_set(equation_set)
            else
                domain_equation_set = meshdata(idom)%eqnset
            end if

            ! Get the equation set identifier
            eqn_ID = self%data%get_equation_set_id(domain_equation_set)

            call self%data%mesh%add_domain( trim(meshdata(idom)%name),   &
                                            meshdata(idom)%nodes,        &
                                            meshdata(idom)%dnodes,       &
                                            meshdata(idom)%vnodes,       &
                                            meshdata(idom)%connectivity, &
                                            meshdata(idom)%nelements_g,  &
                                            meshdata(idom)%coord_system, &
                                            eqn_ID )

        end do !idom



        ! Each processor store the number of points for each block, even though the
        ! block does not belong to the partition managed by the processor
        do iread = 0,NRANK-1
            if ( iread == IRANK ) then
                call read_grid_npoints_hdf(grid_file,npoints)
                self%data%mesh%npoints = npoints
            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do



        ! Sync
        call self%data%mesh%comm_nelements()
        call self%data%mesh%comm_domain_procs()




        !!!-------------------------  REVISIT  --------------------------------!!!
        if (construct_octree_rbf) then
            call self%data%mesh%set_nelems_per_domain(nelems_per_domain)
            call self%data%mesh%set_global_nodes(self%data%sdata%global_nodes)

            call self%data%mesh%octree%init(8, 0.0_rk, (/1, 1, 1/), .true.)
            call write_line("   building octree...", ltrim=.false., io_proc=GLOBAL_MASTER)
            call self%data%mesh%octree%build_octree_depth_first(self%data%mesh%global_nodes)
            call write_line("   building octree - completed...", ltrim=.false., io_proc=GLOBAL_MASTER)
            call self%data%construct_rbf_arrays()


            ! Wait for all processors to finish initializing their meshes, then communicate RBF info.
            nelems = sum(nelems_per_domain)
            allocate(rbf_center_recv(nelems,3), &
                     rbf_radius_recv(nelems,3), stat=ierr)
            if (ierr /= 0) call AllocationError

            call write_line("   communicating RBF arrays...", ltrim=.false., io_proc=GLOBAL_MASTER)
            rbf_center_sendv = self%data%sdata%rbf_center
            rbf_radius_sendv = self%data%sdata%rbf_radius
            call MPI_AllReduce(rbf_center_sendv, rbf_center_recv, 3*nelems, MPI_REAL8, MPI_SUM,ChiDG_COMM, ierr)
            call MPI_AllReduce(rbf_radius_sendv, rbf_radius_recv, 3*nelems, MPI_REAL8, MPI_SUM,ChiDG_COMM, ierr)
            self%data%sdata%rbf_center = rbf_center_recv
            self%data%sdata%rbf_radius = rbf_radius_recv
            call write_line("   communicating RBF arrays - completed...", ltrim=.false., io_proc=GLOBAL_MASTER)

            call write_line("   finding RBF connectivities...", ltrim=.false., io_proc=GLOBAL_MASTER)
            call self%data%find_who_rbfs_touch() 
            call write_line("   finding RBF connectivities - done...", ltrim=.false., io_proc=GLOBAL_MASTER)
        end if
        !!!-------------------------  REVISIT  --------------------------------!!!






        ! Detect if auxiliary variables are required
        auxiliary_fields_local = self%data%get_auxiliary_field_names()

        ! Rule for 'Wall Distance'
        !   1: Detect if proc requires auxiliary field 'Wall Distance : p-Poisson' be provided.
        !   2: Detect if all procs require 'Wall Distance : p-Poisson'. MPI_AllReduce
        ! This is also needed to initialize the storage for the auxiliary adjoint variables
        !-------------------------------------------------------------------------------------
        has_wall_distance = .false.
        do ifield = 1,auxiliary_fields_local%size()
            field_name = auxiliary_fields_local%at(ifield)
            has_wall_distance = (field_name%get() == 'Wall Distance : p-Poisson')
            if (has_wall_distance) exit
        end do !ifield

        ! Save the search as a flag
        call MPI_AllReduce(has_wall_distance, all_have_wall_distance, 1, MPI_LOGICAL, MPI_LOR, ChiDG_COMM, ierr)
        self%data%sdata%compute_auxiliary = all_have_wall_distance


        call write_line('   Done reading domains grids... ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' ',                                 ltrim=.false., io_proc=GLOBAL_MASTER)

    end subroutine read_mesh_grids
    !*****************************************************************************************











    !>  Read boundary conditions portion of mesh from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/5/2016
    !!
    !!  @param[in]  grid_file    String specifying a gridfile, including extension.
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_mesh_boundary_conditions(self, grid_file, bc_wall, bc_inlet, bc_outlet, bc_symmetry, bc_farfield, bc_periodic)
        class(chidg_t),     intent(inout)               :: self
        character(*),       intent(in)                  :: grid_file
        class(bc_state_t),  intent(in),     optional    :: bc_wall
        class(bc_state_t),  intent(in),     optional    :: bc_inlet
        class(bc_state_t),  intent(in),     optional    :: bc_outlet
        class(bc_state_t),  intent(in),     optional    :: bc_symmetry
        class(bc_state_t),  intent(in),     optional    :: bc_farfield
        class(bc_state_t),  intent(in),     optional    :: bc_periodic

        type(domain_patch_data_t),  allocatable :: domain_patch_data(:)
        type(string_t)                          :: group_name, patch_name
        type(bc_state_group_t), allocatable     :: bc_state_groups(:)
        integer(ik)                             :: idom, ndomains, ipatch, ibc, ierr, iread, bc_ID


        call write_line(' ',                                  ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('   Reading boundary conditions... ', ltrim=.false., io_proc=GLOBAL_MASTER)


        ! Call boundary condition reader based on file extension
        do iread = 0,NRANK-1
            if ( iread == IRANK ) then

                call read_boundaryconditions_hdf(grid_file,domain_patch_data,bc_state_groups,self%partition)

            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do


        ! Add all boundary condition state groups
        call write_line('   processing groups...', ltrim=.false., io_proc=GLOBAL_MASTER)
        do ibc = 1,size(bc_state_groups)

            call self%data%add_bc_state_group(bc_state_groups(ibc), bc_wall     = bc_wall,      &
                                                                    bc_inlet    = bc_inlet,     &
                                                                    bc_outlet   = bc_outlet,    &
                                                                    bc_symmetry = bc_symmetry,  &
                                                                    bc_farfield = bc_farfield,  &
                                                                    bc_periodic = bc_periodic )
      
        end do !ibc


        ! Add boundary condition patch groups
        call write_line('   processing patches...', ltrim=.false., io_proc=GLOBAL_MASTER)
        ndomains = size(domain_patch_data)
        do idom = 1,ndomains
            do ipatch = 1,domain_patch_data(idom)%patch_name%size()

                group_name = domain_patch_data(idom)%group_name%at(ipatch)
                patch_name = domain_patch_data(idom)%patch_name%at(ipatch)

                bc_ID = self%data%get_bc_state_group_id(group_name%get())

                call self%data%mesh%add_bc_patch(domain_patch_data(idom)%domain_name,               &
                                                 group_name%get(),                                  &
                                                 patch_name%get(),                                  &
                                                 domain_patch_data(idom)%bc_connectivity(ipatch),   &
                                                 bc_ID)

            end do !iface
        end do !ipatch


        call write_line('   Done reading boundary conditions.', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' ',                                    ltrim=.false., io_proc=GLOBAL_MASTER)


    end subroutine read_mesh_boundary_conditions
    !*****************************************************************************************






    !>  Read prescribed mesh motions from grid file.
    !!
    !!  @author Eric Wolf
    !!  @date  3/30/2017 
    !!
    !!  @param[in]  grid_file    String specifying a grid_file, including extension.
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_mesh_motions(self, grid_file)
        class(chidg_t),     intent(inout)               :: self
        character(*),       intent(in)                  :: grid_file

        character(5),           dimension(1)            :: extensions
        character(:),           allocatable             :: extension
        type(mesh_motion_domain_data_t),  allocatable   :: pmm_domain_data(:)
        type(mesh_motion_group_wrapper_t)               :: pmm_group_wrapper
        type(string_t)      :: pmm_group_name
        type(string_t)      :: group_name
        integer(ik)         :: idom, ndomains, iface, ibc, ierr, iread, npmm_groups

        ! Get filename extension
        extensions = ['.h5']
        extension = get_file_extension(grid_file, extensions)


        ! Call boundary condition reader based on file extension
        call write_line('Reading Mesh Motions...', io_proc=GLOBAL_MASTER)
        do iread = 0,NRANK-1
            if ( iread == IRANK ) then
                if ( extension == '.h5' ) then
                    call read_mesh_motion_hdf(grid_file,pmm_domain_data,pmm_group_wrapper,self%partition)
                else
                    call chidg_signal(FATAL,"chidg%read_mesh_motions: grid file extension not recognized")
                end if
            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do


        ! Add all boundary condition groups
        call write_line('Processing Mesh Motions...', io_proc=GLOBAL_MASTER)
        npmm_groups = pmm_group_wrapper%ngroups
        if (npmm_groups>0) then
            do ibc = 1,npmm_groups
                call self%data%add_mm_group(pmm_group_wrapper%mm_groups(ibc))
            end do !ibc
        end if


        ! Add boundary condition patches
        if (npmm_groups>0) then
            ndomains = size(pmm_domain_data)
            do idom = 1,ndomains
                call pmm_group_name%set(pmm_domain_data(idom)%mm_group_name)
                call self%data%add_mm_domain(pmm_domain_data(idom)%domain_name,pmm_group_name%get())
            end do !ipatch
        end if


    end subroutine read_mesh_motions
    !*****************************************************************************************


    !>  Read functionals from grid file.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/14/2017
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_functionals(self,gridfile,functionals)
        class(chidg_t),             intent(inout)               :: self
        character(*),               intent(in)                  :: gridfile
        type(functional_group_t),   intent(in),     optional    :: functionals

        integer(ik)         :: ierr,iread

        call write_line(' ',                                  ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('   Reading functionals... ', ltrim=.false., io_proc=GLOBAL_MASTER)

        if (present(functionals)) then
            ! Use input functionals (this is for auxiliary problems) 
            self%data%functional_group = functionals

        else

            ! Read functionals from file 
            do iread = 0,NRANK-1
                if ( iread == IRANK ) then
                    call read_functionals_hdf(gridfile,self%data)
                end if
                call MPI_Barrier(ChiDG_COMM,ierr)
            end do

        end if

        call write_line('   Done reading functionals.', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' ',                            ltrim=.false., io_proc=GLOBAL_MASTER)

    end subroutine read_functionals
    !*****************************************************************************************





    !>  Read fields from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @author Matteo Ugolotti
    !!  @date   9/14/2017
    !!
    !!  Added option to read in primary fields and/or adjoint fields
    !!  IF not specified, it reads in primary fields only
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_fields(self,file_name,field_type)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name
        character(*),       intent(in), optional    :: field_type

        character(:),   allocatable :: option

        call write_line(' ',                            ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' Reading solution... ',        ltrim=.false., io_proc=GLOBAL_MASTER)

        option = 'primary'
        if (present(field_type)) option = trim(field_type)
            
        select case (trim(option))
            case ('primary')
                call write_line("   reading primary fields from: ", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)
                call read_primary_fields_hdf(file_name,self%data)

            case ('adjoint')
                call write_line("   reading adjoint fields from: ", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)
                call read_adjoint_fields_hdf(file_name,self%data)

            case ('all')
                call write_line("   reading primary fields from: ", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)
                call read_primary_fields_hdf(file_name,self%data)

                call write_line("   reading adjoint fields from: ", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)
                call read_adjoint_fields_hdf(file_name,self%data)

            case default
                call chidg_signal_one(FATAL,'chidg%read_fields: Invalid field_type.',trim(option))

        end select

        call write_line('Done reading solution.', io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,       io_proc=GLOBAL_MASTER)

    end subroutine read_fields
    !*****************************************************************************************






    !>  Read fields from file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  solutionfile    String containing a solution file name, including extension.
    !!
    !-----------------------------------------------------------------------------------------
    subroutine read_auxiliary_field(self,file_name,field,store_as)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name
        character(*),       intent(in)              :: field
        character(*),       intent(in)              :: store_as

        call write_line(' ',                            ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line(' Reading solution... ',        ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('   reading from: ', file_name, ltrim=.false., io_proc=GLOBAL_MASTER)

        ! Read solution from hdf file
        call read_auxiliary_field_hdf(file_name,self%data,field,store_as)

        call write_line('Done reading solution.', io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,       io_proc=GLOBAL_MASTER)

    end subroutine read_auxiliary_field
    !*****************************************************************************************







!    !>  Check the equation_set's for any auxiliary fields that are required. 
!    !!
!    !!      #1: Check equation_set's for auxiliary fields
!    !!      #2: For auxiliary fields that are found, check the file for the auxiliary field.
!    !!      #3: If no auxiliary field in file, check auxiliary drivers for a rule to compute the field
!    !!      #4: If no rule, error. We don't have the field, and we also don't know how to compute it.
!    !!
!    !!  @author Nathan A. Wukie
!    !!  @date   11/21/2016
!    !!
!    !!
!    !!
!    !-----------------------------------------------------------------------------------------
!    subroutine check_auxiliary_fields(self)
!        class(chidg_t), intent(inout)   :: self
!
!        type(string_t), allocatable :: auxiliary_fields(:)
!        logical,        allocatable :: domain_needs_aux_field(:)
!        logical,        allocatable :: file_has_aux_field(:)
!        logical,        allocatable :: field_in_file
!
!
!
!!        aux_fields = self%data%get_auxiliary_fields()
!!
!!
!!        do iaux = 1,size(aux_fields)
!!
!!
!!            !
!!            ! Check which domains use the auxiliary field
!!            !
!!            do idom = 1,self%data%ndomains()
!!                  ! NOTE: If anyone uncomments this, eqnset(idom) should probably be replaced with eqn_ID
!!                domain_uses_field(idom) = self%data%eqnset(idom)%uses_auxiliary_field(aux_fields(iaux))
!!            end do !idom
!!
!!
!!            !
!!            do idom = 1,self%data%ndomains()
!!                file_has_aux_field(idom) = file%domain_has_field(idom,aux_field(iaux))
!!            end do !idom
!!
!!
!!            !
!!            ! If any domain doesn't have the field in file, get from a pre-defined rule
!!            !
!!            if (any(file_has_aux_field == .false.)) then
!!                call initialize_auxiliary_field(aux_field(iaux))
!!            end if
!!
!!
!!        end do !iaux
!
!        
!
!
!    end subroutine check_auxiliary_fields
!    !*****************************************************************************************







    !>  Write grid to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/21/2016
    !!
    !!  @param[in]  file    String containing a solution file name, including extension.
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_mesh(self,file_name)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name

        integer(ik)     :: ierr, iproc, iwrite
        integer(HID_T)  :: fid
        logical         :: file_exists

        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Writing mesh... ', io_proc=GLOBAL_MASTER)

        ! Check for file existence
        !
        ! Create new file if necessary
        !   Barrier makes sure everyone has called file_exists before
        !   one potentially gets created by another processor
        file_exists = check_file_exists_hdf(file_name)
        call MPI_Barrier(ChiDG_COMM,ierr)
        if (.not. file_exists) then

                ! Create a new file
                if (IRANK == GLOBAL_MASTER) then
                    call initialize_file_hdf(file_name)
                end if
                call MPI_Barrier(ChiDG_COMM,ierr)

                ! Initialize the file structure.
                do iproc = 0,NRANK-1
                    if (iproc == IRANK) then
                        fid = open_file_hdf(file_name)
                        call initialize_file_structure_hdf(fid,self%data%mesh)
                        call close_file_hdf(fid)
                    end if
                    call MPI_Barrier(ChiDG_COMM,ierr)
                end do

        end if
        call MPI_Barrier(ChiDG_COMM,ierr)



        ! Call grid reader based on file extension
        call write_line("   writing to: ", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)

        ! Each process, write its own portion of the solution
        do iwrite = 0,NRANK-1
            if ( iwrite == IRANK ) then

                call write_grids_hdf(self%data,file_name)
                call write_boundaryconditions_hdf(self%data,file_name)
                call write_equations_hdf(self%data,file_name)

            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do


        call write_line("Done writing mesh.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,   io_proc=GLOBAL_MASTER)

    end subroutine write_mesh
    !*****************************************************************************************




    !>  Write solution to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  solutionfile    String containing a solution file name, including extension.
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_fields(self,file_name,field_type)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name
        character(*),       intent(in), optional    :: field_type

        character(:),   allocatable :: option

        call write_line(' ', ltrim=.false.,     io_proc=GLOBAL_MASTER)
        call write_line('Writing fields... ', io_proc=GLOBAL_MASTER)
        call write_line("   writing to:", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)

        option = 'primary'
        if (present(field_type)) option = trim(field_type)

        select case (trim(option))
            case('primary')
                call self%write_primary_fields(file_name)
            case('adjoint')
                call self%write_adjoint_fields(file_name)
            case('X sensitivities')
                ! Write grid_node sensitivities
                call self%write_vol_sensitivities(file_name)
            case('Xs sensitivities')
                ! Write surface-normal grid-node sensitivities
                !TODO: call self%write_xs_sensitivities(file_name)
            case('BC sensitivities')
                ! Write BC parametric sensitivities
                call self%write_BC_sensitivities(file_name)
            case default
            call chidg_signal_one(WARN,'chidg%write_fields: Invalid field_type  string.',trim(field_type))
        end select

        ! Write functionals
        call self%write_functionals(file_name)

        call write_line("Done writing fields.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,       io_proc=GLOBAL_MASTER)

    end subroutine write_fields
    !*****************************************************************************************





    !>  Write primary fields to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/4/2019
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_primary_fields(self,file_name)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name

        character(:),   allocatable :: option

        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Writing primary fields... ', io_proc=GLOBAL_MASTER)
        call write_line("   writing to:", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)

        call write_primary_fields_hdf(self%data,file_name)
        call self%time_integrator%write_time_options(self%data,file_name)

        call write_line("Done writing primary fields.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)

    end subroutine write_primary_fields
    !*****************************************************************************************



    !>  Write adjoint fields to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/4/2019
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_adjoint_fields(self,file_name,field_type)
        class(chidg_t), intent(inout)           :: self
        character(*),   intent(in)              :: file_name
        character(*),   intent(in), optional    :: field_type

        character(:),   allocatable :: option

        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)
        call write_line('Writing adjoint fields... ', io_proc=GLOBAL_MASTER)
        call write_line("   writing to:", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)

        call write_adjoint_fields_hdf(self%data,file_name)
        call self%time_integrator%write_time_options(self%data,file_name)

        call write_line("Done writing adjoint fields.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false., io_proc=GLOBAL_MASTER)

    end subroutine write_adjoint_fields
    !*****************************************************************************************




    !>  Write solution functionals to file.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   7/17/2017
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_functionals(self,file_name)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: file_name

        logical     :: write_func

        write_func = self%data%sdata%functional%check_functional_stored() 

        if (write_func) then

            ! Call grid reader based on file extension
            call write_line("   writing functionals to   :", file_name, ltrim=.false., io_proc=GLOBAL_MASTER)
        
            ! Write functionals to hdf
            call write_functionals_hdf(self%data,file_name)
            
            ! Write functionals to .dat file
            call write_functionals_file(self%data)

        end if

    end subroutine write_functionals
    !*****************************************************************************************





    !>  Write volume sensitivites 
    !!
    !!  @author Matteo Ugolotti
    !!  @date   8/10/2018
    !!
    !!  @param[in]  prefix    String containing the prefix name 'dJ/dX_'.
    !!                        The prefix will be completed with functional name and extension.
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_vol_sensitivities(self,prefix)
        class(chidg_t),     intent(inout)   :: self
        character(*),       intent(in)      :: prefix
        
        integer(ik)                 :: ifunc
        character(:),   allocatable :: filename
        type(string_t)              :: func_name

        ! Only the MASTER rank has all the information about all grid-nodes
        if (IRANK == GLOBAL_MASTER) then
        
            ! Write volume grid-node sensitivities for each functional, one at the time
            do ifunc = 1,self%data%functional_group%n_functionals()

                func_name = self%data%functional_group%fcl_entities(ifunc)%func%name%replace(' ','_')
                filename  = trim(prefix) // func_name%get() 

                ! Write solution for ifunc 
                call write_line("   writing X-sensitivities for functional: ", func_name%get(), ltrim=.false., io_proc=GLOBAL_MASTER)

                ! Write sensitivities to HDF file
                call write_x_sensitivities_hdf(self%data,ifunc,filename)

                ! Write sensitivities to plot3d file
                call write_x_sensitivities_plot3d(self%data,ifunc,filename)

            end do !ifunc

        end if

    end subroutine write_vol_sensitivities
    !*****************************************************************************************





    !>  Write BC paramteric sensitivites 
    !!
    !!  @author Matteo Ugolotti
    !!  @date   11/26/2018
    !!
    !!  @param[in]  prefix    String containing the prefix name 'grad_'.
    !!                        The prefix will be completed with functional name and extension.
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine write_BC_sensitivities(self,prefix)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: prefix
        
        integer(ik)                 :: ifunc
        character(:),   allocatable :: filename
        type(string_t)              :: func_name

        ! Only the MASTER rank writes out the gradient
        if (IRANK == GLOBAL_MASTER) then
        
            ! Write volume grid-node sensitivities for each functional, one at the time
            do ifunc = 1,self%data%functional_group%n_functionals()

                func_name = self%data%functional_group%fcl_entities(ifunc)%func%name%replace(' ','_')
                filename  = trim(prefix) // func_name%get() 

                ! Write solution for ifunc 
                call write_line("   writing BC gradient for functional: ", func_name%get(), ltrim=.false., io_proc=GLOBAL_MASTER)

                ! Write sensitivities to .dat file
                call write_BC_sensitivities_file(self%data,ifunc,filename)

            end do !ifunc

        end if

    end subroutine write_BC_sensitivities
    !*****************************************************************************************







    !>  Write visualization to file.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   8/24/2017
    !!
    !!  @param[in]  solutionfile    String containing a solution file name, including extension.
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine produce_visualization(self,grid_file,solution_file,equation_set)
        class(chidg_t),     intent(inout)           :: self
        character(*),       intent(in)              :: grid_file
        character(*),       intent(in)              :: solution_file
        character(*),       intent(in), optional    :: equation_set

        character(:),   allocatable :: user_msg, time_integrator, solution_file_prefix
        integer(ik),    allocatable :: solution_orders(:)
        integer(HID_T)              :: fid
        

        call write_line(' ', ltrim=.false.,          io_proc=GLOBAL_MASTER)
        call write_line('Writing visualization... ', io_proc=GLOBAL_MASTER)


        ! Check we are running serial
        user_msg = "chidg%produce_visualization: We currently can only write &
                    visualization files in serial. Please run using a single process."
        if (NRANK > 1) call chidg_signal(FATAL,user_msg)


        ! Get properties from solution_file and set
        fid = open_file_hdf(solution_file)
        solution_orders = get_domain_field_orders_hdf(fid)
        time_integrator = get_time_integrator_hdf(fid)
        call close_file_hdf(fid)


        ! Initialize solution data storage
        call self%set('Solution Order', integer_input=solution_orders(1))
        call self%set('Time Integrator', algorithm=trim(time_integrator))
        self%solution_file_in = solution_file


        ! Read grid/solution modes and time integrator options from HDF5
        self%grid_file = grid_file
        call self%read_mesh(grid_file, storage='primal', interpolation='Uniform', level=OUTPUT_RES, equation_set=equation_set)
        call self%read_fields(solution_file)


        ! Process for getting wall distance
        call self%process()


        call self%time_integrator%initialize_state(self%data)
        call self%time_integrator%read_time_options(self%data,solution_file,'process')
        call self%time_integrator%process_data_for_output(self%data)


        ! Write solution
        solution_file_prefix = get_file_prefix(solution_file,'.h5')
        call write_tecio_file(self%data,solution_file_prefix, write_domains=.true., write_surfaces=.true.)


        call write_line("Done writing visualization.", io_proc=GLOBAL_MASTER)
        call write_line(' ', ltrim=.false.,            io_proc=GLOBAL_MASTER)

    end subroutine produce_visualization
    !*****************************************************************************************









    !>  Handle prerun activities, such as initializing auxiliary fields and
    !!  calling auxiliary drivers.
    !!
    !!  Checks:
    !!  ----------------------------
    !!      1: Check if 'Wall Distance : p-Poisson' is required. Yes => call auxiliary_driver
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   6/24/2017
    !!
    !!
    !-------------------------------------------------------------------------------------------
    subroutine process(self,solver_type)
        class(chidg_t), intent(inout)           :: self
        character(*),   intent(in), optional    :: solver_type


        character(:),   allocatable :: user_msg, solver
        integer(ik)                 :: ifield, ierr, iproc
        type(svector_t)             :: auxiliary_fields_local
        type(string_t)              :: field_name
        logical                     :: has_wall_distance, all_have_wall_distance

        solver = 'primal problem'
        if (present(solver_type)) solver = trim(solver_type)


        auxiliary_fields_local = self%data%get_auxiliary_field_names()


        ! Rule for 'Wall Distance'
        !   1: Detect if proc requires auxiliary field 'Wall Distance : p-Poisson' be provided.
        !   2: Detect if all procs require 'Wall Distance : p-Poisson'. MPI_AllReduce
        !   3: If all procs require auxiliary field, call auxiliary_driver for 'Wall Distance'
        !
        !-------------------------------------------------------------------------------------
        has_wall_distance = .false.
        do ifield = 1,auxiliary_fields_local%size()
            field_name = auxiliary_fields_local%at(ifield)
            has_wall_distance = (field_name%get() == 'Wall Distance : p-Poisson')
            if (has_wall_distance) exit
        end do !ifield

        call MPI_AllReduce(has_wall_distance, all_have_wall_distance, 1, MPI_LOGICAL, MPI_LOR, ChiDG_COMM, ierr)

        if (all_have_wall_distance) then
            allocate(self%auxiliary_environment, stat=ierr)
            if (ierr /= 0) call AllocationError
            call auxiliary_driver(self,self%auxiliary_environment,'Wall Distance', solver,          &
                                                                  grid_file = trim(self%grid_file), &
                                                                  aux_file  = 'wall_distance.h5')
        end if
        !*************************************************************************************



    end subroutine process
    !*******************************************************************************************






    !>  Run ChiDG simulation
    !!
    !!      - This routine passes the domain data, nonlinear solver, linear solver, and 
    !!        preconditioner components to the time integrator to take a step.
    !!
    !!  Optional input parameters:
    !!      write_initial   control writing initial solution to file. Default: .false.
    !!      write_final     control writing final solution to file. Default: .true.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!  @date   2/7/2017
    !!
    !------------------------------------------------------------------------------------------
    subroutine run(self, write_initial, write_final, write_tecio, write_report)
        class(chidg_t), intent(inout)           :: self
        logical,        intent(in), optional    :: write_initial
        logical,        intent(in), optional    :: write_final
        logical,        intent(in), optional    :: write_tecio
        logical,        intent(in), optional    :: write_report

        character(100)              :: filename
        character(:),   allocatable :: prefix, tecio_file_prefix
        integer(ik)                 :: istep, nsteps, wcount, iread, ierr, myunit
        logical                     :: option_write_initial, option_write_final, &
                                       option_write_tecio, option_write_report, exists
        real(rk)                    :: force(3), work

        class(chidg_t), pointer :: chidg
    
        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("           Running ChiDG primal problem...         ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)

        
        ! Prerun processing
        !   : Getting/computing auxiliary fields etc.
        call self%process('primal problem')

        ! Initialize algorithms
        call self%init('algorithms')

        ! Check optional incoming parameters
        option_write_initial = .false.
        option_write_final   = .true.
        option_write_tecio   = .false.
        option_write_report  = .false.
        if (present(write_initial)) option_write_initial = write_initial
        if (present(write_final))   option_write_final   = write_final
        if (present(write_tecio))   option_write_tecio   = write_tecio
        if (present(write_report))  option_write_report  = write_report


        ! Write initial solution
        if (option_write_initial) then
            call self%write_mesh('initial.h5')
            call self%write_fields('initial.h5')
        end if


        ! Initialize time integrator state
        call self%time_integrator%initialize_state(self%data)

        do iread = 0,NRANK-1
            if ( iread == IRANK ) then
                if (solutionfile_in /= 'none') call self%time_integrator%read_time_options(self%data,solutionfile_in,'run')
            end if
            call MPI_Barrier(ChiDG_COMM,ierr)
        end do


        ! Get the prefix in the file name in case of multiple output files
        prefix = get_file_prefix(solutionfile_out,'.h5')       


        ! Execute time_integrator, nsteps times 
        wcount = 1
        nsteps = self%data%time_manager%nsteps
        call write_line("Step","System residual", columns=.true., column_width=30, io_proc=GLOBAL_MASTER)
        do istep = 1,nsteps

            ! update time_manager
            self%data%time_manager%istep = istep


            ! Report to file: report from mod_io
            if (option_write_report) call self%reporter(report)

            
            ! Call time integrator to take a step. 
            call self%time_integrator%step(self%data,               &
                                           self%nonlinear_solver,   &
                                           self%linear_solver,      &
                                           self%preconditioner)


            ! Report at final time
            if ( (option_write_report) .and. (istep == nsteps) ) call self%reporter(report)


            ! Write solution every nwrite steps
            if (wcount == self%data%time_manager%nwrite) then

                ! Check if functional computation is needed, if so compute functionals
                if (self%data%functional_group%compute_functionals) call self%time_integrator%compute_functionals(self%data)

                if (self%data%time_manager%t < 1.) then
                    write(filename, "(A,F8.6,A3)") trim(prefix)//'_', self%data%time_manager%t, '.h5'
                else
                    write(filename, "(A,F0.6,A3)") trim(prefix)//'_', self%data%time_manager%t, '.h5'
                end if

                call self%write_mesh(filename)
                call self%write_fields(filename)
                wcount = 0
            end if

            ! Print diagnostics
            call write_line("TIME INTEGRATOR", istep, self%time_integrator%residual_norm%at(istep), io_proc=GLOBAL_MASTER)
            wcount = wcount + 1

        end do !istep


        ! Write the final solution to hdf file
        if (option_write_final) then
            ! Check if functional computation is needed, if so compute functionals
            if (self%data%functional_group%compute_functionals) call self%time_integrator%compute_functionals(self%data)
            call self%write_mesh(solutionfile_out)
            call self%write_fields(solutionfile_out)
        end if


        ! Write tecio visualization 
        if (option_write_tecio) then

            ! Initialize interpolation to Uniform for TecIO output.
            call self%init('all','Uniform',level=OUTPUT_RES)

            ! Re-initialize solution and process for output
            call self%read_fields(solutionfile_out)

            ! Prerun processing
            !   : Getting/computing auxiliary fields etc.
            call self%process()

            ! Get post processing data (q_in -> q -> q_out)
            call self%time_integrator%initialize_state(self%data)
            call self%time_integrator%process_data_for_output(self%data)

            ! Write solution
            tecio_file_prefix = get_file_prefix(solutionfile_out,'.h5')
            call write_tecio_file(self%data, tecio_file_prefix, write_domains=.true., write_surfaces=.true.)

        end if

    end subroutine run
    !*****************************************************************************************






    !>  Run ChiDG Adjoint simulation
    !!
    !!      - This routine passes the domain data, linear solver, and 
    !!        preconditioner components to the time integrator adjoint solver.
    !!
    !!  Optional input parameters:
    !!      write_initial   control writing initial solution to file. Default: .false.
    !!      write_final     control writing final solution to file. Default: .true.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   9/12/2017
    !!
    !!  TODO: check if this works for unsteady adjoint
    !!
    !------------------------------------------------------------------------------------------
    subroutine run_adjoint(self,write_final)
        class(chidg_t), intent(inout)           :: self
        logical,        intent(in), optional    :: write_final

        character(100)              :: filename
        character(:),   allocatable :: prefix, scheme_type
        integer(ik)                 :: istep, nsteps, ierr, iread, ifunc
        logical                     :: option_write_initial, option_write_final,    &
                                       steady, spectral


        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("       Running ChiDG adjoint problem...            ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)


        associate ( adjoint => self%data%sdata%adjoint )
        
            ! Prerun processing
            !   : Getting/computing auxiliary fields etc.
            call self%process('primal problem')

            ! Initialize algorithms
            call self%init('algorithms')

            ! Check optional incoming parameters
            option_write_final   = .true.
            if (present(write_final))   option_write_final   = write_final

            ! Get the prefix in the file name in case of multiple output files
            prefix = get_file_prefix(adjointfile_out,'.h5')       


            ! Set the time manager initial time correctly
            steady   = .false.
            spectral = .false.
            nsteps      = self%data%time_manager%nsteps
            scheme_type = self%data%time_manager%get_type()
            if (scheme_type == 'steady')     steady   = .true. 
            if (scheme_type == 'spectral')   spectral = .true.
            if ( steady .or. spectral ) then
                self%data%time_manager%t = 0
            else
                self%data%time_manager%t = self%data%time_manager%dt*nsteps
            end if


            ! Start adjoint variables computation 
            ! NuTE: Adjoint variables are computed backward in time!
            do istep = nsteps,1,-1
                
                ! Print diagnostics
                call write_line(' ',io_proc=GLOBAL_MASTER)
                call write_line('Start computing primary adjoint variables for time instance ', self%data%time_manager%t ,' ...', io_proc=GLOBAL_MASTER)
                
                ! Pass istep to time_manager
                self%data%time_manager%istep = istep

                ! Compute adjoint variables
                call self%time_integrator%compute_adjoint(self%data,self%linear_solver, &
                                                            self%preconditioner)

                ! Write the adjoint solution to hdf file for each step
                if (option_write_final) then
                    if ( steady .or. spectral) then
                        write(filename, "(A,A3)") trim(prefix),'.h5'
                    else if (self%data%time_manager%t < 1.) then
                        write(filename, "(A,F8.6,A3)") trim(prefix)//'_', self%data%time_manager%t, '.h5'
                    else
                        write(filename, "(A,F0.6,A3)") trim(prefix)//'_', self%data%time_manager%t, '.h5'
                    end if
                    call self%write_mesh(trim(filename))
                    call self%write_fields(trim(filename),'primary')
                    call self%write_fields(trim(filename),'adjoint')
                end if
            
                ! Start accumulation RHS of auxiliary adjoint equations if needed
                ! Assuming only one auxiliary problem: wall_distance
                if (self%data%sdata%compute_auxiliary) then 
                 
                    call write_line('Start computing RHS of auxiliary adjoint equations...', io_proc=GLOBAL_MASTER)
                    ! Update space: distance field linearization
                    call update_space(self%data,differentiate=dD_DIFF)

                    do ifunc = 1,self%data%sdata%functional%nfunc()
                        adjoint%vRd(1,ifunc) = adjoint%vRd(1,ifunc) + chidg_mv(adjoint%Rd(1),adjoint%v(ifunc,istep),adjoint%vRd(1,ifunc))
                    end do
                    
                    call write_line('Done computing RHS of auxiliary adjoint equations.', io_proc=GLOBAL_MASTER)
                
                end if


                ! Increment backward in time
                ! TODO: this might be moved into the time_integrator%compute_adjoint routine
                self%data%time_manager%t = self%data%time_manager%t - self%data%time_manager%dt

            end do !istep backward
        
            ! Compute auxiliary adjoint variables
            call self%process('adjoint problem')

        end associate

    end subroutine run_adjoint
    !*****************************************************************************************








    !>  Run ChiDG Adjointx calculation
    !!
    !!      - This routine computes the grid-node sensitivites for a given 
    !!        primal and adjoint solution for given functionals 
    !!
    !!  Optional input parameters:
    !!      write_initial   control writing initial solution to file. Default: .false.
    !!      write_final     control writing final solution to file. Default: .true.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   8/7/2018
    !!
    !------------------------------------------------------------------------------------------
    subroutine run_adjointx(self,write_final)
        class(chidg_t), intent(inout)           :: self
        logical,        intent(in), optional    :: write_final

        character(:),   allocatable :: prefix,filename
        integer(ik)                 :: istep, nsteps, ierr, iread, ifunc
        logical                     :: option_write_initial, option_write_final

        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("       Running ChiDG AdjointX calculation...       ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)

        ! Prerun processing
        !   : Getting/computing auxiliary fields etc.
        call self%process('primal problem')
        
        ! Prerun processing
        !   : Getting/computing auxiliary mesh sensitivities etc.
        call self%process('adjointx problem')

        ! Initialize algorithms
        call self%init('algorithms')

        ! Check optional incoming parameters
        ! TODO: might need to remove this option
        option_write_final   = .true.
        if (present(write_final))   option_write_final   = write_final

        ! Compute adjoint variables
        call write_line('Start computing primary grid-node sensitivities...', io_proc=GLOBAL_MASTER)

        associate( q            => self%data%sdata%q,                    &
                   Rx           => self%data%sdata%adjointx%Rx,          &
                   Jx           => self%data%sdata%adjointx%Jx,          &
                   vRx          => self%data%sdata%adjointx%vRx,         &
                   wAx          => self%data%sdata%adjointx%wAx,         &
                   Jx_unsteady  => self%data%sdata%adjointx%Jx_unsteady, &
                   v            => self%data%sdata%adjoint%v             )

            ! Loop through all the time steps
            ! (Number of steps deduced from size of adjoint%q_time but we can also
            ! use the time_manager)
            do istep = 1,size(self%data%sdata%adjoint%q_time)

                ! Set time manager (might not be necessary)
                ! Here we are just worried about adding all the sensitivites coming from 
                ! all the time steps
                self%data%time_manager%itime = 1
                self%data%time_manager%t     = ZERO
                
                ! Set vector q equal to the current solution vector at step istep
                q = self%data%sdata%adjoint%q_time(istep)

                ! Assemble the system updating spatial linearization wrt grid-nodes
                ! for istep solution vector
                ! Stored in: sdata%adjointx%Rx
                call Rx%clear()
                call update_space(self%data,differentiate=dX_DIFF)

                ! Update functionals linearization wrt grid-nodes at istep solution
                ! Stored in: sdata%adjointx%Jx
                call self%data%sdata%adjointx%Jx_clear()
                call update_functionals(self%data,differentiate=dX_DIFF)

                ! Clear vRx vectors, this is necessary for unsteady
                call self%data%sdata%adjointx%vRx_clear()
                
                ! Loop through each functional to compute the sensitivities
                do ifunc = 1,size(Jx)

                    ! Compute v*Rx
                    vRx(ifunc) = chidg_mv(Rx,v(ifunc,istep),vRx(ifunc))
            
                    ! Add to Jx the contribution from vRx
                    Jx(ifunc) = Jx(ifunc) + vRx(ifunc)

                    ! Add contribution of istep to overall unsteady sensitivities
                    Jx_unsteady(ifunc) = Jx_unsteady(ifunc) + Jx(ifunc)

                end do !ifunc

            end do !istep
        
            ! Add sensitivities of the auxiliary problem: wall_distance 
            ! Assuming only one auxiliary problem: wall_distance
            if (self%data%sdata%compute_auxiliary) then 
                call write_line('Adding contribution from auxiliary adjoint sensitivities...', io_proc=GLOBAL_MASTER)
                do ifunc = 1,self%data%sdata%functional%nfunc()
                    Jx_unsteady(ifunc) = Jx_unsteady(ifunc) + wAx(ifunc)
                end do
            end if

        end associate

        call write_line('Done computing primary grid-node sensitivities.', io_proc=GLOBAL_MASTER)

        
        ! TODO: ADD here procedure for surface-normal sensitivities
               
                
        ! Write the final solution to hdf file
        prefix = 'dJdX_'
        if (option_write_final) then
            ! Master rank gather all node sensitivities
            call self%data%sdata%adjointx%gather_all(self%data%mesh)
            ! Write out solution: hdf, plot3D
            call self%write_fields(prefix,'X sensitivities')
        end if

    end subroutine run_adjointx
    !*****************************************************************************************








    !>  Run ChiDG Adjointbc calculation
    !!
    !!      - This routine computes the sensitivites of a given functional wrt a BC parameter for a given 
    !!        primal and adjoint solution.
    !!
    !!  Optional input parameters:
    !!      write_final     control writing final solution to file. Default: .true.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   11/26/2018
    !!
    !------------------------------------------------------------------------------------------
    subroutine run_adjointbc(self,bc_params,write_final)
        class(chidg_t),  intent(inout)           :: self
        type(svector_t), intent(in)              :: bc_params
        logical,         intent(in), optional    :: write_final

        character(:),    allocatable :: prefix,filename
        integer(ik)                  :: istep, nsteps, ierr, iread, ifunc
        logical                      :: option_write_initial, option_write_final


        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("       Running ChiDG AdjointBC calculation...       ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("                                                   ", io_proc=GLOBAL_MASTER, delimiter='none')
        call write_line("---------------------------------------------------", io_proc=GLOBAL_MASTER)

        ! Prerun processing
        !   : Getting/computing auxiliary fields etc.
        call self%process('primal problem')
        
        ! Prerun processing
        !   : Getting/computing auxiliary BC sensitivities etc.
        call self%process('adjointbc problem')

        ! Initialize algorithms
        call self%init('algorithms')

        ! Check optional incoming parameters
        ! TODO: might need to remove this option
        option_write_final   = .true.
        if (present(write_final))   option_write_final   = write_final

        ! Compute adjoint variables
        call write_line('Start computing BC parametric sensitivities...', io_proc=GLOBAL_MASTER)

        associate( q            => self%data%sdata%q,                     &
                   Ra           => self%data%sdata%adjointbc%Ra,          &
                   wAa          => self%data%sdata%adjointbc%wAa,         &
                   vRa          => self%data%sdata%adjointbc%vRa,         &
                   Ja_unsteady  => self%data%sdata%adjointbc%Ja_unsteady, &
                   v            => self%data%sdata%adjoint%v             )

            ! Loop through all the time steps
            ! (Number of steps deduced from size of adjoint%q_time but we can also
            ! use the time_manager)
            do istep = 1,size(self%data%sdata%adjoint%q_time)

                ! Set time manager (might not be necessary)
                ! Here we are just worried about adding all the sensitivites coming from 
                ! all the time steps
                self%data%time_manager%itime = 1
                self%data%time_manager%t     = ZERO
                
                ! Set vector q equal to the current solution vector at step istep
                q = self%data%sdata%adjoint%q_time(istep)
                
                ! Assemble the system updating spatial linearization wrt BC parameter
                ! for istep solution vector
                ! Stored in: sdata%adjointbc%Ra
                call Ra%clear()
                call self%data%sdata%adjointbc%vRa_clear()
                call update_space(self%data,differentiate=dBC_DIFF,bc_parameters=bc_params)

                ! Loop through each functional to compute the sensitivities
                do ifunc = 1,size(vRa)
                    ! Compute v*Ra
                    vRa(ifunc) = dot_comm(Ra,v(ifunc,istep),ChiDG_COMM)
            
                    ! Add contribution of istep to overall unsteady sensitivities
                    Ja_unsteady(ifunc) = Ja_unsteady(ifunc) + vRa(ifunc)
                end do !ifunc
            end do !istep

            ! Add contribution from auxiliary problem (this will be zero if no auxiliary problem exists) 
            do ifunc = 1,size(wAa)
                Ja_unsteady(ifunc) = Ja_unsteady(ifunc) + wAa(ifunc)
            end do

        end associate

        call write_line('Done computing BC parametric sensitivities.', io_proc=GLOBAL_MASTER)

        ! Write the final solution to file
        prefix = 'dJdBC_'
        if (option_write_final) then
            ! Write out solution: .dat file
            call self%write_fields(prefix,'BC sensitivities')
        end if

    end subroutine run_adjointbc
    !*****************************************************************************************





    !>  Report on ChiDG simulation
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine reporter(self,selection)
        class(chidg_t), intent(inout)   :: self
        character(*),   intent(in)      :: selection

        integer(ik) :: ireport, ierr, myunit
        real(rk)    :: force(3), power
        logical     :: exists


        select case(trim(selection))
            case ('before') 

                do ireport = 0,NRANK-1
                    if ( ireport == IRANK ) then
                        call write_line('MPI Rank: ', IRANK, io_proc=IRANK)
                        call self%data%report('grid')
                    end if
                    call MPI_Barrier(ChiDG_COMM,ierr)
                end do

            case ('after')

                if ( IRANK == GLOBAL_MASTER ) then
                    !call self%time_integrator%report()
                    call self%nonlinear_solver%report()
                    !call self%preconditioner%report()
                end if

        
            case ('after adjoint' )
                if ( IRANK == GLOBAL_MASTER ) call self%data%report('adjoint')

            case( 'functional' ) 
                if ( IRANK == GLOBAL_MASTER ) call self%data%report('functional')

            case ('forces')

                call report_forces(self%data,trim(report_info),force=force, power=power)
                if (IRANK == GLOBAL_MASTER) then
                    inquire(file="aero.txt", exist=exists)
                    if (exists) then
                        open(newunit=myunit, file="aero.txt", status="old", position="append",action="write")
                    else
                        open(newunit=myunit, file="aero.txt", status="new",action="write")
                        write(myunit,*) 'force-1', 'force-2', 'force-3', 'work'
                    end if
                    write(myunit,*) force(1), force(2), force(3), power
                    close(myunit)
                end if

            case default


        end select


    end subroutine reporter
    !*****************************************************************************************




    !>
    !! 
    !!
    !! @author  Eric M. Wolf
    !! @date    09/18/2018 
    !!
    !--------------------------------------------------------------------------------
    subroutine record_mesh_size(self)
        class(chidg_t),     intent(inout)   :: self

        integer(ik) :: nelems, nnodes, ierr, inode

        real(rk), allocatable :: sendv(:,:), recv(:,:)

        real(rk), allocatable :: sendv_r(:), recv_r(:)
        integer(ik), allocatable :: sendv_i(:), recv_i(:)

        call self%data%record_mesh_size()
        call MPI_Barrier(ChiDG_COMM,ierr)

        nelems = sum(self%data%sdata%nelems_per_domain)
        allocate(sendv(nelems,3))
        allocate(recv(nelems,3))

        recv = ZERO
        sendv = self%data%sdata%mesh_size_elem
        call MPI_Allreduce(sendv, recv, 3*nelems, MPI_REAL8, MPI_MAX,ChiDG_COMM, ierr)

        self%data%sdata%mesh_size_elem = recv

        nnodes = sum(self%data%sdata%nnodes_per_domain)
        if (allocated(sendv)) deallocate(sendv)
        if (allocated(recv)) deallocate(recv)
        allocate(sendv(nnodes,3))
        allocate(recv(nnodes,3))

        recv = ZERO
        sendv = self%data%sdata%mesh_size_vertex
        call MPI_Allreduce(sendv, recv, 3*nnodes, MPI_REAL8, MPI_MAX,ChiDG_COMM, ierr)

        self%data%sdata%mesh_size_vertex = recv

        recv = ZERO
        sendv = self%data%sdata%sum_mesh_h_vertex
        call MPI_Allreduce(sendv, recv, 3*nnodes, MPI_REAL8, MPI_MAX,ChiDG_COMM, ierr)

        self%data%sdata%sum_mesh_h_vertex = recv


        if (allocated(sendv_r)) deallocate(sendv_r)
        if (allocated(recv_r)) deallocate(recv_r)
        allocate(sendv_r(nnodes))
        allocate(recv_r(nnodes))

        recv_r = ZERO
        sendv_r = self%data%sdata%min_mesh_size_vertex
        call MPI_Allreduce(sendv_r, recv_r, nnodes, MPI_REAL8, MPI_MAX,ChiDG_COMM, ierr)

        self%data%sdata%min_mesh_size_vertex = recv_r

        recv_r = ZERO
        sendv_r = self%data%sdata%sum_mesh_size_vertex
        call MPI_Allreduce(sendv_r, recv_r, nnodes, MPI_REAL8, MPI_SUM, ChiDG_COMM, ierr)

        self%data%sdata%sum_mesh_size_vertex = recv_r

        if (allocated(sendv_i)) deallocate(sendv_i)
        if (allocated(recv_i)) deallocate(recv_i)
        allocate(sendv_i(nnodes))
        allocate(recv_i(nnodes))

        recv_i = 0
        sendv_i = self%data%sdata%num_elements_touching_vertex
        call MPI_Allreduce(sendv_i, recv_i, nnodes, MPI_INTEGER4, MPI_SUM,ChiDG_COMM, ierr)

        self%data%sdata%num_elements_touching_vertex = recv_i

        do inode = 1, size(recv_i)
            if (self%data%sdata%num_elements_touching_vertex(inode) /= 0) then
                self%data%sdata%avg_mesh_size_vertex(inode) = self%data%sdata%sum_mesh_size_vertex(inode)/real(self%data%sdata%num_elements_touching_vertex(inode), rk)
                self%data%sdata%avg_mesh_h_vertex(inode,:) = self%data%sdata%sum_mesh_h_vertex(inode,:)/real(self%data%sdata%num_elements_touching_vertex(inode), rk)
            end if

        end do

    end subroutine record_mesh_size 
    !********************************************************************************
















    function compute_l2_state_error(self,q_ref) result(error_val)
        class(chidg_t), intent(inout)       :: self
        type(chidg_vector_t), intent(in)    :: q_ref

        type(chidg_vector_t), allocatable    :: q_diff
        real(rk)                            :: error_val, local_error_val

        integer(ik)                         :: ndom, nelems, nfields, nterms, idom, ielem, iterm, ieqn
        real(rk), allocatable               :: temp(:)
        q_diff = q_ref
        !q_diff = sub_chidg_vector_chidg_vector(self%data%sdata%q,q_ref)
        q_diff = self%data%sdata%q - q_ref
        error_val = ZERO
        !error_val = q_diff%norm_local()

        ndom = self%data%mesh%ndomains()
        do idom = 1, ndom
            nelems  = self%data%mesh%domain(idom)%nelem
            nfields = self%data%mesh%domain(idom)%nfields
            nterms  = self%data%mesh%domain(idom)%nterms_s
            do ielem = 1, nelems
                local_error_val = ZERO
                do ieqn = 1, nfields
                    temp = &
                        matmul(self%data%mesh%domain(idom)%elems(ielem)%basis_s%interpolator_element('Value'),&
                    q_diff%dom(idom)%vecs(ielem)%vec((ieqn-1)*nterms+1:ieqn*nterms))
                    temp = temp**TWO*self%data%mesh%domain(idom)%elems(ielem)%basis_s%weights_element()*self%data%mesh%domain(idom)%elems(ielem)%jinv
                    local_error_val = local_error_val + sum(temp)
                end do
                error_val = error_val + local_error_val
            end do
        end do
        error_val = sqrt(error_val)
    end function compute_l2_state_error







end module type_chidg
