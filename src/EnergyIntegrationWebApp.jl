module EnergyIntegrationWebApp
using Oxygen, JSON, Dates, UUIDs, HTTP, HiGHS
@oxidize
export serve_webapp

const EI_AVAILABLE = Ref(false)
const EI_LOAD_ERROR = Ref{Union{Nothing,String}}(nothing)
try
    import EnergyIntegration as EI
    using EnergyIntegration: JuMP, EIStream, IntervalsConfig, MVRConfig, ScalarSpec, ThermalKind, StreamKind, Energy, Flowrate
    EI_AVAILABLE[] = true
catch e
    EI_AVAILABLE[] = false
    EI_LOAD_ERROR[] = sprint(showerror, e)
end

include("backend/server.jl")

const CONSOLE_LIFECYCLE = Oxygen.LifecycleMiddleware(;
    middleware=identity,
    on_startup=() -> begin
        console_set_shutdown!(false)
        console_reset!()
        if EI_AVAILABLE[]
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
)
    redirect_stdout && start_stdout_redirect()
    serve(; host, port, docs, metrics, async, middleware=[CONSOLE_LIFECYCLE])
end

function __init__()
    CONSOLE_TEE[] = TeeIO(stderr, CONSOLE_IO)
    if EI_AVAILABLE[]
        try
            EI.set_sink!(CONSOLE_TEE[])
        catch e
            console_log("Console tee init failed: " * sprint(showerror, e))
        end
    end
    nothing
end

end
