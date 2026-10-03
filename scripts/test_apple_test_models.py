#!/usr/bin/env python3
"""Hermetic regression checks for downloading and embedding Apple test fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class AppleFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        for name in ('fetch_apple_test_models.sh', 'embed_apple_test_models.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.cache = self.root / '.apple-test-fixtures/FastViTT8F16.mlpackage'
        self.archive = self.root / 'upstream.zip'
        content = b'controlled fixture bytes'
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('FastViTT8F16.mlpackage/model.bin', content)
        manifest = {'models': [{
            'name': 'FastViTT8F16',
            'installPath': '.apple-test-fixtures/FastViTT8F16.mlpackage',
            'url': 'https://example.invalid/model.zip',
            'archiveSha256': hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            'archiveMember': 'FastViTT8F16.mlpackage',
            'files': {'model.bin': hashlib.sha256(content).hexdigest()},
        }]}
        (self.root / 'scripts/apple_test_models.json').write_text(json.dumps(manifest))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.stub('curl', '''#!/bin/bash
set -eu
[[ "${NO_DOWNLOAD:-0}" != 1 ]] || exit 99
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then cp "$TEST_ARCHIVE" "$2"; exit; fi
  shift
done
exit 98
''')
        self.stub('xcrun', '''#!/bin/bash
set -eu
[[ "$1" == coremlcompiler && "$2" == compile ]]
mkdir -p "$4/FastViTT8F16.mlmodelc"
echo compiled > "$4/FastViTT8F16.mlmodelc/model.bin"
''')
        self.resources = self.root / 'products/Test.app'
        self.resources.mkdir(parents=True)
        notices = self.root / 'ios/TestFixtures/FastViT'
        notices.mkdir(parents=True)
        for name in ('FastViT-LICENSE.txt', 'FastViT-ACKNOWLEDGEMENTS.txt'):
            (notices / name).write_text(name)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        TEST_ARCHIVE=str(self.archive), TARGET_BUILD_DIR=str(self.root / 'products'),
                        UNLOCALIZED_RESOURCES_FOLDER_PATH='Test.app', CONFIGURATION='Debug',
                        AIA_INCLUDE_TEST_FIXTURES='NO')

    def stub(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, name, *args, success=True, **env):
        result = subprocess.run([str(self.root / 'scripts' / name), *args],
                                env=dict(self.env, **env), capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_missing_cache_fails_offline_verification(self):
        self.run_script('fetch_apple_test_models.sh', '--verify', success=False)
        self.assertFalse(self.cache.exists())

    def test_fetch_and_cached_offline_reuse(self):
        self.run_script('fetch_apple_test_models.sh')
        self.run_script('fetch_apple_test_models.sh', NO_DOWNLOAD='1')
        self.run_script('fetch_apple_test_models.sh', '--verify', NO_DOWNLOAD='1')
        self.assertEqual((self.cache / 'model.bin').read_bytes(), b'controlled fixture bytes')

    def test_corruption_repaired_but_bad_download_rejected(self):
        self.run_script('fetch_apple_test_models.sh')
        (self.cache / 'model.bin').write_bytes(b'corrupt')
        self.run_script('fetch_apple_test_models.sh', '--verify', success=False)
        self.run_script('fetch_apple_test_models.sh')
        (self.cache / 'model.bin').write_bytes(b'keep until verified replacement')
        self.archive.write_bytes(b'bad archive')
        self.run_script('fetch_apple_test_models.sh', success=False)
        self.assertEqual((self.cache / 'model.bin').read_bytes(), b'keep until verified replacement')

    def test_normal_build_cleans_stale_fixture_without_downloading(self):
        (self.resources / 'FastViTT8F16.mlmodelc').mkdir()
        (self.resources / 'FastViT-LICENSE.txt').touch()
        self.run_script('embed_apple_test_models.sh', NO_DOWNLOAD='1')
        self.assertFalse((self.resources / 'FastViTT8F16.mlmodelc').exists())
        self.assertFalse((self.resources / 'FastViT-LICENSE.txt').exists())
        self.assertFalse(self.cache.exists())

    def test_opt_in_requires_fixture_and_debug_configuration(self):
        self.run_script('embed_apple_test_models.sh', AIA_INCLUDE_TEST_FIXTURES='YES', success=False)
        self.run_script('fetch_apple_test_models.sh')
        self.run_script('embed_apple_test_models.sh', AIA_INCLUDE_TEST_FIXTURES='YES',
                        CONFIGURATION='Release', success=False)
        self.assertFalse((self.resources / 'FastViTT8F16.mlmodelc').exists())

    def test_opt_in_embeds_compiled_fixture_and_notices_offline(self):
        self.run_script('fetch_apple_test_models.sh')
        self.run_script('embed_apple_test_models.sh', AIA_INCLUDE_TEST_FIXTURES='YES', NO_DOWNLOAD='1')
        self.assertTrue((self.resources / 'FastViTT8F16.mlmodelc/model.bin').is_file())
        for name in ('FastViT-LICENSE.txt', 'FastViT-ACKNOWLEDGEMENTS.txt'):
            self.assertEqual((self.resources / name).read_text(), name)


if __name__ == '__main__':
    unittest.main()
