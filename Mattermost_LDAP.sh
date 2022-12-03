#!/bin/bash

# Yunohost LDAP integration into Mattermost Team Edition
# This script uses https://github.com/Crivaledaz/Mattermost-LDAP/

# This script is licenced under the CECILL-2.1 licence
# https://cecill.info/licences/Licence_CeCILL_V2.1-en.html

# Author : SveDec
# https://github.com/SveDec


################################################################################
##### FUNCTIONS ################################################################
################################################################################

echo_ok() { echo -e '\e[32m'"$1"'\e[m'; }
echo_error() { echo -e '\e[31m'"$1"'\e[m'; }
echo_info() { echo -e '\e[34m'"$1"'\e[m'; }
echo_warn() { echo -e '\e[33m'"$1"'\e[m'; }

check_result() {
  if [ "$1" -eq 0 ]; then
    echo_ok 'OK'
    echo
  else
    echo_error 'Une erreur est survenue, le script va quitter ...'
    echo
    exit 1
  fi 
}


################################################################################
##### PRE-CHECKS ###############################################################
################################################################################

if [ "$(id --user)" -ne 0 ]; then
  echo_error 'This script must be run run as root'
  exit 1
fi

YUNOHOST_APP_LIST="$(yunohost app list)"

if echo "$YUNOHOST_APP_LIST" | grep --quiet 'mattermost'; then
  MATTERMOST_URL="$(yunohost app info mattermost | grep 'domain_path' | cut -d : -f 2 | sed 's/ //g')"
  DOMAIN_NAME="$(echo "$MATTERMOST_URL" | cut -d / -f 1)"
else
  echo_error 'You must install the Yunohost Mattermost app before running this script'
  exit 1
fi


################################################################################
##### VARIABLES ################################################################
################################################################################

# General/system configuration

if [ -n "$SUDO_USER" ]; then
  USER_HOME_DIR="$(getent passwd "$SUDO_USER" | cut -d : -f 6)"
else
  USER_HOME_DIR='/root'
fi

GIT_REPO_URL="https://github.com/Crivaledaz/Mattermost-LDAP.git"
LOCAL_REPO="$USER_HOME_DIR/Mattermost-LDAP" # The repo will be cloned here

OAUTH_APP_NAME='OAuth'

SSOWAT_PERSISTENT_CONF_FILE='/etc/ssowat/conf.json.persistent'
YNH_LOGO_URL='/yunohost/sso/assets/img/logo-ynh.svg'

INIT_DB_CONFIG="$LOCAL_REPO/db_init/config_init.sh"
INIT_DB_SCRIPT="$LOCAL_REPO/db_init/init_mysql.sh"

MATTERMOST_CONFIG_FILE='/var/www/mattermost/config/config.json'

# Database configuration

OAUTH_DB_TYPE='mysql'
OAUTH_DB_HOST='localhost'
OAUTH_DB_PORT='3306'
OAUTH_DB_NAME="${OAUTH_APP_NAME,,}_db"
OAUTH_DB_USER="${OAUTH_APP_NAME,,}"
OAUTH_DB_PASS="$(openssl rand -hex 32)"

CLIENT_ID="$(openssl rand -hex 32)"
CLIENT_SECRET="$(openssl rand -hex 32)"
REDIRECT_URI="https://$MATTERMOST_URL/signup/gitlab/complete"
GRANT_TYPES='authorization_code'
SCOPE='api'
USER_ID=''

# LDAP configuration

LDAP_HOST='localhost'
LDAP_PORT=389
LDAP_VERSION=3
LDAP_START_TLS='false'
LDAP_SEARCH_ATTRIBUTE='uid'
LDAP_BASE_DN='dc=yunohost,dc=org'
LDAP_FILTER='(&(objectClass=posixAccount)(permission=cn=mattermost.main,ou=permission,dc=yunohost,dc=org))'
LDAP_BIND_DN=''
LDAP_BIND_PASS=''


################################################################################
##### CHECKS ###################################################################
################################################################################

