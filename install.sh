#!/bin/bash
# 入口：编译并装到本机和对面那台的 /Applications。参数原样传给 scripts/install.sh（如 --local 只装本机）
exec "$(cd "$(dirname "$0")" && pwd)/scripts/install.sh" "$@"
