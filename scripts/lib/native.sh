#!/bin/sh
# Fetches, verifies, compiles, and activates the resident C++ component.
#
# This is the other half of what this repository installs. sm_install_binary
# (lib/install-core.sh) delivers the fork-per-invocation Go macro helper as a
# prebuilt, per-architecture binary. The resident component cannot be
# delivered that way: FPP 10 versions and checks its plugin ABI at dlopen, so
# one object cannot serve both majors, and an object built at release time
# against assumed headers is exactly what that check exists to reject. So it
# ships as architecture-independent source and is compiled here against the
# host's own installed FPP headers, which is what native/adapters/Makefile's
# own header describes as the packaging step's job.
#
# Nothing in FPP compiles this for us. Neither FPP 9.5.3 nor FPP 10.0 runs
# `make` on a plugin directory; what FPP runs is this repository's own
# fpp_install.sh and fpp_upgrade.sh, which is why the compile lives here.
# See README.md for the source citations behind that.
#
# Requires common.sh, fetch.sh, verify.sh, lock.sh, and activate.sh to
# already be sourced.

# The single stable name fppd resolves for this plugin directory.
#
# FPP derives a C++ plugin's object as lib<plugin-directory-name>.so unless
# the callbacks script names one after "c++:" (FPP 10.0
# PluginManager::loadUserPlugin). The `callbacks` file at the root of this
# repository deliberately prints a bare "c++" and no path, so this name is
# what fppd will open. Version selection happens here instead, where FPP
# major detection already has to run: the built objects are
# libshowmesh-fpp9.so and libshowmesh-fpp10.so, and whichever one matches
# this host is what earns this name.
sm_native_object_path() {
    printf '%s\n' "$1/libfpp-showmesh.so"
}

# Reads the host's FPP major version out of FPP's own generated version
# helper, $FPPDIR/www/fppversion.php.
#
# That file is generated at FPP build time from the checked-out git tag, and
# it is the same source FPP's own web UI and API report from, so it answers
# for this host rather than for whatever release this plugin was cut against.
# The stock www/fppunknown_versions.php fallback returns major "99" when FPP
# could not determine its own version; that is refused below rather than
# treated as a real major, because picking an adapter for FPP 99 would mean
# guessing.
#
# Refusing is deliberate and matches sm_detect_arch's posture: an unknown FPP
# major means no adapter can be chosen honestly, and a wrong adapter on FPP 10
# is rejected at dlopen with the plugin silently absent, which is a worse
# outcome to debug on show night than a loud install-time refusal.
sm_fpp_major() {
    local _sm_fppdir _sm_version_php _sm_major _sm_sed
    _sm_fppdir="$1"
    _sm_version_php="$_sm_fppdir/www/fppversion.php"

    if [ ! -f "$_sm_version_php" ]; then
        sm_log_err "FPP's generated version helper is missing at $_sm_version_php; cannot determine this host's FPP major version"
        return 1
    fi

    _sm_sed=$(sm_resolve_bin sed /bin/sed /usr/bin/sed) || return 1

    # Matches the generated body of getFPPMajorVersion(), which returns a
    # quoted integer. Anchored on the function name so an unrelated return
    # elsewhere in the file cannot be picked up. The `q` quits sed on the first
    # match rather than piping through `head`, which would mean a second
    # external tool resolved by absolute path for no gain.
    _sm_major=$("$_sm_sed" -n \
        '/function[[:space:]]*getFPPMajorVersion/,/}/ { s/.*return[[:space:]]*"\{0,1\}\([0-9]\{1,\}\)"\{0,1\}[[:space:]]*;.*/\1/p ; }' \
        "$_sm_version_php")
    # Only the first line, without invoking anything: a generated file with an
    # unexpected second match must not silently concatenate into one token.
    _sm_major=${_sm_major%%
*}

    case "$_sm_major" in
        '' )
            sm_log_err "could not read an FPP major version out of $_sm_version_php; refusing to guess which adapter this host needs"
            return 1
            ;;
        99 )
            sm_log_err "FPP reports major version 99, which is its own \"version unknown\" placeholder; refusing to choose a plugin adapter against it"
            return 1
            ;;
    esac

    printf '%s\n' "$_sm_major"
}

# Maps an FPP major to the adapter make target and the object that target
# produces. Prints "<target> <soname>".
#
# Only the majors this repository actually ships adapters for are accepted. A
# newer FPP major is refused rather than aimed at the closest adapter: FPP 10
# introduced the ABI-checked plugin API, so "probably close enough" is not a
# property any future major can be assumed to have.
sm_native_adapter_for_major() {
    case "$1" in
        9 )  printf '%s\n' 'fpp9 libshowmesh-fpp9.so' ;;
        10 ) printf '%s\n' 'fpp10 libshowmesh-fpp10.so' ;;
        * )
            sm_log_err "no plugin adapter is shipped for FPP major version $1; refusing rather than compiling an adapter built for a different major"
            return 1
            ;;
    esac
}

