"""Targeted installer safety tests. All fixtures live under a temporary directory."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location('gaocipan_installer', Path(__file__).parents[1] / 'Scripts/install.py')
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeSystem:
    def __init__(self, applications, fail_installed=False, fail_registration=False):
        self.applications = applications
        self.fail_installed = fail_installed
        self.fail_registration = fail_registration
        self.registration = []

    def ensure_stopped(self):
        pass

    def verify_signature(self, app):
        # Only a test double. Production always runs codesign + exact identifier.
        if self.fail_installed and app == self.applications / MODULE.APP_NAME:
            version = MODULE.bundle_info(app)['CFBundleShortVersionString']
            if version == MODULE.VERSION:
                raise MODULE.InstallError('Injected installed verification failure')

    def copy(self, source, destination):
        if source.is_dir():
            shutil.copytree(source, destination, copy_function=shutil.copy2)
        else:
            shutil.copy2(source, destination)

    def register(self, source, target):
        if self.fail_registration:
            raise MODULE.InstallError('Injected registration failure')
        self.registration.append((source, target))

    def register_restored(self, target):
        self.registration.append(('restored', target))


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='gaocipan-installer-tests-')
        self.root = Path(self.temporary.name).resolve()
        self.apps = self.root / 'Applications'
        self.home = self.root / 'home'
        self.apps.mkdir()
        self.home.mkdir()
        self.source = self.root / 'candidate' / MODULE.APP_NAME
        self.make_app(self.source, MODULE.VERSION, MODULE.BUILD)
        self.archive = self.root / ('GaoCiPan-' + MODULE.VERSION + '-macOS-arm64.zip')
        MODULE.zip_tree(self.source, self.archive, MODULE.inventory(self.source))
        self.locations = MODULE.Locations(self.archive, self.apps, self.home, self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def make_app(self, target, version, build):
        (target / 'Contents/MacOS').mkdir(parents=True)
        (target / 'Contents/Resources/empty').mkdir(parents=True)
        executable = target / 'Contents/MacOS/GaoCiPan'
        executable.write_bytes(b'isolated test executable ' + version.encode())
        executable.chmod(0o755)
        (target / 'Contents/Resources/example').write_bytes(b'non-personal synthetic asset')
        with (target / 'Contents/Info.plist').open('wb') as handle:
            plistlib.dump({'CFBundleIdentifier': MODULE.BUNDLE, 'CFBundleExecutable': MODULE.EXECUTABLE,
                           'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version,
                           'CFBundleVersion': build}, handle)

    def old_app(self):
        self.make_app(self.locations.target, '0.99', '0')
        return MODULE.inventory(self.locations.target)

    def existing_data(self):
        data = self.locations.state_paths()['data']
        (data / 'Attachments').mkdir(parents=True)
        (data / 'Attachments/file').write_bytes(b'synthetic private attachment\x00')
        (data / 'Attachments/file').chmod(0o600)
        (data / 'empty').mkdir(mode=0o700)
        return data, MODULE.inventory(data)

    def assert_no_expanded_temporary_apps(self):
        self.assertEqual(sorted(path.name for path in self.apps.iterdir()), [MODULE.APP_NAME])
        self.assertFalse(any(self.root.glob('gaocipan-install-*')))
        self.assertFalse(any(self.locations.backups.rglob('Previous.app')))

    def test_first_install_does_not_create_business_data(self):
        system = FakeSystem(self.apps)
        result = MODULE.install(self.locations, system)
        self.assertEqual((result['version'], result['build']), ('1.00', '1'))
        self.assertFalse(result['guiVerified'])
        self.assertTrue(result['firstInstall'])
        self.assertFalse(self.locations.state_paths()['data'].exists())
        self.assertEqual(MODULE.inventory(self.source), MODULE.inventory(self.locations.target))
        receipt = json.loads(Path(result['receipt']).read_text())
        self.assertEqual(receipt['status'], 'installed')
        self.assertTrue(receipt['backupVerified'])
        self.assertEqual(len(system.registration), 1)
        self.assert_no_expanded_temporary_apps()

    def test_standard_utf8_chinese_bundle_zip_roundtrip(self):
        # Real zipfile output, not a fabricated ZipInfo: Chinese root names must
        # carry general-purpose bit 11 so standard readers never use CP437.
        with zipfile.ZipFile(self.archive) as archive:
            members = archive.infolist()
            self.assertTrue(members)
            for member in members:
                self.assertTrue(member.flag_bits & 0x800, member.filename)
                self.assertTrue(member.filename == MODULE.APP_NAME + '/'
                                or member.filename.startswith(MODULE.APP_NAME + '/'))
                self.assertNotIn('__MACOSX', member.filename)
            executable = archive.getinfo(MODULE.APP_NAME + '/Contents/MacOS/' + MODULE.EXECUTABLE)
            self.assertEqual(stat.S_IMODE(executable.external_attr >> 16), 0o755)
        extracted = MODULE.extract_zip(self.archive, self.root / 'utf8-roundtrip')
        self.assertEqual(extracted.name, '搞磁盘.app')
        self.assertEqual(MODULE.inventory(extracted), MODULE.inventory(self.source))

    def test_rejected_first_archive_receipt_does_not_block_retry(self):
        # A rejected release may already have an installation receipt. With no
        # business state ever observed, that receipt is not initialization proof.
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('invalid-root/Contents/Info.plist', b'not a release')
        with self.assertRaisesRegex(MODULE.InstallError, 'Unexpected archive root'):
            MODULE.install(self.locations, FakeSystem(self.apps))
        self.assertFalse(self.locations.target.exists())
        self.assertFalse(self.locations.state_paths()['data'].exists())
        prior_receipts = list(self.locations.backups.rglob('install-receipt.json'))
        self.assertEqual(len(prior_receipts), 1)
        prior = json.loads(prior_receipts[0].read_text())
        self.assertEqual(prior['status'], 'failedRestored')
        self.assertTrue(all(value is None for value in prior['stateBefore'].values()))
        self.archive.unlink()
        MODULE.zip_tree(self.source, self.archive, MODULE.inventory(self.source))
        result = MODULE.install(self.locations, FakeSystem(self.apps))
        self.assertTrue(result['firstInstall'])
        self.assertFalse(self.locations.state_paths()['data'].exists())
        self.assertEqual(len(list(self.locations.backups.rglob('install-receipt.json'))), 2)
        self.assertEqual(MODULE.inventory(self.locations.target), MODULE.inventory(self.source))
        self.assert_no_expanded_temporary_apps()

    def test_update_verifies_all_data_and_archived_old_app(self):
        old = self.old_app()
        data, data_before = self.existing_data()
        result = MODULE.install(self.locations, FakeSystem(self.apps))
        backup = Path(result['receipt']).parent
        self.assertEqual(MODULE.inventory(data), data_before)
        self.assertEqual(MODULE.inventory(backup / 'State-data'), data_before)
        restored = MODULE.extract_zip(backup / 'Previous.app.zip', self.root / 'restore-check')
        self.assertEqual(MODULE.inventory(restored), old)
        self.assert_no_expanded_temporary_apps()

    def test_installed_verification_failure_restores_old_app_and_data(self):
        old = self.old_app()
        data, original = self.existing_data()
        with self.assertRaisesRegex(MODULE.InstallError, 'Injected installed'):
            MODULE.install(self.locations, FakeSystem(self.apps, fail_installed=True))
        self.assertEqual(MODULE.inventory(self.locations.target), old)
        self.assertEqual(MODULE.inventory(data), original)
        receipt = json.loads(next(self.locations.backups.rglob('install-receipt.json')).read_text())
        self.assertEqual(receipt['status'], 'failedRestored')
        self.assertFalse(receipt['installedVerified'])
        self.assert_no_expanded_temporary_apps()

    def test_registration_failure_restores_old_app(self):
        old = self.old_app()
        with self.assertRaisesRegex(MODULE.InstallError, 'Injected registration'):
            MODULE.install(self.locations, FakeSystem(self.apps, fail_registration=True))
        self.assertEqual(MODULE.inventory(self.locations.target), old)
        self.assert_no_expanded_temporary_apps()

    def test_first_install_failure_leaves_no_app_or_data(self):
        with self.assertRaises(MODULE.InstallError):
            MODULE.install(self.locations, FakeSystem(self.apps, fail_installed=True))
        self.assertFalse(self.locations.target.exists())
        self.assertFalse(self.locations.state_paths()['data'].exists())

    def test_linked_and_hardlinked_data_rejected_before_backup(self):
        data = self.locations.state_paths()['data']
        data.parent.mkdir(parents=True)
        (self.root / 'elsewhere').mkdir()
        data.symlink_to(self.root / 'elsewhere')
        with self.assertRaisesRegex(MODULE.InstallError, 'Linked'):
            MODULE.install(self.locations, FakeSystem(self.apps))
        self.assertFalse(self.locations.backups.exists())
        data.unlink()
        data.mkdir()
        (data / 'a').write_bytes(b'test')
        os.link(data / 'a', data / 'b')
        with self.assertRaisesRegex(MODULE.InstallError, 'Hard linked'):
            MODULE.install(self.locations, FakeSystem(self.apps))

    def test_unreadable_directory_rejected(self):
        data, _ = self.existing_data()
        (data / 'empty').chmod(0)
        try:
            with self.assertRaisesRegex(MODULE.InstallError, 'readable'):
                MODULE.install(self.locations, FakeSystem(self.apps))
        finally:
            (data / 'empty').chmod(0o700)

    def test_initialization_marker_missing_data_fails_closed(self):
        prefs = self.locations.state_paths()['preferences']
        prefs.parent.mkdir(parents=True)
        with prefs.open('wb') as handle:
            plistlib.dump({'GaoCiPan.initialized.v1': True}, handle)
        with self.assertRaisesRegex(MODULE.InstallError, 'Initialized'):
            MODULE.install(self.locations, FakeSystem(self.apps))
        self.assertFalse(self.locations.backups.exists())

    def test_prior_receipt_missing_data_fails_closed(self):
        previous = self.locations.backups / 'Install-previous'
        previous.mkdir(parents=True)
        (previous / 'install-receipt.json').write_text(json.dumps({
            'schemaVersion': 1, 'bundleID': MODULE.BUNDLE, 'stateBefore': {'data': {'present': True}}}))
        with self.assertRaisesRegex(MODULE.InstallError, 'Previously recorded'):
            MODULE.install(self.locations, FakeSystem(self.apps))
        self.assertFalse(self.locations.target.exists())

    def test_prior_disposable_cache_missing_does_not_block_install(self):
        previous = self.locations.backups / 'Install-previous'
        previous.mkdir(parents=True)
        (previous / 'install-receipt.json').write_text(json.dumps({
            'schemaVersion': 1, 'bundleID': MODULE.BUNDLE,
            'stateBefore': {'cache': {'present': True}, 'savedApplicationState': {'present': True}}}))
        result = MODULE.install(self.locations, FakeSystem(self.apps))
        self.assertEqual(result['version'], MODULE.VERSION)
        self.assertFalse(self.locations.state_paths()['cache'].exists())

    def test_release_config_is_validated_from_project_files(self):
        config = self.root / 'configuration'
        config.mkdir()
        (config / 'VERSION').write_text('1.23\n')
        (config / 'BUILD').write_text('24\n')
        self.assertEqual(MODULE.release_config(config), ('1.23', '24'))
        (config / 'VERSION').write_text('1.2\n')
        with self.assertRaisesRegex(MODULE.InstallError, 'VERSION'):
            MODULE.release_config(config)
        (config / 'VERSION').write_text('1.23\n')
        (config / 'BUILD').write_text('0\n')
        with self.assertRaisesRegex(MODULE.InstallError, 'BUILD'):
            MODULE.release_config(config)

    def test_copy_failure_never_replaces_old_or_user_data(self):
        old = self.old_app()
        data, original = self.existing_data()
        system = FakeSystem(self.apps)
        def incomplete_copy(source, destination):
            if source.is_dir():
                destination.mkdir()
            else:
                destination.write_bytes(b'bad copy')
        system.copy = incomplete_copy
        with self.assertRaisesRegex(MODULE.InstallError, 'Copied bytes'):
            MODULE.install(self.locations, system)
        self.assertEqual(MODULE.inventory(self.locations.target), old)
        self.assertEqual(MODULE.inventory(data), original)

    def test_wrong_existing_bundle_rejected(self):
        self.old_app()
        info_path = self.locations.target / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = 'example.unrelated.app'
        info_path.write_bytes(plistlib.dumps(info))
        before = MODULE.inventory(self.locations.target)
        with self.assertRaisesRegex(MODULE.InstallError, 'Wrong application identity'):
            MODULE.install(self.locations, FakeSystem(self.apps))
        self.assertEqual(before, MODULE.inventory(self.locations.target))

    def test_archive_traversal_link_collision_and_size_rejected(self):
        cases = [('../escaped', b'x', 0), (MODULE.APP_NAME + '/link', b'target', stat.S_IFLNK | 0o777)]
        for index, (name, payload, mode) in enumerate(cases):
            bad = self.root / ('bad-' + str(index) + '.zip')
            with zipfile.ZipFile(bad, 'w') as archive:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = mode << 16
                archive.writestr(entry, payload)
            with self.assertRaises(MODULE.InstallError):
                MODULE.extract_zip(bad, self.root / ('bad-extract-' + str(index)))
        bad = self.root / 'collision.zip'
        with zipfile.ZipFile(bad, 'w') as archive:
            archive.writestr(MODULE.APP_NAME + '/A', b'a')
            archive.writestr(MODULE.APP_NAME + '/a', b'b')
        with self.assertRaisesRegex(MODULE.InstallError, 'colliding'):
            MODULE.extract_zip(bad, self.root / 'collision-extract')
        entry = zipfile.ZipInfo(MODULE.APP_NAME + '/huge')
        entry.file_size = MODULE.MAX_EXPANDED_BYTES + 1
        class DeclaredArchive:
            def infolist(self): return [entry]
        with self.assertRaisesRegex(MODULE.InstallError, 'too large'):
            MODULE.archive_members(DeclaredArchive())


if __name__ == '__main__':
    unittest.main()
