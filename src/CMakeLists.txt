add_subdirectory(chidg)
add_subdirectory(constants)
add_subdirectory(grid)
add_subdirectory(containers)
add_subdirectory(tools)
add_subdirectory(io)
add_subdirectory(polynomial)
add_subdirectory(quadrature)    
add_subdirectory(time_integrators)
add_subdirectory(equations)
add_subdirectory(spatial)
add_subdirectory(functions)
add_subdirectory(functionals)
add_subdirectory(boundary_conditions)
add_subdirectory(linear_solvers)
add_subdirectory(nonlinear_solvers)
add_subdirectory(preconditioners)
add_subdirectory(numerical_methods)
add_subdirectory(chimera)
add_subdirectory(parallel)
add_subdirectory(actions)
add_subdirectory(drivers)
add_subdirectory(mesh_motion)
add_subdirectory(tutorials)
add_subdirectory(interfaces)
add_subdirectory(json_fortran)

# Propagate lib_srcs list to parent directory
add_lib_sources() 
add_python_sources()


# Add main executable and propagate to parent
add_exe_sources(driver.f90)    

    