# As we are going to use Gitlab SSO as a bridge between Yunohost LDAP and
# Mattermost, we verify that Gitlab is not installed
if echo "$YUNOHOST_APP_LIST" | grep --quiet 'gitlab'; then
  echo_error 'Gitlab is already installed and should be used'
  echo_error 'Installation aborted'
  exit 1
fi

# We check that this Oauth server hasn't been already installed
if [ -d "$LOCAL_REPO" ] || [ -d "$OAUTH_DIR" ]; then
  echo_error 'An Oauth server seems already installed'
  echo_error 'Installation aborted'
  exit 1
fi


################################################################################
##### INSTALLATION #############################################################
################################################################################

echo_info '[STEP 1/15] Downloading repository ...'
git clone "$GIT_REPO_URL" "$LOCAL_REPO"
check_result $?

################################################################################

# We create a blank webapp via Yunohost to make it handle some configurations
echo_info '[STEP 2/15] Installing OAuth blank app ...'
yunohost app install my_webapp --label "$OAUTH_APP_NAME" --args="domain=$DOMAIN_NAME&path=/${OAUTH_APP_NAME,,}&with_sftp=false&password=&is_public=true&phpversion=7.4&with_mysql=false"
check_result $?

################################################################################

echo_info '[STEP 3/15] Getting the app user ...'
OAUTH_APP_USER="$(yunohost app list | grep -B 1 "name: $OAUTH_APP_NAME" | grep 'id' | cut -d : -f 2 | sed 's/ //g')"
check_result $?

OAUTH_DIR="/var/www/$OAUTH_APP_USER/www"

################################################################################

# This is necessary because at some point the .../access_token URL is called,
# and is redirected to the Yunohost panel without this configuration
echo_info '[STEP 4/15] Adding Nginx conf ...'

NGINX_CONFIG_FILE="/etc/nginx/conf.d/$DOMAIN_NAME.d/$OAUTH_APP_USER.conf"
NGINX_TEMP_CONFIG_FILE="$NGINX_CONFIG_FILE-$(date +%Y-%m-%d_%H.%M.%S)"

NGINX_CONF_BLOCK="    location /${OAUTH_APP_NAME,,}/access_token {
      try_files \$uri  /${OAUTH_APP_NAME,,}/index.php;
    }
" 
NGINX_CONF_NEXT_LINE='    # Default indexes and catch-all'

awk -v block="$NGINX_CONF_BLOCK" "/^$NGINX_CONF_NEXT_LINE$/{ print block }1" "$NGINX_CONFIG_FILE" > "$NGINX_TEMP_CONFIG_FILE"
mv "$NGINX_TEMP_CONFIG_FILE" "$NGINX_CONFIG_FILE"
check_result $?

################################################################################

# Yunohost's SSOwat conflicts with the OAuth authentication process, so we
# disable it for the created OAuth app
echo_info '[STEP 5/15] Adding SSOwat conf ...'

SSOWAT_CONF_BLOCK="    \"permissions\": {
        \"$OAUTH_APP_USER.main\": {
            \"auth_header\": false,
            \"label\": \"$OAUTH_APP_NAME\",
            \"public\": true,
            \"show_tile\": false,
            \"uris\": [
                \"$DOMAIN_NAME/${OAUTH_APP_NAME,,}\"
            ],
            \"users\": []
        }
    }"

SSOWAT_PERSISTENT_CONF="$(cat $SSOWAT_PERSISTENT_CONF_FILE)"
if [ "$SSOWAT_PERSISTENT_CONF" == '{}' ]; then
  echo "{
$SSOWAT_CONF_BLOCK
}" > "$SSOWAT_PERSISTENT_CONF_FILE"
check_result $?

else
  SSOWAT_TEMP_CONF_FILE="$SSOWAT_PERSISTENT_CONF_FILE-$(date +%Y-%m-%d_%H.%M.%S)"
  awk -v block="$SSOWAT_CONF_BLOCK" "/^}$/{ print block }1" "$SSOWAT_PERSISTENT_CONF_FILE" > "$SSOWAT_TEMP_CONF_FILE"
  mv "$SSOWAT_TEMP_CONF_FILE" "$SSOWAT_PERSISTENT_CONF_FILE"
  check_result $?
