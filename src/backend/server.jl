# uses: Oxygen, JSON, Dates, UUIDs, HTTP, EnergyIntegration (optional)

include("console.jl")

const hen_store = Dict{String,Tuple{EI.HeatExchangerNetwork,Float64}}()
const hen_lock = ReentrantLock()
const hen_ttl_s = 6 * 60 * 60.0
const frontend_mounted = Ref(false)
const frontend_dist_dir = Ref{Union{Nothing,String}}(nothing)

function mount_frontend!(dist_dir::AbstractString)
    frontend_mounted[] && return
    isdir(dist_dir) || throw(ArgumentError("Web UI dist directory not found: $(dist_dir)"))
    assets_dir = joinpath(dist_dir, "assets")
    isdir(assets_dir) && staticfiles(assets_dir, "assets")
    frontend_dist_dir[] = dist_dir
    frontend_mounted[] = true
    nothing
end

function frontend_file(path::AbstractString)
    dist_dir = frontend_dist_dir[]
    dist_dir === nothing && return HTTP.Response(503, "Web UI not configured.")
    file_path = joinpath(dist_dir, path)
    isfile(file_path) || return HTTP.Response(404, "Not Found")
    return file(file_path)
end

@get "/" () -> frontend_file("index.html")
@get "/vite.svg" () -> frontend_file("vite.svg")
@get "/favicon.svg" () -> frontend_file("favicon.svg")
@get "/favicon.ico" () -> frontend_file("favicon.ico")

function plot_payload_from_plot(p)
    return Dict(
        "data" => getfield(p, :data),
        "layout" => getfield(p, :layout),
        "config" => getfield(p, :config))
end

const streamsets_dir = joinpath(@__DIR__, "data", "streamsets")
mkpath(streamsets_dir)

function iso_ts()
    return Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")
end

function _purge_expired_hens!()
    now_ts = time()
    stale = String[]
    for (id, (_, touched)) in hen_store
        now_ts - touched > hen_ttl_s && push!(stale, id)
    end
    for id in stale
        delete!(hen_store, id)
    end
    nothing
end

function store_hen!(hen::EI.HeatExchangerNetwork)::String
    @lock hen_lock begin
        _purge_expired_hens!()
        id = string(uuid4())
        hen_store[id] = (hen, time())
        return id
    end
end

function get_hen(id::AbstractString)::Union{Nothing,EI.HeatExchangerNetwork}
    @lock hen_lock begin
        _purge_expired_hens!()
        entry = get(hen_store, String(id), nothing)
        entry === nothing && return nothing
        hen, _ = entry
        hen_store[String(id)] = (hen, time())
        return hen
    end
end

function hen_id_from_payload(data)::Union{Nothing,String}
    data isa AbstractDict || return nothing
    haskey(data, "hen_id") || return nothing
    return String(data["hen_id"])
end

function ei_unavailable_response()
    err = Dict(
        "code" => "ei_not_available",
        "message" => "EnergyIntegration is not available in the active project; run Julia with `--project=.` and ensure dependencies are instantiated.",
        "active_project" => Base.active_project(),
        "find_package" => Base.find_package("EnergyIntegration"),
        "load_error" => ei_load_error[])
    return Dict("ok" => false, "error" => err, "ts" => iso_ts())
end

function no_hen_response()
    return Dict(
        "ok" => false,
        "error" => Dict(
            "code" => "no_hen",
            "message" => "No built HEN in server memory. Click Build HEN first."),
        "ts" => iso_ts())
end

function missing_hen_id_response()
    return Dict(
        "ok" => false,
        "error" => Dict(
            "code" => "hen_id_required",
            "message" => "hen_id is required for this request."),
        "ts" => iso_ts())
end

function is_safe_id(id::AbstractString)
    if isempty(id)
        return false
    end
    for c in id
        if !(('0' <= c <= '9') || ('a' <= c <= 'z') || ('A' <= c <= 'Z') || c == '-')
            return false
        end
    end
    return true
end

function streamset_path(id::AbstractString)
    return joinpath(streamsets_dir, "$(String(id)).json")
end

function write_json_atomic(path::String, obj)
    tmp = path * ".tmp"
    open(tmp, "w") do io
        JSON.print(io, obj)
    end
    mv(tmp, path; force=true)
end

function query_param(req, key::String)
    target = String(getproperty(req, :target))
    parts = split(target, "?", limit=2)
    if length(parts) < 2
        return
    end
    for pair in split(parts[2], "&")
        kv = split(pair, "=", limit=2)
        if length(kv) == 2 && kv[1] == key
            return kv[2]
        end
    end
    nothing
end

@get "/api/ping" () -> Dict("ok" => true, "ts" => iso_ts())

@post "/api/echo" req -> JSON.parse(String(req.body)) # 原样回传 JSON

