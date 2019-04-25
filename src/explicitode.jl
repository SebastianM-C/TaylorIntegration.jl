# This file is part of the TaylorIntegration.jl package; MIT licensed

# jetcoeffs!
@doc doc"""
    jetcoeffs!(eqsdiff::Function, t, x, params)

Returns an updated `x` using the recursion relation of the
derivatives obtained from the differential equations
``\dot{x}=dx/dt=f(x, p, t)``.

`eqsdiff` is the function defining the RHS of the ODE,
`x` contains the Taylor1 expansion of the dependent variable(s) and
`t` is the independent variable, and `params` are the parameters appearing on the
function defining the differential equation. See [`taylorinteg`](@ref) for examples
and convention for `eqsdiff`. Note that `x` is of type `Taylor1{U}` where
`U<:Number`; `t` is of type `Taylor1{T}` where `T<:Real`.

Initially, `x` contains only the 0-th order Taylor coefficient of
the current system state (the initial conditions), and `jetcoeffs!`
computes recursively the high-order derivates back into `x`.

"""
function jetcoeffs!(eqsdiff::Function, t::Taylor1{T}, x::Taylor1{U}, params) where
        {T<:Real, U<:Number}
    order = x.order
    for ord in 0:order-1
        ordnext = ord+1

        # Set `taux`, `xaux`, auxiliary Taylor1 variables to order `ord`
        @inbounds taux = Taylor1( t.coeffs[1:ordnext] )
        @inbounds xaux = Taylor1( x.coeffs[1:ordnext] )

        # Equations of motion
        dx = eqsdiff(xaux, params, taux)

        # Recursion relation
        @inbounds x[ordnext] = dx[ord]/ordnext
    end
    nothing
end

@doc doc"""
    jetcoeffs!(eqsdiff!::Function, t, x, dx, xaux, params)

Mutates `x` in-place using the recursion relation of the
derivatives obtained from the differential equations
``\dot{x}=dx/dt=f(x, p, t)``.

`eqsdiff!` is the function defining the RHS of the ODE,
`x` contains the Taylor1 expansion of the dependent variables and
`t` is the independent variable, and `params` are the parameters appearing on the
function defining the differential equation. See [`taylorinteg`](@ref) for examples
and convention for `eqsdiff`. Note that `x` is of type `Vector{Taylor1{U}}`
where `U<:Number`; `t` is of type `Taylor1{T}` where `T<:Real`. In this case,
two auxiliary containers `dx` and `xaux` (both of the same type as `x`) are
needed to avoid allocations.

Initially, `x` contains only the 0-th order Taylor coefficient of
the current system state (the initial conditions), and `jetcoeffs!`
computes recursively the high-order derivates back into `x`.

"""
function jetcoeffs!(eqsdiff!::Function, t::Taylor1{T},
        x::AbstractVector{Taylor1{U}}, dx::AbstractVector{Taylor1{U}},
        xaux::AbstractVector{Taylor1{U}}, params) where {T<:Real, U<:Number}
    order = x[1].order
    for ord in 0:order-1
        ordnext = ord+1

        # Set `taux`, auxiliary Taylor1 variable to order `ord`
        @inbounds taux = Taylor1( t.coeffs[1:ordnext] )
        # Set `xaux`, auxiliary vector of Taylor1 to order `ord`
        for j in eachindex(x)
            @inbounds xaux[j] = Taylor1( x[j].coeffs[1:ordnext] )
        end

        # Equations of motion
        eqsdiff!(dx, xaux, params, taux)

        # Recursion relations
        for j in eachindex(x)
            @inbounds x[j][ordnext] = dx[j][ord]/ordnext
        end
    end
    nothing
end


# __jetcoeffs
"""
    __jetcoeffs!(::Val{bool}, f, t, x, params)
    __jetcoeffs!(::Val{bool}, f, t, x, dx, xaux, params)

Chooses a method of [`jetcoeffs!`](@ref) (hard-coded or generated by
[`@taylorize`](@ref)) depending on `Val{bool}` (`bool::Bool`).
"""
@inline __jetcoeffs!(::Val{false}, f, t, x, params) =
    jetcoeffs!(f, t, x, params)
@inline __jetcoeffs!(::Val{true},  f, t, x, params) =
    jetcoeffs!(Val(f), t, x, params)
@inline __jetcoeffs!(::Val{false}, f, t, x, dx, xaux, params) =
    jetcoeffs!(f, t, x, dx, xaux, params)
