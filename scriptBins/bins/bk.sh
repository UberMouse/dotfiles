export BUILDKITE_ORGANIZATION_SLUG="koordinates"
# Assign then export separately so a failing op-cached (errexit) aborts here
# rather than being masked by export's own exit status (shellcheck SC2155).
BUILDKITE_API_TOKEN="$(op-cached read --account koordinates.1password.com "op://Employee/buildkite-api-token/api-token")"
export BUILDKITE_API_TOKEN
# Bare `bk` resolves to buildkite-cli (prepended via runtimeInputs), not this
# wrapper, which shares the name but sits later on PATH.
exec bk "$@"
