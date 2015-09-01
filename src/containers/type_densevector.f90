!> Data type for storing the dense block matrices for the linearization of each element
!!  @author Nathan A. Wukie
module type_densevector
#include <messenger.h>
    use mod_kinds,      only: rk,ik
    use mod_constants,  only: ZERO
    implicit none






    type, public :: densevector_t
        ! Element Associativity
        integer(ik), private    :: parent_ = 0                  !> Associated parent element


        ! Storage size and equation information
        integer(ik), private    :: nterms_                      !> Number of terms in an expansion
        integer(ik), private    :: nvars_                       !> Number of equations included
    

        ! Vector storage
        real(rk),  dimension(:), allocatable :: vec             !> Vector storage
        real(rk),  dimension(:,:), pointer   :: mat => null()   !> Matrix-view alias of vec  (nterms, neq)




    contains
        ! Initializers
        generic, public :: init => init_vector
        procedure, private :: init_vector       !> Initialize vector storage

        procedure :: parent     !> return parent element
        procedure :: nentries   !> return number of vector entries
        !procedure :: resize     !> resize vector storage
        procedure :: reparent   !> reassign parent
        procedure :: nterms     !> return nterms_
        procedure :: nvars      !> return nvars_


        procedure, public   :: var

        procedure, public   :: clear


        final :: destructor
    end type densevector_t











    !-------------------    OPERATORS   ---------------------
    public operator (*)
    interface operator (*)
        module procedure mult_real_dv   ! real * densevector,   ELEMENTAL
        module procedure mult_dv_real   ! densevector * real,   ELEMENTAL
    end interface



    public operator (/)
    interface operator (/)
        module procedure div_real_dv    ! real / densevector,   ELEMENTAL
        module procedure div_dv_real    ! densevector / real,   ELEMENTAL
    end interface



    public operator (+)
    interface operator (+)
        module procedure add_dv_dv      ! densevector + densevector,    ELEMENTAL
    end interface



    public operator (-)
    interface operator (-)
        module procedure sub_dv_dv      ! densevector - densevector,    ELEMENTAL
    end interface











    private
contains

    !> Subroutine for initializing dense-vector storage
    !!
    !!  @author Nathan A. Wukie
    !!
    !!  @param[in]  nterms  Number of terms in an expansion
    !!  @param[in]  nvars   Number of equations being represented
    !!  @param[in]  parent  Index of associated parent element
    !-----------------------------------------------------------
    subroutine init_vector(self,nterms,nvars,parent)
        class(densevector_t),   intent(inout), target   :: self
        integer(ik),            intent(in)              :: nterms
        integer(ik),            intent(in)              :: nvars
        integer(ik),            intent(in)              :: parent

        integer(ik) :: ierr, vsize

        ! Set dense-vector integer data
        self%parent_ = parent
        self%nterms_ = nterms
        self%nvars_  = nvars


        ! Compute total number of elements for densevector storage
        vsize = nterms * nvars


        ! Allocate block storage
        ! Check if storage was already allocated and reallocate if necessary
        if (allocated(self%vec)) then
            deallocate(self%vec)
            allocate(self%vec(vsize), stat=ierr)
        else
            allocate(self%vec(vsize), stat=ierr)
        end if
        if (ierr /= 0) call AllocationError


        ! Initialize to zero
        self%vec = 0._rk


        ! Initialize matrix pointer alias
        self%mat(1:nterms,1:nvars) => self%vec


    end subroutine







    !> Function returns the stored vector data associated with variable index ivar
    !!
    !!  @author Nathan A. Wukie
    !!
    !--------------------------------------------------------------------------------
    function var(self,ivar) result(modes_out)
        class(densevector_t),   intent(inout)   :: self
        integer(ik),            intent(in)      :: ivar

        real(rk)                                :: modes_out(self%nterms_)

        modes_out = self%mat(:,ivar)
    end function













    !> Function that returns number of entries in block storage
    !!
    !!  @author Nathan A. Wukie
    !------------------------------------------------------------
    function nentries(self) result(n)
        class(densevector_t),   intent(in)      :: self
        integer(ik)                             :: n

        n = size(self%vec)
    end function












    !> Function that returns nterms_ private component
    !!
    !!
    !-----------------------------------------------------------
    pure function nterms(self) result(nterms_out)
        class(densevector_t),   intent(in)  :: self
        integer(ik)                         :: nterms_out

        nterms_out = self%nterms_
    end function










    !> Function that returns nvars_ private component
    !!
    !!
    !-----------------------------------------------------------
    pure function nvars(self) result(nvars_out)
        class(densevector_t),   intent(in)  :: self
        integer(ik)                         :: nvars_out

        nvars_out = self%nvars_
    end function















    !> Function that returns index of block parent
    !!
    !!  @author Nathan A. Wukie
    !------------------------------------------------------------
    function parent(self) result(par)
        class(densevector_t),   intent(in)      :: self
        integer(ik)                             :: par

        par = self%parent_
    end function






    !> Resize dense-block storage
    !!
    !!  @author Nathan A. Wukie
    !!
    !!  @param[in]  vsize   Size of new vector storage array
    !------------------------------------------------------------
    !subroutine resize(self,vsize)
    !    class(densevector_t),   intent(inout)   :: self
    !    integer(ik),            intent(in)      :: vsize
