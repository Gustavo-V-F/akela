#!/bin/sh
# Waits for the GitHub Actions run of commit $1 pushed to ref $2 on the mirror, and fails if it fails.
# Needs gh and GH_TOKEN (read access to the public mirror is enough).
set -eu
sha=$1 ref=$2
repo=Gustavo-V-F/akela
name=${ref#refs/heads/}
name=${name#refs/tags/}

id=""
for _ in $(seq 60); do
    id=$(gh run list --repo "$repo" --workflow ci.yml --event push --commit "$sha" --branch "$name" \
        --limit 1 --json databaseId --jq '.[0].databaseId // empty')
    [ -z "$id" ] || break
    sleep 5
done
[ -n "$id" ] || { echo "FAIL: no GitHub Actions run for $sha on $name after 5 minutes"; exit 1; }

echo "GitHub run: https://github.com/$repo/actions/runs/$id"
gh run watch "$id" --repo "$repo" --exit-status --interval 30
