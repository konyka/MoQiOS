#!/bin/bash
# Shared, sourceable Limine bootstrap checks for the x86 ISO path.

LIMINE_REPOSITORY="https://github.com/limine-bootloader/limine.git"
LIMINE_TAG="v8.7.0-binary"
LIMINE_COMMIT="aad3edd370955449717a334f0289dee10e2c5f01"

limine_error() {
    echo "ERROR: $*" >&2
}

limine_verify_checkout() {
    local limine_dir="$1"
    local inside_work_tree
    local head
    local status

    if [ ! -d "$limine_dir" ]; then
        limine_error "Limine path is not a directory: $limine_dir"
        return 1
    fi

    if ! inside_work_tree="$(git -C "$limine_dir" rev-parse --is-inside-work-tree)"; then
        limine_error "Limine path is not a Git checkout: $limine_dir"
        return 1
    fi
    if [ "$inside_work_tree" != "true" ]; then
        limine_error "Limine path is not inside a Git work tree: $limine_dir"
        return 1
    fi

    if ! head="$(git -C "$limine_dir" rev-parse HEAD)"; then
        limine_error "Cannot determine Limine revision in $limine_dir"
        return 1
    fi
    if [ "$head" != "$LIMINE_COMMIT" ]; then
        limine_error "Limine revision must be $LIMINE_COMMIT (found $head)"
        return 1
    fi

    if ! status="$(git -C "$limine_dir" status --porcelain --untracked-files=all --)"; then
        limine_error "Cannot determine Limine checkout status in $limine_dir"
        return 1
    fi
    if [ -n "$status" ]; then
        limine_error "Limine checkout must be clean (including untracked files): $limine_dir"
        return 1
    fi
}

limine_require_assets() {
    local limine_dir="$1"
    local asset
    local required_assets=(
        limine-bios.sys
        limine-bios-cd.bin
        limine-uefi-cd.bin
        BOOTX64.EFI
    )

    for asset in "${required_assets[@]}"; do
        if [ ! -f "$limine_dir/$asset" ]; then
            limine_error "Required Limine asset missing: $limine_dir/$asset"
            return 1
        fi
    done
    if [ ! -f "$limine_dir/limine" ] || [ ! -x "$limine_dir/limine" ]; then
        limine_error "Limine utility is missing or not executable: $limine_dir/limine"
        return 1
    fi
}

limine_prepare() {
    local limine_dir="$1"
    local parent_dir
    local temp_dir

    if [ -L "$limine_dir" ]; then
        limine_error "Refusing Limine symlink: $limine_dir"
        return 1
    fi

    if [ -e "$limine_dir" ]; then
        limine_verify_checkout "$limine_dir" || return 1
    else
        parent_dir="$(dirname -- "$limine_dir")"
        if [ ! -d "$parent_dir" ]; then
            limine_error "Limine parent directory does not exist: $parent_dir"
            return 1
        fi
        if ! temp_dir="$(mktemp -d "$parent_dir/.limine-bootstrap.XXXXXX")"; then
            limine_error "Cannot create temporary Limine directory beside $limine_dir"
            return 1
        fi

        echo "[limine] Downloading Limine $LIMINE_TAG..."
        if ! git clone --branch "$LIMINE_TAG" --depth 1 "$LIMINE_REPOSITORY" "$temp_dir"; then
            rm -rf -- "$temp_dir"
            return 1
        fi
        if ! limine_verify_checkout "$temp_dir"; then
            rm -rf -- "$temp_dir"
            return 1
        fi
        if [ -e "$limine_dir" ] || [ -L "$limine_dir" ]; then
            limine_error "Limine path appeared during bootstrap: $limine_dir"
            rm -rf -- "$temp_dir"
            return 1
        fi
        if ! mv -- "$temp_dir" "$limine_dir"; then
            rm -rf -- "$temp_dir"
            return 1
        fi
    fi

    if [ -L "$limine_dir/limine" ] || [ -d "$limine_dir/limine" ]; then
        limine_error "Refusing unexpected Limine utility path: $limine_dir/limine"
        return 1
    fi
    if [ -e "$limine_dir/limine" ] && [ ! -f "$limine_dir/limine" ]; then
        limine_error "Refusing non-regular Limine utility path: $limine_dir/limine"
        return 1
    fi
    if [ -f "$limine_dir/limine" ] && ! rm -f -- "$limine_dir/limine"; then
        limine_error "Cannot remove Limine utility: $limine_dir/limine"
        return 1
    fi
    echo "[limine] Building utility..."
    if ! make -C "$limine_dir"; then
        return 1
    fi
    limine_require_assets "$limine_dir"
}

limine_bios_install() {
    local limine_dir="$1"
    local iso_file="$2"

    limine_require_assets "$limine_dir" || return 1
    "$limine_dir/limine" bios-install "$iso_file"
}
