#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: EEJoshua
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/rakshasa/rtorrent

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Relax GCC 14 strictness for older codebases (resolves xmlrpc-c detection issues)
export CFLAGS="-Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=incompatible-pointer-types"
export CXXFLAGS="-Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=incompatible-pointer-types"

# Helper function for generating random alphanumeric strings
_string() { openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c16; }

msg_info "Installing Dependencies"
# Ensure non-free is enabled for unrar
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    sed -i -r 's/^Components: .*/& non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources
fi
$STD apt-get update
$STD apt-get install -y \
  nginx \
  git \
  unzip \
  tmux \
  ffmpeg \
  mediainfo \
  sox \
  curl \
  dtach \
  build-essential \
  automake \
  libtool \
  pkg-config \
  libcurl4-openssl-dev \
  libncursesw5-dev \
  libsigc++-2.0-dev \
  zlib1g-dev \
  libssl-dev \
  subversion \
  libxml2-dev \
  autoconf-archive \
  screen \
  jq \
  python3 \
  python-is-python3 \
  python3-pip \
  irssi \
  libarchive-zip-perl \
  libnet-ssleay-perl \
  libhtml-parser-perl \
  libxml-libxml-perl \
  libdigest-sha-perl \
  libjson-perl \
  libjson-xs-perl \
  libxml-libxslt-perl \
  unrar
msg_ok "Installed Dependencies"

msg_info "Setting up PHP"
PHP_VERSION="8.3"
PHP_FPM="YES" PHP_MODULE="curl,mbstring,cli,xml,zip,sockets" setup_php
msg_ok "Setup PHP"

msg_info "Installing Python Libraries"
$STD pip3 install cloudscraper --break-system-packages
msg_ok "Installed Python Libraries"

msg_info "Compiling XML-RPC-C"
svn checkout -q https://svn.code.sf.net/p/xmlrpc-c/code/advanced xmlrpc-c
cd xmlrpc-c || exit
./configure --disable-cplusplus >/dev/null

# Force i8 (int64) support since configure fails on modern GCC
sed -i '$i #define HAVE_INT64 1' xmlrpc_config.h

make -j$(nproc) CXXFLAGS="-w" CFLAGS="-w" ARFLAGS="rc" >/dev/null
make install >/dev/null
ldconfig
cd ..
rm -rf xmlrpc-c
msg_ok "Compiled XML-RPC-C"

msg_info "Compiling LibTorrent (Rakshasa)"
git clone -q https://github.com/rakshasa/libtorrent.git /opt/libtorrent
cd /opt/libtorrent || exit
autoreconf -fiv >/dev/null 2>&1
./configure --disable-debug --enable-aligned >/dev/null
make -j$(nproc) CXXFLAGS="-w" CFLAGS="-w" >/dev/null
make install >/dev/null
ldconfig
msg_ok "Compiled LibTorrent"

msg_info "Compiling rTorrent (Rakshasa)"
git clone -q https://github.com/rakshasa/rtorrent.git /opt/rtorrent-src
cd /opt/rtorrent-src || exit
autoreconf -fiv >/dev/null 2>&1
./configure --with-xmlrpc-c --disable-debug >/dev/null
make -j$(nproc) CXXFLAGS="-w" CFLAGS="-w" >/dev/null
make install >/dev/null
msg_ok "Compiled rTorrent"

