module Problems

export FixedTimeProblem
export MinTimeProblem
export QuantumControlProblem
export QuantumMinTimeProblem

export solve!
export initialize_trajectory!
export update_traj_data!
export get_traj_data

using ..Utils
using ..Integrators
using ..Costs
using ..QuantumSystems
using ..Trajectories
using ..NLMOI
using ..Evaluators
using ..IpoptOptions
using ..Constraints

using Ipopt
using JLD2
using Libdl
using MathOptInterface
const MOI = MathOptInterface


#
# qubit problem
#
abstract type FixedTimeProblem end

struct QuantumControlProblem <: FixedTimeProblem
    system::AbstractQuantumSystem
    evaluator::QuantumEvaluator
    variables::Vector{MOI.VariableIndex}
    optimizer::Ipopt.Optimizer
    trajectory::Trajectory
    T::Int
    Δt::Float64
end

function QuantumControlProblem(
    system::AbstractQuantumSystem,
    init_traj::Trajectory;
    kwargs...
)
    return QuantumControlProblem(
        system,
        init_traj.T;
        Δt=init_traj.Δt,
        init_traj=init_traj,
        kwargs...
    )
end


function QuantumControlProblem(
    system::AbstractQuantumSystem,
    T::Int;
    integrator=:FourthOrderPade,
    cost=infidelity_cost,
    Δt=0.01,
    Q=200.0,
    R=0.1,
    eval_hessian=true,
    pin_first_qstate=true,
    σ = 0.1,
    linearly_interpolate = true,
    init_traj=Trajectory(
        system,
        T,
        Δt;
        linearly_interpolate = linearly_interpolate,
        σ=σ
    ),
    options=Options(),
    return_constraints=false,
    cons=AbstractConstraint[]
)

    if getfield(options, :linear_solver) == "pardiso" &&
        !Sys.isapple()
        Libdl.dlopen("/usr/lib/x86_64-linux-gnu/liblapack.so.3", RTLD_GLOBAL)
        Libdl.dlopen("/usr/lib/x86_64-linux-gnu/libomp.so.5", RTLD_GLOBAL)
    end

    optimizer = Ipopt.Optimizer()

    # set Ipopt optimizer options
    for name in fieldnames(typeof(options))
        optimizer.options[String(name)] = getfield(options, name)
    end

    total_vars = system.vardim * T
    total_dynamics = system.nstates * (T - 1)
    total_states = system.nstates * T

    variables = MOI.add_variables(optimizer, total_vars)

    # TODO: this is super hacky, I know; it should be fixed
    # subtype(::Type{Type{T}}) where T <: AbstractQuantumIntegrator = T
    # integrator = subtype(integrator)

    evaluator = QuantumEvaluator(
        system,
        integrator,
        cost,
        eval_hessian,
        T, Δt,
        Q, R
    )

    # pin first qstate to be equal to analytic solution
    if pin_first_qstate
        ψ̃¹goal = system.ψ̃goal[1:system.isodim]
        pin_con = EqualityConstraint(
            T,
            1:system.isodim,
            ψ̃¹goal,
            system.vardim
        )
        push!(cons, pin_con)
    end

    # initial quantum state constraints: ψ̃(t=1) = ψ̃1
    ψ1_con = EqualityConstraint(
        1,
        1:system.n_wfn_states,
        system.ψ̃1,
        system.vardim
    )
    push!(cons, ψ1_con)

    # initial a(t = 1) constraints: ∫a, a, da = 0
    aug1_con = EqualityConstraint(
        1,
        system.n_wfn_states .+ (1:system.n_aug_states),
        0.0,
        system.vardim
    )
    push!(cons, aug1_con)

    # final a(t = T) constraints: ∫a, a, da = 0
    augT_con = EqualityConstraint(
        T,
        system.n_wfn_states .+ (1:system.n_aug_states),
        0.0,
        system.vardim
    )
    push!(cons, augT_con)


    # bound |a(t)| < a_bound
    @assert length(system.control_bounds) == length(system.G_drives)

    for cntrl_index in 1:system.ncontrols
        cntrl_bound = BoundsConstraint(
            2:T-1,
            system.n_wfn_states + system.∫a*system.ncontrols + cntrl_index,
            system.control_bounds[cntrl_index],
            system.vardim
        )
        push!(cons, cntrl_bound)
    end

    constrain!(optimizer, variables, cons)

    dynamics_constraints =
        fill(MOI.NLPBoundsPair(0.0, 0.0), total_dynamics)

    block_data =
        MOI.NLPBlockData(dynamics_constraints, evaluator, true)

    MOI.set(optimizer, MOI.NLPBlock(), block_data)
    MOI.set(optimizer, MOI.ObjectiveSense(), MOI.MIN_SENSE)

    prob = QuantumControlProblem(
        system,
        evaluator,
        variables,
        optimizer,
        init_traj,
        T,
        Δt
    )

    if return_constraints
        return prob, cons
    else
        return prob
    end
