add_test_sources(boundary_conditions
                 test_bc_patch_mod.pf
                 test_bc_state_mod.pf
                 test_bc_periodic_mod.pf
                 test_bc_element_coupling_mod.pf
                 ) 


add_test_target(boundary_conditions unit ${boundary_conditions_sources})
