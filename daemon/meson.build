vala_files = [
    'Daemon.vala',
    common_files
]

daemon_dependencies = [
    gee_dep,
    glib_dep,
    gio_dep,
    gio_unix_dep,
    gobject_dep,
    pwquality_dep,
    dependency('polkit-gobject-1'),
]

args = []
backend_sources = []
backend_libraries = []

if installer_backend == 'distinst'
    vala_files += ['DistinstBackend.vala']
    daemon_dependencies += [distinst_dep]
    args += '--define=DISTINST_BACKEND'
elif installer_backend == 'repart'
    vala_files += ['RepartBackend.vala', 'SleepKernel.vala', 'NormalRoot.vala', 'NormalBoot.vala']
    backend_sources += ['LoopBacking.c', 'SwapFile.c']
    backend_libraries += static_library('installer-boot-entry', 'BootEntry.c',
        dependencies: [dependency('efiboot'), dependency('efivar')])
    daemon_dependencies += json_glib_dep
    daemon_dependencies += meson.get_compiler('vala').find_library('posix')
    args += '--define=REPART_BACKEND'
else
    error('No supported installer backend provided')
endif

systemdunitdir = systemd_dep.get_pkgconfig_variable('systemdsystemunitdir')

install_data(
    'io.elementary.InstallerDaemon.service',
    install_dir: systemdunitdir
)

install_data('io.elementary.InstallerDaemon.conf', install_dir : get_option('datadir') / 'dbus-1' / 'system.d')
install_data('io.elementary.installer.policy', install_dir: get_option('datadir') / 'polkit-1' / 'actions')
install_data('io.elementary.installer.rules', install_dir: get_option('datadir') / 'polkit-1' / 'rules.d')

executable(meson.project_name() + '-daemon', vala_files, backend_sources,
           '../common/OwnerCredentials.c',
           include_directories: include_directories('.', '../common'),
           dependencies : daemon_dependencies,
           link_with: backend_libraries,
           vala_args : args,
           install: true)
