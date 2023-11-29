
using GenX
using JuMP
using CSV, DataFrames

# Save Run_case.jl directory 
Run_case_path = joinpath(@__DIR__, "Run_case.jl")
mpc_runs_dir = dirname(Run_case_path)  # This extracts the directory part from run_path
run_path = joinpath(mpc_runs_dir, "data_run") # .../mpc_runs/data_run
rolling_horizon_data_path = joinpath(run_path, "rolling_horizon_data") # .../mpc_runs/data_run/rolling_horizon_data_path
runs_results_path = joinpath(run_path, "runs_results") # .../mpc_runs/data_run/runs_results
data_year_path = joinpath(mpc_runs_dir, "data_year") #.../mpc_runs/data_year


## Set the rolling window (hrs)
window = 24 * 14 # currently set to 14 days (2 weeks)

## Set the maximum number of hours in the model
max_hrs = 8760 

## Set the number of hours for which we will keep
keep_hrs = 24 * 7 # Currently set to 1 week

## This gives you the number of runs
run_number = max_hrs / keep_hrs

# Initialize initial state of charge dictionary 
iSoC = Dict()
####### This is setup for Supercloud so make sure to change your paths accordingly ########
for i in 1:run_number

    case = run_path

    function get_settings_path(case::AbstractString)
        return joinpath(case, "Settings")
    end

    function get_settings_path_yml(case::AbstractString, filename::AbstractString)
        return joinpath(get_settings_path(case), filename)
    end

    genx_settings = get_settings_path_yml(case, "genx_settings.yml") # Settings YAML file path
    mysetup = configure_settings(genx_settings) # mysetup dictionary stores settings and GenX-specific parameters

    inputs_path = case
    settings_path = get_settings_path(case)

    ### Modify the inputs to reflect the rolling window
    start_index = Int((i-1)*keep_hrs + 1)
    end_index = Int((i-1)*keep_hrs + window)
    println("Start: ", start_index, " end: ", end_index)

    idx_len = start_index:end_index

    ## Load 
    load_data_path = joinpath(data_year_path, "Load_data.csv")
    load_data = CSV.read(load_data_path, DataFrame)
    load_window = load_data[start_index:end_index, "Load_MW_z1"]
    # println(load_window)

    run_load_data_path = joinpath(run_path, "Load_data.csv")
    run_load_data = CSV.read(run_load_data_path, DataFrame)

    run_load_data = run_load_data[start_index:end_index, :]
    run_load_data[!, "Timesteps_per_Rep_Period"][1] = window
    run_load_data[!, "Sub_Weights"][1] = window
    run_load_data[!, "Voll"][1] = 50000
    run_load_data[!, "Demand_Segment"][1] = 1
    run_load_data[!, "Cost_of_Demand_Curtailment_per_MW"][1] = 1
    run_load_data[!, "Max_Demand_Curtailment"][1] = 1
    run_load_data[!, "Rep_Periods"][1] = 1

    # Path to write load data to
    CSV.write(joinpath(rolling_horizon_data_path, "Load_data.csv"), run_load_data)

    ## Fuels_data: Path to fuels data from data_year
    fuels_data_path = joinpath(data_year_path, "Fuels_data.csv")
    fuels_data = CSV.read(fuels_data_path, DataFrame)

    # Get the emissions intensities from the fuels_data
    fuels_one = fuels_data[1, :]
    fuels_data = fuels_data[2:end,:]

    # Create a new fuels_data with the emissions intensities
    #println(idx_len)
    fuels_window = fuels_data[start_index:end_index, :]
    #println(fuels_window)
    fuels_time = collect(start_index:end_index)
    #insert!(fuels_time, 1, 0)
    #println(fuels_time)

    fuels_window[!, "Time_Index"] = fuels_time
    insert!(fuels_window, 1, fuels_one)
    #println(fuels_window)

    CSV.write(joinpath(rolling_horizon_data_path, "Fuels_data.csv"), fuels_window)

    ## Generators_variability: Path to generators variability data from data_year
    genvar_data_path = joinpath(data_year_path, "Generators_variability.csv")
    genvar_data = CSV.read(genvar_data_path, DataFrame)

    genvar_filter = genvar_data[start_index:end_index, :]
    genvar_time = collect(start_index:end_index)
    genvar_filter[!, "Time_Index"] = genvar_time
    #println(genvar_filter)


    CSV.write(joinpath(rolling_horizon_data_path, "Generators_variability.csv"), genvar_filter)

    ### Configure solver
    println("Configuring Solver")
    OPTIMIZER = configure_solver(mysetup["Solver"], settings_path)

    #### Running a case
    case = joinpath(case, "rolling_horizon_data")

    ### Load inputs
    println("Loading Inputs")
    myinputs = load_inputs(mysetup, case)

    println("Generating the Optimization Model")
    EP = generate_model(mysetup, myinputs, OPTIMIZER)

    ## Constraint initial state of charge variable setup
    if i != 1
        dfGen = myinputs["dfGen"]
        Reserves = mysetup["Reserves"]

        G = myinputs["G"]     # Number of resources (generators, storage, DR, and DERs)
        T = myinputs["T"]     # Number of time steps (hours)
        Z = myinputs["Z"]     # Number of zones

        STOR_ALL = myinputs["STOR_ALL"]
        STOR_SHORT_DURATION = myinputs["STOR_SHORT_DURATION"]
        representative_periods = myinputs["REP_PERIOD"]

        START_SUBPERIODS = myinputs["START_SUBPERIODS"]
        INTERIOR_SUBPERIODS = myinputs["INTERIOR_SUBPERIODS"]

        hours_per_subperiod = myinputs["hours_per_subperiod"] #total number of hours per subperiod

        ## Constraint initial state of charge
        @constraints(EP, begin
        cSoCInitial[y in STOR_ALL], EP[:vS][y, 1] == iSoC[y]
        end)
    end

    println("Solving Model")
    EP, solve_time = solve_model(EP, mysetup)
    myinputs["solve_time"] = solve_time # Store the model solve time in myinputs

    # Run MGA if the MGA flag is set to 1 else only save the least cost solutionsho    println("Writing Output")
    outputs_path = joinpath(runs_results_path, "Run_$i")
    elapsed_time = @elapsed write_outputs(EP, outputs_path, mysetup, myinputs)
    println("Time elapsed for writing Run_$i is")
    println(elapsed_time)

    STOR_ALL = myinputs["STOR_ALL"]
    dfGen = myinputs["dfGen"]

    
    for y in STOR_ALL
        iSoC[y] = value(EP[:vS][y,window]) - (dfGen[y,:Self_Disch]*value(EP[:vS][y,window]))
    end
    println(iSoC)

end

# Setting initial State of Charge (iSoC). If first run set to zero. Otherwise set to the previous model window results
# if i == 1
#     # Pass
#     println(0)
# else
#     for y in STOR_ALL
#         iSoC[y] = EP[:vS][y,window]-(dfGen[y,:Self_Disch]*EP[:vS][y,window])
#     end
#     println(iSoC)
# end