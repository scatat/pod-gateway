#!/bin/bash

# We use CONFIG env var to as the actual config
config=$CONFIG

# Load main settings
. /default_config/settings.sh
. /${config}/settings.sh

echo "copying /etc/resolv.conf to ${RESOLV_CONF_COPY}"
cp /etc/resolv.conf ${RESOLV_CONF_COPY}

exit 0