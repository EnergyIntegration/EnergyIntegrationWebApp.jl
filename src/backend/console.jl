# uses: Dates, HTTP, Oxygen

@kwdef mutable struct ConsoleState
    lock::ReentrantLock = ReentrantLock()
    max_lines::Int = 2000
    lines::Vector{Tuple{Int,String}} = Tuple{Int,String}[] # (seq, line)
    next_seq::Int = 1
    tail::String = ""
end

function console_snapshot(state::ConsoleState)::Vector{Tuple{Int,String}}
    @lock state.lock copy(state.lines)
end

function _push_lines!(state::ConsoleState, raw::String)
    @lock state.lock begin
        data = isempty(state.tail) ? raw : (state.tail * raw)
        parts = split(data, '\n'; keepempty=true)
        state.tail = parts[end]
        for line in parts[1:end-1]
            isempty(line) && continue
            seq = state.next_seq
            state.next_seq += 1
            push!(state.lines, (seq, line))
        end
        overflow = length(state.lines) - state.max_lines
        if overflow > 0
            deleteat!(state.lines, 1:overflow)
        end
    end
    nothing
end

struct ConsoleIO <: IO
    state::ConsoleState
end

Base.isopen(::ConsoleIO) = true

function Base.write(io::ConsoleIO, bytes::Vector{UInt8})
    _push_lines!(io.state, String(copy(bytes)))
    length(bytes)
end

function Base.unsafe_write(io::ConsoleIO, p::Ptr{UInt8}, n::UInt)
    bytes = unsafe_wrap(Vector{UInt8}, p, Int(n); own=false)
    _push_lines!(io.state, String(copy(bytes)))
    return n
end

Base.flush(io::ConsoleIO) = nothing
Base.close(io::ConsoleIO) = nothing

struct TeeIO <: IO
    io1::IO
    io2::IO
end

Base.isopen(io::TeeIO) = isopen(io.io1) && isopen(io.io2)

function Base.write(io::TeeIO, bytes::Vector{UInt8})
    write(io.io1, bytes)
    write(io.io2, bytes)
    length(bytes)
end

function Base.unsafe_write(io::TeeIO, p::Ptr{UInt8}, n::UInt)
    Base.unsafe_write(io.io1, p, n)
    Base.unsafe_write(io.io2, p, n)
    return n
end

Base.flush(io::TeeIO) = (flush(io.io1); flush(io.io2); nothing)
Base.close(io::TeeIO) = nothing

const console_state = ConsoleState()
const console_io = ConsoleIO(console_state)
const console_tee = Ref{TeeIO}(TeeIO(stderr, console_io))
const console_shutdown = Base.Threads.Atomic{Bool}(false)
const console_stream_lock = ReentrantLock()
const console_streams = IdDict{HTTP.Stream,Nothing}()

function start_stdout_redirect()
    pipe = redirect_stdout()
    @async try
        while !eof(pipe)
            bytes = readavailable(pipe)
            if isempty(bytes)
                sleep(0.01)
                continue
            end
            write(console_tee[], bytes)
        end
    catch
    end
    nothing
end

function console_set_shutdown!(flag::Bool)
    console_shutdown[] = flag
    nothing
end

function _register_console_stream!(stream::HTTP.Stream)
    @lock console_stream_lock console_streams[stream] = nothing
    nothing
end

function _unregister_console_stream!(stream::HTTP.Stream)
    @lock console_stream_lock delete!(console_streams, stream)
    nothing
end

function console_close_all_streams!()
    streams = @lock console_stream_lock collect(keys(console_streams))
    for s in streams
        try
            closewrite(s)
        catch
        end
        try
            close(s)
        catch
        end
    end
    nothing
end

function console_reset!(state::ConsoleState=console_state)
    @lock state.lock begin
        empty!(state.lines)
        state.next_seq = 1
        state.tail = ""
    end
    nothing
end

function console_log(state::ConsoleState, line::AbstractString)
    _push_lines!(state, String(line) * "\n")
    nothing
end

console_log(line::AbstractString) = console_log(console_state, line)

console_ts() = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")

@get "/api/console" () -> begin
    lines = [Dict("seq" => seq, "line" => line) for (seq, line) in console_snapshot(console_state)]
    return Dict("ok" => true, "lines" => lines, "ts" => console_ts())
end

@stream "/api/console/stream" (stream::HTTP.Stream) -> begin
    HTTP.setheader(stream, "Access-Control-Allow-Origin" => "*")
    HTTP.setheader(stream, "Access-Control-Allow-Methods" => "GET")
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.setheader(stream, "Connection" => "keep-alive")
    HTTP.setheader(stream, "X-Accel-Buffering" => "no")

    startwrite(stream)
    _register_console_stream!(stream)

    write(stream, ": connected\n\n")
    flush(stream)

    snap0 = console_snapshot(console_state)
    for (seq, line) in snap0
        write(stream, Oxygen.format_sse_message(line; id=string(seq)))
    end
    flush(stream)

    try
        last_seq = isempty(snap0) ? 0 : snap0[end][1]
        last_ping_s = time()
        while true
            console_shutdown[] && break
            snap = console_snapshot(console_state)
            new_items = Tuple{Int,String}[]
            for item in snap
                item[1] > last_seq && push!(new_items, item)
            end

            if !isempty(new_items)
                for (seq, line) in new_items
                    write(stream, Oxygen.format_sse_message(line; id=string(seq)))
                    last_seq = seq
                end
                flush(stream)
                last_ping_s = time()
            elseif time() - last_ping_s > 2
                write(stream, ": keepalive\n\n")
                flush(stream)
                last_ping_s = time()
            end

            sleep(0.25)
        end
    catch
    # client disconnected or server shutting down
    finally
        _unregister_console_stream!(stream)
        closewrite(stream)
    end
    nothing
end
