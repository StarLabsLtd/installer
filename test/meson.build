hostname_validator_test = executable(
    'HostnameValidatorTest',
    'HostnameValidatorTest.vala',
    meson.project_source_root() / 'src' / 'HostnameValidator.vala',
    dependencies: glib_dep,
    install: false
)

test('HostnameValidator Test', hostname_validator_test)

repart_command_test = executable(
    'RepartCommandTest',
    'RepartCommandTest.vala',
    meson.project_source_root() / 'daemon' / 'RepartCommand.vala',
    dependencies: gio_dep,
    install: false
)

test('Repart command exit status', repart_command_test)

repart_backend_test = executable(
    'RepartBackendTest',
    'RepartBackendTest.vala',
    meson.project_source_root() / 'daemon' / 'InstallerInterface.vala',
    meson.project_source_root() / 'daemon' / 'RepartCommand.vala',
    meson.project_source_root() / 'daemon' / 'RepartBackend.vala',
    common_files,
    dependencies: [gio_dep, gio_unix_dep],
    install: false
)

test('Repart backend failure control flow', repart_backend_test)
