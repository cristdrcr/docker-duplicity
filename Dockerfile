FROM python:3-slim AS builder

WORKDIR /app
ADD pyproject.toml poetry.lock ./
RUN pip install --no-cache-dir poetry

# Build a requirements.txt file matching poetry.lock, that pip understands
RUN poetry export --extras duplicity --output /app/requirements.txt

FROM python:3-alpine AS base

ENV CRONTAB_15MIN='*/15 * * * *' \
    CRONTAB_HOURLY='0 * * * *' \
    CRONTAB_DAILY='0 2 * * MON-SAT' \
    CRONTAB_WEEKLY='0 1 * * SUN' \
    CRONTAB_MONTHLY='0 5 1 * *' \
    DST='' \
    EMAIL_FROM='' \
    EMAIL_SUBJECT='Backup report: {hostname} - {periodicity} - {result}' \
    EMAIL_TO='' \
    JOB_300_WHAT='backup' \
    JOB_300_WHEN='daily' \
    OPTIONS='' \
    OPTIONS_EXTRA='--metadata-sync-mode partial' \
    SMTP_HOST='smtp' \
    SMTP_PASS='' \
    SMTP_PORT='25' \
    SMTP_TLS='' \
    SMTP_USER='' \
    SRC='/mnt/backup/src'

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
CMD ["/usr/sbin/crond", "-fd8"]

# Link the job runner in all periodicities available
RUN ln -s /usr/local/bin/jobrunner /etc/periodic/15min/jobrunner
RUN ln -s /usr/local/bin/jobrunner /etc/periodic/hourly/jobrunner
RUN ln -s /usr/local/bin/jobrunner /etc/periodic/daily/jobrunner
RUN ln -s /usr/local/bin/jobrunner /etc/periodic/weekly/jobrunner
RUN ln -s /usr/local/bin/jobrunner /etc/periodic/monthly/jobrunner

# Runtime dependencies and database clients
RUN apk add --no-cache \
        ca-certificates \
        dbus \
        gettext \
        gnupg \
        krb5-libs \
        lftp \
        libffi \
        librsync \
        ncftp \
        openssh \
        openssl \
        rsync \
        tzdata \
    && sync

# Default backup source directory
RUN mkdir -p "$SRC"

# Preserve cache among containers
VOLUME [ "/root" ]

# Build dependencies
COPY --from=builder /app/requirements.txt requirements.txt
RUN apk add --no-cache --virtual .build \
        build-base \
        krb5-dev \
        libffi-dev \
        librsync-dev \
        libxml2-dev \
        libxslt-dev \
        openssl-dev \
        cargo \
    # Runtime dependencies, based on https://gitlab.com/duplicity/duplicity/-/blob/master/requirements.txt
    && pip install --no-cache-dir -r requirements.txt \
    && apk del .build \
    && rm -rf /root/.cargo

