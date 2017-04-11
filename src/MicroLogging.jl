__precompile__()

module MicroLogging

export Logger,
    @debug, @info, @warn, @error,
    with_logger, get_logger, configure_logging


include("handlers.jl")

"""
Severity/verbosity of a log record.

The log level provides a key against which log records may be filtered before
any work is done formatting the log message and other metadata.
"""
@enum LogLevel Debug Info Warn Error


#-------------------------------------------------------------------------------
type Logger
    min_level::LogLevel
    children::Vector
end

Logger(parent::Logger) =
    Logger(parent.min_level, Vector{Any}())

Logger(level::LogLevel) = Logger(level, Vector{Any}())

Base.push!(parent::Logger, child) = push!(parent.children, child)

"""
    shouldlog(logger, level)

Determine whether messages of severity `level` should be sent to `logger`.
"""
shouldlog(logger::Logger, level) = logger.min_level <= level


#-------------------------------------------------------------------------------
# Logging macros

function match_log_macro_exprs(exs, module_, macroname)
    # Match key,value pairs
    args = Any[]
    kwargs = Any[]
    for ex in exs
        if isa(ex,Expr) && ex.head == :(=)
            isa(ex.args[1], Symbol) || throw(ArgumentError("Expected key value pair, got $ex"))
            push!(kwargs, Expr(:kw, ex.args[1], esc(ex.args[2])))
        else
            push!(args, ex)
        end
    end
    if length(args) == 1
        logger = get_logger(module_)
        msg = esc(args[1])
    else
        error("@$macroname must be called with one positional argument (the log message)")
    end
    logger, msg, kwargs
end

for (macroname, level) in [(:debug, Debug),
                           (:info,  Info),
                           (:warn,  Warn),
                           (:error, Error)]
    @eval macro $macroname(exs...)
        mod = current_module()
        logger, msg, kwargs = match_log_macro_exprs(exs, mod, $(Expr(:quote, macroname)))
        # FIXME: The following dubious hack gives an approximate line number
        # only - the line of the start of the toplevel expression! See #1.
        lineno = Int(unsafe_load(cglobal(:jl_lineno, Cint)))
        id = Expr(:quote, gensym())
        quote
            logger = $logger
            if shouldlog(logger, $($level))
                handlelog(log_handler(), $($level), $msg;
                    id=$id, module_=$mod, location=(@__FILE__, $lineno),
                    $(kwargs...))
            end
            nothing
        end
    end
end


#-------------------------------------------------------------------------------
# Registry of module loggers
const _registered_loggers = Dict{Module,Any}()
_global_handler = nothing

function __init__()
    _registered_loggers[Main] = Logger(Info)
    global _global_handler = LogHandler(STDERR)
end


"""
    get_logger(context)

Get the logger which should be used to dispatch messages for `context`.

When `context` is a module, the global logger instance for the module will be
returned; if this doesn't yet exist, it will be created and added to a logger
heirarchy with parent equal to `parent_module(context)`.
"""
function get_logger(mod::Module=Main)
    get!(_registered_loggers, mod) do
        parent = get_logger(module_parent(mod))
        logger = Logger(parent)
        push!(parent, logger)
        logger
    end
end

#-------------------------------------------------------------------------------
# Log system config
"""
    configure_logging([module|logger]; level=l)

Configure logging system
"""
function configure_logging(logger; level=nothing)
    level   === nothing || (logger.min_level = level;)

    for child in logger.children
        configure_logging(child; level=level)
    end
end

configure_logging(mod::Module=Main; kwargs...) = configure_logging(get_logger(mod); kwargs...)

with_logger(f::Function, loghandler) = task_local_storage(f, :LOG_HANDLER, loghandler)
log_handler() = get(task_local_storage(), :LOG_HANDLER, _global_handler)


end

