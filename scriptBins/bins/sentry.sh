# The token is for Koordinates' self-hosted Sentry; an env token carries
# no host, so pin it here (otherwise the CLI assumes sentry.io and rejects
# the matching .sentryclirc).
export SENTRY_URL=https://sentry-live2.kx.gd
# SENTRY_FORCE_ENV_TOKEN makes the injected token win over any stored
# OAuth login, so 1Password is the single source of truth (like bk).
export SENTRY_FORCE_ENV_TOKEN=1
# Assign then export separately (shellcheck SC2155); see bk.sh.
SENTRY_AUTH_TOKEN="$(op-cached read --account koordinates.1password.com "op://Employee/sentry-api-token/api-token")"
export SENTRY_AUTH_TOKEN
# Bare `sentry` resolves to the sentry package (prepended via runtimeInputs),
# not this wrapper, which shares the name but sits later on PATH.
exec sentry "$@"