fi

################################################################################

echo_info '[STEP 6/15] Copying the oauth server directory ...'
rm -rf "$OAUTH_DIR"
cp --archive "$LOCAL_REPO/oauth" "$OAUTH_DIR"
check_result $?

################################################################################

echo_info '[STEP 7/15] Refactoring the LDAP form ...'

LDAP_FORM_FILE="$OAUTH_DIR/form_prompt.html"
LDAP_TEMP_FORM_FILE="$LDAP_FORM_FILE-$(date +%Y-%m-%d_%H.%M.%S)"

awk -v line=7 -v size=3 'line <= NR && NR <= line+size-1 { next } { print }' "$LDAP_FORM_FILE" > "$LDAP_TEMP_FORM_FILE" # Removes external font providers
sed --in-place 's/LDAP/Yunohost LDAP/g' "$LDAP_TEMP_FORM_FILE" # Adds 'Yunohost' mention
sed --in-place '/^[[:space:]]*$/d' "$LDAP_TEMP_FORM_FILE" # Removes blank lines
sed --in-place '/<h1>/d' "$LDAP_TEMP_FORM_FILE" # Removes the (useless) page title
sed --in-place "s/.\/images\/prompt_icon.png/${YNH_LOGO_URL//\//\\\/}/" "$LDAP_TEMP_FORM_FILE" # Replaces the default picture with the Yunohost logo
mv "$LDAP_TEMP_FORM_FILE" "$LDAP_FORM_FILE"
check_result $?

################################################################################

echo_info '[STEP 8/15] Ajusting oauth directory rights ...'
chown --recursive "$OAUTH_APP_USER":www-data "$OAUTH_DIR"
check_result $?

################################################################################

echo_info '[STEP 9/15] Building the config file for the oauth database installation script ...'

touch "$INIT_DB_CONFIG"
chmod 755 "$INIT_DB_CONFIG"

# The lines below are the ones from the config_init.sh.example file
cat <<EOT >> "$INIT_DB_CONFIG"
#####################################--CONFIGURATION FILE--########################################

#Client configuration
client_id=$CLIENT_ID
client_secret=$CLIENT_SECRET
redirect_uri=$REDIRECT_URI
grant_types=$GRANT_TYPES
scope=$SCOPE
user_id=$USER_ID

#Database configuration
db_user=$OAUTH_DB_USER
db_name=$OAUTH_DB_NAME
db_pass=$OAUTH_DB_PASS
db_host=$OAUTH_DB_HOST
db_port=$OAUTH_DB_PORT
EOT

check_result $?

################################################################################

echo_info '[STEP 10/15] Modifying the oauth database install script ...'
# This is because in the script, the config file path is not absolute
sed --in-place "s/source config_init.sh/source \"${INIT_DB_CONFIG//\//\\\/}\"/" "$INIT_DB_SCRIPT"
# This is to simplify these lines
sed --in-place 's/sudo mysql -u root --password=\$mysql_pass/mysql/g' "$INIT_DB_SCRIPT"
# And this is to correct the scope of the user
sed --in-place "s/\$db_user@'%'/\$db_user@localhost/g" "$INIT_DB_SCRIPT"
check_result $?

################################################################################

echo_info '[STEP 11/15] Installing the oauth database ...'
"$INIT_DB_SCRIPT"
check_result $?

################################################################################

echo_info '[STEP 12/15] Building the config file for the oauth LDAP ...'

LDAP_CONFIG_FILE="$OAUTH_DIR/LDAP/config_ldap.php"

touch "$LDAP_CONFIG_FILE"
chmod 755 "$LDAP_CONFIG_FILE"

# The lines below are the ones from the config_ldap.php.example file
cat <<EOT >> "$LDAP_CONFIG_FILE"
<?php
// LDAP parameters
\$ldap_host = "$LDAP_HOST";
\$ldap_port = $LDAP_PORT;
\$ldap_version = $LDAP_VERSION;
\$ldap_start_tls = $LDAP_START_TLS;

