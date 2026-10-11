#!/usr/bin/env bash
# Generates a random proxy URI prefix (16 lowercase base32 characters, 80 bits),
# the same format upstream tproxy-server uses.
head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z' | tr -d '=\n'
echo
