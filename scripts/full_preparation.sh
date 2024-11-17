#!/usr/bin/bash

if [[ "${DNSMASQ_DISSABLED}" == "1" ]]; then
    "/bin/rundnsmasq"
fi

if [[ "${HTTPD_DISSABLED}" == "1" ]]; then
    "/bin/runhttpd"
fi

/bin/runironic
