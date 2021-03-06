! 
!    Copyright 2011 Sebastian Heimann
! 
!    Licensed under the Apache License, Version 2.0 (the "License");
!    you may not use this file except in compliance with the License.
!    You may obtain a copy of the License at
! 
!        http://www.apache.org/licenses/LICENSE-2.0
! 
!    Unless required by applicable law or agreed to in writing, software
!    distributed under the License is distributed on an "AS IS" BASIS,
!    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
!    See the License for the specific language governing permissions and
!    limitations under the License.
!


module receiver

    use better_varying_string
    use util
    use orthodrome
    use sparse_trace
    use piecewise_linear_function
    use comparator
    use seismogram_io
    
    implicit none
    
    private
    
  ! This module groups methods to handle multi-component receivers, and
  ! to calculate misfits.
      
    integer, parameter, public :: C_AWAY   =  1   ! a
    integer, parameter, public :: C_COMING = -1   ! c
    
    integer, parameter, public :: C_RIGHT  =  2   ! r
    integer, parameter, public :: C_LEFT   = -2   ! l
    
    integer, parameter, public :: C_DOWN   =  3   ! d
    integer, parameter, public :: C_UP     = -3   ! u
    
    integer, parameter, public :: C_NORTH  =  4   ! n
    integer, parameter, public :: C_SOUTH  = -4   ! s
    
    integer, parameter, public :: C_EAST   =  5   ! e
    integer, parameter, public :: C_WEST   = -5   ! w
    
  ! probe ids
    integer, parameter, public :: REFERENCES = 1
    integer, parameter, public :: SYNTHETICS = 2
    
    character, public, dimension(1:2) :: probe_names = (/ 'r', 's' /)

    character, public, dimension(-5:5) :: component_names = (/ 'w', 's', 'u', 'l', 'c', '?', 'a', 'r', 'd', 'n', 'e' /)
    
    type, public :: t_receiver
    
      ! flag true if this receiver is to be processed
        logical                                    :: enabled

      ! ids to mark output files
        type(varying_string)                       :: network, station, location

      ! sampling rate
        real                                       :: dt
    
      ! location of the receiver
        type(t_geo_coords)                         :: origin
        real                                       :: depth = 0.0
        
      ! number of components (must be in sync with size(components))
        integer                                    :: ncomponents
        
      ! what component is what
        integer, dimension(:), allocatable         :: components
      
      ! displacement for each component
        type(t_strip),dimension(:), allocatable    :: displacement
      
      ! misfit between synthetic and reference for every component
        real, dimension(:), allocatable            :: misfits
        real, dimension(:), allocatable            :: misfits_norm_factors
        
      ! cross-correlation between synthetics and reference for every component
        real, dimension(:,:), allocatable          :: cross_corr

      ! probes for each component of reference and sythetics
      ! (these are used to compare references to synthetics in comparator.f90)
        type(t_probe), dimension(:), allocatable   :: ref_probes, syn_probes

      ! allowed range of shifts for floating misfits
        integer, dimension(2)                      :: floating_shiftrange = (/ 0, 0 /)

      ! last occured best floating shift
        integer                                    :: floating_shift = 0

    end type

    public receiver_init
    public receiver_destroy
    public receiver_set_ids
    public receiver_component_index
    public receiver_component_sign
    public receiver_set_enabled
    public receiver_set_filter
    public receiver_set_taper
    public receiver_set_synthetics_factor
    public receiver_output_seismogram
    public receiver_output_seismogram_spectra
    public receiver_set_ref_seismogram
    public receiver_shift_ref_seismogram
    public receiver_autoshift_ref_seismogram
    public receiver_calculate_misfits
    public receiver_calculate_cross_correlations
    public receiver_output_cross_correlations
    public receiver_get_maxabs
    public receiver_get_arias_intensity
    public receiver_scaled_seismograms_to_probes

    public character_to_id
    
  contains
 
    pure subroutine intersection( a, b, c )
    
        real, dimension(2), intent(in) :: a, b
        real, dimension(2), intent(out) :: c
        
        c(1) = max(a(1),b(1))
        c(2) = min(a(2),b(2))
        
    end subroutine
    
    subroutine receiver_init( self, origin, depth, components_str, dt, ok )
    
        type(t_receiver), intent(inout)  :: self
        type(t_geo_coords), intent(in)   :: origin          ! location of receiver 
        real                             :: depth
        character(len=*), intent(in)     :: components_str  ! componenents at this receiver
        real, intent(in)                 :: dt              ! sampling rate
        logical, intent(out)             :: ok              ! exit status
        
      ! initialize a receiver object
        
        integer id, i,j, ncomponents,icomponent
        
        call receiver_destroy( self )
        ok = .false.

        self%enabled = .true.
        
        self%network = ''
        self%station = ''
        self%location = ''

        self%dt = dt
        
      ! parse and check components string
      
        ncomponents = len_trim( components_str )
        allocate( self%components(ncomponents) )
        if (ncomponents .eq. 0) then
            self%enabled = .false.            
        end if
        do i=1,ncomponents
            id = character_to_id( components_str(i:i) )
            
            if (id .eq. 0) then
                deallocate( self%components )
                return
            end if
            
          ! check for forbidden combinations
            if (i>1) then
                do j=1,i-1
                    if (abs(self%components(j)) == abs(id)) then
                        deallocate( self%components )
                        return
                    end if
                end do
            end if
            
            self%components(i) = id
            
        end do
        
        ok = .true.
        
      ! initialize the contents
      
        self%ncomponents = ncomponents
        self%origin = origin
        self%depth = depth
        
        allocate( self%displacement(ncomponents) )
        allocate( self%ref_probes(ncomponents) )
        allocate( self%syn_probes(ncomponents) )
        allocate( self%misfits(ncomponents) )
        allocate( self%misfits_norm_factors(ncomponents) )
        
        do icomponent=1,ncomponents
            call probe_init( self%ref_probes(icomponent), dt )
            call probe_init( self%syn_probes(icomponent), dt )
        end do
        

    end subroutine
    
    subroutine receiver_set_ids(self, network, station, location)

        type(t_receiver), intent(inout)  :: self
        type(varying_string), intent(in) :: network, station, location

        self%network = network
        self%station = station
        self%location = location

    end subroutine

    subroutine receiver_destroy( self )
    
        type(t_receiver), intent(inout)  :: self
        
      ! deallocate everything attached to this receiver object
      ! this does not fail when called more then once or the object has not been initialized.
        
        integer ::  icomponent
        
        if (allocated(self%ref_probes)) then
            do icomponent=1,self%ncomponents
                call probe_destroy( self%ref_probes(icomponent) )
            end do
            deallocate( self%ref_probes )
        end if
        
        if (allocated(self%syn_probes)) then
            do icomponent=1,self%ncomponents
                call probe_destroy( self%syn_probes(icomponent) )
            end do
            deallocate( self%syn_probes )
        end if
        
        if (allocated(self%displacement)) then
            do icomponent=1,self%ncomponents
                call strip_destroy( self%displacement(icomponent) )
            end do
            deallocate( self%displacement )
        end if
        
        if (allocated(self%components)) then
            deallocate(self%components)
        end if
        
        if (allocated(self%misfits)) then
            deallocate(self%misfits)
        end if
        
        if (allocated(self%misfits_norm_factors)) then
            deallocate(self%misfits_norm_factors)
        end if
        
        self%ncomponents = 0
        self%origin%lat = 0.0
        self%origin%lon = 0.0
        self%dt = 0.0
        self%enabled = .false.
        
        call delete(self%network)
        call delete(self%station)
        call delete(self%location)

    end subroutine

    pure subroutine receiver_set_enabled( self, newstate )

        type(t_receiver), intent(inout)  :: self
        logical, intent(in) :: newstate

        integer :: icomponent

        if (.not. newstate) then
          ! put zeroes into the synthetic data, in case seismogram output is requested, 
          ! so that no old data is output
            
            if (allocated(self%displacement)) then
                do icomponent=1,self%ncomponents
                    call strip_nullify( self%displacement(icomponent) )
                end do
            end if
        end if

        self%enabled = newstate

    end subroutine
    
    pure function character_to_id( ch )
    
        character, intent(in) :: ch
        integer :: character_to_id
        
      ! lookup id of component character
        
        integer :: i
        
        do i=lbound(component_names,1),ubound(component_names,1)
            character_to_id = i
            if (ch .eq. component_names(i)) return
        end do
        character_to_id = 0
    
    end function
  
    function receiver_component_index( self, component  ) result( ind )
        
        type(t_receiver), intent(in) :: self
        integer, intent(in) :: component
        integer :: ind
        
      ! get index of a specific component or zero if it is not available
        
        integer :: i
        
        ind = 0
        if (.not. allocated(self%components)) return
        
        do i=1,size(self%components,1)
            if (abs(self%components(i)) == abs(component)) then
               ind = i
               return
            end if
        end do
        
    end function
    
    function receiver_component_sign( self, component  ) result( sig )
        
        type(t_receiver), intent(in) :: self
        integer, intent(in) :: component
        real :: sig
        
      ! get sign of a specific component or zero if component not available
        
        integer :: i
        
        sig = 0.
        if (.not. allocated(self%components)) return
        
        do i=1,size(self%components,1)
            if (abs(self%components(i)) == abs(component)) then
               sig = sign(1.,real(self%components(i)))
               return
            end if
        end do
        
    end function
    
    subroutine receiver_set_filter( self, filter )
    
        type(t_receiver), intent(inout) :: self
        type(t_plf), intent(in) :: filter
        
      ! turn on filtering on all components of this receiver
       
        integer :: icomponent
        
        do icomponent=1,self%ncomponents
            call probe_set_filter( self%ref_probes(icomponent), filter )
            call probe_set_filter( self%syn_probes(icomponent), filter )
        end do
        
    end subroutine
    
    subroutine receiver_set_taper( self, taper )
    
        type(t_receiver), intent(inout) :: self
        type(t_plf), intent(in) :: taper
      
      ! turn on tapering on all components of this receiver 
       
        integer :: icomponent
        
        do icomponent=1,self%ncomponents
            call probe_set_taper( self%ref_probes(icomponent), taper )
            call probe_set_taper( self%syn_probes(icomponent), taper )
        end do
        
    end subroutine

    subroutine receiver_set_synthetics_factor( self, factor )
    
        type(t_receiver), intent(inout) :: self
        real, intent(in) :: factor
      
      ! the synthetic seismogram is multiplied by this factor during misfit calculation
      ! this can be used to quickly check for scalar moment
       
        integer :: icomponent
        
        do icomponent=1,self%ncomponents
            call probe_set_factor( self%syn_probes(icomponent), factor )
        end do
        
    end subroutine

    subroutine receiver_calculate_misfits( self, misfit_method )
    
        type(t_receiver), intent(inout) :: self
        integer, intent(in)             :: misfit_method
        
      ! calculate misfits between synthetics and references for all components of this receiver
        
        integer :: icomponent

        if (misfit_method == FLOATING_L1NORM .or. misfit_method == FLOATING_L2NORM) then
            call receiver_calculate_floating_misfits( self, misfit_method, self%floating_shiftrange )
        else
        
            do icomponent=1,self%ncomponents
            
                if (self%enabled) then
                    self%misfits(icomponent) = probes_norm( self%ref_probes(icomponent), &
                                                            self%syn_probes(icomponent), &
                                                            misfit_method )
                    self%misfits_norm_factors(icomponent) = &
                                            probe_norm( self%ref_probes(icomponent), &
                                                            misfit_method )
                else
                    self%misfits(icomponent) = 0.0
                    self%misfits_norm_factors(icomponent) = 0.0
                end if

            end do
        end if
    
    end subroutine

    subroutine receiver_calculate_floating_misfits( self, misfit_method, shiftrange )
    
        type(t_receiver), intent(inout)    :: self
        integer, intent(in)                :: misfit_method  ! FLOATING_L?NORM
        integer, intent(in), dimension(2)  :: shiftrange
        
      ! calculate misfits between synthetics and references for all components of this receiver
        
        integer :: icomponent
        real :: min_misfit
        integer :: ishift, i, iloc
        real, dimension(self%ncomponents,slen(shiftrange)) :: misfits, norms
        integer :: evaluate_misfit_method

        if (misfit_method == FLOATING_L1NORM) then
            evaluate_misfit_method = L1NORM
        else if (misfit_method == FLOATING_L2NORM) then
            evaluate_misfit_method = L2NORM
        else
            call die('receiver_calculate_floating_misfits only works with FLOATING_L1NORM or FLOATING_L2NORM')
        end if

        if (self%ncomponents == 0) then
            return
        end if 
        
        if (.not. self%enabled) then
            do icomponent=1,self%ncomponents
                self%misfits(icomponent) = 0.0
                self%misfits_norm_factors(icomponent) = 0.0
            end do

        else

            ishift = shiftrange(1)
            
            do i=1,slen(shiftrange)
                do icomponent=1,self%ncomponents
                    call probe_shift( self%ref_probes(icomponent), ishift )

                    misfits(icomponent,i) = probes_norm( self%ref_probes(icomponent), &
                                                            self%syn_probes(icomponent), &
                                                            evaluate_misfit_method )

                    norms(icomponent,i) = probe_norm( self%ref_probes(icomponent), &
                                                            evaluate_misfit_method )
 
                end do
                ishift = 1
            end do
            
            if (evaluate_misfit_method == L1NORM) then
                iloc = minloc( sum(misfits,1),1 )
            else if (evaluate_misfit_method == L2NORM) then
                iloc = minloc( sum(misfits**2,1),1 )
            else
                iloc = 1 ! should not happen
            end if

            self%floating_shift = shiftrange(1) + (iloc-1)

            self%misfits = misfits(:,iloc)
            self%misfits_norm_factors = sum(norms,2) / slen(shiftrange)

          ! reset shift
            do icomponent=1,self%ncomponents
                call probe_shift( self%ref_probes(icomponent), -shiftrange(2) )
            end do

        end if 
    
    end subroutine

    subroutine get_component_ids( self, iver, ihor1, ihor2 )
    
      ! get the horizontal components, preferably a/c and r/l
    
        type(t_receiver), intent(in) :: self
        integer, intent(out) :: iver, ihor1, ihor2
        
        integer ict, icomponent
        ihor1 = 0
        ihor2 = 0
        iver = 0
        do icomponent=1, self%ncomponents
            ict = abs(self%components(icomponent))
            if (ict == 1) ihor1 = icomponent
            if (ict == 2) ihor2 = icomponent
            if (ict == 3) iver = icomponent
        end do
        if (ihor1 == 0 .or. ihor2 == 0) then
            do icomponent=1, self%ncomponents
                ict = abs(self%components(icomponent))
                if (ict == 4) ihor1 = icomponent
                if (ict == 5) ihor2 = icomponent
            end do
        end if
        if (ihor1 == 0 .or. ihor2 == 0) then 
          ! return none, if incomplete 
            ihor1 = 0 
            ihor2 = 0
        end if

    end subroutine

    subroutine receiver_get_maxabs( self, differentiate, val )
    
        type(t_receiver), intent(inout) :: self
        integer, intent(in) :: differentiate     ! 1, or 2 ; zero is not implemented yet.
        real, intent(out) :: val
        
        integer i, ii, nused
        integer, dimension(3) :: icomp
        integer, dimension(3) :: icomp_used

        val = 0.
        if (self%enabled) then 
            call get_component_ids( self, icomp(1), icomp(2), icomp(3) )
            nused = 0
            do i=1,3
                if (icomp(i) /= 0) then
                    nused = nused + 1
                    icomp_used(nused) = icomp(i)
                end if
            end do
            if (nused == 1) then
                val = probes_max_vecnorm_1( differentiate, self%syn_probes(icomp_used(1)) )
            else if (nused == 2) then
                val = probes_max_vecnorm_2( differentiate, self%syn_probes(icomp_used(1)), self%syn_probes(icomp_used(2)) )
            else if (nused == 3) then
                val = probes_max_vecnorm_3( differentiate, self%syn_probes(icomp_used(1)), self%syn_probes(icomp_used(2)), &
                            self%syn_probes(icomp_used(3)) )
            end if
        end if

    end subroutine

    subroutine receiver_get_arias_intensity( self, val )
    
        type(t_receiver), intent(inout) :: self
        real, intent(out) :: val
        
        integer iver, ihor1, ihor2
        
        val = 0.
        if (self%enabled) then 
            call get_component_ids( self, iver, ihor1, ihor2 )
            if (iver /= 0 .and. ihor1 /= 0 .and. ihor2 /= 0) then
                val = probes_arias_intensity_3( self%syn_probes(iver), self%syn_probes(ihor1), self%syn_probes(ihor2) )
            else if (ihor1 /= 0 .and. ihor2 /= 0) then
                val = probes_arias_intensity_2( self%syn_probes(ihor1), self%syn_probes(ihor2) )
            else if (iver /= 0) then
                val = probes_arias_intensity_1( self%syn_probes(iver) )
            end if
        end if
    end subroutine
 

    subroutine receiver_calculate_cross_correlations( self, shiftrange )
    
        type(t_receiver), intent(inout)    :: self
        integer, intent(in), dimension(2)  :: shiftrange
        
      ! calculate cross-correlation between synthetics and references for all components of this receiver
        
        integer :: icomponent
        
        if (allocated(self%cross_corr)) then
            deallocate( self%cross_corr )
        end if
        allocate( self%cross_corr(shiftrange(1):shiftrange(2),self%ncomponents) )

        do icomponent=1,self%ncomponents
            call probes_windowed_cross_corr( self%syn_probes(icomponent), self%ref_probes(icomponent), &
                                             shiftrange, self%cross_corr(:,icomponent) )
        end do
    
    end subroutine
    
    subroutine receiver_output_seismogram( self, filenamebase, fileformat, which_probe, which_processing, reftime, ok )
    
        type(t_receiver), intent(inout)   :: self
        type(varying_string), intent(in)  :: filenamebase, fileformat
        integer, intent(in)               :: which_probe, which_processing
        real(kind=8), intent(in)          :: reftime
        logical, intent(out)              :: ok
        
        type(varying_string)        :: outfn
        integer                     :: icomponent
        integer                     :: nerr
        type(t_strip)               :: strip
        integer, dimension(2)       :: span
 
        real :: dt
        
        dt = self%dt
        
        ok = .true.
        if (.not. self%enabled) return
        do icomponent=1, self%ncomponents
            outfn = filenamebase // "-" // component_names(self%components(icomponent)) // "." // fileformat
            
            if (which_probe == SYNTHETICS) then
                call probe_get( self%syn_probes(icomponent), strip, which_processing )
            else 
                call probe_get( self%ref_probes(icomponent), strip, which_processing )
            end if
            span = strip_span( strip )
            call writeseismogram( char(outfn), "*", &
                        strip%data, &
                        reftime+(span(1)-1)*dt, dt, &
                        char(self%network), char(self%station), char(self%location), &
                        component_names(self%components(icomponent))//probe_names(which_probe), &
                        nerr )
            
            if (nerr /= 0) then
                ok = .false.
                call error( "failed to write output file: " // outfn )
                call strip_destroy(strip)
                return
            end if
            
        end do
        call strip_destroy( strip )
        
    end subroutine
    
    subroutine receiver_output_seismogram_spectra( self, filenamebase, which_probe, which_processing, ok )
    
        type(t_receiver), intent(inout)   :: self
        type(varying_string), intent(in)  :: filenamebase
        integer, intent(in)               :: which_probe, which_processing
        logical, intent(out)              :: ok
        
        type(varying_string)        :: outfn
        integer                     :: icomponent
        integer                     :: nerr
        type(t_strip)               :: strip
 
        real :: df
        
        ok = .true.
        if (.not. self%enabled) return
        
        do icomponent=1, self%ncomponents
            outfn = filenamebase // "-" // component_names(self%components(icomponent)) // ".table"
            
            if (which_probe == SYNTHETICS) then
                call probe_get_amp_spectrum( self%syn_probes(icomponent), strip, df, which_processing )
            else
                call probe_get_amp_spectrum( self%ref_probes(icomponent), strip, df, which_processing )
            end if
                
            call writeseismogram( char(outfn), "*", &
                                  strip%data, &
                                  dble(0.0), df, &
                                  char(self%network), char(self%station), char(self%location), &
                                  component_names(self%components(icomponent)), &
                                  nerr )
            if (nerr /= 0) then
                ok = .false.
                call error( "failed to write output file: " // outfn )
                call strip_destroy( strip )
                return
            end if
            
        end do
        call strip_destroy( strip )
        
    end subroutine

    subroutine receiver_output_cross_correlations( self, filenamebase, ok )
    
        type(t_receiver), intent(inout)   :: self
        type(varying_string), intent(in)  :: filenamebase
        logical, intent(out)              :: ok

        type(varying_string)        :: outfn
        integer                     :: icomponent
        integer                     :: nerr

        ok = .true.
        if (.not. self%enabled) return
        if (.not. allocated(self%cross_corr)) then
            ok = .false.
            call error( "no cross-correlations have been calculated yet" )
            return
        end if

        ok = .true.
        do icomponent=1, self%ncomponents
            outfn = filenamebase // "-" // component_names(self%components(icomponent)) // ".table"
            call writeseismogram( char(outfn), "*", &
                                  self%cross_corr(:,icomponent), &
                                  dble(lbound(self%cross_corr,1)*self%dt), self%dt, &
                                  char(self%network), char(self%station), char(self%location), &
                                  component_names(self%components(icomponent)), &
                                  nerr )
            if (nerr /= 0) then
                ok = .false.
                call error( "failed to write output file: " // outfn )
                return
            end if
        end do

    end subroutine
    
    subroutine receiver_set_ref_seismogram( self, reffnbase, refformat, reftime, ok )
    
        type(t_receiver), intent(inout)    :: self
        type(varying_string), intent(in)   :: reffnbase, refformat
        real(kind=8), intent(in)           :: reftime
        logical, intent(out) :: ok

      ! read a set of reference seismograms from ascii or sac files
        
        integer                         :: icomponent, nerr
        real(kind=8)                    :: toffset
        real                            :: deltat
        type(varying_string)            :: reffn
        type(t_strip)                   :: strip
        real, dimension(:), allocatable :: temp_seismogram
        
        ok = .true.
        
        if (.not. self%enabled) return

        do icomponent=1,self%ncomponents
            reffn = reffnbase // "-" // component_names(self%components(icomponent)) // "." // refformat
            call readseismogram( char(reffn), "*", temp_seismogram, toffset, &
                                deltat, nerr )
            if (nerr /= 0) then
                call error("failed to read seismogram from file " // reffn)
                ok = .false.
                exit
            end if
            
            if (abs(deltat - self%dt)>self%dt/10000.) then
                call error("sampling rate in file '" // reffn // "' is " // deltat //&
                            " but required sampling rate is " // self%dt )
                ok = .false.
                exit
            end if
            
            if (abs(toffset-reftime) > 3600.*24.*7.) then
                call error("origin time and seismogram starting time differ by " //&
                           " more than 7 days (file is '" // reffn // ")" )
                ok = .false.
                exit
            end if
            
            call seismogram_to_strip( temp_seismogram, real(toffset-reftime), self%dt, &
                                    strip )
            
            call probe_set_array( self%ref_probes(icomponent), strip )
            
        end do

        call strip_destroy( strip )
        if ( allocated(temp_seismogram) ) deallocate(temp_seismogram)


    end subroutine
    
    subroutine receiver_shift_ref_seismogram( self, ishift )

        type(t_receiver), intent(inout)    :: self
        integer, intent(in) :: ishift

        integer :: icomponent

        do icomponent=1,self%ncomponents
            call probe_shift( self%ref_probes(icomponent), ishift )
        end do

    end subroutine

    subroutine receiver_autoshift_ref_seismogram( self, ishiftrange, ishift )

        type(t_receiver), intent(inout)    :: self
        integer, dimension(2), intent(in)  :: ishiftrange
        integer, intent(out) :: ishift

        integer :: imax
        ishift = 0
        if (self%enabled) then
            call receiver_calculate_cross_correlations( self, ishiftrange )

            imax = maxloc( sum(max(self%cross_corr/max(1.,maxval(self%cross_corr)),0.)**2,2),1 )
            ishift = imax+ishiftrange(1)-1
            call receiver_shift_ref_seismogram( self, ishift )
        end if
        
    end subroutine

    subroutine seismogram_to_strip( seismogram, tbegin, deltat, strip )
    
        real, dimension(:), intent(in) :: seismogram
        real, intent(in) :: tbegin, deltat
        type(t_strip), intent(inout) :: strip
        
        integer :: ibeg,nlen
        
        ibeg = nint(tbegin/deltat)
        nlen = size(seismogram,1)
      !  if (abs(ibeg*deltat - tbegin) > deltat/100.) then
      !      call die( "time of first sample of seismogram not "// &
      !                 "divideable by sampling distance" )
      !  end if
        
        call strip_init( (/ibeg+1,ibeg+nlen/), seismogram, strip )
    
    end subroutine
 
    subroutine receiver_scaled_seismograms_to_probes(receiver, risetime, moment)

      ! Put seismogram data into probes and apply moment and rise-time

        type(t_receiver), intent(inout) :: receiver
        real, intent(in) :: risetime, moment

        integer :: icomp, ishift, nshifts
        type(t_strip) :: tmp
        real, dimension(2) :: rrise, rsamp, rover
        real, dimension(:), allocatable :: weights, shifts
        real :: ts

        if (receiver%enabled) then

            ! make weights and shifts for stf
            if (risetime > 0.0) then
                rrise(1) = -risetime/2.
                rrise(2) = +risetime/2.
                nshifts = 1 + 2 * nint(0.5*risetime/receiver%dt)
                if (allocated(weights)) deallocate(weights)
                if (allocated(shifts)) deallocate(shifts)
                allocate( weights(nshifts))
                allocate( shifts(nshifts))
                do ishift=1,nshifts
                    ts = (ishift-1 - 0.5*(nshifts-1))*receiver%dt
                    rsamp(1) = ts-receiver%dt/2.
                    rsamp(2) = ts+receiver%dt/2.
                    call intersection(rrise, rsamp, rover)
                    weights(ishift) = max(0., rover(2)-rover(1))
                    shifts(ishift) = ts / receiver%dt
                end do
                weights = weights/sum(weights)
            end if
            
            do icomp=1,receiver%ncomponents
                
                call strip_copy(receiver%displacement(icomp), tmp)
                if (risetime > 0.0) then
                    call strip_fold( tmp, shifts, weights )
                end if
                call probe_set_array( receiver%syn_probes(icomp), tmp, &
                                    factor_=moment )

            end do
        end if

        if (allocated(weights)) deallocate(weights)
        if (allocated(shifts)) deallocate(shifts)
        call strip_destroy(tmp)

    end subroutine

    pure function slen( span )
        integer, dimension(2), intent(in) :: span
        integer :: slen
        slen = span(2) - span(1) + 1
    end function

end module
