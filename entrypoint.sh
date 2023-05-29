#!/bin/sh

# Fixup the passwd file, in case we're on OpenShift
if ! whoami > /dev/null 2>&1; then
  if [ "$(id -u)" -ne 5050 ]; then
    if [ -w /etc/passwd ]; then
      echo "${USER_NAME:-pgadminr}:x:$(id -u):0:${USER_NAME:-pgadminr} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi
fi

# Populate config_distro.py. This has some default config, as well as anything
# provided by the user through the PGADMIN_CONFIG_* environment variables.
# Only update the file on first launch. The empty file is created during the
# container build so it can have the required ownership.
if [ "$(wc -m /pgadmin4/config_distro.py | awk '{ print $1 }')" = "0" ]; then
    cat << EOF > /pgadmin4/config_distro.py
CA_FILE = '/etc/ssl/certs/ca-certificates.crt'
LOG_FILE = '/dev/null'
HELP_PATH = '../../docs'
DEFAULT_BINARY_PATHS = {
        'pg': '/usr/local/pgsql-15',
        'pg-15': '/usr/local/pgsql-15',
        'pg-14': '/usr/local/pgsql-14',
        'pg-13': '/usr/local/pgsql-13',
        'pg-12': '/usr/local/pgsql-12',
        'pg-11': '/usr/local/pgsql-11',
        'pg-10': '/usr/local/pgsql-10'
}
EOF

    # This is a bit kludgy, but necessary as the container uses BusyBox/ash as
    # it's shell and not bash which would allow a much cleaner implementation
    for var in $(env | grep PGADMIN_CONFIG_ | cut -d "=" -f 1); do
        # shellcheck disable=SC2086
        # shellcheck disable=SC2046
        echo ${var#PGADMIN_CONFIG_} = $(eval "echo \$$var") >> /pgadmin4/config_distro.py
    done
fi

if [ ! -f /var/lib/pgadmin/pgadmin4.db ]; then
    if [ -z "${PGADMIN_DEFAULT_EMAIL}" ] || { [ -z "${PGADMIN_DEFAULT_PASSWORD}" ] && [ -z "${PGADMIN_DEFAULT_PASSWORD_FILE}" ]; }; then
        echo 'You need to define the PGADMIN_DEFAULT_EMAIL and PGADMIN_DEFAULT_PASSWORD or PGADMIN_DEFAULT_PASSWORD_FILE environment variables.'
        exit 1
    fi

    if ! echo "${PGADMIN_DEFAULT_EMAIL}" | grep -E "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$" > /dev/null; then
        echo "'${PGADMIN_DEFAULT_EMAIL}' does not appear to be a valid email address. Please reset the PGADMIN_DEFAULT_EMAIL environment variable and try again."
        exit 1
    fi

    # Read secret contents
    if [ -n "${PGADMIN_DEFAULT_PASSWORD_FILE}" ]; then
        PGADMIN_DEFAULT_PASSWORD=$(cat "${PGADMIN_DEFAULT_PASSWORD_FILE}")
        export PGADMIN_DEFAULT_PASSWORD
    fi

    # Set the default username and password in a
    # backwards compatible way
    export PGADMIN_SETUP_EMAIL="${PGADMIN_DEFAULT_EMAIL}"
    export PGADMIN_SETUP_PASSWORD="${PGADMIN_DEFAULT_PASSWORD}"

    # Initialize DB before starting Gunicorn
    # Importing pgadmin4 (from this script) is enough
    /venv/bin/python3 run_pgadmin.py

    export PGADMIN_SERVER_JSON_FILE="${PGADMIN_SERVER_JSON_FILE:-/pgadmin4/servers.json}"

    # Pre-load any required servers
    if [ -f "${PGADMIN_SERVER_JSON_FILE}" ]; then
        # When running in Desktop mode, no user is created
        # so we have to import servers anonymously
        if [ "${PGADMIN_CONFIG_SERVER_MODE}" = "False" ]; then
            /venv/bin/python3 /pgadmin4/setup.py --load-servers "${PGADMIN_SERVER_JSON_FILE}"
        else
            /venv/bin/python3 /pgadmin4/setup.py --load-servers "${PGADMIN_SERVER_JSON_FILE}" --user "${PGADMIN_DEFAULT_EMAIL}"
        fi
    fi
fi

# Setup connection to DataLab-DB
echo "Setting up connection to DataLab-DB"
/venv/bin/python3 /pgadmin4/setup.py --replace --load-servers /pgadmin4/datalab-connection.json --user admin@datalab.com
echo "Connected to DataLab-DB"

# Start Postfix to handle password resets etc.
if [ -z "${PGADMIN_DISABLE_POSTFIX}" ]; then
    sudo /usr/sbin/postfix start
fi

# Get the session timeout from the pgAdmin config. We'll use this (in seconds)
# to define the Gunicorn worker timeout
TIMEOUT=$(cd /pgadmin4 && /venv/bin/python3 -c 'import config; print(config.SESSION_EXPIRATION_TIME * 60 * 60 * 24)')

# NOTE: currently pgadmin can run only with 1 worker due to sessions implementation
# Using --threads to have multi-threaded single-process worker

if [ -n "${PGADMIN_ENABLE_TLS}" ]; then
    exec /venv/bin/gunicorn --limit-request-line "${GUNICORN_LIMIT_REQUEST_LINE:-8190}" --timeout "${TIMEOUT}" --bind "${PGADMIN_LISTEN_ADDRESS:-[::]}:${PGADMIN_LISTEN_PORT:-443}" -w 1 --threads "${GUNICORN_THREADS:-25}" --access-logfile "${GUNICORN_ACCESS_LOGFILE:--}" --keyfile /certs/server.key --certfile /certs/server.cert -c gunicorn_config.py run_pgadmin:app
else
    exec /venv/bin/gunicorn --limit-request-line "${GUNICORN_LIMIT_REQUEST_LINE:-8190}" --timeout "${TIMEOUT}" --bind "${PGADMIN_LISTEN_ADDRESS:-[::]}:${PGADMIN_LISTEN_PORT:-80}" -w 1 --threads "${GUNICORN_THREADS:-25}" --access-logfile "${GUNICORN_ACCESS_LOGFILE:--}" -c gunicorn_config.py run_pgadmin:app
fi

