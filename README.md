# Mattermost LDAP integration into YunoHost
> *This bash script allows you to use your YunoHost accounts in Mattermost on a YunoHost server.
If you don't have YunoHost, please consult [the guide](https://yunohost.org/#/install) to learn how to install it.*

## Overview
The Mattermost Team Edition does not include a native LDAP feature. This subject is discussed [*here*](https://github.com/YunoHost-Apps/mattermost_ynh/issues/58).

Fortunately, GitHub user [Crivaledaz](https://github.com/Crivaledaz) developed [*a module*](https://github.com/Crivaledaz/Mattermost-LDAP) that uses the Gitlab SSO feature to provide a bridge between YunoHost users and Mattermost TE.

## Script description
This bash script allows automatic integration of this module into an existing YunoHost environment.

It installs a new [*Custom Webapp for YunoHost*](https://github.com/YunoHost-Apps/my_webapp_ynh) that will be the OAuth servern and then follows the module [*installation instructions*](https://github.com/Crivaledaz/Mattermost-LDAP/blob/master/BareMetal.md), doing just a few minor modifications.

## Disclaimer
This script should adapt to your YunoHost environment, but it has only been tested successfully on ONE YunoHost 11.1 installation, and without the benefit of hindsight : it may not be ready for a critical production environment. Use at your own risks.