function scalar_spec_from_payload(x, role::Symbol)
    if x isa Number
        v = Float64(x)
        return ScalarSpec(v, v; role=role)
    elseif x isa AbstractVector && length(x) == 2
        lo = Float64(x[1])
        hi = Float64(x[2])
        return ScalarSpec(lo, hi; role=role)
    else
        throw(ArgumentError("Invalid ScalarSpec payload for role=$role: $(typeof(x))"))
    end
end

function pricing_basis_from_payload(x)
    s = String(x)
    s == "Energy" ? Energy :
    s == "Power"  ? Flowrate :
    throw(ArgumentError("Invalid pricing_basis payload: $x"))
end

function streams_from_payload(data)
    streams = data["streams"]
    out = Vector{EIStream}(undef, length(streams))
    for (i, s) in pairs(streams)
        name = Symbol(String(s["name"]))
        thermal::ThermalKind = s["thermal"]
        kind::StreamKind = s["kind"]

        F    = scalar_spec_from_payload(s["F"], :flow)
        Tin  = scalar_spec_from_payload(s["Tin"], :temperature)
        Tout = scalar_spec_from_payload(s["Tout"], :temperature)

        Pin_raw = haskey(s, "Pin") ? s["Pin"] : nothing
        Pout_raw = haskey(s, "Pout") ? s["Pout"] : nothing
        Pin = (Pin_raw === nothing) ? scalar_spec_from_payload(NaN, :pressure) : scalar_spec_from_payload(Pin_raw, :pressure)
        Pout = (Pout_raw === nothing) ? scalar_spec_from_payload(NaN, :pressure) : scalar_spec_from_payload(Pout_raw, :pressure)

        frac = Float64.(s["frac"])
        h = s["Hcoeff"]
        Hcoeff = ntuple(j -> Float64(h[j]), Val(6))

        pricing_basis = pricing_basis_from_payload(s["pricing_basis"])

        out[i] = EIStream(name;
            thermal=thermal,
            kind=kind,
            F=F,
            Tin=Tin,
            Tout=Tout,
            Pin=Pin,
            Pout=Pout,
            frac=frac,
            Hcoeff=Hcoeff,
            Hvap=Float64(s["Hvap"]),
            HTC=Float64(s["HTC"]),
            Tcont=Float64(s["Tcont"]),
            cost=Float64(s["cost"]),
            pricing_basis=pricing_basis,
            min_TD=Float64(s["min_TD"]),
            superheating_deg=Float64(s["superheating_deg"]),
            subcooling_deg=Float64(s["subcooling_deg"]),
        )
    end
    return out
end

function intervals_config_from_payload(cfg)
    cfg isa AbstractDict || throw(ArgumentError("intervals_config must be an object"))

    node_rule = haskey(cfg, "node_rule") ? cfg["node_rule"] : "inout"
    T_interval_method = haskey(cfg, "T_interval_method") ? cfg["T_interval_method"] : "default"
    T_nodes_specified = haskey(cfg, "T_nodes_specified") ? collect(Float64, cfg["T_nodes_specified"]) : Float64[]
    maxDeltaT = haskey(cfg, "maxDeltaT") ? Float64(cfg["maxDeltaT"]) : 0.0
    maxnumT = haskey(cfg, "maxnumT") ? Int(cfg["maxnumT"]) : 0
    use_clapeyron = haskey(cfg, "use_clapeyron") ? Bool(cfg["use_clapeyron"]) : false

    mvr_raw = haskey(cfg, "mvr_config") ? cfg["mvr_config"] : Dict{String,Any}()
    mvr_method = haskey(mvr_raw, "method") ? mvr_raw["method"] : "piecewise"
    mvr_mode = haskey(mvr_raw, "mode") ? Symbol(String(mvr_raw["mode"])) : :polytropic
    step_ratio = haskey(mvr_raw, "step_ratio") ? Float64(mvr_raw["step_ratio"]) : 0.007
    isentropic_efficiency = haskey(mvr_raw, "isentropic_efficiency") ? Float64(mvr_raw["isentropic_efficiency"]) : 0.72
    polytropic_efficiency = haskey(mvr_raw, "polytropic_efficiency") ? Float64(mvr_raw["polytropic_efficiency"]) : 0.75
    mechanical_efficiency = haskey(mvr_raw, "mechanical_efficiency") ? Float64(mvr_raw["mechanical_efficiency"]) : 0.97
    mvr_config = MVRConfig(;
        method=mvr_method,
        mode=mvr_mode,
        step_ratio=step_ratio,
        isentropic_efficiency=isentropic_efficiency,
        polytropic_efficiency=polytropic_efficiency,
        mechanical_efficiency=mechanical_efficiency,
    )

    forbidden_match = Dict{Tuple{Symbol,Symbol},Tuple{Float64,Float64}}()
    if haskey(cfg, "forbidden_match") && (cfg["forbidden_match"] isa AbstractVector)
        for row in cfg["forbidden_match"]
            row isa AbstractDict || continue
            hot = haskey(row, "hot") ? String(row["hot"]) : ""
            cold = haskey(row, "cold") ? String(row["cold"]) : ""
            isempty(hot) && continue
            isempty(cold) && continue
            Q_lb = haskey(row, "Q_lb") ? Float64(row["Q_lb"]) : 0.0
            Q_ub = haskey(row, "Q_ub") ? Float64(row["Q_ub"]) : 0.0
            forbidden_match[(Symbol(hot), Symbol(cold))] = (Q_lb, Q_ub)
        end
    end

    return IntervalsConfig(;
        forbidden_match=forbidden_match,
        node_rule=node_rule,
        T_interval_method=T_interval_method,
        T_nodes_specified=T_nodes_specified,
        maxΔT=maxDeltaT,
        maxnumT=maxnumT,
        mvr_config=mvr_config,
        use_clapeyron=use_clapeyron,
    )