end


function initialize_trajectory!(
    prob::QuantumControlProblem,
    traj::Trajectory
)
    for (t, x, u) in zip(1:prob.T, traj.states, traj.actions)
        MOI.set(
            prob.optimizer,
            MOI.VariablePrimalStart(),
            prob.variables[slice(t, prob.system.vardim)],
            [x; u]
        )
    end
end

initialize_trajectory!(prob) =
    initialize_trajectory!(prob, prob.trajectory)

@views function update_traj_data!(prob::QuantumControlProblem)
    Z = MOI.get(
        prob.optimizer,
        MOI.VariablePrimal(),
        prob.variables
    )

    xs = []

    for t = 1:prob.T
        xₜ = Z[slice(t, prob.system.nstates, prob.system.vardim)]
        push!(xs, xₜ)
    end

    us = []

    for t = 1:prob.T
        uₜ = Z[
            slice(
                t,
                prob.system.nstates + 1,
                prob.system.vardim,
                prob.system.vardim
            )
        ]
        push!(us, uₜ)
    end

    prob.trajectory.states .= xs
    prob.trajectory.actions .= us
end

function solve!(prob::QuantumControlProblem; init_traj=prob.trajectory, save = false, path = nothing)

    @assert !(save && isnothing(path))
        "must provide path for saving"

    initialize_trajectory!(prob, init_traj)

    MOI.optimize!(prob.optimizer)

    update_traj_data!(prob)

    if save
        path_parts = split(path, "/")
        dir = joinpath(path_parts[1:end-1])
        if !isdir(dir)
            mkpath(dir)
        end
        save_object(path, prob)
    end
end


#
# min time problem
#

abstract type MinTimeProblem end

struct QuantumMinTimeProblem <: MinTimeProblem
    subprob::QuantumControlProblem
    evaluator::MinTimeEvaluator
    variables::Vector{MOI.VariableIndex}
    optimizer::Ipopt.Optimizer
    T::Int
end

# TODO: rewrite this constructor (hacky implementation rn)

function QuantumMinTimeProblem(prob::FixedTimeProblem; kwargs...)
    return QuantumMinTimeProblem(
        prob.system,
        prob.T;
        Δt=prob.trajectory.Δt,
        init_traj=prob.trajectory,
        kwargs...
    )
end

