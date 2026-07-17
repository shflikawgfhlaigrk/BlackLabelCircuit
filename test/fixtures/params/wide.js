// Fixture for the long-parameter-list maintainability rule.
// `sixArgs` is over the >=6 threshold and must flag; `fiveArgs` sits at 5 and
// must stay silent. `withGeneric` proves a comma inside a generic type does NOT
// inflate the count (still 5 params, silent).
export function sixArgs(alpha, beta, gamma, delta, epsilon, zeta) {
  return alpha + beta + gamma + delta + epsilon + zeta;
}

export function fiveArgs(alpha, beta, gamma, delta, epsilon) {
  return alpha + beta + gamma + delta + epsilon;
}

export function withGeneric(a, b, c, d, map) {
  return [a, b, c, d, map];
}
