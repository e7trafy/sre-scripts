#!/bin/bash
################################################################################
# SRE Helpers - Step 4: PHP Installation
# Installs PHP-FPM with common extensions and applies secure php.ini defaults.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/common/lib.sh"

CURRENT_STEP=4

sre_show_help() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Step 4: PHP Installation
  Installs PHP-FPM and common extensions (mysql, pgsql, mbstring, xml, curl,
  zip, gd, intl, bcmath, soap, redis, imagick, opcache).
  Configures secure php.ini defaults.

Prerequisites: Step 1 (base-setup) and Step 3 (web-server) must be complete.

Options:
  --force-imagick   Recompile ImageMagick 7 and rebuild the PHP imagick
                    extension even if they already look installed. Use when
                    Arabic text renders unshaped/reversed.
  --dry-run   Print planned actions without executing
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --yes --dry-run
  sudo bash $0 --force-imagick        # rebuild IM7 with Arabic shaping
EOF
}

# Consumed before the common parser, which would treat it as an unknown arg.
SRE_FORCE_IMAGICK="false"
_argv=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-imagick) SRE_FORCE_IMAGICK="true" ;;
        *)               _argv+=("$1") ;;
    esac
    shift
done
set -- "${_argv[@]+"${_argv[@]}"}"

sre_parse_args "04-php.sh" "$@"
require_root

sre_header "Step 4: PHP Installation"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

require_config_key "SRE_PHP_VERSION" "1" > /dev/null
require_config_key "SRE_WEB_SERVER_INSTALLED" "3" > /dev/null

SRE_OS_FAMILY="$(config_get SRE_OS_FAMILY)"
SRE_PHP_VERSION="$(config_get SRE_PHP_VERSION)"
SRE_PHP_EXTRA="$(config_get SRE_PHP_EXTRA_VERSIONS "")"

# Build list of all PHP versions to install
all_php_versions=("$SRE_PHP_VERSION")
if [[ -n "$SRE_PHP_EXTRA" ]]; then
    IFS=',' read -ra extra_vers <<< "$SRE_PHP_EXTRA"
    for v in "${extra_vers[@]}"; do
        v=$(echo "$v" | tr -d ' ')
        [[ -n "$v" && "$v" != "$SRE_PHP_VERSION" ]] && all_php_versions+=("$v")
    done
fi

sre_info "OS family: $SRE_OS_FAMILY"
sre_info "Default PHP version: $SRE_PHP_VERSION"
sre_info "All PHP versions to install: ${all_php_versions[*]}"

# --- Install PHP-FPM and Extensions (all versions) ---

_install_php_version() {
    local ver="$1"
    sre_header "Installing PHP ${ver}"

    case "$SRE_OS_FAMILY" in
        debian)
            # Add ondrej/php PPA if not already present
            if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
                sre_info "Adding ondrej/php PPA..."
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    pkg_install software-properties-common
                    add-apt-repository -y ppa:ondrej/php
                    pkg_update
                else
                    sre_info "[DRY-RUN] Would add ondrej/php PPA"
                fi
            fi

            php_packages=(
                "php${ver}-fpm"
                "php${ver}-cli"
                "php${ver}-mysql"
                "php${ver}-pgsql"
                "php${ver}-mbstring"
                "php${ver}-xml"
                "php${ver}-curl"
                "php${ver}-zip"
                "php${ver}-gd"
                "php${ver}-intl"
                "php${ver}-bcmath"
                "php${ver}-soap"
                "php${ver}-redis"
                "php${ver}-opcache"
            )

            sre_info "Installing PHP ${ver} packages: ${php_packages[*]}"
            pkg_install "${php_packages[@]}"
            ;;

        rhel)
            # Enable Remi repository for PHP
            if ! rpm -q remi-release &>/dev/null; then
                sre_info "Enabling Remi repository..."
                if [[ "$SRE_DRY_RUN" != "true" ]]; then
                    os_ver="$(config_get SRE_OS_VERSION)"
                    remi_major="${os_ver%%.*}"
                    dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${remi_major}.rpm" || true
                fi
            fi

            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                dnf module -y reset php 2>/dev/null || true
                dnf module -y enable "php:remi-${ver}" 2>/dev/null || true
            fi

            php_packages=(
                php-fpm php-cli php-mysqlnd php-pgsql php-mbstring
                php-xml php-curl php-zip php-gd php-intl
                php-bcmath php-soap php-pecl-redis php-opcache
            )

            sre_info "Installing PHP ${ver} packages: ${php_packages[*]}"
            pkg_install "${php_packages[@]}"
            ;;
    esac

    # Enable and start FPM for this version
    local fpm_svc
    fpm_svc=$(get_phpfpm_svc "$ver")
    svc_enable_start "$fpm_svc"

    sre_success "PHP ${ver} installed and ${fpm_svc} running"
}

