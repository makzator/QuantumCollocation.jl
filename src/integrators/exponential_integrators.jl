"""
This file includes expoential integrators for states and unitaries
"""

using ExponentialAction

# ----------------------------------------------------------------------------- #
#                         Quantum Exponential Integrators                       #
# ----------------------------------------------------------------------------- #

abstract type QuantumExponentialIntegrator <: QuantumIntegrator end

# ----------------------------------------------------------------------------- #
#                         Unitary Exponential Integrator                        #
# ----------------------------------------------------------------------------- #

struct UnitaryExponentialIntegrator <: QuantumExponentialIntegrator
    unitary_components::Vector{Int}
    drive_components::Vector{Int}
    timestep::Union{Real, Int}
    freetime::Bool
    n_drives::Int
    ketdim::Int
    dim::Int
    zdim::Int
    autodiff::Bool
    G::Function
    ∂aG::Vector{Function}

    function UnitaryExponentialIntegrator(
        sys::AbstractQuantumSystem,
        unitary_name::Symbol,
        drive_name::Union{Symbol, Tuple{Vararg{Symbol}}},
        traj::NamedTrajectory;
        G::Union{Function, Nothing}=nothing,
        ∂aG::Union{Vector{Function}, Nothing}=nothing,
        autodiff::Bool=false
    )
        ketdim = size(sys.H_drift, 1)
        dim = 2ketdim^2

        unitary_components = traj.components[unitary_name]

        if drive_name isa Tuple
            drive_components = vcat((traj.components[s] for s ∈ drive_name)...)
        else
            drive_components = traj.components[drive_name]
        end

        n_drives = length(drive_components)

        @assert all(diff(drive_components) .== 1) "controls must be in order"

        if isnothing(G)
            G = a -> G_bilinear(a, sys.G_drift, sys.G_drives)
            ∂aG = [a -> sys.G_drives[i] for i in 1:n_drives]
        else
            @assert !isnothing(∂aG) "∂aG must be provided if G is provided"
        end

        freetime = traj.timestep isa Symbol

        if freetime
            timestep = traj.components[traj.timestep][1]
        else
            timestep = traj.timestep
        end

        if autodiff
            println("autodiff turned on in exp integrator")
        end

        return new(
            unitary_components,
            drive_components,
            timestep,
            freetime,
            n_drives,
            ketdim,
            dim,
            traj.dim,
            autodiff,
            G,
            ∂aG
        )
    end
end

function (integrator::UnitaryExponentialIntegrator)(
    sys::AbstractQuantumSystem,
    traj::NamedTrajectory;
    unitary_name::Union{Nothing, Symbol}=nothing,
    drive_name::Union{Nothing, Symbol, Tuple{Vararg{Symbol}}}=nothing,
    G::Union{Function,Nothing}=integrator.G,
    ∂aG::Union{Vector{Function}, Nothing}=integrator.∂aG,
    autodiff::Bool=integrator.autodiff
)
    @assert !isnothing(unitary_name) "unitary_name must be provided"
    @assert !isnothing(drive_name) "drive_name must be provided"
    return UnitaryExponentialIntegrator(
        sys,
        unitary_name,
        drive_name,
        traj;
        G=G,
        ∂aG=∂aG,
        autodiff=autodiff
    )
end

function get_comps(P::UnitaryExponentialIntegrator, traj::NamedTrajectory)
    if P.freetime
        return P.unitary_components, P.drive_components, traj.components[traj.timestep]
    else
        return P.unitary_components, P.drive_components
    end
end

# ------------------------------ Integrator --------------------------------- #

@views function (ℰ::UnitaryExponentialIntegrator)(
    zₜ::AbstractVector,
    zₜ₊₁::AbstractVector,
    t::Int
)
    Ũ⃗ₜ₊₁ = zₜ₊₁[ℰ.unitary_components]
    Ũ⃗ₜ = zₜ[ℰ.unitary_components]
    aₜ = zₜ[ℰ.drive_components]
    
    if ℰ.freetime
        Δtₜ = zₜ[ℰ.timestep]
    else
        Δtₜ = ℰ.timestep
    end

    Gₜ = ℰ.G(aₜ)

    return Ũ⃗ₜ₊₁ - expv(Δtₜ, I(ℰ.ketdim) ⊗ Gₜ, Ũ⃗ₜ)
