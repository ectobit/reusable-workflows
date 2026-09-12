#!/usr/bin/env python3
"""Execute workflow shell steps against isolated tools and fixture projects."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    return yaml.safe_load((ROOT / '.github/workflows' / name).read_text())


def steps(name):
    jobs = workflow(name)['jobs']
    return {s['name']: s for j in jobs.values() for s in j.get('steps', []) if 'name' in s}


class RunnerToolsContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        BUN_VERSION='1.4.2', PLAYWRIGHT_VERSION='1.63.0',
                        GITHUB_OUTPUT=str(self.root / 'outputs'),
                        TOOL_LOG=str(self.root / 'tool-log'))
        self.env.pop('BUILDX_BUILDER', None)
        (self.root / 'package.json').write_text('{"packageManager":"bun@1.4.2"}')

    def tool(self, name, script):
        p = self.bin / name
        p.write_text('#!/bin/sh\nset -eu\n' + script)
        p.chmod(0o755)

    def run_step(self, file, name, **env):
        return subprocess.run(['bash', '-eo', 'pipefail', '-c', steps(file)[name]['run']],
                              cwd=self.root, env=dict(self.env, **env),
                              capture_output=True, text=True)

    def test_bun_version_and_project_contract(self):
        self.tool('bun', 'echo "${TEST_BUN_VERSION:-1.4.2}"\n')
        self.assertEqual(self.run_step('frontend-check.yaml', 'Verify Bun toolchain').returncode, 0)
        self.assertNotEqual(self.run_step('frontend-check.yaml', 'Verify Bun toolchain',
                                         TEST_BUN_VERSION='1.4.0').returncode, 0)
        (self.root / 'package.json').write_text('{"packageManager":"bun@1.4.0"}')
        result = self.run_step('frontend-check.yaml', 'Verify Bun toolchain')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Update and validate the project toolchain first', result.stderr)

    def test_playwright_rejects_mismatched_locked_version(self):
        module = self.root / 'node_modules/playwright-core'
        module.mkdir(parents=True)
        package = module / 'package.json'
        package.write_text('{"version":"1.63.0"}')
        self.assertEqual(self.run_step('frontend-check.yaml', 'Verify Playwright compatibility',
                                      PREINSTALLED_TOOLS='false').returncode, 0)
        package.write_text('{"version":"1.62.0"}')
        result = self.run_step('frontend-check.yaml', 'Verify Playwright compatibility',
                               PREINSTALLED_TOOLS='false')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match workflow', result.stderr)

    def test_caller_commands_fail_closed(self):
        for step, key in [('Prepare', 'PREPARE_COMMAND'), ('Run checks', 'CHECK_COMMAND'),
                          ('Run repository-root checks', 'ROOT_CHECK_COMMAND')]:
            self.assertEqual(self.run_step('frontend-check.yaml', step, **{key: 'exit 23'}).returncode, 23)
            self.assertNotEqual(self.run_step('frontend-check.yaml', step,
                                             **{key: 'false | true'}).returncode, 0)
            self.assertEqual(self.run_step('frontend-check.yaml', step,
                                          **{key: 'printf "%s" "literal $(printf value)"'}).stdout,
                             'literal value')
        definitions = steps('frontend-check.yaml')
        self.assertNotIn('working-directory', definitions['Run repository-root checks'])
        self.assertEqual(definitions['Run checks']['working-directory'], '${{ inputs.working-directory }}')

    def test_builder_requires_name_and_capabilities(self):
        self.tool('docker', '''printf '%s\n' "$*" >> "$TOOL_LOG"
if [ "$2" = version ]; then echo 'github.com/docker/buildx v0.37.1'; exit 0; fi
printf '%s\n' "$TEST_BUILDER_INFO"
''')
        info = 'Name: fixture\nPlatforms: linux/arm64*, linux/amd64, linux/amd64/v2\n'
        args = dict(REQUESTED_PLATFORMS='linux/amd64,linux/arm64', TEST_BUILDER_INFO=info)
        self.assertNotEqual(self.run_step('buildx.yaml', 'Verify runner builder', **args).returncode, 0)
        args['BUILDX_BUILDER'] = 'fixture-builder'
        result = self.run_step('buildx.yaml', 'Verify runner builder', **args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'outputs').read_text(), 'name=fixture-builder\n')
        args['REQUESTED_PLATFORMS'] = 'linux/s390x'
        self.assertNotEqual(self.run_step('buildx.yaml', 'Verify runner builder', **args).returncode, 0)
        args['REQUESTED_PLATFORMS'] = ''
        self.assertNotEqual(self.run_step('buildx.yaml', 'Verify runner builder', **args).returncode, 0)
        log = (self.root / 'tool-log').read_text()
        self.assertNotIn('create', log)
        self.assertNotIn('rm ', log)

    def test_hadolint_preserves_flags_and_failure(self):
        self.tool('hadolint', '''if [ "$1" = --version ]; then echo "Haskell Dockerfile Linter ${TEST_HADOLINT_VERSION:-2.15.1}"; exit 0; fi
printf '%s\n' "$HADOLINT_IGNORE" "$@" > "$TOOL_LOG"
exit "${TEST_LINT_STATUS:-0}"
''')
        env = dict(DOCKERFILE='a directory/Dockerfile', HADOLINT_FAILURE_THRESHOLD='warning',
                   HADOLINT_IGNORE='DL3008,SC2086')
        result = self.run_step('buildx.yaml', 'Lint Dockerfile with preinstalled Hadolint', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'tool-log').read_text().splitlines(),
                         ['DL3008,SC2086', '--failure-threshold', 'warning', 'a directory/Dockerfile'])
        self.assertEqual(self.run_step('buildx.yaml', 'Lint Dockerfile with preinstalled Hadolint',
                                      **env, TEST_LINT_STATUS='1').returncode, 1)
        self.assertNotEqual(self.run_step('buildx.yaml', 'Lint Dockerfile with preinstalled Hadolint',
                                         **env, TEST_HADOLINT_VERSION='2.14.0').returncode, 0)

    def test_helm_rejects_incompatible_runner(self):
        self.tool('helm', 'echo "${TEST_HELM_VERSION:-v4.3.0}"\n')
        self.assertEqual(self.run_step('chart.yaml', 'Verify preinstalled Helm').returncode, 0)
        self.assertNotEqual(self.run_step('chart.yaml', 'Verify preinstalled Helm',
                                         TEST_HELM_VERSION='v3.22.0').returncode, 0)

    def test_compatibility_and_security_gates(self):
        for name in ['chart.yaml', 'buildx.yaml', 'frontend-check.yaml']:
            data = workflow(name)
            call = data.get('on', data.get(True))['workflow_call']
            self.assertIs(call['inputs']['preinstalled-tools']['default'], False)
        build = steps('buildx.yaml')
        for name in ['Set up QEMU', 'Set up Docker Buildx']:
            self.assertEqual(build[name]['if'], '${{ !inputs.reuse-runner-builder }}')
        for step in build.values():
            if step.get('uses', '').startswith('docker/build-push-action@'):
                self.assertEqual(step['with']['builder'], '${{ steps.runner-builder.outputs.name }}')
        scan = build['Scan image with Grype']['with']
        self.assertEqual(scan['fail-build'], '${{ inputs.grype-fail-build }}')
        self.assertEqual(scan['severity-cutoff'], '${{ inputs.grype-severity-cutoff }}')
        self.assertEqual(scan['vex'], '${{ inputs.grype-vex }}')
        self.assertIn('always()', build['Upload Grype SARIF artifact']['if'])
        frontend = steps('frontend-check.yaml')
        self.assertEqual(frontend['Install dependencies']['run'], 'bun install --frozen-lockfile')
        self.assertEqual(frontend['Install Playwright browsers']['if'],
                         '${{ inputs.browser-tests && !inputs.preinstalled-tools }}')
        self.assertIn('chromium webkit', frontend['Install Playwright browsers']['run'])
        self.assertIn('always()', frontend['Upload results']['if'])


if __name__ == '__main__':
    unittest.main()