for php_ver in "${all_php_versions[@]}"; do
    _install_php_version "$php_ver"
done

# Set default CLI version
local_ver="${SRE_PHP_VERSION}"
if [[ "$SRE_OS_FAMILY" == "debian" && "$SRE_DRY_RUN" != "true" ]]; then
    update-alternatives --set php "/usr/bin/php${local_ver}" 2>/dev/null || true
    update-alternatives --set php-config "/usr/bin/php-config${local_ver}" 2>/dev/null || true
    update-alternatives --set phpize "/usr/bin/phpize${local_ver}" 2>/dev/null || true
    sre_success "Default CLI PHP set to ${local_ver}"
fi

sre_success "All PHP versions installed: ${all_php_versions[*]}"

# --- ImageMagick 7 + Arabic Support ---
sre_header "Installing ImageMagick 7 with Arabic/Unicode Support"

if [[ "$SRE_DRY_RUN" != "true" ]]; then

    # Install Arabic fonts and text shaping libraries
    case "$SRE_OS_FAMILY" in
        debian)
            pkg_install fonts-noto fonts-noto-cjk fonts-noto-color-emoji fonts-arabeyes \
                fonts-hosny-amiri fonts-kacst fonts-kacst-one \
                fontconfig libfribidi-dev libfribidi0 libharfbuzz-dev pango1.0-tools \
                2>/dev/null || \
            pkg_install fonts-noto fonts-arabeyes fontconfig libfribidi-dev libharfbuzz-dev
            ;;
        rhel)
            pkg_install google-noto-sans-arabic-fonts google-noto-naskh-arabic-fonts \
                google-noto-sans-fonts fontconfig fribidi-devel harfbuzz-devel pango \
                2>/dev/null || \
            pkg_install google-noto-sans-fonts fontconfig fribidi-devel harfbuzz-devel
            ;;
    esac
    fc-cache -f 2>/dev/null || true
    sre_success "Arabic fonts and text shaping libraries installed"

    # Check current ImageMagick version
    current_im_ver=""
    if command -v magick &>/dev/null; then
        current_im_ver=$(magick --version 2>/dev/null | head -1 | grep -oP 'ImageMagick \K[0-9]+')
    elif command -v convert &>/dev/null; then
        current_im_ver=$(convert --version 2>/dev/null | head -1 | grep -oP 'ImageMagick \K[0-9]+')
    fi

    # Skipping requires BOTH conditions: version 7 AND the Arabic shaping
    # delegates. An IM7 built without harfbuzz/fribidi cannot shape Arabic, so
    # treating "version is 7" as done leaves the machine permanently broken for
    # Arabic — the skip guarantees it is never rebuilt.
    _im_arabic_ok=false
    if [[ "$current_im_ver" == "7" ]]; then
        sre_check_imagick_arabic >/dev/null 2>&1 && _im_arabic_ok=true
    fi

    if [[ "$current_im_ver" == "7" && "$_im_arabic_ok" == "true" && "$SRE_FORCE_IMAGICK" != "true" ]]; then
        sre_skipped "ImageMagick 7 with Arabic shaping already installed"
        sre_check_imagick_arabic || true
    else
        if [[ "$current_im_ver" == "7" && "$_im_arabic_ok" != "true" ]]; then
            sre_warning "ImageMagick 7 is installed but WITHOUT Arabic text shaping."
            sre_check_imagick_arabic || true
            sre_warning "Recompiling it with --with-harfbuzz --with-fribidi --with-raqm."
            sre_warning "The existing build will be replaced."
            if ! prompt_yesno "Recompile ImageMagick 7 now? (takes several minutes)" "yes"; then
                sre_skipped "Keeping the current ImageMagick 7 (Arabic shaping stays broken)"
                _im_skip_build=true
            fi
        elif [[ "$SRE_FORCE_IMAGICK" == "true" ]]; then
            sre_info "--force-imagick given: rebuilding ImageMagick 7 from source"
        fi
    fi

    if [[ "${_im_skip_build:-false}" != "true" ]] \
       && { [[ "$current_im_ver" != "7" ]] || [[ "$_im_arabic_ok" != "true" ]] || [[ "$SRE_FORCE_IMAGICK" == "true" ]]; }; then
        sre_info "Installing ImageMagick 7 from source..."

        # Remove old ImageMagick 6 if present
        case "$SRE_OS_FAMILY" in
            debian)
                apt-get remove -y imagemagick libmagickwand-dev libmagickcore-dev 2>/dev/null || true
                apt-get autoremove -y 2>/dev/null || true
                # Build dependencies
                pkg_install build-essential pkg-config libltdl-dev \
                    libpng-dev libjpeg-dev libwebp-dev libtiff-dev \
                    libfreetype6-dev libfontconfig1-dev \
                    libharfbuzz-dev libfribidi-dev libraqm-dev \
                    libpango1.0-dev libxml2-dev libzip-dev \
                    liblcms2-dev libheif-dev libraw-dev libopenjp2-7-dev
                ;;
            rhel)
                dnf remove -y ImageMagick ImageMagick-devel 2>/dev/null || true
                pkg_install gcc make pkgconfig libtool-ltdl-devel \
                    libpng-devel libjpeg-devel libwebp-devel libtiff-devel \
                    freetype-devel fontconfig-devel \
                    harfbuzz-devel fribidi-devel libraqm-devel \
                    pango-devel libxml2-devel libzip-devel \
                    lcms2-devel libheif-devel LibRaw-devel openjpeg2-devel
                ;;
        esac

        # The Arabic shaping trio is installed as part of a large batch above.
        # apt-get/dnf fail the ENTIRE batch if any one package name is
        # unavailable, which is how an IM7 ends up built without harfbuzz and
        # fribidi. Install them individually and confirm the headers exist
        # before configure, so this fails here with a clear message rather than
        # silently producing a build that cannot shape Arabic.
        sre_info "Verifying Arabic shaping build dependencies..."
        case "$SRE_OS_FAMILY" in
            debian)
                for _p in libharfbuzz-dev libfribidi-dev libraqm-dev; do
                    pkg_install "$_p" || sre_warning "  could not install $_p"
                done
                ;;
            rhel)
                for _p in harfbuzz-devel fribidi-devel libraqm-devel; do
                    pkg_install "$_p" || sre_warning "  could not install $_p"
                done
                ;;
        esac

        _missing_dev=()
        for _m in harfbuzz fribidi raqm; do
            pkg-config --exists "$_m" 2>/dev/null || _missing_dev+=("$_m")
        done
        if (( ${#_missing_dev[@]} > 0 )); then
            sre_error "Missing development libraries: ${_missing_dev[*]}"
            sre_error "ImageMagick would build WITHOUT Arabic text shaping."
            case "$SRE_OS_FAMILY" in
                debian) sre_error "  sudo apt-get install -y libharfbuzz-dev libfribidi-dev libraqm-dev" ;;
                rhel)   sre_error "  sudo dnf install -y harfbuzz-devel fribidi-devel libraqm-devel" ;;
            esac
            if ! prompt_yesno "Continue anyway (Arabic shaping will NOT work)?" "no"; then
                sre_error "Aborting so the dependencies can be installed first."
                exit 1
            fi
        else
            sre_success "harfbuzz, fribidi and raqm development libraries present"
        fi

        # Download and compile ImageMagick 7
        im7_build_dir="/tmp/imagemagick7-build"
        rm -rf "$im7_build_dir"
        mkdir -p "$im7_build_dir"
        cd "$im7_build_dir"

        im7_version="7.1.1-43"
        wget -q "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${im7_version}.tar.gz" -O "ImageMagick-${im7_version}.tar.gz" \
            || wget -q "https://imagemagick.org/archive/ImageMagick-${im7_version}.tar.gz"

        tar xzf "ImageMagick-${im7_version}.tar.gz"
        im7_src_dir=$(find . -maxdepth 1 -type d -name 'ImageMagick*' | head -1)
        if [[ -z "$im7_src_dir" ]]; then
            sre_error "ImageMagick source directory not found after extraction"
            exit 1
        fi
        cd "$im7_src_dir"

        ./configure \
            --prefix=/usr/local \
            --with-modules \
            --enable-shared \
            --disable-static \
            --with-freetype=yes \
            --with-fontconfig=yes \
            --with-harfbuzz=yes \
            --with-fribidi=yes \
            --with-raqm=yes \
            --with-pango=yes \
            --with-png=yes \
            --with-jpeg=yes \
            --with-webp=yes \
            --with-tiff=yes \
            --with-heic=yes \
            --with-xml=yes \
            --with-lcms=yes

        # configure SUCCEEDS even when raqm/harfbuzz/fribidi are unavailable —
        # it just quietly builds without them, and Arabic text then renders
        # unshaped and reversed. Catch that here, before spending minutes on
        # make, rather than discovering it in a browser later.
        # Read the FINAL column of configure's summary table, e.g.
        #   RAQM            --with-raqm=yes         yes
        # Matching "yes" anywhere on the line is wrong: it also matches the
        # --with-raqm=yes flag name on a line whose result column says "no".
        _im7_missing=()
        for _dep in raqm harfbuzz fribidi; do
            _val=$(awk -v d="$_dep" \
                'toupper($1)==toupper(d) { print tolower($NF) }' config.log 2>/dev/null | tail -1)
            [[ "$_val" == "yes" ]] || _im7_missing+=("$_dep")
        done
        if (( ${#_im7_missing[@]} > 0 )); then
            sre_warning "configure could not enable: ${_im7_missing[*]}"
            sre_warning "Arabic text shaping needs all of raqm, harfbuzz and fribidi."
            sre_warning "Install the -dev/-devel packages and re-run step 4."
            if ! prompt_yesno "Continue building anyway (Arabic shaping may not work)?" "no"; then
                sre_error "Aborting ImageMagick 7 build at user request."
                cd /; rm -rf "$im7_build_dir"
                exit 1
            fi
        fi

        make -j"$(nproc)"
        make install
        ldconfig

        # Verify installation. Use the freshly installed binary explicitly:
        # a stale IM6 `convert` may still be first on PATH in this shell.
        _im7_magick="/usr/local/bin/magick"
        [[ -x "$_im7_magick" ]] || _im7_magick="magick"
        if "$_im7_magick" --version 2>/dev/null | grep -q "ImageMagick 7"; then
            sre_success "ImageMagick 7 compiled and installed"
            # Confirm the Arabic delegates actually made it into the binary.
            sre_check_imagick_arabic || true
        else
            sre_error "ImageMagick 7 installation may have failed — check manually"
        fi

        cd /
        rm -rf "$im7_build_dir"
    fi

    # Rebuild PHP imagick extension against ImageMagick 7 (all installed versions)
    sre_info "Rebuilding PHP imagick extension for ImageMagick 7..."

    # Track per-version failures so the summary reflects reality. Declared
    # before the loop because set -u would abort on an unset array below.
    _imagick_failed=()

    for _php_ver in "${all_php_versions[@]}"; do
        sre_info "  Building imagick for PHP ${_php_ver}..."

        # Remove distro php-imagick (linked to IM6)
        case "$SRE_OS_FAMILY" in
            debian) apt-get remove -y "php${_php_ver}-imagick" 2>/dev/null || true ;;
            rhel)   dnf remove -y php-imagick 2>/dev/null || true ;;
        esac

        # Install build deps. ImageMagick headers are required, not just
        # php-dev — without them the build fails on "Cannot find MagickWand.h".
        case "$SRE_OS_FAMILY" in
            debian)
                pkg_install "php${_php_ver}-dev" || pkg_install php-dev || true
                pkg_install pkg-config make gcc || true
                ;;
            rhel)
                pkg_install php-devel || true
                pkg_install pkgconfig make gcc || true
                ;;
        esac

        # Where the headers come from depends on how we got here. If this run
        # compiled IM7, they are under /usr/local. But if IM7 was SKIPPED as
        # already-installed and came from a package rather than source, there
        # are no /usr/local headers and PECL fails on a missing MagickWand.h.
        # Only fall back to the distro -dev package when no source IM7 exists,
        # since that package carries the IM6 headers we must not link against.
        if _im7_pfx="$(sre_im7_prefix)"; then
            sre_info "  Using ImageMagick 7 headers from ${_im7_pfx}"
        elif pkg-config --exists MagickWand 2>/dev/null; then
            sre_info "  Using ImageMagick headers already on the system ($(pkg-config --modversion MagickWand 2>/dev/null))"
        else
            sre_warning "  No ImageMagick development headers found — installing distro package."
            sre_warning "  These are ImageMagick 6 headers; Arabic shaping needs a source IM7."
            case "$SRE_OS_FAMILY" in
                debian) pkg_install libmagickwand-dev || true ;;
                rhel)   pkg_install ImageMagick-devel || true ;;
            esac
        fi

        if ! sre_pecl_install_imagick "$_php_ver"; then
            sre_error "  imagick build FAILED for PHP ${_php_ver}"
            sre_error "  Not writing imagick.ini — a stale extension= line makes"
            sre_error "  every PHP request emit a startup warning."
            _imagick_failed+=("$_php_ver")
            continue
        fi

        case "$SRE_OS_FAMILY" in
            debian)
                im_ini_dir="/etc/php/${_php_ver}/mods-available"
                mkdir -p "$im_ini_dir"
                echo "extension=imagick.so" > "${im_ini_dir}/imagick.ini"
                phpenmod -v "$_php_ver" imagick 2>/dev/null || true
                ;;
            rhel)
                echo "extension=imagick.so" > "/etc/php.d/imagick.ini"
                ;;
        esac

        # phpenmod/the .ini has already been written, so the CLI should see the
        # extension immediately. If it does not, the build produced nothing
        # usable — treat that as a failure rather than a "check it later".
        if sre_verify_imagick "$_php_ver"; then
            sre_success "  imagick built and loaded for PHP ${_php_ver}"
        else
            sre_error "  imagick does NOT load for PHP ${_php_ver} despite building."
            sre_error "  Usual cause: built against a different PHP, so the .so"
            sre_error "  landed in another extension_dir. Compare:"
            sre_error "    php${_php_ver} -i | grep '^extension_dir'"
            sre_error "    ls -l \$(php${_php_ver} -r 'echo ini_get(\"extension_dir\");')/imagick.so"
            _imagick_failed+=("$_php_ver")
        fi
    done

    if (( ${#_imagick_failed[@]} > 0 )); then
        sre_error "PHP imagick could NOT be built for: ${_imagick_failed[*]}"
        sre_error "Arabic text rendering will not work for those versions."
        sre_error "Retry later with: sudo bash fixes/12-fixes.sh  → imagick-arabic"
    else
        sre_success "PHP imagick extension rebuilt for ImageMagick 7"
    fi

    # Configure ImageMagick policy for Arabic text rendering
    im_policy_path=""
    if [[ -f /usr/local/etc/ImageMagick-7/policy.xml ]]; then
        im_policy_path="/usr/local/etc/ImageMagick-7/policy.xml"
    elif [[ -f /etc/ImageMagick-7/policy.xml ]]; then
        im_policy_path="/etc/ImageMagick-7/policy.xml"
    fi

    if [[ -n "$im_policy_path" ]]; then
        backup_config "$im_policy_path"
        # Ensure text/font delegates are not blocked
        sed -i '/<policy domain="coder" rights="none" pattern="TEXT"/d' "$im_policy_path"
        sed -i '/<policy domain="coder" rights="none" pattern="LABEL"/d' "$im_policy_path"
        sed -i '/<policy domain="coder" rights="none" pattern="PANGO"/d' "$im_policy_path"
        sre_success "ImageMagick policy updated: TEXT/LABEL/PANGO delegates enabled"
    fi

    # Set default font to Noto Sans Arabic for ImageMagick
    im_type_path=""
    if [[ -d /usr/local/etc/ImageMagick-7 ]]; then
        im_type_path="/usr/local/etc/ImageMagick-7/type-arabic.xml"
    elif [[ -d /etc/ImageMagick-7 ]]; then
        im_type_path="/etc/ImageMagick-7/type-arabic.xml"
    fi

    if [[ -n "$im_type_path" ]]; then
        cat > "$im_type_path" <<'TYPEXML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE typemap [
  <!ELEMENT typemap (type)+>
  <!ATTLIST type name CDATA #REQUIRED>
  <!ATTLIST type fullname CDATA #IMPLIED>
  <!ATTLIST type family CDATA #IMPLIED>
  <!ATTLIST type style CDATA #IMPLIED>
  <!ATTLIST type stretch CDATA #IMPLIED>
  <!ATTLIST type weight CDATA #IMPLIED>
  <!ATTLIST type glyphs CDATA #REQUIRED>
]>
<typemap>
  <type name="NotoSansArabic" fullname="Noto Sans Arabic" family="Noto Sans Arabic"
    style="Normal" stretch="Normal" weight="400"
    glyphs="/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"/>
  <type name="NotoSansArabic-Bold" fullname="Noto Sans Arabic Bold" family="Noto Sans Arabic"
    style="Normal" stretch="Normal" weight="700"
    glyphs="/usr/share/fonts/truetype/noto/NotoSansArabic-Bold.ttf"/>
  <type name="Amiri" fullname="Amiri" family="Amiri"
    style="Normal" stretch="Normal" weight="400"
    glyphs="/usr/share/fonts/truetype/hosny-amiri/Amiri-Regular.ttf"/>
  <type name="KacstOne" fullname="KacstOne" family="KacstOne"
    style="Normal" stretch="Normal" weight="400"
    glyphs="/usr/share/fonts/truetype/kacst-one/KacstOne.ttf"/>
</typemap>
TYPEXML
        sre_success "Arabic font type map registered with ImageMagick"
    fi

else
    sre_info "[DRY-RUN] Would install ImageMagick 7 from source with Arabic support:"
    sre_info "  - Arabic fonts (Noto, Amiri, KACST, Arabeyes)"
    sre_info "  - Text shaping: harfbuzz, fribidi, raqm, pango"
    sre_info "  - Compile ImageMagick 7 with --with-harfbuzz --with-fribidi --with-raqm --with-pango"
    sre_info "  - Rebuild PHP imagick extension via PECL"
    sre_info "  - Register Arabic fonts in ImageMagick type map"
fi

# --- Configure Secure php.ini Defaults ---
sre_header "Configuring php.ini (FPM + CLI)"

php_ini_files=()
case "$SRE_OS_FAMILY" in
    debian)
        for _php_ver in "${all_php_versions[@]}"; do
            php_ini_files+=("/etc/php/${_php_ver}/fpm/php.ini")
            php_ini_files+=("/etc/php/${_php_ver}/cli/php.ini")
        done
        ;;
    rhel)
        php_ini_files+=("/etc/php.ini")
        ;;
