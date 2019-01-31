FROM repo.cylo.io/ubuntu-lemp

# Disable Supervisor on the parent image, this allows us to run commands after the parent has finished installing.
ENV START_SUPERVISOR=false

# Declare Environment variables required by the parent:
ENV MYSQL_ROOT_PASS=mysqlr00t
ENV DB_NAME=nextlcloud

# Nextcloud Environment variables
ENV NEXTCLOUD_VER="15.0.2"
ENV ADMIN_USER=admin
ENV ADMIN_PASS=Letmein123

RUN apt update; \
    apt install -y unzip \
                   samba \
                   samba-dev \
                   php-zip \
                   php-gd \
                   php-dom \
                   php-mbstring \
                   php-smbclient

ADD /scripts /scripts
RUN chmod -R +x /scripts

ADD /sources /tmp

ENTRYPOINT ["/scripts/Entrypoint.sh"]