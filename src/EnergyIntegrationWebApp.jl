module EnergyIntegrationWebApp
using Oxygen, JSON, Dates, UUIDs, HTTP, HiGHS, Artifacts, LazyArtifacts
@oxidize
export serve_webapp

const ei_available = Ref(false)
const ei_load_error = Ref{Union{Nothing,String}}(nothing)
try
    import EnergyIntegration as EI
    using EnergyIntegration: JuMP, EIStream, IntervalsConfig, MVRConfig, ScalarSpec, ThermalKind, StreamKind, Energy, Flowrate
    ei_available[] = true
catch e
    ei_available[] = false
    ei_load_error[] = sprint(showerror, e)
end

include("backend/server.jl")

const webapp_artifact = "webapp_dist"
const webapp_dist_env = "EIWEBAPP_DIST"

function resolve_dist_dir(dist_dir::Union{Nothing,AbstractString}=nothing)::String
    if dist_dir !== nothing
        dir = String(dist_dir)
    elseif haskey(ENV, webapp_dist_env) && !isempty(ENV[webapp_dist_env])
        dir = ENV[webapp_dist_env]
    else
        try
            dir = artifact"webapp_dist"
        catch e
            msg = "Web UI artifact not available. Set ENV[\"$(webapp_dist_env)\"] to a built dist directory or install the artifact."
            throw(ArgumentError(msg * " (cause: " * sprint(showerror, e) * ")"))
        end
    end
    isdir(dir) || throw(ArgumentError("Web UI dist directory not found: $(dir)"))
    return dir
end

const console_lifecycle = Oxygen.LifecycleMiddleware(;
    middleware=identity,
    on_startup=() -> begin
        console_set_shutdown!(false)
        console_reset!()
        if ei_available[]
            try
                EI.clog(:webapp, 0, "Console tee enabled.")
            catch e
                console_log("Console tee init failed: " * sprint(showerror, e))
            end
        end
        nothing
    end,
    on_shutdown=() -> begin
        console_set_shutdown!(true)
        console_close_all_streams!()
        nothing
    end,
)

function serve_webapp(;
    host::AbstractString  = "127.0.0.1",
    port::Integer         = 8001,
    docs::Bool            = true,
    metrics::Bool         = true,
    redirect_stdout::Bool = false,
    async::Bool           = false,
    static::Bool          = true,
    dist_dir::Union{Nothing,AbstractString} = nothing,
)
    redirect_stdout && start_stdout_redirect()
    if static
        mount_frontend!(resolve_dist_dir(dist_dir))
    end
    serve(; host, port, docs, metrics, async, middleware=[console_lifecycle])
end

function __init__()
    console_tee[] = TeeIO(stderr, console_io)
    if ei_available[]
        try
            EI.set_sink!(console_tee[])
        catch e
            console_log("Console tee init failed: " * sprint(showerror, e))
        end
    end
    nothing
end

end
