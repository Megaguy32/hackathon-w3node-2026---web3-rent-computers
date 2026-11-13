#!/usr/bin/env bash
set -euo pipefail
apptainer exec docker://alpine:3.20 /bin/sh -c 'echo W3Node manual HTCondor test; hostname; uname -a'
