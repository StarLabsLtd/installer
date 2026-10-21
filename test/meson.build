hostname_validator_test = executable(
    'HostnameValidatorTest',
    'HostnameValidatorTest.vala',
    meson.project_source_root() / 'src' / 'HostnameValidator.vala',
    dependencies: glib_dep,
    install: false
)

test('HostnameValidator Test', hostname_validator_test)

owner_password_test = executable(
    'OwnerPasswordTest',
    'OwnerPasswordTest.c',
    meson.project_source_root() / 'common' / 'OwnerCredentials.c',
    include_directories: include_directories('../common'),
    dependencies: [gio_dep, pwquality_dep],
    install: false
)

test('Owner password policy', owner_password_test)

dave_readiness_test = executable(
    'DaveReadinessTest',
    'DaveReadinessTest.vala',
    meson.project_source_root() / 'common' / 'DaveReadiness.vala',
    dependencies: [glib_dep, gio_dep],
    install: false
)

test('Dave firmware vendor', dave_readiness_test)

keyboard_sources_test = executable(
    'KeyboardSourcesTest',
    'KeyboardSourcesTest.vala',
    meson.project_source_root() / 'common' / 'KeyboardSources.vala',
    dependencies: [glib_dep, gobject_dep],
    install: false
)

test('Keyboard sources', keyboard_sources_test)

hibernate_credentials_test = executable(
    'HibernateCredentialsTest',
    'HibernateCredentialsTest.c',
    meson.project_source_root() / 'common' / 'OwnerCredentials.c',
    include_directories: include_directories('../common'),
    dependencies: [gio_dep, pwquality_dep],
    install: false
)

test('Hibernate credential custody', hibernate_credentials_test)

if installer_backend == 'repart'
    swap_file_test = executable(
        'SwapFileTest',
        'SwapFileTest.c',
        meson.project_source_root() / 'daemon' / 'SwapFile.c',
        include_directories: include_directories('../daemon'),
        dependencies: glib_dep,
        install: false
    )
    test('Persistent swapfile qualification', swap_file_test)

    sleep_kernel_test = executable(
        'SleepKernelTest',
        'SleepKernelTest.vala',
        meson.project_source_root() / 'daemon' / 'SleepKernel.vala',
        dependencies: [glib_dep, gio_dep],
        install: false
    )
    test('Target kernel sleep policy', sleep_kernel_test)

    normal_root_test = executable(
        'NormalRootTest',
        'NormalRootTest.vala',
        meson.project_source_root() / 'daemon' / 'NormalRoot.vala',
        meson.project_source_root() / 'daemon' / 'SwapFile.c',
        include_directories: include_directories('../daemon'),
        dependencies: [glib_dep, gio_dep, json_glib_dep, meson.get_compiler('vala').find_library('posix')],
        install: false
    )
    test('Normal ROOT and ESP publication', normal_root_test)

    loop_backing_test = executable(
        'LoopBackingTest',
        'LoopBackingTest.c',
        meson.project_source_root() / 'daemon' / 'LoopBacking.c',
        include_directories: include_directories('../daemon'),
        dependencies: glib_dep,
        install: false
    )
    test('Loop backing identity', loop_backing_test)
endif
repart_command_test = executable(
    'RepartCommandTest',
    'RepartCommandTest.vala',
    meson.project_source_root() / 'daemon' / 'RepartCommand.vala',
    dependencies: gio_dep,
    install: false
)

test('Repart command exit status', repart_command_test)

if installer_backend == 'repart'
    test('Privileged daemon bus and lifetime',
        find_program('dbus-run-session'),
        args: ['--', 'sh', files('DaemonBusTest.sh'), installer_daemon],
        timeout: 30
    )
endif
