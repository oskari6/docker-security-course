#!/bin/sh
set -e

if [ "$#" -ne 2 ]; then
  echo "Usage: ./builder.sh <github-repo> <docker-image>"
  exit 1
fi

repo_dir=$(mktemp -d)
trap 'rm -rf "$repo_dir"' EXIT

git clone "https://github.com/$1" "$repo_dir"
docker build -t "$2" "$repo_dir"
docker push "$2"