// Attribute use to identify user on LDAP - ex : uid, mail, sAMAccountName
\$ldap_search_attribute = "$LDAP_SEARCH_ATTRIBUTE";

// variable use in resource.php
\$ldap_base_dn = "$LDAP_BASE_DN";
\$ldap_filter = "$LDAP_FILTER";

// ldap service user to allow search in ldap
\$ldap_bind_dn = "$LDAP_BIND_DN";
\$ldap_bind_pass = "$LDAP_BIND_PASS";
EOT

check_result $?

################################################################################

echo_info '[STEP 13/15] Building the config file for the oauth database ...'

OAUTH_CONFIG_FILE="$OAUTH_DIR/config_db.php"

touch "$OAUTH_CONFIG_FILE"
chmod 755 "$OAUTH_CONFIG_FILE"

# The lines below are the ones from the config_db.php.example file
cat <<EOT >> "$OAUTH_CONFIG_FILE"

<?php

\$db_port	  = "$OAUTH_DB_PORT";
\$db_host	  = "$OAUTH_DB_HOST";
\$db_name	  = "$OAUTH_DB_NAME";
\$db_type 	  = "$OAUTH_DB_TYPE";
\$db_user 	  = "$OAUTH_DB_USER";
\$db_pass 	  = "$OAUTH_DB_PASS";
\$dsn	      = \$db_type . ":dbname=" . \$db_name . ";host=" . \$db_host . ";port=" . \$db_port;

/* Uncomment the line below to set date.timezone to avoid E.Notice raise by strtotime() (in Pdo.php)
 * If date.timezone is not defined in php.ini or with this function, Mattermost could return a bad token request error
*/
//date_default_timezone_set ('Europe/Paris');
EOT

check_result $?

################################################################################

echo_info '[STEP 14/15] Enabling Gitlab auth in Mattermost ...'

MATTERMOST_TEMP_CONFIG_FILE="$MATTERMOST_CONFIG_FILE-$(date +%Y-%m-%d_%H.%M.%S)"
GITLAB_SETTINGS_FIRST_LINE="$(grep --line-number 'GitLabSettings' "$MATTERMOST_CONFIG_FILE" | cut -d : -f 1)"
GITLAB_SETTINGS_BLOCK_SIZE=12
GITLAB_SETTINGS_BLOCK="    \"GitLabSettings\": {
        \"Enable\": true,
        \"Secret\": \"$CLIENT_SECRET\",
        \"Id\": \"$CLIENT_ID\",
        \"Scope\": \"\",
        \"AuthEndpoint\": \"https://$DOMAIN_NAME/oauth/authorize.php\",
        \"TokenEndpoint\": \"https://$DOMAIN_NAME/oauth/token.php\",
        \"UserAPIEndpoint\": \"https://$DOMAIN_NAME/oauth/resource.php\",
        \"DiscoveryEndpoint\": \"\",
        \"ButtonText\": \"\",
        \"ButtonColor\": \"\"
    },"
GITLAB_SETTINGS_NEXT_BLOCK_LINE="$(grep --after-context="$GITLAB_SETTINGS_BLOCK_SIZE" 'GitLabSettings' "$MATTERMOST_CONFIG_FILE" | tail --lines=1)"


# Delete old block
awk -v line="$GITLAB_SETTINGS_FIRST_LINE" -v size="$GITLAB_SETTINGS_BLOCK_SIZE" 'line <= NR && NR <= line+size-1 { next } { print }' "$MATTERMOST_CONFIG_FILE" > "$MATTERMOST_TEMP_CONFIG_FILE"
# Insert new block
awk -v block="$GITLAB_SETTINGS_BLOCK" "/^$GITLAB_SETTINGS_NEXT_BLOCK_LINE$/{ print block }1" "$MATTERMOST_TEMP_CONFIG_FILE" > "$MATTERMOST_CONFIG_FILE"
check_result $?
rm -f "$MATTERMOST_TEMP_CONFIG_FILE"

################################################################################

echo_info '[STEP 15/15] Restarting Mattermost & Nginx ...'
systemctl restart nginx.service
systemctl restart mattermost.service
check_result $?

echo_ok 'Installation complete !'

exit 0