esac

_apply_php_ini_settings() {
    local ini_file="$1"
    if [[ ! -f "$ini_file" ]]; then
        sre_warning "php.ini not found at $ini_file — skipping"
        return 0
    fi

    sre_info "Configuring $ini_file"
    backup_config "$ini_file"

    # Security settings
    sed -i 's/^[;]*\s*expose_php\s*=.*/expose_php = Off/' "$ini_file"

    # Disable dangerous functions — keep exec/proc_open/popen for Laravel, Composer, Horizon
    sed -i 's/^[;]*\s*disable_functions\s*=.*/disable_functions = passthru,shell_exec,system/' "$ini_file"

    # Opcache must respect filesystem permissions on cache hits — all FPM pools
    # share one opcache SHM, so without this a per-project pool could read
    # another project's cached scripts (required for the isolation model)
    local _oc
    for _oc in opcache.validate_permission opcache.validate_root; do
        if grep -qE "^[;[:space:]]*${_oc}[[:space:]]*=" "$ini_file"; then
            sed -i "s/^[;[:space:]]*${_oc}[[:space:]]*=.*/${_oc} = 1/" "$ini_file"
        else
            echo "${_oc} = 1" >> "$ini_file"
        fi
    done

    # Upload and memory limits
    sed -i 's/^[;]*\s*upload_max_filesize\s*=.*/upload_max_filesize = 256M/' "$ini_file"
    sed -i 's/^[;]*\s*post_max_size\s*=.*/post_max_size = 256M/' "$ini_file"
    sed -i 's/^[;]*\s*memory_limit\s*=.*/memory_limit = 1024M/' "$ini_file"
    sed -i 's/^[;]*\s*max_execution_time\s*=.*/max_execution_time = 1200/' "$ini_file"
    sed -i 's/^[;]*\s*max_input_time\s*=.*/max_input_time = 1200/' "$ini_file"
    sed -i 's/^[;]*\s*max_file_uploads\s*=.*/max_file_uploads = 20/' "$ini_file"

    sre_success "Configured: $ini_file"
}