!
!        integer(ik) :: ierr
!
!        ! Allocate block storage
!        ! Check if storage was already allocated and reallocate if necessary
!        if (allocated(self%vec)) then
!            deallocate(self%vec)
!            allocate(self%vec(vsize),stat=ierr)
!        else
!            allocate(self%vec(vsize),stat=ierr)
!        end if
!        if (ierr /= 0) call AllocationError
!
!    end subroutine






    !> reset index of parent
    !!
    !!  @author Nathan A. Wukie
    !!
    !!  @param[in]  par     Index of new parent element
    !------------------------------------------------------------
    subroutine reparent(self,par)
        class(densevector_t),   intent(inout)   :: self
        integer(ik),            intent(in)      :: par

        self%parent_ = par
    end subroutine












    !> Zero vector storage, self%vec
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !-----------------------------------------------------------
    subroutine clear(self)
        class(densevector_t),   intent(inout)   :: self


        self%vec = ZERO

    end subroutine clear

















    !-------------------------------------------------------------------
    !-------------      OPERATOR IMPLEMENTATIONS    --------------------
    !-------------------------------------------------------------------
    elemental function mult_real_dv(left,right) result(res)
        real(rk),               intent(in)  :: left
        type(densevector_t),    intent(in)  :: right
        type(densevector_t), target :: res
        real(rk), pointer :: temp(:)

        res%parent_ = right%parent_
        res%nvars_  = right%nvars_
        res%nterms_ = right%nterms_

        res%vec     = left * right%vec

        
        temp => res%vec
        res%mat(1:res%nterms_,1:res%nvars_) => temp

    end function

   
    elemental function mult_dv_real(left,right) result(res)
        type(densevector_t),    intent(in)  :: left
        real(rk),               intent(in)  :: right
        type(densevector_t), target :: res
        real(rk), pointer :: temp(:)


        res%parent_ = left%parent_
        res%nvars_  = left%nvars_
        res%nterms_ = left%nterms_

        res%vec     = left%vec * right


        temp => res%vec
        res%mat(1:res%nterms_,1:res%nvars_) => temp
    end function








    elemental function div_real_dv(left,right) result(res)
        real(rk),               intent(in)  :: left
        type(densevector_t),    intent(in)  :: right
        type(densevector_t), target :: res
        real(rk), pointer :: temp(:)


        res%parent_ = right%parent_
        res%nvars_  = right%nvars_
        res%nterms_ = right%nterms_
        
        res%vec     = left / right%vec

        temp => res%vec
        res%mat(1:res%nterms_,1:res%nvars_) => temp
    end function


    elemental function div_dv_real(left,right) result(res)
        type(densevector_t),        intent(in)  :: left
        real(rk),                   intent(in)  :: right
        type(densevector_t), target :: res
        real(rk), pointer :: temp(:)


        res%parent_ = left%parent_
        res%nvars_  = left%nvars_
        res%nterms_ = left%nterms_

        res%vec     = left%vec / right


        temp => res%vec
        res%mat(1:res%nterms_,1:res%nvars_) => temp
    end function







    elemental function add_dv_dv(left,right) result(res)
        type(densevector_t),    intent(in)  :: left
        type(densevector_t),    intent(in)  :: right
        type(densevector_t), target :: res
        real(rk), pointer :: temp(:)


        res%parent_ = left%parent_
        res%nvars_  = left%nvars_
        res%nterms_ = left%nterms_

        res%vec     = left%vec + right%vec



        temp => res%vec
        res%mat(1:res%nterms_,1:res%nvars_) => temp
    end function




    elemental function sub_dv_dv(left,right) result(res)
        type(densevector_t),    intent(in)  :: left
        type(densevector_t),    intent(in)  :: right
        type(densevector_t), target :: res
        real(rk), pointer :: temp(:)


        res%parent_ = left%parent_
        res%nvars_  = left%nvars_
        res%nterms_ = left%nterms_

        res%vec     = left%vec - right%vec


        temp => res%vec
        res%mat(1:res%nterms_,1:res%nvars_) => temp
    end function


    





































    subroutine destructor(self)
        type(densevector_t),    intent(inout)   :: self

    end subroutine

end module type_densevector