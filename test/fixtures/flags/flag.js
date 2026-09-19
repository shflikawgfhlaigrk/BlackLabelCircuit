// Fixture for the boolean-flag (boolean-trap) maintainability rule.
// `twoFlags` carries two boolean-default params and must flag at the >=2
// threshold. `oneFlag` has a single boolean default (like Circuit's own
// `loadGraph(preservePositions = false)`) and must stay silent. `noFlags` has
// none. `comparisonDefault` proves a numeric default and a name that merely
// contains "true"/"false" never register as flags.
export function twoFlags(data, verbose = false, dryRun = true) {
  return [data, verbose, dryRun];
}

export function oneFlag(data, verbose = false) {
  return [data, verbose];
}

export function noFlags(a, b, c) {
  return a + b + c;
}

export function comparisonDefault(a, limit = 10, truthy = 3) {
  return a + limit + truthy;
}