@inline __jetcoeffs!(::Val{true},  f, t, x, dx, xaux, params) =
    jetcoeffs!(Val(f), t, x, dx, params)


# stepsize
"""
    stepsize(x, epsilon) -> h

Returns a maximum time-step for a the Taylor expansion `x`
using a prescribed absolute tolerance `epsilon` and the last two
Taylor coefficients of (each component of) `x`.

Note that `x` is of type `Taylor1{U}` or `Vector{Taylor1{U}}`, including
also the cases `Taylor1{TaylorN{U}}` and `Vector{Taylor1{TaylorN{U}}}`.

Depending of `eltype(x)`, i.e., `U<:Number`, it may be necessary to overload
`stepsize`, specializing it on the type `U`, to avoid type instabilities.
"""
function stepsize(x::Taylor1{U}, epsilon::T) where {T<:Real, U<:Number}
    R = promote_type(typeof(norm(constant_term(x), Inf)), T)
    ord = x.order
    h = convert(R, Inf)
    z = zero(R)
    for k in (ord-1, ord)
        @inbounds aux = norm( x[k], Inf)
        aux == z && continue
        aux1 = _stepsize(aux, epsilon, k)
        h = min(h, aux1)
    end
    return h::R
end

function stepsize(q::AbstractArray{Taylor1{U},1}, epsilon::T) where
        {T<:Real, U<:Number}
    R = promote_type(typeof(norm(constant_term(q[1]), Inf)), T)
    h = convert(R, Inf)
    for i in eachindex(q)
        @inbounds hi = stepsize( q[i], epsilon )
        h = min( h, hi )
    end

    # If `isinf(h)==true`, we use the maximum (finite)
    # step-size obtained from all coefficients as above.
    # Note that the time step is independent from `epsilon`.
    if isinf(h)
        h = zero(R)
        for i in eachindex(q)
            @inbounds hi = _second_stepsize(q[i], epsilon)
            h = max( h, hi )
        end
    end
    return h::R
end

"""
    _stepsize(aux1, epsilon, k)

Helper function to avoid code repetition.
Returns ``(epsilon/aux1)^(1/k)``.
"""
@inline function _stepsize(aux1::U, epsilon::T, k::Int) where {T<:Real, U<:Number}
    aux = epsilon / aux1
    kinv = 1 / k
    return aux^kinv
end

"""
    _second_stepsize(x, epsilon)

Corresponds to the "second stepsize control" in Jorba and Zou
(2005) paper. We use it if [`stepsize`](@ref) returns `Inf`.
"""
function _second_stepsize(x::Taylor1{U}, epsilon::T) where {T<:Real, U<:Number}
    R = promote_type(typeof(norm(constant_term(x), Inf)), T)
    x == zero(x) && return convert(R, Inf)
    ord = x.order
    z = zero(R)
    u = one(R)
    h = z
    for k in 1:ord-2
        @inbounds aux = norm( x[k], Inf)
        aux == z && continue
        aux1 = _stepsize(aux, u, k)
        h = max(h, aux1)
    end
    return h::R
end

#taylorstep
@doc doc"""
    taylorstep!(f, t, x, t0, order, abstol, params, parse_eqs=true) -> δt
    taylorstep!(f!, t, x, dx, xaux, t0, order, abstol, params, parse_eqs=true) -> δt

One-step Taylor integration for the one-dependent variable ODE ``\dot{x}=dx/dt=f(x, p, t)``
with initial conditions ``x(t_0)=x_0``.
Returns the time-step `δt` of the actual integration carried out (δt is positive).

Here, `f` is the function defining the RHS of the ODE (see
[`taylorinteg`](@ref)), `t` is the
independent variable, `x` contains the Taylor expansion of the dependent
variable, `order` is
the degree  used for the `Taylor1` polynomials during the integration
`abstol` is the absolute tolerance used to determine the time step
of the integration, and `params` are the parameters entering the ODE
functions.
For several variables, `dx` and `xaux`, both of the same type as `x`,
are needed to save allocations. Finally, `parse_eqs` is a switch
to force *not* using (`parse_eqs=false`) the specialized method of `jetcoeffs!`
created with [`@taylorize`](@ref); the default is `true` (parse the equations).
Finally, `parse_eqs` is a switch
to force *not* using (`parse_eqs=false`) the specialized method of `jetcoeffs!`
created with [`@taylorize`](@ref); the default is `true` (parse the equations).

"""
function taylorstep!(f, t::Taylor1{T}, x::Taylor1{U}, abstol::T, params,
        parse_eqs::Bool=true) where {T<:Real, U<:Number}

    # Compute the Taylor coefficients
    __jetcoeffs!(Val(parse_eqs), f, t, x, params)

    # Compute the step-size of the integration using `abstol`
    δt = stepsize(x, abstol)
    if isinf(δt)
        δt = _second_stepsize(x, abstol)
    end

    return δt
