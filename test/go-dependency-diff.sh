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
  fail_on_changes="${9:-false}"

  if [ -n "$event_base_sha" ]; then
    event_name=pull_request
  else
    event_name=workflow_dispatch
  fi

  (
    cd "$repo"
    INPUT_BASE_REF="$base_ref" \
      INPUT_HEAD_REF="$head_ref" \
      INPUT_GO_MOD_FILE="$go_mod_file" \
      EVENT_BASE_SHA="$event_base_sha" \
      EVENT_HEAD_SHA="$event_head_sha" \
      EVENT_NAME="$event_name" \
      INPUT_FAIL_ON_CHANGES="$fail_on_changes" \
      GITHUB_SHA="$(git rev-parse HEAD)" \
      GITHUB_OUTPUT="$output" \
      GITHUB_STEP_SUMMARY="$summary" \
      GOTOOLCHAIN=local \
      bash "$diff_script"
  )
}

assert_report() {
  output="$1"
  filter="$2"
  description="$3"
  report="$(sed -n 's/^report_json=//p' "$output")"

  if ! printf '%s' "$report" | jq -e "$filter" >/dev/null; then
    echo "Report did not contain $description:" >&2
    printf '%s\n' "$report" >&2
    exit 1
  fi
}

assert_summary_contains() {
  summary="$1"
  expected="$2"

  if ! grep -Fq -- "$expected" "$summary"; then
    echo "Summary did not contain: $expected" >&2
    cat "$summary" >&2
    exit 1
  fi
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

  report="$(sed -n 's/^report_json=//p' "$output")"
  merge_base="$(git -C "$repo" merge-base "$main_sha" "$feature_sha")"
  actual="$(printf '%s' "$report" | jq -r '[.base_is_merge_base, .base_ref_commit, .base_commit] | join(",")')"
  expected="true,$main_sha,$merge_base"
  [ "$actual" = "$expected" ] || {
    echo "Expected merge-base metadata $expected, got $actual" >&2
    exit 1
  }
}

test_explicit_pull_request_base_uses_merge_base() {
  repo="$(new_repo explicit-merge-base)"
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

  output="$tmp_root/explicit-merge-base.output"
  summary="$tmp_root/explicit-merge-base.summary"
  run_diff "$repo" "$main_sha" '' "$main_sha" "$feature_sha" go.mod "$output" "$summary"
  assert_output_value "$output" has_changes false
}

test_existing_module_is_unchanged() {
  repo="$(new_repo unchanged)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  echo unchanged >"$repo/README.md"
  commit_all "$repo" unrelated-change
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/unchanged.output"
  summary="$tmp_root/unchanged.summary"
  run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary"
  assert_output_value "$output" has_changes false
  assert_report "$output" '
    .counts == {base_direct: 1, head_direct: 1, added: 0, removed: 0, updated: 0} and
    .added == [] and .removed == [] and .updated == []
  ' 'an unchanged direct dependency set'
  assert_summary_contains "$summary" '| Updated | 0 |'
  assert_summary_contains "$summary" '_None_'
}

test_existing_module_adds_dependency() {
  repo="$(new_repo added)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  echo 'require example.com/added v1.2.0' >>"$repo/backend/go.mod"
  commit_all "$repo" add-dependency
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/added.output"
  summary="$tmp_root/added.summary"
  run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary"
  assert_output_value "$output" has_changes true
  assert_report "$output" '
    .counts == {base_direct: 1, head_direct: 2, added: 1, removed: 0, updated: 0} and
    .added == [{module: "example.com/added", version: "v1.2.0"}] and
    .removed == [] and .updated == []
  ' 'one added direct dependency'
  assert_summary_contains "$summary" "- \`example.com/added\` \`v1.2.0\`"
}

test_existing_module_removes_dependency() {
  repo="$(new_repo removed)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  echo 'require example.com/removed v1.2.0' >>"$repo/backend/go.mod"
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" remove-dependency
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/removed.output"
  summary="$tmp_root/removed.summary"
  run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary"
  assert_output_value "$output" has_changes true
  assert_report "$output" '
    .counts == {base_direct: 2, head_direct: 1, added: 0, removed: 1, updated: 0} and
    .added == [] and
    .removed == [{module: "example.com/removed", version: "v1.2.0"}] and
    .updated == []
  ' 'one removed direct dependency'
  assert_summary_contains "$summary" "- \`example.com/removed\` \`v1.2.0\`"
}

test_existing_module_updates_dependency() {
  repo="$(new_repo updated)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  write_go_mod "$repo/backend/go.mod" example.com/app v1.1.0 yes
  commit_all "$repo" update-dependency
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/updated.output"
  summary="$tmp_root/updated.summary"
  run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary"
  assert_output_value "$output" has_changes true
  assert_report "$output" '
    .counts == {base_direct: 1, head_direct: 1, added: 0, removed: 0, updated: 1} and
    .added == [] and .removed == [] and
    .updated == [{module: "example.com/dependency", from: "v1.0.0", to: "v1.1.0"}]
  ' 'one updated direct dependency'
  assert_summary_contains "$summary" "- \`example.com/dependency\` \`v1.0.0\` → \`v1.1.0\`"
}

test_fail_on_changes_rejects_dependency_update() {
  repo="$(new_repo fail-on-changes)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  write_go_mod "$repo/backend/go.mod" example.com/app v1.1.0 yes
  commit_all "$repo" update-dependency
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/fail-on-changes.output"
  summary="$tmp_root/fail-on-changes.summary"
  error="$tmp_root/fail-on-changes.error"
  if run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary" true 2>"$error"; then
    echo "Expected fail-on-changes to reject a dependency update" >&2
    exit 1
  fi
  grep -q 'Direct Go dependency changes were detected.' "$error" || {
    echo "Expected a clear dependency-policy error" >&2
    cat "$error" >&2
    exit 1
  }
}

test_fail_on_changes_allows_unchanged_module() {
  repo="$(new_repo fail-on-unchanged)"
  write_go_mod "$repo/backend/go.mod" example.com/app v1.0.0 yes
  commit_all "$repo" base
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  echo unchanged >"$repo/README.md"
  commit_all "$repo" unrelated-change
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  output="$tmp_root/fail-on-unchanged.output"
  summary="$tmp_root/fail-on-unchanged.summary"
  run_diff "$repo" "$base_sha" "$head_sha" '' '' backend/go.mod "$output" "$summary" true
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
    explicit-merge-base) test_explicit_pull_request_base_uses_merge_base ;;
    unchanged) test_existing_module_is_unchanged ;;
    added) test_existing_module_adds_dependency ;;
    removed) test_existing_module_removes_dependency ;;
    updated) test_existing_module_updates_dependency ;;
    fail-on-changes) test_fail_on_changes_rejects_dependency_update ;;
    fail-on-unchanged) test_fail_on_changes_allows_unchanged_module ;;
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
  for name in merge-base explicit-merge-base unchanged added removed updated fail-on-changes fail-on-unchanged missing-base missing-head both-missing directory-path remote-branch missing-jq; do
    run_test "$name"
  done
else
  run_test "$test_case"
fi
