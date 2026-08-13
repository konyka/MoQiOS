#!/bin/bash
# Validate the tracked canonical disk fixture without modifying any files.

disk_fixture_error() {
    printf 'ERROR: canonical disk fixture: %s\n' "$*" >&2
    return 1
}

disk_fixture_check() {
    local manifest="$1" disk="$2"
    local line key value size hash actual_size actual_hash
    local format_version='' filename='' expected_size='' expected_hash=''
    local seen_format=0 seen_filename=0 seen_size=0 seen_hash=0

    if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then
        disk_fixture_error "manifest must be a regular file: $manifest"
        return 1
    fi
    if [ -L "$disk" ] || [ ! -f "$disk" ]; then
        disk_fixture_error "disk must be a non-symlink regular file: $disk"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *=*)
                key=${line%%=*}
                value=${line#*=}
                ;;
            *)
                disk_fixture_error "malformed manifest record"
                return 1
                ;;
        esac
        [ -n "$key" ] && [ -n "$value" ] || {
            disk_fixture_error "manifest fields must have non-empty values"
            return 1
        }
        case "$key" in
            format_version)
                [ "$seen_format" -eq 0 ] || { disk_fixture_error "duplicate format_version"; return 1; }
                format_version=$value; seen_format=1
                ;;
            filename)
                [ "$seen_filename" -eq 0 ] || { disk_fixture_error "duplicate filename"; return 1; }
                filename=$value; seen_filename=1
                ;;
            size)
                [ "$seen_size" -eq 0 ] || { disk_fixture_error "duplicate size"; return 1; }
                expected_size=$value; seen_size=1
                ;;
            sha256)
                [ "$seen_hash" -eq 0 ] || { disk_fixture_error "duplicate sha256"; return 1; }
                expected_hash=$value; seen_hash=1
                ;;
            *)
                disk_fixture_error "unknown manifest field: $key"
                return 1
                ;;
        esac
    done < "$manifest"

    [ "$seen_format" -eq 1 ] && [ "$seen_filename" -eq 1 ] && [ "$seen_size" -eq 1 ] && [ "$seen_hash" -eq 1 ] || {
        disk_fixture_error "manifest is missing required fields"
        return 1
    }
    [ "$format_version" = '1' ] || { disk_fixture_error "unsupported format version: $format_version"; return 1; }
    [ "$filename" = 'disk.img' ] && [ "${disk##*/}" = 'disk.img' ] || {
        disk_fixture_error "filename must be disk.img"
        return 1
    }
    [[ "$expected_size" =~ ^(0|[1-9][0-9]*)$ ]] || { disk_fixture_error "invalid size format"; return 1; }
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || { disk_fixture_error "invalid SHA-256 format"; return 1; }

    actual_size=$(wc -c < "$disk") || return 1
    actual_size=${actual_size//[[:space:]]/}
    [ "$actual_size" = "$expected_size" ] || { disk_fixture_error "size mismatch"; return 1; }

    actual_hash=$(sha256sum -- "$disk") || return 1
    actual_hash=${actual_hash%% *}
    [ "$actual_hash" = "$expected_hash" ] || { disk_fixture_error "SHA-256 mismatch"; return 1; }
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$#" -ne 2 ]; then
        printf 'Usage: %s MANIFEST DISK\n' "$0" >&2
        exit 2
    fi
    disk_fixture_check "$1" "$2"
fi