end

@post "/api/streams" (req) -> begin
    try
        ei_available[] || return ei_unavailable_response()
        data = JSON.parse(String(req.body))
        streams = streams_from_payload(data)
        intervals_cfg = haskey(data, "intervals_config") ? intervals_config_from_payload(data["intervals_config"]) : IntervalsConfig()
        hen = EI.build_hen(streams; config=intervals_cfg)
        hen_id = store_hen!(hen)
        EI.clog(:webapp, 0, "Built HEN with ", length(streams), " stream(s).")
        plot_payload = nothing
        plot_error = nothing
        try
            p = EI.plot_composite_curve(hen.composite)
            plot_payload = plot_payload_from_plot(p)
            layout = plot_payload["layout"]
            @assert layout isa AbstractDict
            haskey(layout, :width) && delete!(layout, :width)
            haskey(layout, :height) && delete!(layout, :height)
            layout[:autosize] = true

            cfg = plot_payload["config"]
            @assert cfg isa AbstractDict
            cfg[:responsive] = true
            cfg[:displaylogo] = false
        catch e
            plot_error = sprint(showerror, e)
        end
        names = [String(s.name) for s in streams]
        n_nodes = length(hen.T_nodes)
        T_first = n_nodes > 0 ? hen.T_nodes[1] : NaN
        T_last = n_nodes > 0 ? hen.T_nodes[end] : NaN
        return Dict(
            "ok" => true,
            "hen_id" => hen_id,
            "n_streams" => length(streams),
            "names" => names,
            "hen" => Dict(
                "summary" => string(hen),
                "n_T_nodes" => n_nodes,
                "T_first" => T_first,
                "T_last" => T_last,
            ),
            "plot" => plot_payload,
            "plot_error" => plot_error,
            "ts" => iso_ts(),
        )
    catch e
        return Dict("ok" => false, "error" => Dict("message" => sprint(showerror, e)), "ts" => iso_ts())
    end
end

@post "/api/solve" (req) -> begin
    try
        ei_available[] || return ei_unavailable_response()

        body_str = String(req.body)
        payload = nothing
        isempty(strip(body_str)) || (payload = JSON.parse(body_str))
        hen_id = payload === nothing ? nothing : hen_id_from_payload(payload)
        hen_id === nothing && (hen_id = query_param(req, "hen_id"))
        hen_id === nothing && return missing_hen_id_response()
        prob = get_hen(hen_id)
        prob === nothing && return no_hen_response()
        cb = (cbtype::Cint, msg::Ptr{Cchar}, _) -> begin
            if cbtype == HiGHS.kHighsCallbackLogging || cbtype == HiGHS.kHighsCallbackMipLogging
                msg == C_NULL || EI.clog(:opti, unsafe_string(msg))
            end
            return Cint(0)
        end
        model_hook = (model) -> begin
            opt = JuMP.backend(model)
            JuMP.MOI.set(opt, HiGHS.CallbackFunction(Cint[
                    HiGHS.kHighsCallbackLogging,
                    HiGHS.kHighsCallbackMipLogging,
                ]), cb)
            nothing
        end
        hen_model = EI.solve_transp!(prob, HiGHS.Optimizer; model_hook)
        EI.load_solution!(prob, hen_model)

        data, rows, cols = EI._materialize(prob.result.edges)
        hot_names = String.(rows)
        cold_names = String.(cols)
        edges = Any[]
        for i in axes(data, 1), j in axes(data, 2)
            q_total = data[i, j]
            q_total == 0 && continue
            hot = rows[i]
            cold = cols[j]
            push!(edges, Dict(
                "hot" => String(hot),
                "cold" => String(cold),
                "q_total" => q_total,
            ))
        end

        return Dict(
            "ok" => true,
            "hen_id" => hen_id,
            "obj_value" => prob.result.obj_value,
            "hot_names" => hot_names,
            "cold_names" => cold_names,
            "edges" => edges,
            "solution_report" => prob.result.solution_report,
            "economic_report" => prob.result.economic_report,
            "ts" => iso_ts(),
        )
    catch e
        return Dict("ok" => false, "error" => Dict("message" => sprint(showerror, e)), "ts" => iso_ts())
    end
