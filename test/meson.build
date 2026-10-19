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
