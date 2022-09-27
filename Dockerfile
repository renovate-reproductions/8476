# https://hub.docker.com/_/python/
FROM python:3.7-slim-bullseye as builder
ENV NODE_VERSION="14.x" \
    ENABLE_BASIC_AUTH=True \ 
    ALWAYS_RUN_MIGRATIONS=True \
    UWSGI_PROCESSES=1 \
    UWSGI_THREADS=32 \
    PIPENV_VENV_IN_PROJECT=1 \
    PATH=/srv/.venv/bin:${PATH} 

WORKDIR /app
COPY docker/locale.gen /etc/locale.gen
COPY system-requirements.txt /srv/system-requirements.txt

# The yarn package has a https repo
# these are the pieces of working equivalent to curl -sL https://deb.nodesource.com/setup_8.x | bash -
RUN apt-get -qq update && apt-get -qq install --no-install-recommends curl apt-transport-https gnupg && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    curl -s https://deb.nodesource.com/gpgkey/nodesource.gpg.key | apt-key add - && \
    echo "deb https://deb.nodesource.com/node_${NODE_VERSION} bullseye main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get -qq update && \
    xargs apt-get -qq install --no-install-recommends < /srv/system-requirements.txt && \
    apt-get upgrade -y -qq --no-install-recommends &&\ 
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app/main/static  && \
    mkdir -p /data/static && \
    mkdir -p /data/media

# pipenv
COPY Pipfile* /srv/
RUN  cd /srv && \
    pip install -U pip && \
    pip install pipenv && \
    pipenv install && \
    pipenv run pip install "setuptools<58.0.0"
# end pipenv
# pip install "setuptools<58.0.0" --> Hack to make it work with old versions of django libs.


COPY package.json /node/package.json
RUN cd /node && yarn install


COPY src/ .
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/app.docker.ini /app/app.ini
COPY docker/app.docker.ini /srv/app.ini
COPY docker/uwsgi.ini /etc/uwsgi/uwsgi.ini

RUN cd /app/main/static/ && yarn install

RUN echo "Compiling messages..." && \
    CACHE_TYPE=dummy SECRET_KEY=naru python manage.py compilemessages && \
    echo "Compressing..." && \
    CACHE_TYPE=dummy SECRET_KEY=naru python manage.py compress --traceback --force && \
    echo "Collecting statics..." && \
    CACHE_TYPE=dummy SECRET_KEY=naru python manage.py collectstatic --noinput --traceback -v 0
ENTRYPOINT ["/entrypoint.sh"]


FROM python:3.7-slim-bullseye as final

ENV NODE_VERSION="14.x" \
    ENABLE_BASIC_AUTH=True \ 
    ALWAYS_RUN_MIGRATIONS=True \
    UWSGI_PROCESSES=1 \
    UWSGI_THREADS=32 \
    PATH=/srv/.venv/bin:${PATH} \
    PIPENV_VENV_IN_PROJECT=1

COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/app.docker.ini /app/app.ini
COPY docker/app.docker.ini /srv/app.ini
COPY docker/uwsgi.ini /etc/uwsgi/uwsgi.ini
COPY --from=builder --chown=1000:1000 /data/ /data/
COPY --from=builder --chown=1000:1000 /app/ /app/
COPY --from=builder --chown=1000:1000 /srv/ /srv/
COPY --from=428062847257.dkr.ecr.eu-west-1.amazonaws.com/devops/aws-go-paramstore:latest /aws-go-paramstore /bin/aws-go-paramstore
# TODO: Add node & scss 
# TODO: Remove duplicated static folder  /app/main/static || /data/static/

EXPOSE 8080 1717
HEALTHCHECK --interval=30s --timeout=3s \
            CMD launch-probe

# Create de user 1000
RUN export exe=`exec 2>/dev/null; readlink "/proc/$$/exe"| rev | cut  -f 1 -d '/' | rev` && \
    case "$exe" in \
        'busybox') \
            echo "Busybox: $exe"; \
            getent group  1000 || addgroup -g 1000 -S app; \
            getent passwd 1000 || adduser -S -G app -u 1000 app; \
            ;; \
        *) \
            echo "Not Busybox: $exe"; \
            getent group  1000 || addgroup --gid 1000 --system  app; \
            getent passwd 1000 || adduser --system --no-create-home --ingroup app  --uid 1000 app; \
            ;; \
    esac && \ 
    apt-get -qq update && \
    apt-get -qq upgrade && \
    apt-get install --no-install-recommends -y jq curl libpcre3 media-types && \
    apt purge -y  && \
    apt autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*  


WORKDIR /app
USER 1000
VOLUME /data/static
ENTRYPOINT ["/entrypoint.sh"]
CMD ["run-uwsgi"]