end

function taylorstep!(f!, t::Taylor1{T}, x::Vector{Taylor1{U}},
        dx::Vector{Taylor1{U}}, xaux::Vector{Taylor1{U}}, abstol::T, params,
        parse_eqs::Bool=true) where {T<:Real, U<:Number}

    # Compute the Taylor coefficients
    __jetcoeffs!(Val(parse_eqs), f!, t, x, dx, xaux, params)

    # Compute the step-size of the integration using `abstol`
    δt = stepsize(x, abstol)

    return δt
end



"""
    _determine_parsing!(parse_eqs::Bool, f, t, x, params)
    _determine_parsing!(parse_eqs::Bool, f, t, x, dx, params)

Check if the parsed method of `jetcoeffs!` exists and check it
runs without error.
"""
function _determine_parsing!(parse_eqs::Bool, f, t, x, params)
    parse_eqs = parse_eqs &&
        !isempty(methodswith(Val{f}, TaylorIntegration.jetcoeffs!))
    if parse_eqs
        try
            jetcoeffs!(Val(f), t, x, params)
        catch
            @warn("""Unable to use the parsed method of `jetcoeffs!`
            despite of having `parse_eqs=true`, due to some internal error.
            Using `parse_eqs = $false`""")
            parse_eqs = false
        end
    end
    return parse_eqs
end
function _determine_parsing!(parse_eqs::Bool, f, t, x, dx, params)
    parse_eqs = parse_eqs &&
        !isempty(methodswith(Val{f}, TaylorIntegration.jetcoeffs!))
    if parse_eqs
        try
            jetcoeffs!(Val(f), t, x, dx, params)
        catch
            @warn("""Unable to use the parsed method of `jetcoeffs!`
            despite of having `parse_eqs=true`, due to some internal error.
            Using `parse_eqs = $false`""")
            parse_eqs = false
        end
    end
    return parse_eqs
end