if [[ "$SRE_DRY_RUN" != "true" ]]; then
    for ini_file in "${php_ini_files[@]}"; do
        _apply_php_ini_settings "$ini_file"
    done
    sre_success "All php.ini files configured with secure defaults"
else
    sre_info "[DRY-RUN] Would configure php.ini files: ${php_ini_files[*]}"
    sre_info "  expose_php = Off"
    sre_info "  disable_functions = passthru,shell_exec,system"
    sre_info "  opcache.validate_permission = 1"
    sre_info "  opcache.validate_root = 1"
    sre_info "  upload_max_filesize = 256M"
    sre_info "  post_max_size = 256M"
    sre_info "  memory_limit = 1024M"
    sre_info "  max_execution_time = 1200"
    sre_info "  max_input_time = 1200"
    sre_info "  max_file_uploads = 20"
fi

# --- Verify PHP-FPM Services ---
sre_header "Verifying PHP-FPM Services"

for _php_ver in "${all_php_versions[@]}"; do
    fpm_svc=$(get_phpfpm_svc "$_php_ver")
    if systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
        sre_success "$fpm_svc is running"
    else
        sre_warning "$fpm_svc not running — attempting restart..."
        svc_enable_start "$fpm_svc"
    fi
done

# --- Persist config ---
config_set "SRE_PHP_INSTALLED" "true"

sre_success "PHP installation complete: ${all_php_versions[*]} (default: ${local_ver})"
sre_info "Config saved to: $SRE_CONFIG_FILE"

recommend_next_step "$CURRENT_STEP"
