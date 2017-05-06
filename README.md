# MicroLogging

[![Build Status](https://travis-ci.org/c42f/MicroLogging.jl.svg?branch=master)](https://travis-ci.org/c42f/MicroLogging.jl)

[![codecov.io](http://codecov.io/github/c42f/MicroLogging.jl/coverage.svg?branch=master)](http://codecov.io/github/c42f/MicroLogging.jl?branch=master)

MicroLogging is a prototype for a new logging interface for `Base` in julia-0.7.
For design discussion see the Julep -
https://github.com/JuliaLang/Juleps/pull/30/files

Logging should be useful and pleasant for the average package developer, but
should meet the efficiency and flexibility demands of production deployment.
`MicroLogging` sets out to achieve both of these things in one interface.

## Quickstart

```julia
module LogTest
using MicroLogging
function f(x)
    @debug "a LogTest module debug message $x"
    @info  "a LogTest module info message $x"
    @warn  "a LogTest module warning message $x"
    @error "a LogTest module error message $x"
end
end

using MicroLogging
using Compat
using Base.Markdown

@info md"# Simple logging"
@info "Default level is info"
@debug "I am an invisible debug message"

@info """
A big
log
message
in a
multiline
string
"""

@info "Non-strings are converted to strings"
@info reshape(1:16, (4,4))

@info md"# Early filtering of logs per module, for efficiency"

limit_logging(LogTest, MicroLogging.Warn)
@info "Logging at Warn for LogTest module"
LogTest.f(1)

@info "Set all loggers to Debug level"
limit_logging(MicroLogging.Debug)
LogTest.f(2)


@info md"# Log suppression with `once` and `max_log`"
for i=1:20
    if i > 7
        @error "i=$i out of bounds (set once=true)" once=true
        @warn "i=$i out of bounds (set max_log=2)" max_log=2
        continue
    end
    @info "The value of (1+i) is $(1+i)"
end


@info md"# Simple progress logging"
for i=1:100
    sleep(0.01)
    i%40 != 0 || @warn "foo"
    @info "algorithm1" progress=i/100
end

@debug "Progress logging also at debug (or any) log level"
for i=1:100
    sleep(0.01)
    @debug "algorithm2" progress=i/100
end


@info md"# Redirect logging to an IO stream"
logstream = IOBuffer()
with_logger(SimpleLogger(logstream, false)) do
    @info "Logging redirected"
    LogTest.f(3)
end

@info "Now directed back to stderr"
@info """
Contents of redirected IO stream buffer:
................................
$(strip(String(take!(logstream))))
................................
"""

@info md"# Exception reporting, with backtrace"
try
    1÷0
catch err
    @error err
end
```

The script above produces console output like the following.  Note the
unconventional choice of metadata placement.  In interactive mode,
`MicroLogging` tries to put this out of your way as much as possible, by
placing it on the right hand of the terminal.  The premise here is that you
want to see your log message, not some metadata.

![Micrologging example screenshot](doc/micrologging_example.png)


## MicroLogging implementation choices

### Early filtering

The filtering of log messages should cheap enough that users feel free to leave
them available rather than commenting them out or otherwise disabling them at
compile time. The only way to achieve this is to filter early, before the
entire log message and other log record metadata is fully determined. Thus, we
have the following design challenge:

> Allow early filtering of log records *before* the record is fully constructed.

In most logging libraries, a basic level of filtering is achieved based on an
ordered **log level** which represents a verbosity/severity (debug, info,
warning, error, etc).  Messages more verbose than the currently minimum level
are filtered out.  This seems simple, effective and efficient as a first pass
filter. Naturally, further filtering may also occur based on the log message or
other log record metadata.

*TODO*: can we generalize early filtering (eg, allow package-defined log
levels) without loosing efficiency?

In `MicroLogging`, early filtering can be controlled on a per-module basis
using the `limit_logging` function:

```julia
limit_logging(MyModule, MicroLogging.Info)
```

### Logging macros

Efficiency seems to dictate that some filtering decision is done *before* any
logging-specific user code is run. This implies either a logging macro to insert
an early test and branch, or that the log record creation is passed as a
closure. We'd also like to gather information from lexical scope, and to look
up/create the logger for the current module at compile time.

These considerations indicate that a macro be used, which also has the nice side
effect of being visually simple:

```julia
x = 42
@info "my value is x = $x"
```

To achieve early filtering, this example currently expands to something like

```julia
mod_log_ctx = $(get_logger(current_module()))
if shouldlog(mod_log_ctx, Info)
    logmsg(current_logger(), Info, "my value is x = $x", #=...=#)
end
```

### Logging context and dispatch

Every log record has various types of context which can be associated with it.
Some types of context include:

* static **lexical context** - based on the location in the code - local
    variables, line number, file, function, module.
* dynamic **caller context** - the current stack trace, and data visible in
    it. Consider, for example, the context which can be passed with the
    femtolisp `with-bindings` construct.
* dynamic **data context** - context created from data structures available at
    log record creation.

Log context can be used in two ways.  First, to dispatch the log record to
appropriate handler *code*.  Second, to enrich the log record with *data* about
the state of the program.

> Which code processes a log message after it is created?

Here we've got to choose between lexical vs dynamic scope to look up the log
handler code.  MicroLogging chooses a *dynamically scoped* log handler bound to
the current task.  To understand why this might be good choice, consider the two
audiences of a logging library:

* *Package authors* want to emit logs in a simple way, without caring about how
  they're dispatched.
* *Application programmers* care about a complete application as built up from
  many packages.  They need to control how log records are dispatched, but don't
  get any control over how they're created.

Application programmers tend to be calling functions from many different
packages to achieve an overall task. With dynamic scoping for log handlers, it's
easy to control log dispatch based on task.

```julia
logger = MyLogger(#= ... =#)

with_logger(logger) do
    Package1.foo()
    Package2.bar()
    Package2.baz()
end
```

Notably, this approach works no matter how deeply nested the call tree becomes
within the various functions called by `Package1.foo()`, without any thought by
the author of any of the packages in use.

Most logging libraries seem to look up the log handler in lexical scope, which
implies a global entry point for log dispatch.  For example, the python
community seems to have settled on using
[per-module contexts](https://docs.python.org/3/library/logging.html#logger-objects)
to dispatch log messages (TODO: double check how this works).

TODO: Need more research about the tradeoff between thread-global lexically
scoped loggers vs dynamically scoped loggers.  For example, Log4j 2 attacks this
problem by adding thread context to log records via the
["fish tagging"](https://logging.apache.org/log4j/2.x/manual/thread-context.html)
approach.

> Which metadata is automatically included with the log record?

*TODO*

### Efficiency - messages you never see should cost almost nothing

The following should be fast

```julia
@debug begin
    A = #=Long, complex calculation=#
    "det(A) = $(det(A))"
end
```

... *FIXME* more to write here

