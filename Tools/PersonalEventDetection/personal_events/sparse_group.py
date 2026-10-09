"""Ported from the local forecasting lab; see PORTING.md."""
import warnings
import numpy as np
from scipy.special import expit

class SparseGroupLogistic:
    """Binary logistic loss + L1 + sqrt(group size)-weighted group L2, solved by proximal gradient.

    Intercept is unpenalized. Coefficients apply to standardized tabular features. This is an
    original logistic implementation inspired by sparse-group regularization, not the paper's
    linear-regression solver or a claim of identical software.
    """
    def __init__(self, strength=.01, l1_ratio=.2, max_iter=2500, tol=1e-6):
        self.strength, self.l1_ratio = strength, l1_ratio
        self.max_iter, self.tol = max_iter, tol

    def fit(self, X, y, groups):
        n, d = X.shape
        self.coef_ = np.zeros(d)
        self.intercept_ = float(np.log((np.sum(y) + .5) / (n - np.sum(y) + .5)))
        design = np.column_stack([X, np.ones(n)])
        # Backtracking avoids a full SVD of a potentially enormous concatenated feature bank.
        # A positive starting bound is increased until it majorizes the smooth logistic loss.
        L = max(.25 * np.mean(design * design), 1e-4)
        w = np.r_[self.coef_, self.intercept_]
        extrapolated, momentum = w.copy(), 1.
        self.converged_ = False
        for iteration in range(self.max_iter):
            logits = design @ extrapolated
            smooth = np.mean(np.logaddexp(0, logits) - y * logits)
            grad = design.T @ (expit(logits) - y) / n
            while True:
                step = 1 / L
                new = extrapolated - step * grad
                threshold = step * self.strength * self.l1_ratio
                new[:-1] = np.sign(new[:-1]) * np.maximum(np.abs(new[:-1]) - threshold, 0)
                for sl in groups.values():
                    norm = np.linalg.norm(new[sl])
                    penalty = step * self.strength * (1 - self.l1_ratio) * np.sqrt(sl.stop - sl.start)
                    new[sl] *= max(0, 1 - penalty / max(norm, 1e-15))
                difference = new - extrapolated
                new_logits = design @ new
                new_smooth = np.mean(np.logaddexp(0, new_logits) - y * new_logits)
                if new_smooth <= smooth + grad @ difference + .5 * L * (difference @ difference) + 1e-12:
                    break
                L *= 2
            if np.linalg.norm(new - w) <= self.tol * max(1, np.linalg.norm(w)):
                self.converged_ = True; w = new; break
            new_momentum = (1 + np.sqrt(1 + 4 * momentum ** 2)) / 2
            extrapolated = new + (momentum - 1) / new_momentum * (new - w)
            momentum = new_momentum
            w = new
        self.n_iter_ = iteration + 1
        self.coef_, self.intercept_ = w[:-1], float(w[-1])
        self.group_norms_ = {g: float(np.linalg.norm(self.coef_[sl])) for g, sl in groups.items()}
        if not self.converged_:
            warnings.warn("Sparse-group solver reached max_iter; inspect convergence before interpreting selection")
        return self

    def predict_proba(self, X):
        p = expit(X @ self.coef_ + self.intercept_)
        return np.column_stack([1 - p, p])