# Path of the marker recording that the resident component is not installed,
# and why. Read by an operator, and by preStart.sh's reporting if it ever
# grows a consumer; written whenever the compile or activation fails.
sm_native_failure_marker_path() {
    printf '%s\n' "$(sm_state_dir)/native-install-failed.txt"
}

# Removes the failure marker once the resident component is genuinely live,
# so a marker left by an earlier failed attempt does not outlive the problem
# it described. A marker that cannot be removed is reported but does not fail
# an otherwise good activation: the object is already in place and working,
# and a stale marker is a reporting defect, not a broken install.
sm_native_clear_failure_marker() {
    local _sm_marker _sm_rm
    _sm_marker=$(sm_native_failure_marker_path)
    [ -e "$_sm_marker" ] || return 0
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 0
    "$_sm_rm" -f "$_sm_marker" || sm_log_err "could not remove the stale marker at $_sm_marker; the resident component IS installed despite what that file says"
    return 0
}

# Records why the resident component is absent, so the failure is visible to
# somebody reading the host rather than only to whoever was watching the
# install output scroll past.
#
# Written through sm_write_stamp so a failed write cannot truncate an
# existing marker to empty, the same reason the architecture stamp is written
# that way.
sm_native_record_failure() {
    local _sm_reason _sm_marker
    _sm_reason="$1"
    _sm_marker=$(sm_native_failure_marker_path)

    if ! sm_write_stamp "$_sm_marker" "$_sm_reason"; then
        sm_log_err "could not record the resident-component failure at $_sm_marker; the reason is in this install log only"
    fi
}

# Compiles one adapter out of an extracted bundle. Prints nothing; the built
# object lands at <bundle>/native/adapters/build/<target>/<soname>.
#
# Build output is captured to $2 rather than left to interleave with the rest
# of the install log: a compile failure on a host is the one case here where
# the actual compiler diagnostics are the whole point, and they need to
# survive in one readable block.
sm_native_compile() {
    local _sm_bundle _sm_logfile _sm_target _sm_fpp_src _sm_make
    _sm_bundle="$1"
    _sm_logfile="$2"
    _sm_target="$3"
    _sm_fpp_src="$4"

    if [ ! -f "$_sm_bundle/native/adapters/Makefile" ]; then
        sm_log_err "the native source bundle did not contain native/adapters/Makefile"
        return 1
    fi
    if [ ! -d "$_sm_fpp_src" ]; then
        sm_log_err "FPP's source headers are not present at $_sm_fpp_src; the resident component compiles against this host's own FPP headers and cannot be built without them"
        return 1
    fi

    _sm_make=$(sm_resolve_bin make /usr/bin/make /bin/make) || return 1

    sm_log "compiling the resident component ($_sm_target) against $_sm_fpp_src"
    if ! "$_sm_make" -C "$_sm_bundle/native/adapters" "$_sm_target" \
        FPP_SRC="$_sm_fpp_src" > "$_sm_logfile" 2>&1; then
        return 1
    fi
    return 0
}

