"""
    initialize_sediment_model(config::Config)

Initial part of the sediment model concept. Reads the input settings and data as defined in the
Config object. Will return a Model that is ready to run.
"""
function initialize_sediment_model(config::Config)

    # unpack the paths to the NetCDF files
    tomldir = dirname(config)
    static_path = joinpath(tomldir, config.input.path_static)
    cyclic_path = joinpath(tomldir, config.input.path_static)
    dynamic_path = joinpath(tomldir, config.input.path_forcing)
    instate_path = joinpath(tomldir, config.state.path_input)
    output_path = joinpath(tomldir, config.output.path)

    Δt = Second(config.timestepsecs)
    sizeinmetres = get(config.model, "sizeinmetres", false)
    reinit = get(config.model, "reinit", true)
    
    # do_rivers = get(config.model, "runrivermodel", false)
    do_reservoirs = get(config.model, "reservoirs", false)
    do_lakes = get(config.model, "lakes", false)
    
    # Rainfall erosion equation: ["answers", "eurosem"]
    rainerosmethod = get(config.model, "rainerosmethod", "answers") 
    # Overland flow transport capacity method: ["yalinpart", "govers", "yalin"]
    # landtransportmethod = get(config.model, "landtransportmethod", "yalinpart")
    # River flow transport capacity method: ["bagnold", "engelund", "yang", "kodatie", "molinas"]
    # rivtransportmethod = get(config.model, "rivtransportmethod", "bagnold") 

    nc = NCDataset(static_path)
    dims = dimnames(nc[param(config, "input.subcatchment")])

    # There is no need to permute the dimensions of the data, since the active indices are
    # correctly calculated in both ways.
    # The dimension order only needs to be known for interpreting the LDD directions
    # and creating the coordinate maps.
    dims_xy = dims[2] in ("y", "lat")

    subcatch_2d = ncread(nc, param(config, "input.subcatchment"); allow_missing = true)
    # indices based on catchment
    inds, rev_inds = active_indices(subcatch_2d, missing)
    n = length(inds)
    modelsize_2d = size(subcatch_2d)

    altitude =
        ncread(nc, param(config, "input.vertical.altitude"); sel = inds, type = Float64)
    river_2d = ncread(nc, param(config, "input.river_location"); type = Bool, fill = false)
    river = river_2d[inds]
    riverwidth_2d =
        ncread(nc, param(config, "input.lateral.river.width"); type = Float64, fill = 0)
    riverwidth = riverwidth_2d[inds]
    riverlength_2d =
        ncread(nc, param(config, "input.lateral.river.length"); type = Float64, fill = 0)
    riverlength = riverlength_2d[inds]

    # read x, y coordinates and calculate cell length [m]
    y_nc = "y" in keys(nc.dim) ? ncread(nc, "y") : ncread(nc, "lat")
    x_nc = "x" in keys(nc.dim) ? ncread(nc, "x") : ncread(nc, "lon")
    if dims_xy
        y = permutedims(repeat(y_nc, outer = (1, length(x_nc))))[inds]
    else
        y = repeat(y_nc, outer = (1, length(x_nc)))[inds]
    end
    cellength = abs(mean(diff(x_nc)))

    # Initialise parameters for the soil loss part EROS
    canopyheight = ncread(
        nc,
        param(config, "input.vertical.canopyheight", nothing);
        sel = inds,
        defaults = 3.0,
        type = Float64,
    )
    erosk = ncread(
        nc,
        param(config, "input.vertical.erosk", nothing);
        sel = inds,
        defaults = 0.6,
        type = Float64,
    )
    erosspl = ncread(
        nc,
        param(config, "input.vertical.erosspl", nothing);
        sel = inds,
        defaults = 2.0,
        type = Float64,
    )
    erosov = ncread(
        nc,
        param(config, "input.vertical.erosov", nothing);
        sel = inds,
        defaults = 0.9,
        type = Float64,
    )
    pathfrac = ncread(
        nc,
        param(config, "input.vertical.pathfrac", nothing);
        sel = inds,
        defaults = 0.01,
        type = Float64,
    )
    slope = ncread(
        nc,
        param(config, "input.vertical.slope", nothing);
        sel = inds,
        defaults = 0.01,
        type = Float64,
    )
    usleC = ncread(
        nc,
        param(config, "input.vertical.usleC", nothing);
        sel = inds,
        defaults = 0.01,
        type = Float64,
    )
    usleK = ncread(
        nc,
        param(config, "input.vertical.usleK", nothing);
        sel = inds,
        defaults = 0.1,
        type = Float64,
    )

    # if leaf area index climatology provided use sl, swood and kext to calculate cmax, e_r and canopygapfraction
    # TODO replace by something else
    if isnothing(true)
        # cmax, e_r, canopygapfraction only required when leaf area index climatology not provided
        cmax = ncread(
            nc,
            param(config, "input.vertical.cmax", nothing);
            sel = inds,
            defaults = 1.0,
            type = Float64,
        )
        e_r = ncread(
            nc,
            param(config, "input.vertical.eoverr", nothing);
            sel = inds,
            defaults = 0.1,
            type = Float64,
        )
        canopygapfraction = ncread(
            nc,
            param(config, "input.vertical.canopygapfraction", nothing);
            sel = inds,
            defaults = 0.1,
            type = Float64,
        )
        sl = fill(mv, n)
        swood = fill(mv, n)
        kext = fill(mv, n)
    else
        # TODO confirm if leaf area index climatology is present in the NetCDF
        sl = ncread(
            nc,
            param(config, "input.vertical.specific_leaf");
            sel = inds,
            type = Float64,
        )
        swood = ncread(
            nc,
            param(config, "input.vertical.storage_wood");
            sel = inds,
            type = Float64,
        )
        kext = ncread(nc, param(config, "input.vertical.kext"); sel = inds, type = Float64)
        cmax = fill(mv, n)
        e_r = fill(mv, n)
        canopygapfraction = fill(mv, n)
    end


    # these are filled in the loop below
    # TODO see if we can replace this approach
    xl = fill(mv, n)
    yl = fill(mv, n)
    riverfrac = fill(mv, n)

    for i = 1:n
        xl[i] = sizeinmetres ? cellength : lattometres(y[i])[1] * cellength
        yl[i] = sizeinmetres ? cellength : lattometres(y[i])[2] * cellength
        riverfrac[i] =
            river[i] ? min((riverlength[i] * riverwidth[i]) / (xl[i] * yl[i]), 1.0) : 0.0

    end


    eros = EROS{Float64}(
        n = n,   
        yl = yl,
        xl = xl,
        riverfrac = riverfrac,
        # Forcing
        interception = fill(mv, n),
        h_land = fill(mv, n),
        precipitation = fill(mv, n),
        q_land = fill(mv, n),
        # Parameters
        canopyheight = canopyheight,
        canopygapfraction = canopygapfraction,
        erosk = erosk,
        erosspl = erosspl,
        erosov = erosov,
        pathfrac = pathfrac,
        slope = slope,
        usleC = usleC,
        usleK = usleK,
        # Interception related to climatology (leaf_area_index)
        sl = sl,
        swood = swood,
        kext = kext,
        leaf_area_index = fill(mv, n),
        # Outputs
        sedspl = fill(mv, n),
        sedov = fill(mv, n),
        soilloss = fill(mv, n),
        
    )

    # states sediment concept
    states = ()
    # for state in statevars(sediment)
    #     states = (states...,(:vertical,state))
    # end

    inds_riv, rev_inds_riv = active_indices(river_2d, 0)
    nriv = length(inds_riv)

    # reservoirs
    pits = zeros(Bool, modelsize_2d)
    if do_reservoirs
        reservoirs, resindex, reservoir, pits = initialize_simple_reservoir(config, nc, inds_riv, nriv, pits)
        for state in statevars(reservoirs)
            states = (states...,(:lateral,:river,:reservoir,state))
        end
    else
        reservoir = ()
    end

    # lakes
    if do_lakes
        lakes, lakeindex, lake, pits = initialize_natural_lake(config, nc, inds_riv, nriv, pits)
        for state in statevars(lakes)
            states = (states...,(:lateral,:river,:lake,state))
        end
    else
        lake = ()
    end

    # # lateral part sediment in overland flow
    βₗ = ncread(nc, param(config, "input.lateral.land.slope"); sel = inds, type = Float64)
    clamp!(βₗ, 0.00001, Inf)
    ldd_2d = ncread(nc, param(config, "input.ldd"); allow_missing = true)
    ldd = ldd_2d[inds]
    dl = fill(mv, n)
    dw = fill(mv, n)

    for i = 1:n
        dl[i] = detdrainlength(ldd[i], xl[i], yl[i])
        dw[i] = detdrainwidth(ldd[i], xl[i], yl[i])
    end

    # n_land = ncread(
    #     nc,
    #     param(config, "input.lateral.land.n", nothing);
    #     sel = inds,
    #     defaults = 0.072,
    #     type = Float64,
    # )
    # ols = SurfaceSed(
        # sl = βₗ,
        # n = n_land,
        # dl = dl,
        # Δt = Float64(Δt.value),
        # width = dw,
        # wb_pit = pits[inds],
    # )
    ols = ()

    pcr_dir = dims_xy ? permute_indices(Wflow.pcrdir) : Wflow.pcrdir
    graph = flowgraph(ldd, inds, pcr_dir)

    # River processes
    riverslope = ncread(
        nc,
        param(config, "input.lateral.river.slope");
        sel = inds_riv,
        type = Float64,
    )
    clamp!(riverslope, 0.00001, Inf)
    riverlength = riverlength_2d[inds_riv]
    riverwidth = riverwidth_2d[inds_riv]

    ldd_riv = ldd_2d[inds_riv]
    graph_riv = flowgraph(ldd_riv, inds_riv, pcr_dir)

    # the indices of the river cells in the land(+river) cell vector
    index_river = filter(i -> !isequal(river[i], 0), 1:n)
    frac_toriver = Wflow.fraction_runoff_toriver(graph, ldd, index_river, βₗ, n)

    # rs = RiverSed(
        # sl = riverslope,
        # n = n_river,
        # dl = riverlength,
        # Δt = Float64(Δt.value),
        # width = riverwidth,
        # reservoir_index = do_reservoirs ? resindex : fill(0, nriv),
        # lake_index = do_lakes ? lakeindex : fill(0, nriv),
        # reservoir = do_reservoirs ? reservoirs : nothing,
        # lake = do_lakes ? lakes : nothing,
        # rivercells = river,
    # )
    rs = ()




    reader = prepare_reader(dynamic_path, cyclic_path, config)

    modelmap = (vertical = eros, lateral = (land = ols, river = rs))
    indices_reverse = (
        land = rev_inds,
        river = rev_inds_riv,
        reservoir = isempty(reservoir) ? nothing : reservoir.reverse_indices,
        lake = isempty(lake) ? nothing : lake.reverse_indices,
    )
    writer = prepare_writer(
        config,
        reader,
        output_path,
        modelmap,
        states,
        indices_reverse,
        x_nc,
        y_nc,
        dims_xy,
        nc,
    )

    # for each domain save the directed acyclic graph, the traversion order,
    # and the indices that map it back to the two dimensional grid
    land = (
        graph = graph,
        order = topological_sort_by_dfs(graph),
        indices = inds,
        reverse_indices = rev_inds,
    )
    river = (
        graph = graph_riv,
        order = topological_sort_by_dfs(graph_riv),
        indices = inds_riv,
        reverse_indices = rev_inds_riv,
    )

    model = Model(
        config,
        (; land, river, reservoir, lake, index_river, frac_toriver),
        (land = ols, river = rs),
        eros,
        Clock(config.starttime, 1, Δt),
        reader,
        writer,
    )

    # read and set states in model object if reinit=false
    if reinit  == false
        set_states(
            instate_path,
            model,
            states,
            inds,
            config;
            type = Float64
        )
    end

    # make sure the forcing is already loaded
    # it's fine to run twice, and may help catching errors earlier
    update_forcing!(model)
    if haskey(config.input, "cyclic")
        update_cyclic!(model)
    end
    return model
end

function update(model::Model{N,L,V,R,W}) where {N,L,V<:EROS,R,W}
    @unpack lateral, vertical, network, clock, config = model

    update_forcing!(model)
    if haskey(config.input, "cyclic")
        update_cyclic!(model)
    end

    update_until_ols(vertical, config)



    write_output(model, model.writer)

    # update the clock
    clock.iteration += 1
    clock.time += clock.Δt

    return model
end