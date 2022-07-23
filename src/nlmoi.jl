module NLMOI

using ..Evaluators

using MathOptInterface
const MOI = MathOptInterface


MOI.initialize(::AbstractPICOEvaluator, features) = nothing


function MOI.features_available(evaluator::AbstractPICOEvaluator)
    if evaluator.eval_hessian
        return [:Grad, :Jac, :Hess]
    else
        return [:Grad, :Jac]
    end
end


# objective and gradient

function MOI.eval_objective(evaluator::AbstractPICOEvaluator, Z)
    return evaluator.objective.L(Z)
end

function MOI.eval_objective_gradient(evaluator::AbstractPICOEvaluator, ∇, Z)
    ∇ .= evaluator.objective.∇L(Z)
    return nothing
end


# constraints and Jacobian

function MOI.eval_constraint(evaluator::AbstractPICOEvaluator, g, Z)
    g .= evaluator.dynamics.F(Z)
    return nothing
end

function MOI.jacobian_structure(evaluator::AbstractPICOEvaluator)
    return evaluator.dynamics.∇F_structure
end

function MOI.eval_constraint_jacobian(evaluator::AbstractPICOEvaluator, J, Z)
    ∇s = evaluator.dynamics.∇F(Z)
    for (k, ∇ₖ) in enumerate(∇s)
        J[k] = ∇ₖ
    end
    return nothing
end


# Hessian of the Lagrangian

function MOI.hessian_lagrangian_structure(evaluator::AbstractPICOEvaluator)
    structure = vcat(evaluator.objective.∇²L_structure, evaluator.dynamics.∇²F_structure)
    return structure
end

function MOI.eval_hessian_lagrangian(evaluator::AbstractPICOEvaluator, H, Z, σ, μ)

    σ∇²Ls = σ * evaluator.objective.∇²L(Z)

    for (k, σ∇²Lₖ) in enumerate(σ∇²Ls)
        H[k] = σ∇²Lₖ
    end

    μ∇²Fs = evaluator.dynamics.∇²F(Z, μ)

    offset = length(evaluator.objective.∇²L_structure)

    for (k, μ∇²Fₖ) in enumerate(μ∇²Fs)
        H[offset + k] = μ∇²Fₖ
    end

    return nothing
end

end
