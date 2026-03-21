#!/bin/sh
plugins_path='/app/plugins'
echo 'Running setup of each plugin in '
find "$plugins_path" -type f -name "setup.sh" \
  -exec sh -c 'cd "$(dirname "$1")" && sh "$1"' _ {} \;

echo 'Running server'
lapis server development