# Fetches, verifies, compiles, and activates the resident C++ component.
#
# Returns non-zero on any failure, and every failure path leaves the Go macro
# helper alone. That separation is the point: this component is the newer and
# more fragile half of the install (it compiles on the host, against headers
# this repository does not control), and a host that cannot build it must
# still end up with a working macro helper rather than a half-installed
# plugin. sm_install_or_upgrade is what decides that this returning non-zero
# does not fail the whole install; see its call site.
sm_install_native() {
    local _sm_plugin_dir _sm_fppdir _sm_version _sm_major _sm_adapter
    local _sm_target _sm_soname _sm_tarball _sm_base_url _sm_expected_hash
    local _sm_mktemp _sm_rm _sm_workdir _sm_tar _sm_built _sm_object
    local _sm_staging _sm_buildlog
    _sm_plugin_dir="$1"
    _sm_fppdir="$2"
    _sm_version="$3"

    _sm_major=$(sm_fpp_major "$_sm_fppdir") || {
        sm_native_record_failure "FPP major version could not be determined, so no adapter could be chosen"
        return 1
    }
    _sm_adapter=$(sm_native_adapter_for_major "$_sm_major") || {
        sm_native_record_failure "no adapter is shipped for FPP major version $_sm_major"
        return 1
    }
    _sm_target=${_sm_adapter%% *}
    _sm_soname=${_sm_adapter##* }
    sm_log "detected FPP major version $_sm_major; building adapter $_sm_target"

    _sm_tarball="showmesh-fpp-plugin-native_${_sm_version}.tar.gz"
    _sm_base_url=$(sm_artifact_base_url "$_sm_version")
    sm_check_base_url_scheme "$_sm_base_url" || {
        sm_native_record_failure "the artifact base URL was refused"
        return 1
    }

    # Resolved before any network access, exactly as sm_install_binary does:
    # a missing or version-mismatched lock entry refuses the install rather
    # than fetching bytes there is nothing trustworthy to check against. The
    # native bundle is architecture-independent, so it appears in the lock
    # under one filename with no architecture in it.
    _sm_expected_hash=$(sm_lock_expected_sha256 "$_sm_plugin_dir" "$_sm_version" "$_sm_tarball") || {
        sm_log_err "refusing to install the resident component without a matching artifacts.lock.json entry for $_sm_tarball"
        sm_native_record_failure "no artifacts.lock.json entry for $_sm_tarball"
        return 1
    }

    _sm_mktemp=$(sm_resolve_bin mktemp /bin/mktemp /usr/bin/mktemp) || return 1
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1
    _sm_workdir=$("$_sm_mktemp" -d /tmp/fpp-showmesh-native.XXXXXX) || {
        sm_log_err "could not create a temporary working directory for the resident component"
        sm_native_record_failure "no temporary working directory could be created"
        return 1
    }
    # No trap, for the same reason sm_install_binary sets none: a trap set
    # inside a function is process-global in POSIX sh and would replace a
    # caller's own EXIT trap.

    sm_log "fetching $_sm_tarball from $_sm_base_url"
    if ! sm_download "$_sm_base_url/$_sm_tarball" "$_sm_workdir/$_sm_tarball"; then
        "$_sm_rm" -rf "$_sm_workdir"
        sm_native_record_failure "$_sm_tarball could not be downloaded from $_sm_base_url"
        return 1
    fi

    if ! sm_verify_sha256 "$_sm_workdir/$_sm_tarball" "$_sm_expected_hash"; then
        sm_log_err "refusing to compile a source bundle that failed checksum verification against artifacts.lock.json"
        "$_sm_rm" -rf "$_sm_workdir"
        sm_native_record_failure "$_sm_tarball failed checksum verification"
        return 1
    fi

    _sm_tar=$(sm_resolve_bin tar /bin/tar /usr/bin/tar) || {
        "$_sm_rm" -rf "$_sm_workdir"
        return 1
    }
    if ! "$_sm_tar" -xzf "$_sm_workdir/$_sm_tarball" -C "$_sm_workdir"; then
        sm_log_err "could not extract $_sm_tarball"
        "$_sm_rm" -rf "$_sm_workdir"
        sm_native_record_failure "$_sm_tarball could not be extracted"
        return 1
    fi

    _sm_buildlog="$_sm_workdir/build.log"
    if ! sm_native_compile "$_sm_workdir" "$_sm_buildlog" "$_sm_target" "$_sm_fppdir/src"; then
        sm_log_err "the resident component did not compile on this host; the macro helper is unaffected"
        if [ -f "$_sm_buildlog" ]; then
            sm_log_err "--- compiler output begins ---"
            while IFS= read -r _sm_line; do
                sm_log_err "$_sm_line"
            done < "$_sm_buildlog"
            sm_log_err "--- compiler output ends ---"
        fi
        "$_sm_rm" -rf "$_sm_workdir"
        sm_native_record_failure "the adapter $_sm_target did not compile against $_sm_fppdir/src on this host; see the install log for the compiler output"
        return 1
    fi

    _sm_built="$_sm_workdir/native/adapters/build/$_sm_target/$_sm_soname"
    if [ ! -f "$_sm_built" ]; then
        sm_log_err "the compile reported success but produced no $_sm_soname"
        "$_sm_rm" -rf "$_sm_workdir"
        sm_native_record_failure "the adapter $_sm_target compiled without producing $_sm_soname"
        return 1
    fi

    _sm_object=$(sm_native_object_path "$_sm_plugin_dir")
    # Staged beside its final target so the activating rename stays within one
    # directory and therefore one filesystem; lib/activate.sh's header has the
    # full reasoning.
    _sm_staging="$_sm_object.staging"

    if ! sm_stage_binary "$_sm_built" "$_sm_staging"; then
        "$_sm_rm" -rf "$_sm_workdir"
        sm_native_record_failure "the built $_sm_soname could not be staged next to $_sm_object"
        return 1
    fi
    "$_sm_rm" -rf "$_sm_workdir"

    if ! sm_activate_binary "$_sm_staging" "$_sm_object"; then
        sm_native_record_failure "the built $_sm_soname could not be activated at $_sm_object"
        return 1
    fi

    # Same transaction boundary as sm_install_binary's: the rename already
    # made the new object live, but the previous one stays at
    # $_sm_object.previous until the mode readback below also succeeds, so a
    # failure there restores what fppd was loading before this install rather
    # than leaving an unverified object live with no way back.
    if ! sm_verify_mode "$_sm_object" 755; then
        sm_activate_undo "$_sm_object"
        sm_native_record_failure "$_sm_object did not read back as mode 0755 after activation and was rolled back"
        return 1
    fi

    sm_activate_commit "$_sm_object"
    sm_native_clear_failure_marker

    # fppd holds the previous object mapped until it restarts or the plugin is
    # unloaded and reloaded, so the file being in place is not the same as the
    # new build running. FPP 10 can reload a plugin at runtime; FPP 9 needs an
    # fppd restart. Saying so here, rather than restarting anything, is the
    # same rule sm_note_possible_restart_need follows and for the same reason:
    # this script never restarts a host that might be mid-show.
    sm_log "installed the resident component ($_sm_soname, FPP $_sm_major) to $_sm_object"
    sm_log "fppd keeps the previously loaded object mapped until it is reloaded; the operator decides when that happens"
    return 0
}
