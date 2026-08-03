#!/usr/bin/env bash
exec python3 "$(dirname "$0")/../parser.py" --model "$(basename "$0" .sh)"