msg_info "Compiling dumptorrent"
git clone -q https://github.com/tomcdj71/dumptorrent.git /opt/dumptorrent
cd /opt/dumptorrent || exit
gcc -Wall -o dumptorrent src/*.c -I include >/dev/null 2>&1
cp dumptorrent /usr/local/bin/
chmod +x /usr/local/bin/dumptorrent
cd ..
rm -rf /opt/dumptorrent
msg_ok "Compiled dumptorrent"

msg_info "Configuring rTorrent User"
useradd -u 1000 -U -d /home/rtorrent -s /bin/bash rtorrent
mkdir -p /home/rtorrent/{.session,download,watch}
chown -R rtorrent:rtorrent /home/rtorrent
msg_ok "Configured rTorrent User"

msg_info "Configuring Autodl-Irssi"
RELEASE_URL=$(curl -sL https://api.github.com/repos/autodl-community/autodl-irssi/releases/latest | jq -r '.assets[0].browser_download_url')
if [[ -z "$RELEASE_URL" || "$RELEASE_URL" == "null" ]]; then
    msg_error "Failed to fetch autodl-irssi release URL"
    exit 1
fi

wget -q "$RELEASE_URL" -O /tmp/autodl-irssi.zip
if [[ ! -f /tmp/autodl-irssi.zip ]]; then
    msg_error "Failed to download autodl-irssi"
    exit 1
fi

mkdir -p /home/rtorrent/.irssi/scripts/autorun
unzip -o /tmp/autodl-irssi.zip -d /home/rtorrent/.irssi/scripts/ >/dev/null
if [[ ! -f /home/rtorrent/.irssi/scripts/autodl-irssi.pl ]]; then
    msg_error "Failed to extract autodl-irssi"
    exit 1
fi
cp /home/rtorrent/.irssi/scripts/autodl-irssi.pl /home/rtorrent/.irssi/scripts/autorun/

IRSSI_PASS=$(_string)
IRSSI_PORT=$(shuf -i 20000-61000 -n 1)
mkdir -p /home/rtorrent/.autodl
cat > /home/rtorrent/.autodl/autodl.cfg << EOF
[options]
gui-server-port = ${IRSSI_PORT}
gui-server-password = ${IRSSI_PASS}
EOF

chown -R rtorrent:rtorrent /home/rtorrent/.irssi
chown -R rtorrent:rtorrent /home/rtorrent/.autodl
rm /tmp/autodl-irssi.zip

cat > "/etc/systemd/system/irssi@.service" << EOF
[Unit]
Description=AutoDL IRSSI
After=network.target

[Service]
Type=forking
KillMode=none
User=%i
ExecStart=/usr/bin/screen -d -m -fa -S irssi /usr/bin/irssi
ExecStop=/usr/bin/screen -S irssi -X stuff '/quit\n'
WorkingDirectory=/home/%i/

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now irssi@rtorrent
msg_ok "Configured Autodl-Irssi"

msg_info "Configuring rTorrent Service"
cat <<EOF >/etc/systemd/system/rtorrent.service
[Unit]
Description=rTorrent
After=network.target

[Service]
Type=forking
User=rtorrent
Group=rtorrent
ExecStart=/usr/bin/tmux new-session -s rtorrent -n rtorrent -d '/usr/local/bin/rtorrent'
ExecStop=/usr/bin/tmux kill-session -t rtorrent
WorkingDirectory=/home/rtorrent
RemainAfterExit=yes
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now rtorrent
msg_info "Installing ruTorrent"
mkdir -p /var/www
git clone -q https://github.com/Novik/ruTorrent.git /var/www/rutorrent
# Disable false-positive XML-RPC version check
sed -i 's/public \$badXMLRPCVersion = true;/public \$badXMLRPCVersion = false;/' /var/www/rutorrent/php/settings.php
chown -R www-data:www-data /var/www/rutorrent
chmod -R 775 /var/www/rutorrent
msg_ok "Installed ruTorrent"

msg_info "Installing Autodl-Irssi Plugin"
git clone -q https://github.com/swizzin/autodl-rutorrent.git /var/www/rutorrent/plugins/autodl-irssi
chown -R www-data:www-data /var/www/rutorrent/plugins/autodl-irssi

# Use conf.php to force IPv4 and avoid config conflicts
IRSSI_PORT=$(grep gui-server-port /home/rtorrent/.autodl/autodl.cfg | cut -d= -f2 | sed 's/ //g')
IRSSI_PASS=$(grep gui-server-password /home/rtorrent/.autodl/autodl.cfg | cut -d= -f2 | sed 's/ //g')

cat <<EOF > /var/www/rutorrent/plugins/autodl-irssi/conf.php
<?php
\$autodlHost = "127.0.0.1";
\$autodlPort = "${IRSSI_PORT}";
\$autodlPassword = "${IRSSI_PASS}";
?>
EOF
chown www-data:www-data /var/www/rutorrent/plugins/autodl-irssi/conf.php

# Skip incompatible rDirBrowser code that causes JS errors
sed -i 's/if (thePlugins.isInstalled("_getdir"))/if (false \&\& thePlugins.isInstalled("_getdir"))/' /var/www/rutorrent/plugins/autodl-irssi/js/UploadMethod.js

msg_ok "Installed Autodl-Irssi Plugin"



msg_info "Configuring Nginx"
rm -f /etc/nginx/sites-enabled/default

cat <<EOF >/etc/nginx/sites-available/rutorrent
server {
    listen 80;
    server_name _;
    root /var/www/rutorrent;
    index index.html index.php;

    access_log /var/log/nginx/rutorrent-access.log;
    error_log /var/log/nginx/rutorrent-error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location /RPC2 {
        include scgi_params;
        scgi_pass 127.0.0.1:5000;
    }
}
EOF
ln -s /etc/nginx/sites-available/rutorrent /etc/nginx/sites-enabled/rutorrent

cat <<EOF >/home/rtorrent/.rtorrent.rc
# Global settings
directory.default.set = /home/rtorrent/download
session.path.set = /home/rtorrent/.session
protocol.encryption.set = allow_incoming,try_outgoing,enable_retry

# RPC for ruTorrent
network.scgi.open_port = 127.0.0.1:5000
encoding.add = UTF-8

# Watch directory
schedule2 = watch_directory,5,5,load.start=/home/rtorrent/watch/*.torrent
EOF
chown rtorrent:rtorrent /home/rtorrent/.rtorrent.rc

systemctl restart rtorrent
systemctl restart nginx
systemctl restart php"${PHP_VERSION}"-fpm
msg_ok "Configured Web Server"

motd_ssh
customize
cleanup_lxc
