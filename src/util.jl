
# Utility function - find all accesses to variables inside `exs` which are not
# bound there.
#
# As this works with the surface syntax, it unfortunately has to reproduce some
# of the lowering logic.
function find_var_uses(exs...)
    # Bindings which are accessed inside `exs`
    vars = Symbol[]
    # Bindings which are created inside `exs`
    for ex in exs
        bound_vars = Symbol[]
        find_var_uses!(vars, bound_vars, macroexpand(ex))
    end
    vars
end

function find_var_uses!(varlist, bound_vars, ex)
    if isa(ex, Symbol)
        if !(ex in bound_vars)
            ex ∈ varlist || push!(varlist, ex)
        end
        return varlist
    elseif isa(ex, Expr)
        if ex.head == :quote || ex.head == :line
            return varlist
        end
        if ex.head == :(=)
            find_var_uses_lhs!(varlist, bound_vars, ex.args[1])
            find_var_uses!(varlist, bound_vars, ex.args[2])
        elseif ex.head == :kw
            find_var_uses!(varlist, bound_vars, ex.args[2])
        elseif ex.head == :for || ex.head == :while || ex.head == :comprehension || ex.head == :let
            # New scopes
            inner_bindings = copy(bound_vars)
            find_var_uses!(varlist, inner_bindings, ex.args)
        elseif ex.head == :try
            # New scope + ex.args[2] is a new binding
            find_var_uses!(varlist, copy(bound_vars), ex.args[1])
            catch_bindings = copy(bound_vars)
            !isa(ex.args[2], Symbol) || push!(catch_bindings, ex.args[2])
            find_var_uses!(varlist,catch_bindings,ex.args[3])
            if length(ex.args) > 3
                finally_bindings = copy(bound_vars)
                find_var_uses!(varlist,finally_bindings,ex.args[4])
            end
        elseif ex.head == :call
            find_var_uses!(varlist, bound_vars, ex.args[2:end])
        elseif ex.head == :local
            foreach(ex.args) do e
                if !isa(e, Symbol)
                    find_var_uses!(varlist, bound_vars, e)
                end
            end
        else
            find_var_uses!(varlist, bound_vars, ex.args)
        end
    end
    varlist
end

find_var_uses!(varlist, bound_vars, exs::Vector) = foreach(e->find_var_uses!(varlist, bound_vars, e), exs)

# Find variable uses on the left hand side of an assignment.  Some of what may
# be variable uses turn into bindings in this context (cf. tuple unpacking).
function find_var_uses_lhs!(varlist, bound_vars, ex)
    if isa(ex, Symbol)
        ex ∈ bound_vars || push!(bound_vars, ex)
    elseif isa(ex, Expr)
        if ex.head == :tuple
            find_var_uses_lhs!(varlist, bound_vars, ex.args)
        else
            find_var_uses!(varlist, bound_vars, ex.args)
        end
    end
end

find_var_uses_lhs!(varlist, bound_vars, exs::Vector) = foreach(e->find_var_uses_lhs!(varlist, bound_vars, e), exs)