# taylorinteg
@doc doc"""
    taylorinteg(f, x0, t0, tmax, order, abstol, params[=nothing]; kwargs... )

General-purpose Taylor integrator for the explicit ODE ``\dot{x}=f(x, p, t)``.
The initial condition are specified by `x0` at time `t0`, and any parameters
encoded in `params`. The initial condition `x0` may be of type `T<:Number`
or `Vector{T}`, with `T` including `TaylorN{T}`; the latter case
is of interest for [jet transport applications](@ref jettransport).

The equations of motion are specified by the function `f`; we follow the same
convention of `DifferentialEquations.jl` to define this function, i.e.,
`f(x, p, t)` or `f!(dx, x, p, t)`; see the examples below.

It returns a vector with the values of time (independent variable),
and a vector with the computed values of
the dependent variable(s). The integration stops when time
is larger than `tmax`, in which case the last returned
value(s) correspond to that time, or when the number of saved steps is larger
than `maxsteps`.

The integration method uses polynomial expansions on the independent variable
of order `order`; the parameter `abstol` serves to define the
time step using the last two Taylor coefficients of the expansions.
Make sure you use a *large enough* `order` to assure convergence.

Currently, the recognized keyword arguments are:
- `maxsteps[=500]`: maximum number of integration steps.
- `parse_eqs[=true]`: use the specialized method of `jetcoeffs!` created
    with [`@taylorize`](@ref).

## Examples

For one dependent variable the function `f` defines the RHS of the equation of
motion, returning the value of ``\dot{x}``. The arguments of
this function are `(x, p, t)`, where `x` are the dependent variables, `p` are
the paremeters and `t` is the independent variable.

For several (two or more) dependent variables, the function `f!` defines
the RHS of the equations of motion, mutating (in-place) the (preallocated) vector
with components of ``\dot{x}``. The arguments of this function are `(dx, x, p, t)`,
where `dx` is the preallocated vector of ``\dot{x}``, `x` are the dependent
variables, `p` are the paremeters entering the ODEs and `t` is the independent
variable. The function may return this vector or simply `nothing`.

```julia
using TaylorIntegration

f(x, p, t) = x^2

tv, xv = taylorinteg(f, 3, 0.0, 0.3, 25, 1.0e-20, maxsteps=100 )

function f!(dx, x, p, t)
    for i in eachindex(x)
        dx[i] = x[i]^2
    end
    return nothing
end

tv, xv = taylorinteg(f!, [3, 3], 0.0, 0.3, 25, 1.0e-20, maxsteps=100 )
```

"""
function taylorinteg(f, x0::U, t0::T, tmax::T, order::Int, abstol::T,
    params = nothing; maxsteps::Int=500, parse_eqs::Bool=true, dense::Bool=false) where {T<:Real, U<:Number}

    # Allocation
    tv = Array{T}(undef, maxsteps+1)
    xv = Array{U}(undef, maxsteps+1)
    if dense
        xv_interp = Array{Taylor1{U}}(undef, maxsteps+1)
    end

    # Initialize the Taylor1 expansions
    t = Taylor1( T, order )
    x = Taylor1( x0, order )

    # Initial conditions
    nsteps = 1
    @inbounds t[0] = t0
    @inbounds tv[1] = t0
    @inbounds xv[1] = x0
    sign_tstep = copysign(1, tmax-t0)

    # Determine if specialized jetcoeffs! method exists
    parse_eqs = _determine_parsing!(parse_eqs, f, t, x, params)

    # Integration
    while sign_tstep*t0 < sign_tstep*tmax
        δt = taylorstep!(f, t, x, abstol, params, parse_eqs) # δt is positive!
        # Below, δt has the proper sign according to the direction of the integration
        δt = sign_tstep * min(δt, sign_tstep*(tmax-t0))
        x0 = evaluate(x, δt) # new initial condition
        if dense
            xv_interp[nsteps] = deepcopy(x)
        end
        @inbounds x[0] = x0
        t0 += δt
        @inbounds t[0] = t0
        nsteps += 1
        @inbounds tv[nsteps] = t0
        @inbounds xv[nsteps] = x0
        if nsteps > maxsteps
            @warn("""
            Maximum number of integration steps reached; exiting.
            """)
            break
        end
    end

    #return tv, xv
    if dense
        return TaylorInterpolant(view(tv,1:nsteps), view(xv_interp,1:nsteps-1))
    else
        return view(tv,1:nsteps), view(xv,1:nsteps)
    end
end

function taylorinteg(f!, q0::Array{U,1}, t0::T, tmax::T, order::Int, abstol::T,
        params = nothing; maxsteps::Int=500, parse_eqs::Bool=true, dense::Bool=false) where {T<:Real, U<:Number}

    # Allocation
    tv = Array{T}(undef, maxsteps+1)
    dof = length(q0)
    xv = Array{U}(undef, dof, maxsteps+1)
    if dense
        xv_interp = Array{Taylor1{U}}(undef, dof, maxsteps+1)
    end

    # Initialize the vector of Taylor1 expansions
    t = Taylor1(T, order)
    x = Array{Taylor1{U}}(undef, dof)
    dx = Array{Taylor1{U}}(undef, dof)
    xaux = Array{Taylor1{U}}(undef, dof)
    for i in eachindex(q0)
        @inbounds x[i] = Taylor1( q0[i], order )
        @inbounds dx[i] = Taylor1( zero(q0[i]), order )
    end

    # Initial conditions
    @inbounds t[0] = t0
    x .= Taylor1.(q0, order)
    x0 = deepcopy(q0)
    @inbounds tv[1] = t0
    @inbounds xv[:,1] .= q0
    sign_tstep = copysign(1, tmax-t0)

    # Determine if specialized jetcoeffs! method exists
    parse_eqs = _determine_parsing!(parse_eqs, f!, t, x, dx, params)

    # Integration
    nsteps = 1
    while sign_tstep*t0 < sign_tstep*tmax
        δt = taylorstep!(f!, t, x, dx, xaux, abstol, params, parse_eqs) # δt is positive!
        # Below, δt has the proper sign according to the direction of the integration
        δt = sign_tstep * min(δt, sign_tstep*(tmax-t0))
        evaluate!(x, δt, x0) # new initial condition
        if dense
            xv_interp[:,nsteps] .= deepcopy(x)
        end
        for i in eachindex(x0)
            @inbounds x[i][0] = x0[i]
            @inbounds dx[i] = Taylor1( zero(x0[i]), order )
        end
        t0 += δt
        @inbounds t[0] = t0
        nsteps += 1
        @inbounds tv[nsteps] = t0
        @inbounds xv[:,nsteps] .= x0
        if nsteps > maxsteps
            @warn("""
            Maximum number of integration steps reached; exiting.
            """)
            break
        end
    end

    if dense
        return TaylorInterpolant(view(tv,1:nsteps), view(transpose(view(xv_interp,:,1:nsteps-1)),1:nsteps-1,:))
    else
        return view(tv,1:nsteps), view(transpose(view(xv,:,1:nsteps)),1:nsteps,:)
    end