end

@get "/api/results/match" (req) -> begin
    try
        ei_available[] || return ei_unavailable_response()
        hen_id = query_param(req, "hen_id")
        hen_id === nothing && return missing_hen_id_response()
        prob = get_hen(hen_id)
        prob === nothing && return no_hen_response()

        hot_raw = query_param(req, "hot")
        cold_raw = query_param(req, "cold")
        if hot_raw === nothing || cold_raw === nothing
            return Dict(
                "ok" => false,
                "error" => Dict("code" => "bad_request", "message" => "hot and cold are required"),
                "ts" => iso_ts(),
            )
        end

        hot = Symbol(HTTP.URIs.unescapeuri(String(hot_raw)))
        cold = Symbol(HTTP.URIs.unescapeuri(String(cold_raw)))
        match = try
            prob.result.edges[hot, cold]
        catch
            return Dict(
                "ok" => false,
                "error" => Dict("code" => "not_found", "message" => "match not found"),
                "ts" => iso_ts(),
            )
        end

        data, rows, cols = EI._materialize(match.q)
        return Dict(
            "ok" => true,
            "hen_id" => hen_id,
            "hot" => string(hot),
            "cold" => string(cold),
            "rows" => string.(rows),
            "cols" => string.(cols),
            "q" => collect(eachrow(data)),
            "ts" => iso_ts(),
        )
    catch e
        return Dict("ok" => false, "error" => Dict("message" => sprint(showerror, e)), "ts" => iso_ts())
    end
end

@get "/api/results/stream" req -> begin
    try
        ei_available[] || return ei_unavailable_response()
        hen_id = query_param(req, "hen_id")
        hen_id === nothing && return missing_hen_id_response()
        prob = get_hen(hen_id)
        prob === nothing && return no_hen_response()

        name_raw = query_param(req, "name")
        if name_raw === nothing
            return Dict(
                "ok" => false,
                "error" => Dict("code" => "bad_request", "message" => "name is required"),
                "ts" => iso_ts(),
            )
        end

        name = Symbol(HTTP.URIs.unescapeuri(String(name_raw)))
        unit_raw = query_param(req, "unit")
        if unit_raw === nothing
            return Dict(
                "ok" => false,
                "error" => Dict("code" => "bad_request", "message" => "unit is required"),
                "ts" => iso_ts(),
            )
        end
        unit_label = String(HTTP.URIs.unescapeuri(String(unit_raw)))
        unit_parse = unit_label == "°R" ? "Ra" : unit_label
        unit = try
            EI.uparse(unit_parse)
        catch
            return Dict(
                "ok" => false,
                "error" => Dict("code" => "bad_request", "message" => "invalid unit"),
                "ts" => iso_ts(),
            )
        end
        q_str, describes, t_upper, t_lower = EI.show_result(prob, name; unit=unit, verbose=false)
        return Dict(
            "ok" => true,
            "hen_id" => hen_id,
            "name" => string(name),
            "unit" => unit_label,
            "q_str" => q_str,
            "describes" => describes,
            "t_upper" => t_upper,
            "t_lower" => t_lower,
            "ts" => iso_ts(),
        )
    catch e
        return Dict("ok" => false, "error" => Dict("message" => sprint(showerror, e)), "ts" => iso_ts())
    end
end

@post "/api/streamsets" (req) -> begin
    try
        data = JSON.parse(String(req.body))
        id = string(uuid4())
        name = haskey(data, "name") ? String(data["name"]) : id
        schema_version = haskey(data, "schema_version") ? String(data["schema_version"]) : "unknown"
        streams = haskey(data, "streams") ? data["streams"] : Any[]
        intervals_config = haskey(data, "intervals_config") ? data["intervals_config"] : nothing

        saved = Dict(
            "id" => id,
            "name" => name,
            "schema_version" => schema_version,
            "saved_at" => iso_ts(),
            "streams" => streams,
            "intervals_config" => intervals_config,
        )
        write_json_atomic(streamset_path(id), saved)
        return Dict("ok" => true, "id" => id, "name" => name, "saved_at" => saved["saved_at"])
    catch e
        return Dict("ok" => false, "error" => Dict("message" => sprint(showerror, e)), "ts" => iso_ts())
    end
end
