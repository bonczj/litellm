#!/bin/sh
# ⚠️ KEEP IN SYNC: Changes to docker/prod_entrypoint.sh logic should be reviewed
# This entrypoint is based on prod_entrypoint.sh but simplified for New Relic only

if [ "$SEPARATE_HEALTH_APP" = "1" ]; then
    export LITELLM_ARGS="$@"
    export SUPERVISORD_STOPWAITSECS="${SUPERVISORD_STOPWAITSECS:-3600}"
    # Use New Relic-specific supervisor config
    exec supervisord -c /etc/supervisord_newrelic.conf
fi

# For standard mode, wrap directly with newrelic-admin
exec newrelic-admin run-program litellm "$@"
