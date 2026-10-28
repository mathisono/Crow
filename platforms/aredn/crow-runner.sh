#!/bin/sh
# Start the application, not the router library, using the same explicit
# module search path as the procd service.
exec /usr/bin/ucode -L /usr/local/crow /usr/local/crow/crow.uc "$@"
