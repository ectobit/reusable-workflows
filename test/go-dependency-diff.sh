#!/bin/sh
set -eu

repo_root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/go-dependency-diff.yaml"
test_case="${1:-all}"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

diff_script="$tmp_root/go-dependency-diff.sh"
awk '
  $0 == "        id: diff" { found_step = 1; next }
  found_step && $0 == "        run: |" { found_run = 1; next }
  found_run && $0 ~ /^      - name:/ { exit }
  found_run { sub(/^          /, ""); print }
' "$workflow" >"$diff_script"

if [ ! -s "$diff_script" ]; then
  echo "Could not extract the dependency diff script from $workflow" >&2
  exit 1
fi

new_repo() {
  name="$1"
  repo="$tmp_root/$name"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf '%s\n' "$repo"
}

write_go_mod() {
  path="$1"
  module="$2"
  version="$3"
  dependency="$4"

  mkdir -p "$(dirname "$path")"
  {
    echo "module $module"
    echo
    echo "go 1.26.5"
    if [ -n "$dependency" ]; then
      echo
      echo "require example.com/dependency $version"
    fi
  } >"$path"
}

commit_all() {
  repo="$1"
  message="$2"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "$message"
}

run_diff() {
  repo="$1"
  base_ref="$2"
  head_ref="$3"
  event_base_sha="$4"
  event_head_sha="$5"
  go_mod_file="$6"
  output="$7"
  summary="$8"

  (
    cd "$repo"
    INPUT_BASE_REF="$base_ref" \
      INPUT_HEAD_REF="$head_ref" \
      INPUT_GO_MOD_FILE="$go_mod_file" \
      EVENT_BASE_SHA="$event_base_sha" \
      EVENT_HEAD_SHA="$event_head_sha" \
      GITHUB_SHA="$(git rev-parse HEAD)" \
      GITHUB_OUTPUT="$output" \
      GITHUB_STEP_SUMMARY="$summary" \
      GOTOOLCHAIN=local \
      bash "$diff_script"
  )
}

assert_output_value() {
  output="$1"
  name="$2"
  expected="$3"
  actual="$(sed -n "s/^${name}=//p" "$output")"

  if [ "$actual" != "$expected" ]; then
    echo "Expected $name=$expected, got $actual" >&2
    exit 1
  fi
}

test_pull_request_uses_merge_base() {
  repo="$(new_repo merge-base)"
  write_go_mod "$repo/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base

  git -C "$repo" switch -q -c feature
  echo feature >"$repo/feature.txt"
  commit_all "$repo" feature
  feature_sha="$(git -C "$repo" rev-parse HEAD)"

  git -C "$repo" switch -q main
  write_go_mod "$repo/go.mod" example.com/app v1.1.0 yes
  commit_all "$repo" main-update
  main_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" switch -q feature

  output="$tmp_root/merge-base.output"
  summary="$tmp_root/merge-base.summary"
  run_diff "$repo" '' '' "$main_sha" "$feature_sha" go.mod "$output" "$summary"
  assert_output_value "$output" has_changes false
}

test_missing_base_is_empty() {
  repo="$(new_repo missing-base)"
  echo base >"$repo/README.md"
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" add-module
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/missing-base.output"
  summary="$tmp_root/missing-base.summary"
  run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary"
  report="$(sed -n 's/^report_json=//p' "$output")"
  actual="$(printf '%s' "$report" | jq -r '[.counts.added, .counts.removed, .counts.updated] | join(",")')"
  [ "$actual" = '1,0,0' ] || {
    echo "Expected one added dependency, got $actual" >&2
    exit 1
  }
}

test_missing_head_is_empty() {
  repo="$(new_repo missing-head)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  git -C "$repo" rm -q backend/go.mod
  commit_all "$repo" remove-module
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/missing-head.output"
  summary="$tmp_root/missing-head.summary"
  run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary"
  report="$(sed -n 's/^report_json=//p' "$output")"
  actual="$(printf '%s' "$report" | jq -r '[.counts.added, .counts.removed, .counts.updated] | join(",")')"
  [ "$actual" = '0,1,0' ] || {
    echo "Expected one removed dependency, got $actual" >&2
    exit 1
  }
}

test_both_missing_fails_clearly() {
  repo="$(new_repo both-missing)"
  echo base >"$repo/README.md"
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  echo head >>"$repo/README.md"
  commit_all "$repo" head
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/both-missing.output"
  summary="$tmp_root/both-missing.summary"
  error="$tmp_root/both-missing.error"
  if run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary" 2>"$error"; then
    echo "Expected missing module files to fail" >&2
    exit 1
  fi
  grep -q 'does not exist at either commit' "$error" || {
    echo "Expected a clear both-missing error" >&2
    cat "$error" >&2
    exit 1
  }
}

test_directory_path_fails_clearly() {
  repo="$(new_repo directory-path)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/directory-path.output"
  summary="$tmp_root/directory-path.summary"
  error="$tmp_root/directory-path.error"
  if run_diff "$repo" "$sha" "$sha" '' '' backend "$output" "$summary" 2>"$error"; then
    echo "Expected a directory module path to fail" >&2
    exit 1
  fi
  grep -q 'is not a file at commit' "$error" || {
    echo "Expected a clear non-file error" >&2
    cat "$error" >&2
    exit 1
  }
}

test_plain_branch_falls_back_to_origin() {
  repo="$(new_repo remote-branch)"
  write_go_mod "$repo/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" update-ref refs/remotes/origin/main "$sha"
  git -C "$repo" switch -q -c feature
  git -C "$repo" branch -q -D main

  output="$tmp_root/remote-branch.output"
  summary="$tmp_root/remote-branch.summary"
  run_diff "$repo" main HEAD '' '' go.mod "$output" "$summary"
  assert_output_value "$output" has_changes false
}

test_missing_jq_fails_clearly() {
  bin="$tmp_root/bin"
  mkdir -p "$bin"
  ln -s "$(command -v git)" "$bin/git"
  ln -s "$(command -v go)" "$bin/go"
  error="$tmp_root/missing-jq.error"

  if PATH="$bin" \
    INPUT_BASE_REF=HEAD \
    INPUT_HEAD_REF=HEAD \
    INPUT_GO_MOD_FILE=go.mod \
    EVENT_BASE_SHA='' \
    EVENT_HEAD_SHA='' \
    GITHUB_SHA=HEAD \
    GITHUB_OUTPUT="$tmp_root/missing-jq.output" \
    GITHUB_STEP_SUMMARY="$tmp_root/missing-jq.summary" \
    GOTOOLCHAIN=local \
    /bin/bash "$diff_script" 2>"$error"; then
    echo "Expected a missing jq command to fail" >&2
    exit 1
  fi

  grep -q 'Missing required command: jq' "$error" || {
    echo "Expected a clear missing-jq error" >&2
    cat "$error" >&2
    exit 1
  }
}

run_test() {
  case "$1" in
    merge-base) test_pull_request_uses_merge_base ;;
    missing-base) test_missing_base_is_empty ;;
    missing-head) test_missing_head_is_empty ;;
    both-missing) test_both_missing_fails_clearly ;;
    directory-path) test_directory_path_fails_clearly ;;
    remote-branch) test_plain_branch_falls_back_to_origin ;;
    missing-jq) test_missing_jq_fails_clearly ;;
    *)
      echo "Unknown test case: $1" >&2
      exit 1
      ;;
  esac
}

if [ "$test_case" = all ]; then
  for name in merge-base missing-base missing-head both-missing directory-path remote-branch missing-jq; do
    run_test "$name"
  done
else
  run_test "$test_case"
fi