end

# Integrate and return results evaluated at given time
@doc doc"""
    taylorinteg(f, x0, trange, order, abstol, params[=nothing]; keyword... )

General-purpose Taylor integrator for the explicit ODE
``\dot{x}=f(t,x)`` with initial condition specified by `x0::{T<:Number}`
or `x0::Vector{T}` at time `t0`.

The method returns a vector with the computed values of
the dependent variable(s), evaluated *only* at the times specified by
the range `trange`.

## Examples

```julia
xv = taylorinteg(f, 3, 0.0:0.001:0.3, 25, 1.0e-20, maxsteps=100 )

xv = taylorinteg(f!, [3, 3], 0.0:0.001:0.3, 25, 1.0e-20, maxsteps=100 );

```

"""
function taylorinteg(f, x0::U, trange::AbstractVector{T},
        order::Int, abstol::T, params = nothing;
        maxsteps::Int=500, parse_eqs::Bool=true) where {T<:Real, U<:Number}

    # Check if trange is increasingly or decreasingly sorted
    @assert (issorted(trange) ||
        issorted(reverse(trange))) "`trange` or `reverse(trange)` must be sorted"

    # Allocation
    nn = length(trange)
    xv = Array{U}(undef, nn)
    fill!(xv, T(NaN))

    # Initialize the Taylor1 expansions
    t = Taylor1( T, order )
    x = Taylor1( x0, order )

    # Initial conditions
    @inbounds t0, t1, tmax = trange[1], trange[2], trange[end]
    sign_tstep = copysign(1, tmax-t0)
    @inbounds t[0] = t0
    @inbounds xv[1] = x0

    # Determine if specialized jetcoeffs! method exists
    parse_eqs = _determine_parsing!(parse_eqs, f, t, x, params)

    # Integration
    iter = 2
    nsteps = 1
    while sign_tstep*t0 < sign_tstep*tmax
        δt = taylorstep!(f, t, x, abstol, params, parse_eqs)# δt is positive!
        # Below, δt has the proper sign according to the direction of the integration
        δt = sign_tstep * min(δt, sign_tstep*(tmax-t0))
        x0 = evaluate(x, δt) # new initial condition
        tnext = t0+δt
        # Evaluate solution at times within convergence radius
        while sign_tstep*t1 < sign_tstep*tnext
            x1 = evaluate(x, t1-t0)
            @inbounds xv[iter] = x1
            iter += 1
            @inbounds t1 = trange[iter]
        end
        if δt == tmax-t0
            @inbounds xv[iter] = x0
            break
        end
        @inbounds x[0] = x0
        t0 = tnext
        @inbounds t[0] = t0
        nsteps += 1
        if nsteps > maxsteps
            @warn("""
            Maximum number of integration steps reached; exiting.
            """)
            break
        end
    end
    return xv
end

