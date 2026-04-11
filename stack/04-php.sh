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
  --dry-run   Print planned actions without executing
  --yes       Accept defaults without prompting
  --config    Override config file path
  --log       Override log file path
  --help      Show this help

Example:
  sudo bash $0
  sudo bash $0 --yes --dry-run
EOF
}

sre_parse_args "04-php.sh" "$@"
require_root

sre_header "Step 4: PHP Installation"

config_load || { sre_error "Config not found. Run step 1 first."; exit 2; }

require_config_key "SRE_PHP_VERSION" "1" > /dev/null
require_config_key "SRE_WEB_SERVER_INSTALLED" "3" > /dev/null

SRE_OS_FAMILY="$(config_get SRE_OS_FAMILY)"
SRE_PHP_VERSION="$(config_get SRE_PHP_VERSION)"

sre_info "OS family: $SRE_OS_FAMILY"
sre_info "PHP version: $SRE_PHP_VERSION"

# --- Install PHP-FPM and Extensions ---
sre_header "Installing PHP ${SRE_PHP_VERSION}"

local_ver="${SRE_PHP_VERSION}"

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
        else
            sre_skipped "ondrej/php PPA already present"
        fi

        php_packages=(
            "php${local_ver}-fpm"
            "php${local_ver}-cli"
            "php${local_ver}-mysql"
            "php${local_ver}-pgsql"
            "php${local_ver}-mbstring"
            "php${local_ver}-xml"
            "php${local_ver}-curl"
            "php${local_ver}-zip"
            "php${local_ver}-gd"
            "php${local_ver}-intl"
            "php${local_ver}-bcmath"
            "php${local_ver}-soap"
            "php${local_ver}-redis"
            "php${local_ver}-opcache"
        )

        sre_info "Installing PHP packages: ${php_packages[*]}"
        pkg_install "${php_packages[@]}"
        ;;

    rhel)
        # Enable Remi repository for PHP 8.x
        if ! rpm -q remi-release &>/dev/null; then
            sre_info "Enabling Remi repository for PHP ${local_ver}..."
            if [[ "$SRE_DRY_RUN" != "true" ]]; then
                os_ver=""
                os_ver="$(config_get SRE_OS_VERSION)"
                remi_major="${os_ver%%.*}"
                dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${remi_major}.rpm" || true
                dnf module -y reset php 2>/dev/null || true
                remi_stream="${local_ver//./}"
                dnf module -y enable "php:remi-${local_ver}" 2>/dev/null || true
            else
                sre_info "[DRY-RUN] Would enable Remi repository"
            fi
        else
            sre_skipped "Remi repository already enabled"
        fi

        php_packages=(
            php-fpm
            php-cli
            php-mysqlnd
            php-pgsql
            php-mbstring
            php-xml
            php-curl
            php-zip
            php-gd
            php-intl
            php-bcmath
            php-soap
            php-pecl-redis
            php-opcache
        )

        sre_info "Installing PHP packages: ${php_packages[*]}"
        pkg_install "${php_packages[@]}"
        ;;
esac

sre_success "PHP ${local_ver} packages installed"

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

    if [[ "$current_im_ver" == "7" ]]; then
        sre_skipped "ImageMagick 7 already installed"
    else
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

        # Download and compile ImageMagick 7
        im7_build_dir="/tmp/imagemagick7-build"
        rm -rf "$im7_build_dir"
        mkdir -p "$im7_build_dir"
        cd "$im7_build_dir"

        im7_version="7.1.1-43"
        wget -q "https://imagemagick.org/archive/ImageMagick-${im7_version}.tar.gz" \
            || wget -q "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${im7_version}.tar.gz" -O "ImageMagick-${im7_version}.tar.gz"

        tar xzf "ImageMagick-${im7_version}.tar.gz"
        cd ImageMagick-* || cd imagemagick-*

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

        make -j"$(nproc)"
        make install
        ldconfig

        # Verify installation
        if magick --version 2>/dev/null | grep -q "ImageMagick 7"; then
            sre_success "ImageMagick 7 compiled and installed"
        else
            sre_error "ImageMagick 7 installation may have failed — check manually"
        fi

        cd /
        rm -rf "$im7_build_dir"
    fi

    # Rebuild PHP imagick extension against ImageMagick 7
    sre_info "Rebuilding PHP imagick extension for ImageMagick 7..."

    # Remove distro php-imagick (linked to IM6)
    case "$SRE_OS_FAMILY" in
        debian) apt-get remove -y "php${local_ver}-imagick" 2>/dev/null || true ;;
        rhel)   dnf remove -y php-imagick 2>/dev/null || true ;;
    esac

    # Install from PECL
    pkg_install "php${local_ver}-dev" 2>/dev/null || pkg_install php-devel
    printf "\n" | pecl install imagick 2>/dev/null || true

    # Enable the extension
    im_ini_dir=""
    case "$SRE_OS_FAMILY" in
        debian) im_ini_dir="/etc/php/${local_ver}/mods-available" ;;
        rhel)   im_ini_dir="/etc/php.d" ;;
    esac

    if [[ -n "$im_ini_dir" ]]; then
        mkdir -p "$im_ini_dir"
        echo "extension=imagick.so" > "${im_ini_dir}/imagick.ini"
        case "$SRE_OS_FAMILY" in
            debian) phpenmod -v "$local_ver" imagick 2>/dev/null || true ;;
        esac
    fi

    sre_success "PHP imagick extension rebuilt for ImageMagick 7"

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
        php_ini_files+=("/etc/php/${local_ver}/fpm/php.ini")
        php_ini_files+=("/etc/php/${local_ver}/cli/php.ini")
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
    sre_info "  upload_max_filesize = 256M"
    sre_info "  post_max_size = 256M"
    sre_info "  memory_limit = 1024M"
    sre_info "  max_execution_time = 1200"
    sre_info "  max_input_time = 1200"
    sre_info "  max_file_uploads = 20"
fi

# --- Enable and Start PHP-FPM ---
sre_header "Starting PHP-FPM"

case "$SRE_OS_FAMILY" in
    debian)
        fpm_service="php${local_ver}-fpm"
        ;;
    rhel)
        fpm_service="php-fpm"
        ;;
esac

sre_info "Enabling and starting $fpm_service..."
svc_enable_start "$fpm_service"
sre_success "$fpm_service is running"

# --- Persist config ---
config_set "SRE_PHP_INSTALLED" "true"

sre_success "PHP ${local_ver} installation and configuration complete!"
sre_info "Config saved to: $SRE_CONFIG_FILE"

recommend_next_step "$CURRENT_STEP"
