#!/bin/sh
set -eu

cd elixir
exec mise exec -- mix test