COPY bin/* /usr/local/bin/
RUN chmod a+rx /usr/local/bin/* && sync

FROM base AS s3
ENV JOB_500_WHAT='dup full $SRC $DST' \
    JOB_500_WHEN='weekly' \
    OPTIONS_EXTRA='--metadata-sync-mode partial --full-if-older-than 1W --file-prefix-archive archive-$(hostname -f)- --file-prefix-manifest manifest-$(hostname -f)- --file-prefix-signature signature-$(hostname -f)- --s3-european-buckets --s3-multipart-chunk-size 10 --s3-use-new-style'


FROM base AS docker
RUN apk add --no-cache docker-cli


FROM docker AS docker-s3
ENV JOB_500_WHAT='dup full $SRC $DST' \
    JOB_500_WHEN='weekly' \
    OPTIONS_EXTRA='--metadata-sync-mode partial --full-if-older-than 1W --file-prefix-archive archive-$(hostname -f)- --file-prefix-manifest manifest-$(hostname -f)- --file-prefix-signature signature-$(hostname -f)- --s3-european-buckets --s3-multipart-chunk-size 10 --s3-use-new-style'


FROM base AS postgres

RUN apk add --no-cache postgresql-client \
	&& psql --version \
    && pg_dump --version

# Install full version of grep to support more options
RUN apk add --no-cache grep

ENV JOB_200_WHAT set -euo pipefail; psql -0Atd postgres -c \"SELECT datname FROM pg_database WHERE NOT datistemplate AND datname != \'postgres\'\" | grep --null-data -E \"\$DBS_TO_INCLUDE\" | grep --null-data --invert-match -E \"\$DBS_TO_EXCLUDE\" | xargs -0tI DB pg_dump --dbname DB --no-owner --no-privileges --file \"\$SRC/DB.sql\"
ENV JOB_200_WHEN='daily weekly' \
    DBS_TO_INCLUDE='.*' \
    DBS_TO_EXCLUDE='$^' \
    PGHOST=db


FROM postgres AS postgres-s3
ENV JOB_500_WHAT='dup full $SRC $DST' \
    JOB_500_WHEN='weekly' \
    OPTIONS_EXTRA='--metadata-sync-mode partial --full-if-older-than 1W --file-prefix-archive archive-$(hostname -f)- --file-prefix-manifest manifest-$(hostname -f)- --file-prefix-signature signature-$(hostname -f)- --s3-european-buckets --s3-multipart-chunk-size 10 --s3-use-new-style'
FROM postgres AS postgres-mega
ENV JOB_500_WHAT='dup full $SRC $DST' \
    JOB_500_WHEN='weekly' \
    OPTIONS_EXTRA='--metadata-sync-mode partial --full-if-older-than 1W --file-prefix-archive archive-$(hostname -f)- --file-prefix-manifest manifest-$(hostname -f)- --file-prefix-signature signature-$(hostname -f)-'
RUN apk add --update build-base libcurl curl-dev asciidoc openssl-dev glib-dev glib libtool automake autoconf
RUN rm -rf /src
RUN mkdir -p /src
WORKDIR /src
RUN wget https://megatools.megous.com/builds/megatools-1.10.2.tar.gz
RUN tar -xzvf megatools-1.10.2.tar.gz megatools-1.10.2
WORKDIR /src/megatools-1.10.2
RUN ./configure --prefix=$HOME/.local
RUN make -j4
RUN make install
RUN rm -rf /usr/local/bin/megacopy
RUN ln -s /src/megatools-1.10.2/megacopy /usr/local/bin/megacopy
RUN rm -rf /usr/local/bin/megadf
RUN ln -s /src/megatools-1.10.2/megadf /usr/local/bin/megadf
RUN rm -rf /usr/local/bin/megadl
RUN ln -s /src/megatools-1.10.2/megadl /usr/local/bin/megadl
RUN rm -rf /usr/local/bin/megaget
RUN ln -s /src/megatools-1.10.2/megaget /usr/local/bin/megaget
RUN rm -rf /usr/local/bin/megals
RUN ln -s /src/megatools-1.10.2/megals /usr/local/bin/megals
RUN rm -rf /usr/local/bin/megamkdir
RUN ln -s /src/megatools-1.10.2/megamkdir /usr/local/bin/megamkdir
RUN rm -rf /usr/local/bin/megaput
RUN ln -s /src/megatools-1.10.2/megaput /usr/local/bin/megaput
RUN rm -rf /usr/local/bin/megareg
RUN ln -s /src/megatools-1.10.2/megareg /usr/local/bin/megareg
RUN rm -rf /usr/local/bin/megarm
RUN ln -s /src/megatools-1.10.2/megarm /usr/local/bin/megarm

FROM postgres-mega AS postgres-mysql-mega
RUN apk add mysql-client
ENV JOB_200_WHAT='/usr/bin/mysqldump -u root -h $MYSQL_HOST --password=$MYSQL_PASSWORD $MYSQL_DATABASE> $SRC/$MYSQL_DATABASE.sql'
