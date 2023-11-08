@doc raw"""
	write_capacity_retrofit(path::AbstractString, inputs::Dict, setup::Dict, EP::Model))

Function for writing retrofited technologies
"""
function write_capacity_retrofit(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
	# Capacity decisions
	dfGen = inputs["dfGen"]
	RETRO_SOURCE_IDS = inputs["RETROFIT_SOURCE_IDS"] # Source technologies by ID for each retrofit [1:G]
	RETRO_EFFICIENCY = inputs["RETROFIT_EFFICIENCIES"]
	NUM_RETRO_SOURCES = inputs["NUM_RETROFIT_SOURCES"]
	
	RETROFIT_SOURCE = [];
	RETROFIT_DEST = [];
	RETROFIT_CAP = [];
	ORIG_CAP = [];
	RETRO_EFF = [];

	for (i,j) in keys(EP[:vRETROFIT].data)
		push!(RETROFIT_SOURCE, inputs["RESOURCES"][i])
		push!(RETROFIT_DEST, inputs["RESOURCES"][j])
		push!(RETROFIT_CAP, value(EP[:vRETROFIT].data[i,j]))
		push!(ORIG_CAP, dfGen[!,:Existing_Cap_MW][i])
		push!(RETRO_EFF, RETRO_EFFICIENCY[j][findfirst(item -> item == i, RETRO_SOURCE_IDS[j])])
	end


	dfCapRetro = DataFrame(
		RetrofitResource = RETROFIT_SOURCE,
		OriginalCapacity = ORIG_CAP,
		RetrofitDestination = RETROFIT_DEST,
		RetrofitedCapacity = RETROFIT_CAP,
		OperationalRetrofitedCapacity = RETROFIT_CAP .* RETRO_EFF
	)
	if setup["ParameterScale"] ==1
		dfCapRetro.OriginalCapacity = dfCapRetro.OriginalCapacity * ModelScalingFactor
		dfCapRetro.RetrofitedCapacity = dfCapRetro.RetrofitedCapacity * ModelScalingFactor
		dfCapRetro.OperationalRetrofitedCapacity = dfCapRetro.OperationalRetrofitedCapacity * ModelScalingFactor
	end
	
	CSV.write(joinpath(path, "capacity_retrofit.csv"), dfCapRetro)
	return dfCapRetro
end