#!/usr/bin/env python3
"""Install the fixed GaoCiPan release without launching it or editing user data.

The production CLI accepts no overrides. Unit tests import the module and inject
temporary paths / system operations; those test hooks are not exposed by CLI.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import uuid
import zipfile
from dataclasses import dataclass

BUNDLE = 'com.gaoseries.GaoCiPan'
APP_NAME = '搞磁盘.app'
EXECUTABLE = 'GaoCiPan'
PROJECT = Path(__file__).absolute().parent.parent
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024 * 1024
MAX_MEMBERS = 30000
MAX_BACKUP_FILES = 1000000
MAX_BACKUP_BYTES = 256 * 1024 * 1024 * 1024


class InstallError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise InstallError(message)


def lexists(path):
    return os.path.lexists(path)


def no_link_ancestors(path):
    path = Path(path).absolute()
    for item in (path, *path.parents):
        if lexists(item):
            require(not stat.S_ISLNK(item.lstat().st_mode), 'Linked path is not allowed: ' + str(item))


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def inventory(path):
    """All ordinary files + empty directories, with modes and streamed hashes.

    Directory descriptors and O_NOFOLLOW keep traversal attached to the inspected
    objects. Unsupported types, hard links, unreadable objects and races fail.
    """
    path = Path(path)
    no_link_ancestors(path)
    result, totals = {}, [0, 0]

    def visit(parent_fd, name, relative):
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        mode = stat.S_IMODE(before.st_mode)
        require(not stat.S_ISLNK(before.st_mode), 'Symbolic link in state: ' + relative)
        is_dir = stat.S_ISDIR(before.st_mode)
        require(is_dir or stat.S_ISREG(before.st_mode), 'Unknown object type: ' + relative)
        require(mode & 0o444, 'Object has no readable mode: ' + relative)
        if is_dir:
            require(mode & 0o111, 'Directory has no searchable mode: ' + relative)
        else:
            require(before.st_nlink == 1, 'Hard linked file is not supported: ' + relative)
        flags = os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if is_dir else 0)
        fd = os.open(name, flags, dir_fd=parent_fd)
        try:
            require(identity(os.fstat(fd)) == identity(before), 'Object changed before reading: ' + relative)
            totals[0] += 1
            require(totals[0] <= MAX_BACKUP_FILES, 'State entry budget exceeded')
            if is_dir:
                result[relative] = {'type': 'directory', 'mode': mode}
                names = sorted(os.listdir(fd))
                for child in names:
                    visit(fd, child, child if relative == '.' else relative + '/' + child)
                require(sorted(os.listdir(fd)) == names, 'Directory changed during reading: ' + relative)
            else:
                totals[1] += before.st_size
                require(totals[1] <= MAX_BACKUP_BYTES, 'State byte budget exceeded')
                digest = hashlib.sha256()
                actual = 0
                while True:
                    block = os.read(fd, 1024 * 1024)
                    if not block:
                        break
                    actual += len(block)
                    require(actual <= before.st_size, 'File grew during reading: ' + relative)
                    digest.update(block)
                require(actual == before.st_size, 'Short read: ' + relative)
                result[relative] = {'type': 'file', 'mode': mode,
                                    'size': actual, 'sha256': digest.hexdigest()}
            require(identity(os.fstat(fd)) == identity(before), 'Object changed during reading: ' + relative)
            require(identity(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) == identity(before),
                    'Object replaced during reading: ' + relative)
        finally:
            os.close(fd)

    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        visit(parent, path.name, '.')
    finally:
        os.close(parent)
    return result


def snapshot(path):
    no_link_ancestors(path)
    return inventory(path) if lexists(path) else None


def read_plist(path):
    value = plistlib.loads(safe_bytes(path, 2 * 1024 * 1024))
    require(isinstance(value, dict), 'Plist is not a dictionary')
    return value


def safe_bytes(path, limit):
    no_link_ancestors(path)
    before = os.lstat(path)
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= limit,
            'Invalid or oversized regular file: ' + str(path))
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        require(identity(os.fstat(fd)) == identity(before), 'File changed before reading')
        value = bytearray()
        while True:
            chunk = os.read(fd, min(1024 * 1024, limit + 1 - len(value)))
            if not chunk:
                break
            value.extend(chunk)
            require(len(value) <= limit, 'File exceeds byte budget')
        require(len(value) == before.st_size and identity(os.fstat(fd)) == identity(before)
                and identity(os.lstat(path)) == identity(before), 'File changed during reading')
        return bytes(value)
    finally:
        os.close(fd)


def release_config(project):
    version = safe_bytes(project / 'VERSION', 64).decode('ascii').strip()
    build = safe_bytes(project / 'BUILD', 64).decode('ascii').strip()
    require(re.fullmatch(r'[0-9]+\.[0-9]{2}', version) is not None, 'Invalid VERSION')
    require(re.fullmatch(r'[1-9][0-9]*', build) is not None, 'Invalid BUILD')
    return version, build


VERSION, BUILD = release_config(PROJECT)


def bundle_info(app, expected_version=None):
    inventory(app)
    info = read_plist(app / 'Contents/Info.plist')
    require(info.get('CFBundleIdentifier') == BUNDLE, 'Wrong application identity')
    require(info.get('CFBundleExecutable') == EXECUTABLE, 'Wrong application executable')
    require(info.get('CFBundlePackageType') == 'APPL', 'Not an application bundle')
    require((app / 'Contents/MacOS' / EXECUTABLE).is_file(), 'Application executable is missing')
    if expected_version:
        require((info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) == expected_version,
                'Unexpected release version/build')
    return info


def archive_members(archive):
    """Validate all paths/types/sizes before any extraction; AppleDouble is data."""
    members = archive.infolist()
    require(0 < len(members) <= MAX_MEMBERS, 'Archive member budget exceeded')
    seen, files, total = set(), set(), 0
    for member in members:
        name = member.filename
        require('\x00' not in name and '\\' not in name and not name.startswith('/'), 'Unsafe archive path')
        raw = name[:-1] if name.endswith('/') else name
        parts = raw.split('/')
        require(parts and all(part not in ('', '.', '..') for part in parts), 'Unsafe archive component')
        require(parts[0] in (APP_NAME, '__MACOSX'), 'Unexpected archive root')
        if parts[0] == '__MACOSX':
            if len(parts) == 1:
                require(member.is_dir(), 'Invalid metadata root')
            else:
                logical = parts[1:]
                if not member.is_dir():
                    require(logical[-1].startswith('._'), 'Unexpected archive metadata')
                    logical[-1] = logical[-1][2:]
                require(logical[0] == APP_NAME, 'Metadata belongs to another application')
        key = unicodedata.normalize('NFC', raw).casefold()
        require(key not in seen, 'Duplicate or colliding archive path')
        require(not any('/'.join(key.split('/')[:index]) in files for index in range(1, len(parts))), 'File/directory path conflict')
        seen.add(key)
        mode = member.external_attr >> 16
        kind = stat.S_IFMT(mode)
        require(kind in (0, stat.S_IFDIR, stat.S_IFREG), 'Linked or special archive member')
        require(not stat.S_IMODE(mode) & 0o7000, 'Special archive permission bits are unsupported')
        require(not member.flag_bits & 1, 'Encrypted archive is unsupported')
        require(member.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), 'Unsupported archive compression')
        require(0 <= member.file_size <= MAX_EXPANDED_BYTES, 'Archive member too large')
        if member.is_dir():
            require(kind != stat.S_IFREG and member.file_size == 0, 'Invalid archive directory')
        else:
            require(kind != stat.S_IFDIR, 'Invalid archive file')
            require(not any(existing.startswith(key + '/') for existing in seen if existing != key), 'Conflicting archive entry')
            files.add(key)
            require(member.file_size <= max(1024 * 1024, member.compress_size * 1000), 'Archive compression ratio exceeds budget')
        total += member.file_size
        require(total <= MAX_EXPANDED_BYTES, 'Expanded archive budget exceeded')
    return members


def extract_zip(source, destination):
    require(not lexists(destination), 'Extraction destination already exists')
    destination.mkdir(mode=0o700)
    with zipfile.ZipFile(source) as archive:
        members = archive_members(archive)
        directory_modes = {}
        for member in members:
            # Candidate AppleDouble metadata is intentionally not materialized.
            # Backup user data is copied by ditto, never through this extractor.
            if member.filename.startswith('__MACOSX/'):
                with archive.open(member) as handle:
                    while handle.read(1024 * 1024):
                        pass  # also verify CRC for metadata
                continue
            path = destination.joinpath(*PurePosixPath(member.filename).parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            mode = stat.S_IMODE(member.external_attr >> 16) & 0o777
            if member.is_dir():
                path.mkdir(exist_ok=True)
                directory_modes[path] = mode or 0o755
            else:
                with archive.open(member) as incoming, open(path, 'xb') as outgoing:
                    copied = 0
                    while True:
                        block = incoming.read(1024 * 1024)
                        if not block:
                            break
                        copied += len(block)
                        require(copied <= member.file_size, 'Inflated archive member grew')
                        outgoing.write(block)
                    require(copied == member.file_size, 'Incomplete archive member')
                os.chmod(path, mode or 0o644)
        for path in sorted(directory_modes, key=lambda item: len(item.parts), reverse=True):
            os.chmod(path, directory_modes[path])
    require({entry.name for entry in destination.iterdir()} == {APP_NAME}, 'Unexpected extracted root')
    return destination / APP_NAME


def zip_tree(source, destination, expected):
    """Create a bounded ordinary-file backup; modes and every file are verified."""
    require(inventory(source) == expected, 'Old application changed before backup')
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for relative, entry in expected.items():
            path = source if relative == '.' else source / relative
            arcname = APP_NAME if relative == '.' else APP_NAME + '/' + relative
            archive.write(path, arcname)
    os.chmod(destination, 0o600)
    require(inventory(source) == expected, 'Old application changed during backup')


def atomic_json(path, value):
    temp = path.with_name('.' + path.name + '.' + str(uuid.uuid4()))
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if lexists(temp):
            temp.unlink()


@dataclass(frozen=True)
class Locations:
    archive: Path
    applications: Path
    home: Path
    temporary: Path = Path('/private/tmp')

    @property
    def target(self):
        return self.applications / APP_NAME

    @property
    def backups(self):
        return self.home / 'Library/Application Support/GaoSeries/GaoCiPan-Backups'

    def state_paths(self):
        library = self.home / 'Library'
        result = {
            'data': library / 'Application Support/GaoSeries/GaoCiPan',
            'preferences': library / 'Preferences' / (BUNDLE + '.plist'),
            'container': library / 'Containers' / BUNDLE,
            'applicationSupportBundle': library / 'Application Support' / BUNDLE,
            'savedApplicationState': library / 'Saved Application State' / (BUNDLE + '.savedState'),
            'cache': library / 'Caches' / BUNDLE,
            'applicationScripts': library / 'Application Scripts' / BUNDLE,
            'initializationRecord': library / 'Application Support/GaoSeries/GaoCiPan-Initialization.json',
        }
        by_host = library / 'Preferences/ByHost'
        no_link_ancestors(by_host)
        if by_host.exists():
            require(by_host.is_dir() and os.access(by_host, os.R_OK | os.X_OK), 'ByHost preferences unreadable')
            for path in sorted(by_host.iterdir()):
                if path.name.startswith(BUNDLE + '.') and path.name.endswith('.plist'):
                    result['byHost-' + path.name] = path
        return result


class System:
    def run(self, *arguments):
        return subprocess.run(arguments, check=True, capture_output=True, text=True)

    def ensure_stopped(self):
        process = subprocess.run(['/usr/bin/pgrep', '-x', EXECUTABLE], capture_output=True)
        require(process.returncode == 1, 'Quit GaoCiPan before installing (or process check failed)')

    def verify_signature(self, app):
        self.run('/usr/bin/codesign', '--verify', '--deep', '--strict',
                 '--test-requirement', '=identifier "' + BUNDLE + '"', str(app))
        detail = self.run('/usr/bin/codesign', '-dv', '--verbose=4', str(app))
        require(('Identifier=' + BUNDLE) in (detail.stdout + detail.stderr).splitlines(), 'Signed identifier mismatch')

    def copy(self, source, destination):
        self.run('/usr/bin/ditto', '--rsrc', '--extattr', str(source), str(destination))

    def register(self, source, target):
        removed = subprocess.run([LSREGISTER, '-u', str(source)], capture_output=True, text=True)
        require(removed.returncode == 0 or '-10814' in removed.stdout + removed.stderr,
                'Cannot unregister exact temporary source')
        self.run(LSREGISTER, '-f', str(target))

    def register_restored(self, target):
        self.run(LSREGISTER, '-f', str(target))


def initialization_check(paths, snapshots, backup_root):
    initialized = snapshots['initializationRecord'] is not None
    for key, path in paths.items():
        if (key == 'preferences' or key.startswith('byHost-')) and snapshots[key] is not None:
            preferences = read_plist(path)
            initialized = initialized or any(preferences.get(marker) is True or preferences.get(marker) == 1
                                            for marker in ('GaoCiPan.initialized.v1', 'GaoCiPan.initialized'))
    require(not initialized or snapshots['data'] is not None,
            'Initialized application data is missing; restore before installing')
    if lexists(backup_root):
        no_link_ancestors(backup_root)
        require(backup_root.is_dir() and os.access(backup_root, os.R_OK | os.X_OK), 'Backup root unreadable')
        for folder in backup_root.iterdir():
            if not folder.name.startswith('Install-'):
                continue
            require(not folder.is_symlink() and folder.is_dir(), 'Invalid previous backup directory')
            receipt = folder / 'install-receipt.json'
            if lexists(receipt):
                manifest = inventory(receipt)['.']
                require(manifest['size'] <= 64 * 1024 * 1024, 'Previous receipt too large')
                previous = json.loads(safe_bytes(receipt, 64 * 1024 * 1024))
                require(previous.get('schemaVersion') == 1 and previous.get('bundleID') == BUNDLE,
                        'Unknown previous installation receipt')
                for key, value in previous.get('stateBefore', {}).items():
                    # macOS may legitimately discard caches and saved windows.
                    # Their prior existence is not business-initialization proof.
                    if value is not None and key in snapshots and key not in ('cache', 'savedApplicationState'):
                        require(snapshots[key] is not None, 'Previously recorded application state is missing: ' + key)


def verified_copy(system, source, destination, expected):
    require(not lexists(destination), 'Copy destination already exists')
    require(inventory(source) == expected, 'Source changed before copy')
    system.copy(source, destination)
    require(inventory(source) == expected and inventory(destination) == expected,
            'Copied bytes/modes differ or source changed')


def unchanged_state(paths, expected):
    for key, path in paths.items():
        require(snapshot(path) == expected[key], 'Application state changed during installation: ' + key)


def install(locations, system=None):
    system = system or System()
    require(locations.archive.name == 'GaoCiPan-' + VERSION + '-macOS-arm64.zip', 'Unexpected release archive name')
    no_link_ancestors(locations.archive)
    archive_state = inventory(locations.archive)
    require(archive_state['.']['size'] <= MAX_ARCHIVE_BYTES, 'Release archive too large')
    no_link_ancestors(locations.applications)
    require(locations.applications.is_dir(), 'Applications directory missing')
    system.ensure_stopped()
    target = locations.target
    old_inventory = snapshot(target)
    if old_inventory is not None:
        bundle_info(target)
        system.verify_signature(target)
    paths = locations.state_paths()
    state_before = {key: snapshot(path) for key, path in paths.items()}
    for key, value in state_before.items():
        if value is not None:
            expected_type = 'file' if key in ('preferences', 'initializationRecord') or key.startswith('byHost-') else 'directory'
            require(value['.']['type'] == expected_type, 'Unexpected application state type: ' + key)
    initialization_check(paths, state_before, locations.backups)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(uuid.uuid4())
    backup = locations.backups / ('Install-' + stamp)
    no_link_ancestors(backup.parent)
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup, 0o700)
    receipt_path = backup / 'install-receipt.json'
    receipt = {'schemaVersion': 1, 'bundleID': BUNDLE, 'version': VERSION, 'build': BUILD,
               'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'status': 'preparing', 'guiVerified': False, 'stateBefore': state_before,
               'backupVerified': False, 'installedVerified': False,
               'firstInstall': old_inventory is None and not any(value is not None for value in state_before.values())}
    atomic_json(receipt_path, receipt)
    stage = locations.applications / ('.GaoCiPan-install-' + str(uuid.uuid4()) + '.app')
    old = locations.applications / ('.GaoCiPan-previous-' + str(uuid.uuid4()) + '.app')
    moved_old, installed = False, False
    try:
        with tempfile.TemporaryDirectory(prefix='gaocipan-install-', dir=locations.temporary) as scratch_name:
            scratch = Path(scratch_name)
            candidate = extract_zip(locations.archive, scratch / 'candidate')
            require(inventory(locations.archive) == archive_state, 'Release archive changed during extraction')
            info = bundle_info(candidate, (VERSION, BUILD))
            system.verify_signature(candidate)
            candidate_inventory = inventory(candidate)
            for key, path in paths.items():
                if state_before[key] is not None:
                    verified_copy(system, path, backup / ('State-' + key), state_before[key])
            if old_inventory is not None:
                old_zip = backup / 'Previous.app.zip'
                zip_tree(target, old_zip, old_inventory)
                old_verification = extract_zip(old_zip, scratch / 'old-verification')
                require(inventory(old_verification) == old_inventory, 'Archived old application failed extraction verification')
                system.verify_signature(old_verification)
                receipt['oldAppArchive'] = inventory(old_zip)['.']
                receipt['oldAppInventory'] = old_inventory
                shutil.rmtree(scratch / 'old-verification')
            unchanged_state(paths, state_before)
            receipt['backupVerified'] = True
            receipt['status'] = 'backedUp'
            atomic_json(receipt_path, receipt)
            verified_copy(system, candidate, stage, candidate_inventory)
            require(bundle_info(stage, (VERSION, BUILD)) == info, 'Staged Info.plist differs')
            system.verify_signature(stage)
            system.ensure_stopped()
            require(snapshot(target) == old_inventory, 'Installed target changed before swap')
            unchanged_state(paths, state_before)
            if old_inventory is not None:
                target.rename(old)
                moved_old = True
            stage.rename(target)
            installed = True
            system.verify_signature(target)
            require(bundle_info(target, (VERSION, BUILD)) == info and inventory(target) == candidate_inventory,
                    'Installed version/bytes/modes verification failed')
            unchanged_state(paths, state_before)
            system.register(candidate, target)
            receipt['installedVerified'] = True
            receipt['status'] = 'installed'
            receipt['registration'] = {'temporarySourceUnregistered': True, 'installedRegistered': True,
                                       'scope': 'exact bundle paths only'}
            atomic_json(receipt_path, receipt)
            if moved_old:
                require(inventory(old) == old_inventory, 'Old application changed before cleanup')
                shutil.rmtree(old)
                moved_old = False
        return {'installed': str(target), 'version': VERSION, 'build': BUILD,
                'receipt': str(receipt_path), 'guiVerified': False, 'firstInstall': receipt['firstInstall']}
    except BaseException as error:
        rollback_error = None
        try:
            if installed and lexists(target):
                require(not target.is_symlink() and bundle_info(target).get('CFBundleIdentifier') == BUNDLE,
                        'Cannot remove unexpected target during rollback')
                shutil.rmtree(target)
            if moved_old:
                require(not lexists(target), 'Rollback target occupied')
                old.rename(target)
                require(inventory(target) == old_inventory, 'Restored application differs')
                system.verify_signature(target)
                # Re-register only the restored exact bundle, without a reset.
                system.register_restored(target)
            unchanged_state(paths, state_before)
        except BaseException as failed_rollback:
            rollback_error = str(failed_rollback)
        receipt['status'] = 'rollbackFailed' if rollback_error else 'failedRestored'
        receipt['installedVerified'] = False
        receipt['errorType'] = type(error).__name__
        if rollback_error:
            receipt['rollbackError'] = rollback_error
        atomic_json(receipt_path, receipt)
        if rollback_error:
            raise InstallError('Install failed; manual recovery required; see ' + str(receipt_path)) from error
        raise
    finally:
        if lexists(stage):
            require(not stage.is_symlink(), 'Unexpected staged link; preserved for review')
            shutil.rmtree(stage)


def main():
    require(len(sys.argv) == 1, 'This installer accepts no path, identity or test overrides')
    require(sys.platform == 'darwin', 'Production installer requires macOS')
    require(os.getuid() != 0, 'Run as the signed-in user; do not use sudo')
    require(release_config(PROJECT) == (VERSION, BUILD), 'Release configuration changed during execution')
    locations = Locations(PROJECT / 'dist' / ('GaoCiPan-' + VERSION + '-macOS-arm64.zip'),
                          Path('/Applications'), Path.home())
    print(json.dumps(install(locations), ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (InstallError, OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError) as failure:
        print(json.dumps({'installed': False, 'error': str(failure), 'guiVerified': False}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