end

function hermitian_exp(G::AbstractMatrix)
    Ĥ = Hermitian(Matrix(Isomorphisms.H(G)))
    λ, V = eigen(Ĥ)
    expG = Isomorphisms.iso(sparse(V * Diagonal(exp.(-im * λ)) * V'))
    droptol!(expG, 1e-12)
    return expG
end

@views function jacobian(
    ℰ::UnitaryExponentialIntegrator,
    zₜ::AbstractVector,
    zₜ₊₁::AbstractVector,
    t::Int
)
    # get the state and control vectors
    Ũ⃗ₜ = zₜ[ℰ.unitary_components]
    aₜ = zₜ[ℰ.drive_components]

    # obtain the timestep
    if ℰ.freetime
        Δtₜ = zₜ[ℰ.timestep]
    else
        Δtₜ = ℰ.timestep
    end

    # compute the generator
    Gₜ = ℰ.G(aₜ)

    Id = I(ℰ.ketdim)

    expĜₜ = Id ⊗ hermitian_exp(Δtₜ * Gₜ)

    ∂Ũ⃗ₜ₊₁ℰ = sparse(I, ℰ.dim, ℰ.dim)
    ∂Ũ⃗ₜℰ = -expĜₜ

    if ℰ.autodiff
        ∂aₜℰ = -ForwardDiff.jacobian(
            a -> expv(Δtₜ, Id ⊗ ℰ.G(a), Ũ⃗ₜ),
            aₜ
        )
    else
        # Copilot idea: this is wrong bc assumes commutativity- but what is the
        # error we would be making? good enough gradient?
        # ∂aₜℰ = -ℰ.∂aG[1](aₜ) * expĜₜ * Ũ⃗ₜ
        # for i = 2:ℰ.n_drives
        #     ∂aₜℰ += -ℰ.∂aG[i](aₜ) * expĜₜ * Ũ⃗ₜ
        # end

        G̃ = I(ℰ.ketdim * (ℰ.n_drives+1)) ⊗ Gₜ
        for j=1:ℰ.n_drives
            G̃[j*ℰ.dim+1:(j+1)*ℰ.dim,1:ℰ.dim] = Id ⊗ ℰ.∂aG[j](aₜ) 
        end
        Ũ̃ = vcat(Ũ⃗ₜ, zeros(ℰ.dim * ℰ.n_drives))
        ∂aₜℰ = -expv(Δtₜ, G̃, Ũ̃)[ℰ.dim+1:end]
        ∂aₜℰ = reshape(∂aₜℰ, ℰ.dim, ℰ.n_drives)

        # alternative approach with smaller exponentials
        # ∂aₜℰ = Array{Float64}(undef, ℰ.dim, ℰ.n_drives)
        # Ũ̃ = vcat(Ũ⃗ₜ, zeros(ℰ.dim))
        # for j=1:ℰ.n_drives
        #     G̃ = I(2*ℰ.ketdim) ⊗ Gₜ
        #     G̃[ℰ.dim+1:end, 1:ℰ.dim] = Id ⊗ ℰ.∂aG[j](aₜ)
        #     ∂aₜℰ[:,j] = -expv(Δtₜ, G̃, Ũ̃)[ℰ.dim+1:end]
        # end
    end

    if ℰ.freetime
        ∂Δtₜℰ = -(Id ⊗ Gₜ) * expĜₜ * Ũ⃗ₜ
        return ∂Ũ⃗ₜℰ, ∂Ũ⃗ₜ₊₁ℰ, ∂aₜℰ, ∂Δtₜℰ
    else
        return ∂Ũ⃗ₜℰ, ∂Ũ⃗ₜ₊₁ℰ, ∂aₜℰ
    end
end

struct QuantumStateExponentialIntegrator <: QuantumExponentialIntegrator
    state_components::Vector{Int}
    drive_components::Vector{Int}
    timestep::Union{Real, Int}
    freetime::Bool
    n_drives::Int
    ketdim::Int
    dim::Int
    zdim::Int
    autodiff::Bool
    G::Function

    function QuantumStateExponentialIntegrator(
        sys::AbstractQuantumSystem,
        state_name::Symbol,
        drive_name::Union{Symbol, Tuple{Vararg{Symbol}}},
        traj::NamedTrajectory;
        G::Function=a -> G_bilinear(a, sys.G_drift, sys.G_drives),
        autodiff::Bool=false
    )
        ketdim = size(sys.H_drift, 1)
        dim = 2ketdim

        state_components = traj.components[state_name]

        if drive_name isa Tuple
            drive_components = vcat((traj.components[s] for s ∈ drive_name)...)
        else
            drive_components = traj.components[drive_name]
        end

        n_drives = length(drive_components)

        @assert all(diff(drive_components) .== 1) "controls must be in order"

        freetime = traj.timestep isa Symbol

        if freetime
            timestep = traj.components[traj.timestep][1]
        else
            timestep = traj.timestep
        end

        return new(
            state_components,
            drive_components,
            timestep,
            freetime,
            n_drives,
            ketdim,
            dim,
            traj.dim,
            autodiff,
            G
        )
    end
end

function get_comps(P::QuantumStateExponentialIntegrator, traj::NamedTrajectory)
    if P.freetime
        return P.state_components, P.drive_components, traj.components[traj.timestep]
    else
        return P.state_components, P.drive_components
    end
end

function (integrator::QuantumStateExponentialIntegrator)(
    sys::AbstractQuantumSystem,
    traj::NamedTrajectory;
    state_name::Union{Nothing, Symbol}=nothing,
    drive_name::Union{Nothing, Symbol, Tuple{Vararg{Symbol}}}=nothing,
    G::Function=integrator.G,
    autodiff::Bool=integrator.autodiff
)
    @assert !isnothing(state_name) "state_name must be provided"
    @assert !isnothing(drive_name) "drive_name must be provided"
    return QuantumStateExponentialIntegrator(
        sys,
        state_name,
        drive_name,
        traj;
        G=G,
        autodiff=autodiff
    )
end

# ------------------------------ Integrator --------------------------------- #

@views function (ℰ::QuantumStateExponentialIntegrator)(
    zₜ::AbstractVector,
    zₜ₊₁::AbstractVector,
    t::Int
)
    ψ̃ₜ₊₁ = zₜ₊₁[ℰ.state_components]
    ψ̃ₜ = zₜ[ℰ.state_components]
    aₜ = zₜ[ℰ.drive_components]

    if ℰ.freetime
        Δtₜ = zₜ[ℰ.timestep]
    else
        Δtₜ = ℰ.timestep
    end

    Gₜ = ℰ.G(aₜ)


    return ψ̃ₜ₊₁ - expv(Δtₜ, Gₜ, ψ̃ₜ)
end

@views function jacobian(
    ℰ::QuantumStateExponentialIntegrator,
    zₜ::AbstractVector,
    zₜ₊₁::AbstractVector,
    t::Int
)
    # get the state and control vectors
    ψ̃ₜ = zₜ[ℰ.state_components]
    aₜ = zₜ[ℰ.drive_components]

    # obtain the timestep
    if ℰ.freetime
        Δtₜ = zₜ[ℰ.timestep]
    else
        Δtₜ = ℰ.timestep
    end

    # compute the generator
    Gₜ = ℰ.G(aₜ)

    expGₜ = hermitian_exp(Δtₜ * Gₜ)

    ∂ψ̃ₜ₊₁ℰ = sparse(I, ℰ.dim, ℰ.dim)
    ∂ψ̃ₜℰ = -expGₜ

    ∂aₜℰ = -ForwardDiff.jacobian(
        a -> expv(Δtₜ, ℰ.G(a), ψ̃ₜ),
        aₜ
    )

    if ℰ.freetime
        ∂Δtₜℰ = -Gₜ * expGₜ * ψ̃ₜ
        return ∂ψ̃ₜℰ, ∂ψ̃ₜ₊₁ℰ, ∂aₜℰ, ∂Δtₜℰ
    else
        return ∂ψ̃ₜℰ, ∂ψ̃ₜ₊₁ℰ, ∂aₜℰ
    end
end

# ******************************************************************************* #

@testitem "testing UnitaryExponentialIntegrator" begin
    using NamedTrajectories
    using ForwardDiff

    T = 100
    H_drift = GATES[:Z]
    H_drives = [GATES[:X], GATES[:Y]]
    n_drives = length(H_drives)

    system = QuantumSystem(H_drift, H_drives)

    U_init = GATES[:I]
    U_goal = GATES[:X]

    Ũ⃗_init = operator_to_iso_vec(U_init)
    Ũ⃗_goal = operator_to_iso_vec(U_goal)

    dt = 0.1

    Z = NamedTrajectory(
        (
            Ũ⃗ = unitary_geodesic(U_goal, T),
            a = randn(n_drives, T),
            da = randn(n_drives, T),
            Δt = fill(dt, 1, T),
        ),
        controls=(:da,),
        timestep=:Δt,
        goal=(Ũ⃗ = Ũ⃗_goal,)
    )

    ℰ = UnitaryExponentialIntegrator(system, :Ũ⃗, :a, Z)


    ∂Ũ⃗ₜℰ, ∂Ũ⃗ₜ₊₁ℰ, ∂aₜℰ, ∂Δtₜℰ = jacobian(ℰ, Z[1].data, Z[2].data, 1)

    ∂ℰ_forwarddiff = ForwardDiff.jacobian(
        zz -> ℰ(zz[1:Z.dim], zz[Z.dim+1:end], 1),
        [Z[1].data; Z[2].data]
    )

    @test ∂Ũ⃗ₜℰ ≈ ∂ℰ_forwarddiff[:, 1:ℰ.dim]
    @test ∂Ũ⃗ₜ₊₁ℰ ≈ ∂ℰ_forwarddiff[:, Z.dim .+ (1:ℰ.dim)]
    @test ∂aₜℰ ≈ ∂ℰ_forwarddiff[:, Z.components.a]
    @test ∂Δtₜℰ ≈ ∂ℰ_forwarddiff[:, Z.components.Δt]
end

@testitem "testing QuantumStateExponentialIntegrator" begin
    using NamedTrajectories
    using ForwardDiff

    T = 100
    H_drift = GATES[:Z]
    H_drives = [GATES[:X], GATES[:Y]]
    n_drives = length(H_drives)

    system = QuantumSystem(H_drift, H_drives)

    U_init = GATES[:I]
    U_goal = GATES[:X]

    ψ̃_init = ket_to_iso(ket_from_string("g", [2]))
    ψ̃_goal = ket_to_iso(ket_from_string("e", [2]))

    dt = 0.1

    Z = NamedTrajectory(
        (
            ψ̃ = linear_interpolation(ψ̃_init, ψ̃_goal, T),
            a = randn(n_drives, T),
            da = randn(n_drives, T),
            Δt = fill(dt, 1, T),
        ),
        controls=(:da,),
        timestep=:Δt,
        goal=(ψ̃ = ψ̃_goal,)
    )

    ℰ = QuantumStateExponentialIntegrator(system, :ψ̃, :a, Z)
    ∂ψ̃ₜℰ, ∂ψ̃ₜ₊₁ℰ, ∂aₜℰ, ∂Δtₜℰ = jacobian(ℰ, Z[1].data, Z[2].data, 1)

    ∂ℰ_forwarddiff = ForwardDiff.jacobian(
        zz -> ℰ(zz[1:Z.dim], zz[Z.dim+1:end], 1),
        [Z[1].data; Z[2].data]
    )

    @test ∂ψ̃ₜℰ ≈ ∂ℰ_forwarddiff[:, 1:ℰ.dim]
    @test ∂ψ̃ₜ₊₁ℰ ≈ ∂ℰ_forwarddiff[:, Z.dim .+ (1:ℰ.dim)]
    @test ∂aₜℰ ≈ ∂ℰ_forwarddiff[:, Z.components.a]
    @test ∂Δtₜℰ ≈ ∂ℰ_forwarddiff[:, Z.components.Δt]
end