function QuantumMinTimeProblem(
    system::AbstractQuantumSystem,
    T::Int;
    Rᵤ=0.001,
    Rₛ=0.001,
    Δt=0.01,
    Δt_lbound=0.1 * Δt,
    Δt_ubound=Δt,
    integrator=:FourthOrderPade,
    σ = 0.1,
    linearly_interpolate = true,
    init_traj=Trajectory(
        system, T, Δt,
        linearly_interpolate = linearly_interpolate,
        σ = σ),
    eval_hessian=true,
    mintime_options=Options(),
    kwargs...
)

    optimizer = Ipopt.Optimizer()

    # set Ipopt optimizer options
    for name in fieldnames(typeof(mintime_options))
        optimizer.options[String(name)] =
            getfield(mintime_options, name)
    end

    total_vars = system.vardim * T
    total_dynamics = system.nstates * (T - 1)

    # defining Z = [Z; Δts]
    variables = MOI.add_variables(optimizer, total_vars + T - 1)

    # set up sub problem
    subprob, cons = QuantumControlProblem(
        system,
        init_traj;
        return_constraints=true,
        integrator=integrator,
        eval_hessian=eval_hessian,
        pin_first_qstate=false, # TODO: figure out a better way to implement this - pinned first qstate dissallows constraints on all qstates during mintime solve
        kwargs...
    )

    # constraints on Δtₜs
    Δt_bounds_con =
        TimeStepBoundsConstraint((Δt_lbound, Δt_ubound), T)

    push!(cons, Δt_bounds_con)

    constrain!(optimizer, variables, cons)

    # build min time evaluator
    evaluator = MinTimeEvaluator(
        subprob.system,
        integrator,
        T,
        Rᵤ,
        Rₛ,
        eval_hessian
    )

    dynamics_constraints =
        [MOI.NLPBoundsPair(0.0, 0.0) for _ = 1:total_dynamics]

    block_data = MOI.NLPBlockData(
        dynamics_constraints,
        evaluator,
        true
    )

    MOI.set(optimizer, MOI.NLPBlock(), block_data)
    MOI.set(optimizer, MOI.ObjectiveSense(), MOI.MIN_SENSE)

    return QuantumMinTimeProblem(
        subprob,
        evaluator,
        variables,
        optimizer,
        T,
    )
end

function initialize_trajectory!(
    prob::MinTimeProblem,
    traj::Trajectory
)
    for (t, x, u) in zip(1:prob.T, traj.states, traj.actions)
        MOI.set(
            prob.optimizer,
            MOI.VariablePrimalStart(),
            prob.variables[slice(t, prob.subprob.system.vardim)],
            [x; u]
        )
    end
    MOI.set(
        prob.optimizer,
        MOI.VariablePrimalStart(),
        prob.variables[(end - (prob.T - 1) + 1):end],
        fill(prob.subprob.Δt, prob.T - 1)
    )
end

function initialize_trajectory!(prob::MinTimeProblem)
    initialize_trajectory!(prob, prob.subprob.trajectory)
end

@views function update_traj_data!(prob::MinTimeProblem)

    vardim  = prob.subprob.system.vardim
    nstates = prob.subprob.system.nstates

    Z = MOI.get(
        prob.optimizer,
        MOI.VariablePrimal(),
        prob.variables
    )

    xs = [Z[slice(t, nstates, vardim)] for t = 1:prob.T]

    us = [
        Z[slice(t, nstates + 1, vardim, vardim)]
            for t = 1:prob.T
    ]

    Δts = [0.0; Z[(end - (prob.T - 1) + 1):end]]

    prob.subprob.trajectory.states .= xs
    prob.subprob.trajectory.actions .= us
    prob.subprob.trajectory.times .= cumsum(Δts)
end


function solve!(prob::MinTimeProblem; save=false, path=nothing)
    @assert !(save && isnothing(path))
        "must provide path for saving"

    solve!(prob.subprob)

    init_traj = prob.subprob.trajectory

    initialize_trajectory!(prob, init_traj)


    # constrain end points to match subprob solution

    # TODO: this is a hacky way to do this - fix this
    isodim       = prob.subprob.system.isodim
    n_wfn_states = prob.subprob.system.n_wfn_states

    ψ̃T_con! = EqualityConstraint(
        prob.T,
        1:n_wfn_states,
        init_traj.states[end][1:n_wfn_states],
        prob.subprob.system.vardim
    )

    ψ̃T_con!(prob.optimizer, prob.variables)

    MOI.optimize!(prob.optimizer)

    update_traj_data!(prob)
    if save
        save_trajectory(prob.subprob.trajectory, path)
    end
end


# TODO: add functionality to vizualize Δt distribution


end