function taylorinteg(f!, q0::Array{U,1}, trange::AbstractVector{T},
        order::Int, abstol::T, params = nothing; maxsteps::Int=500,
        parse_eqs::Bool=true) where {T<:Real, U<:Number}

    # Check if trange is increasingly or decreasingly sorted
    @assert (issorted(trange) ||
        issorted(reverse(trange))) "`trange` or `reverse(trange)` must be sorted"

    # Allocation
    nn = length(trange)
    dof = length(q0)
    x0 = similar(q0, eltype(q0), dof)
    x1 = similar(x0)
    fill!(x0, T(NaN))
    xv = Array{eltype(q0)}(undef, dof, nn)
    for ind in 1:nn
        @inbounds xv[:,ind] .= x0
    end

    # Initialize the vector of Taylor1 expansions
    t = Taylor1( T, order )
    x = Array{Taylor1{U}}(undef, dof)
    dx = Array{Taylor1{U}}(undef, dof)
    xaux = Array{Taylor1{U}}(undef, dof)
    for i in eachindex(q0)
        @inbounds x[i] = Taylor1( q0[i], order )
        @inbounds dx[i] = Taylor1( zero(q0[i]), order )
    end

    # Initial conditions
    @inbounds t[0] = trange[1]
    @inbounds t0, t1, tmax = trange[1], trange[2], trange[end]
    sign_tstep = copysign(1, tmax-t0)
    x .= Taylor1.(q0, order)
    @inbounds x0 .= q0
    @inbounds xv[:,1] .= q0

    # Determine if specialized jetcoeffs! method exists
    parse_eqs = _determine_parsing!(parse_eqs, f!, t, x, dx, params)

    # Integration
    iter = 2
    nsteps = 1
    while sign_tstep*t0 < sign_tstep*tmax
        δt = taylorstep!(f!, t, x, dx, xaux, abstol, params, parse_eqs) # δt is positive!
        # Below, δt has the proper sign according to the direction of the integration
        δt = sign_tstep * min(δt, sign_tstep*(tmax-t0))
        evaluate!(x, δt, x0) # new initial condition
        tnext = t0+δt
        # Evaluate solution at times within convergence radius
        while sign_tstep*t1 < sign_tstep*tnext
            evaluate!(x, t1-t0, x1)
            @inbounds xv[:,iter] .= x1
            iter += 1
            @inbounds t1 = trange[iter]
        end
        if δt == tmax-t0
            @inbounds xv[:,iter] .= x0
            break
        end
        for i in eachindex(x0)
            @inbounds x[i][0] = x0[i]
            @inbounds dx[i] = Taylor1( zero(x0[i]), order )
        end
        t0 = tnext
        @inbounds t[0] = t0
        nsteps += 1
        if nsteps > maxsteps
            @warn("""
            Maximum number of integration steps reached; exiting.
            """)
            break
        end
    end

    return transpose(xv)
end


# Generic functions
for R in (:Number, :Integer)
    @eval begin
        function taylorinteg(f, xx0::S, tt0::T, ttmax::U, order::Int, aabstol::V,
                params = nothing; maxsteps::Int=500, parse_eqs::Bool=true) where
                    {S<:$R, T<:Real, U<:Real, V<:Real}

            # In order to handle mixed input types, we promote types before integrating:
            t0, tmax, abstol, bfloat = promote(tt0, ttmax, aabstol, one(Float64))
            x0, tfloat1 = promote(xx0, t0)

            taylorinteg(f, x0, t0, tmax, order, abstol, params, maxsteps=maxsteps,
                parse_eqs=parse_eqs)
        end

        function taylorinteg(f, q0::Array{S,1}, tt0::T, ttmax::U, order::Int, aabstol::V,
                params = nothing; maxsteps::Int=500, parse_eqs::Bool=true) where
                    {S<:$R, T<:Real, U<:Real, V<:Real}

            #promote to common type before integrating:
            t0, tmax, abstol, afloat = promote(tt0, ttmax, aabstol, one(Float64))
            elq0, tt0 = promote(q0[1], t0)
            #convert the elements of q0 to the common, promoted type:
            q0_ = convert(Array{typeof(elq0)}, q0)

            taylorinteg(f, q0_, t0, tmax, order, abstol, params, maxsteps=maxsteps,
                parse_eqs=parse_eqs)
        end

        function taylorinteg(f, xx0::S, trange::AbstractVector{T},
                order::Int, aabstol::U, params = nothing;
                maxsteps::Int=500, parse_eqs::Bool=true) where
                    {S<:$R, T<:Real, U<:Real}
                    #
                t0, abstol, bfloat = promote(trange[1], aabstol, one(Float64))
                x0, tfloat1 = promote(xx0, t0)
                taylorinteg(f, x0, vec(trange.*one(t0)), order, abstol,
                    params, maxsteps=maxsteps, parse_eqs=parse_eqs)
        end

        function taylorinteg(f, q0::Array{S,1}, trange::AbstractVector{T},
                order::Int, aabstol::U, params = nothing;
                maxsteps::Int=500, parse_eqs::Bool=true) where
                    {S<:$R, T<:Real, U<:Real}
                    #
                t0, abstol, bfloat = promote(trange[1], aabstol, one(Float64))
                elq0, tt0 = promote(q0[1], t0)
                q0_ = convert(Array{typeof(elq0)}, q0)

                taylorinteg(f, q0_, vec(trange.*one(t0)), order, abstol,
                    params, maxsteps=maxsteps, parse_eqs=parse_eqs)
        end
    end
end
