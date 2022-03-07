ARG ALPINE_VERSION=3.15.0

FROM golang:1.17-buster as ct-submit
RUN go get github.com/grahamedgecombe/ct-submit

FROM alpine:${ALPINE_VERSION} as pagespeed
ARG MOD_PAGESPEED_TAG=v1.13.35.2
RUN apk add --no-cache \
        apache2-dev \
        apr-dev \
        apr-util-dev \
        build-base \
        curl \
        gettext-dev \
        git \
        gperf \
        icu-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libressl-dev \
        pcre-dev \
        py-setuptools \
        zlib-dev \
    ;

WORKDIR /usr/src
RUN git clone -b ${MOD_PAGESPEED_TAG} \
              --recurse-submodules \
              --depth=1 \
              -c advice.detachedHead=false \
              -j`nproc` \
              https://github.com/apache/incubator-pagespeed-mod.git \
              modpagespeed \
    ;

WORKDIR /usr/src/modpagespeed

COPY files/patches/modpagespeed/*.patch ./

RUN for i in *.patch; do printf "\r\nApplying patch ${i%%.*}\r\n"; patch -p1 < $i || exit 1; done

WORKDIR /usr/src/modpagespeed/tools/gyp
RUN ./setup.py install

WORKDIR /usr/src/modpagespeed

RUN build/gyp_chromium --depth=. \
                       -D use_system_libs=1 \
    && \
    cd /usr/src/modpagespeed/pagespeed/automatic && \
    make psol BUILDTYPE=Release \
              CFLAGS+="-I/usr/include/apr-1" \
              CXXFLAGS+="-I/usr/include/apr-1 -DUCHAR_TYPE=uint16_t" \
              -j`nproc` \
    ;

RUN mkdir -p /usr/src/ngxpagespeed/psol/lib/Release/linux/x64 && \
    mkdir -p /usr/src/ngxpagespeed/psol/include/out/Release && \
    cp -R out/Release/obj /usr/src/ngxpagespeed/psol/include/out/Release/ && \
    cp -R pagespeed/automatic/pagespeed_automatic.a /usr/src/ngxpagespeed/psol/lib/Release/linux/x64/ && \
    cp -R net \
          pagespeed \
          testing \
          third_party \
          url \
          /usr/src/ngxpagespeed/psol/include/ \
    ;

FROM alpine:${ALPINE_VERSION} as nginx
ARG NGINX_WWW_ROOT=/var/www/html
ARG NGINX_LOG_ROOT=/var/log/nginx
ARG NGINX_CACHE_ROOT=/var/cache/nginx
ARG NGINX_PREFIX_PATH=/etc/nginx
ARG NGINX_SBIN_PATH=/usr/sbin/nginx
ARG NGINX_MODULE_PATH=/usr/lib/nginx/modules
ARG NGINX_CONF_PATH=/etc/nginx/nginx.conf
ARG NGINX_VERSION=1.21.4
ARG NGINX_DEPS gcc \
        g++ \
        make  \
        autoconf \
        automake \
        patch \
        ruby-rake \
        curl \
        curl-dev \
        musl-dev \
        perl-dev \
        libxslt-dev \
        openssl-dev \
        linux-headers \
        libpng-dev \
        freetype-dev \
        libxpm-dev \
        expat-dev \
        tiff-dev \
        libxcb-dev \
        pcre-dev \
        geoip-dev \
        gd-dev \
        ruby-etc \
        ruby-dev \
        libxpm-dev \
        fontconfig-dev \
        libuuid \
        util-linux-dev \
        zlib-dev \
        gnupg1 \    
        gettext
COPY files/ct-submit.sh /usr/bin/ct-submit.sh
COPY --from=ct-submit /go/bin/ct-submit /usr/bin/ct-submit
RUN mkdir -m755 -p ${NGINX_WWW_ROOT} ${NGINX_LOG_ROOT} \
    && apk update \
    && apk add --no-cache --virtual .user shadow \
    && groupadd -g 1000 www \
    && useradd -d /var/lib/www -s /bin/nologin -g www -M -u 1000 httpd \
    && chown -R httpd:www ${NGINX_WWW_ROOT} ${NGINX_LOG_ROOT} \
    && apk del --purge .user \
\
    # add build pkg
\
    && GPG_KEYS=B0F4253373F8F6F510D42178520A9993A1C052F8 \
    && nginx_ct_version=1.3.2 \
    && ngx_cache_purge_version=2.3 \
    && ngx_brotli_version=1.0.0rc \
    && naxsi_tarball_name=naxsi \
    && naxsi_version=1.3 \
    && nginx_shibboleth_version=2.0.1 \
    && headers_more_module_version=0.33 \
    && lua_nginx_module_name=lua-nginx-module \
    && lua_nginx_module_version=0.10.20 \
    && vts_version=0.1.18 \
    && ngx_devel_kit_version=0.3.1 \
    && lua_resty_core_version=0.1.22 \
    && lua_resty_lrucache_version=0.11 \
    && luajit_fork_version=2.1-20210510 \
    && stream_lua_nginx_version=0.0.10 \
    && brotli_version=1.0.9 \
    && nps_version=1.13.35.2-stable \
    && apk upgrade apk-tools \
    && apk add --no-cache --virtual .builddep ${NGINX_DEPS} \
    && mkdir /tmp/build \
    && cd /tmp/build \
\
# lua resty config
\
    && export PREFIX=/usr \
    && export LUA_LIB_DIR=/usr/share/lua/5.1 \
    && curl -fSLO https://github.com/openresty/lua-resty-core/archive/v${lua_resty_core_version}.tar.gz \
    && tar xf v${lua_resty_core_version}.tar.gz \
    && (cd lua-resty-core-${lua_resty_core_version} \
    && make install && ls -lR /usr/local/share ) \
    && curl -fSLO https://github.com/openresty/lua-resty-lrucache/archive/v${lua_resty_lrucache_version}.tar.gz \
    && tar xf v${lua_resty_lrucache_version}.tar.gz \
    && (cd lua-resty-lrucache-${lua_resty_lrucache_version} && make install && ls -lR /usr/local/share ) \
\
# luafork
\
    && curl -fSLO https://github.com/openresty/luajit2/archive/v${luajit_fork_version}.tar.gz \
    && tar xf v${luajit_fork_version}.tar.gz \
    && (cd luajit2-${luajit_fork_version} \
    && sed -i -e 's,/usr/local,/usr,' Makefile \
    && sed -i -e 's,/usr/local,/usr,' -e 's,LUA_LMULTILIB\t"lib",LUA_LMULTILIB "lib64",' src/luaconf.h \
    && make install DESTDIR=/tmp/build \
    && rm /tmp/build/usr/lib/*.so ) \
\
# nginx 
\
    && curl -fSL http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -o nginx.tar.gz \ 
    && curl -fSL http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc -o nginx.tar.gz.asc \
    && export GNUPGHOME="$(mktemp -d)" \
    && found=''; \
    for server in \
        keys.gnupg.net \
        ha.pool.sks-keyservers.net \
        hkp://keyserver.ubuntu.com:80 \
        hkp://p80.pool.sks-keyservers.net:80 \
        pgp.mit.edu \
    ; do \
        echo "Fetching GPG key $GPG_KEYS from $server"; \
        gpg --keyserver "$server" --keyserver-options timeout=10 --recv-keys "$GPG_KEYS" && found=yes && break; \
    done; \
    test -z "$found" && echo >&2 "error: failed to fetch GPG key $GPG_KEYS" && exit 1; \
    gpg --batch --verify nginx.tar.gz.asc nginx.tar.gz \
    && rm -rf "$GNUPGHOME" nginx.tar.gz.asc \
    && tar xf nginx.tar.gz \
    && mkdir nginx-${NGINX_VERSION}/extensions \
    && cd ./nginx-${NGINX_VERSION}/extensions \
    && curl -fSLo nginx-ct-${nginx_ct_version}.tar.gz \
        https://github.com/grahamedgecombe/nginx-ct/archive/v${nginx_ct_version}.tar.gz \
    && curl -fSLo ngx_cache_purge-${ngx_cache_purge_version}.tar.gz  \
        https://github.com/FRiCKLE/ngx_cache_purge/archive/${ngx_cache_purge_version}.tar.gz \
    && curl -fSLo ngx_brotli-${ngx_brotli_version}.tar.gz \
        https://github.com/google/ngx_brotli/archive/v${ngx_brotli_version}.tar.gz \
    && curl -fSLo brotli-${brotli_version}.tar.gz \
        https://github.com/google/brotli/archive/v${brotli_version}.tar.gz \
    && curl -fSLo ngx_devel_kit-${ngx_devel_kit_version}.tar.gz \
        https://github.com/simplresty/ngx_devel_kit/archive/v${ngx_devel_kit_version}.tar.gz \
    && curl -fSLo nginx-http-shibboleth-${nginx_shibboleth_version}.tar.gz \
        https://github.com/nginx-shib/nginx-http-shibboleth/archive/v${nginx_shibboleth_version}.tar.gz \
    && curl -fSLo headers-more-nginx-module-${headers_more_module_version}.tar.gz \
        https://github.com/openresty/headers-more-nginx-module/archive/v${headers_more_module_version}.tar.gz \
    && curl -fSLo nginx-module-vts-${vts_version}.tar.gz \
        https://github.com/vozlt/nginx-module-vts/archive/v${vts_version}.tar.gz \
    && curl -fSLo ${lua_nginx_module_name}-${lua_nginx_module_version}.tar.gz \
        https://github.com/openresty/${lua_nginx_module_name}/archive/v${lua_nginx_module_version}.tar.gz \
    && curl -fSLo ${naxsi_tarball_name}-${naxsi_version}.tar.gz \
        https://github.com/nbs-system/naxsi/archive/${naxsi_version}.tar.gz \
    && curl -fSLo stream_lua_nginx-${stream_lua_nginx_version}.tar.gz \
        https://github.com/openresty/stream-lua-nginx-module/archive/v${stream_lua_nginx_version}.tar.gz \
    && curl -fSLo ngx_pagespeed-${nps_version}.tar.gz \
        https://github.com/apache/incubator-pagespeed-ngx/archive/v${nps_version}.tar.gz \ 
    && tar xf nginx-ct-${nginx_ct_version}.tar.gz \
    && mv nginx-ct-${nginx_ct_version} nginx-ct \
    && tar xf ngx_cache_purge-${ngx_cache_purge_version}.tar.gz \
    && mv ngx_cache_purge-${ngx_cache_purge_version} ngx_cache_purge \
    && tar xf ngx_brotli-${ngx_brotli_version}.tar.gz \
    && mv ngx_brotli-${ngx_brotli_version} ngx_brotli \
    && tar xf ngx_devel_kit-${ngx_devel_kit_version}.tar.gz \
    && mv ngx_devel_kit-${ngx_devel_kit_version} ngx_devel_kit \
    && tar xf ${lua_nginx_module_name}-${lua_nginx_module_version}.tar.gz \
    && mv ${lua_nginx_module_name}-${lua_nginx_module_version} ${lua_nginx_module_name} \
    && tar xf ${naxsi_tarball_name}-${naxsi_version}.tar.gz \
    && mv ${naxsi_tarball_name}-${naxsi_version} ${naxsi_tarball_name} \
    && tar xf brotli-${brotli_version}.tar.gz \
    && (test -d ngx_brotli/deps/brotli && rmdir ngx_brotli/deps/brotli) \
    && mv brotli-${brotli_version} ngx_brotli/deps/brotli \
    && tar xf nginx-http-shibboleth-${nginx_shibboleth_version}.tar.gz \
    && mv nginx-http-shibboleth-${nginx_shibboleth_version} nginx-http-shibboleth \
    && tar xf headers-more-nginx-module-${headers_more_module_version}.tar.gz \
    && mv headers-more-nginx-module-${headers_more_module_version} headers-more-nginx-module \
    && tar xf nginx-module-vts-${vts_version}.tar.gz \
    && mv nginx-module-vts-${vts_version} nginx-module-vts \
    && tar xf stream_lua_nginx-${stream_lua_nginx_version}.tar.gz \
    && mv stream-lua-nginx-module-${stream_lua_nginx_version} stream-lua-nginx-module \
    && tar xf ngx_pagespeed-${nps_version}.tar.gz \
    && mv incubator-pagespeed-ngx-${nps_version} ngx_pagespeed \ 
    && cd ngx_pagespeed \  
    && NPS_RELEASE_NUMBER=${nps_version/beta/} \ 
    && NPS_RELEASE_NUMBER=${nps_version/stable/} \ 
    && psol_url=https://dl.google.com/dl/page-speed/psol/${NPS_RELEASE_NUMBER}.tar.gz \ 
    && [ -e scripts/format_binary_url.sh ] && psol_url=$(. scripts/format_binary_url.sh PSOL_BINARY_URL) \ 
    && wget -O- ${psol_url} | tar -xz \ 
    && cd ../.. \
\
# configure
    && export LUAJIT_INC=/tmp/build/usr/include/luajit-2.1 \
    && export LUAJIT_LIB=/tmp/build/usr/lib \
    && CC=/usr/bin/cc \
    && CXX=/usr/bin/c++ \
    && CONF="\
        --prefix=${NGINX_PREFIX} \
        --conf-path=${NGINX_CONF_PATH} \
        --sbin-path=${NGINX_SBIN_PATH} \
        --modules-path=${NGINX_MODULE_PATH} \
        --error-log-path=${NGINX_LOG_ROOT}/error.log \
        --http-log-path=${NGINX_LOG_ROOT}/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=${NGINX_CACHE_ROOT}/client_temp \
        --http-proxy-temp-path=${NGINX_CACHE_ROOT}/proxy_temp \
        --http-fastcgi-temp-path=${NGINX_CACHE_ROOT}/fastcgi_temp \
        --http-uwsgi-temp-path=${NGINX_CACHE_ROOT}/uwsgi_temp \
        --http-scgi-temp-path=${NGINX_CACHE_ROOT}/scgi_temp \
        --user=httpd \
        --group=www \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module \
        --with-http_xslt_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-http_secure_link_module \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --with-stream_geoip_module \
        --with-http_slice_module \
        --with-http_mp4_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-compat \
        --with-file-aio \
        --with-http_v2_module \
        --with-http_perl_module=dynamic \
        --with-pcre-jit \
        --add-module=./extensions/ngx_devel_kit \
        --add-module=./extensions/${lua_nginx_module_name} \
        --add-module=./extensions/ngx_cache_purge \
        --add-module=./extensions/nginx-ct \
        --add-module=./extensions/ngx_brotli \
        --add-module=./extensions/${naxsi_tarball_name}/naxsi_src \
        --add-module=./extensions/nginx-http-shibboleth \
        --add-module=./extensions/headers-more-nginx-module \
        --add-module=./extensions/nginx-module-vts \
        --add-module=./extensions/stream-lua-nginx-module \
        --add-module=./extensions/ngx_pagespeed \ 
    " \
    && CFLAGS='-O2 -g -pipe -Wp,-D_FORTIFY_SOURCE=2 \
        -fexceptions -fstack-protector \
        -m64 -mtune=generic \
        -Wno-deprecated-declarations \
        -Wno-cast-function-type \
        -Wno-unused-parameter \
        -Wno-stringop-truncation \
        -Wno-stringop-overflow' \
    && ./configure $CONF --with-cc-opt="$CFLAGS" \ 
\
# build
\
    && make \
    && make install \ 
    && mkdir -p /usr/lib/nginx/modules /etc/nginx/naxsi.d \
    && install -m644 extensions/${naxsi_tarball_name}/naxsi_config/naxsi_core.rules /etc/nginx/naxsi.d/naxsi_core.rules.conf \
    && (for so in `find extensions -type f -name '*.so'`; do mv $so /usr/lib/nginx/modules ; done; true) \
    && mv /usr/bin/envsubst /tmp/ \ 
\
# remove pkg
\
    && runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' /usr/sbin/nginx /usr/lib/nginx/modules/*.so /tmp/envsubst \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" \
    && apk add --no-cache --virtual .nginx-rundeps $runDeps tzdata openssl \
    && apk del --purge .builddep \
\
    && mv /tmp/envsubst /usr/bin/envsubst \
# setup configures
    && mkdir -p -m755 ${NGINX_WWW_ROOT} \
        ${NGINX_PREFIX}/conf.d \
        ${NGINX_CACHE_ROOT} \
        ${NGINX_LOG_ROOT}  \
    && chown -R httpd:www ${NGINX_PREFIX} \
        ${NGINX_WWW_ROOT} \
        ${NGINX_CACHE_ROOT} \
        ${NGINX_LOG_ROOT} \
    && install -m644 ${NGINX_PREFIX}/html/50x.html ${NGINX_WWW_ROOT}\
    && install -m644 ${NGINX_PREFIX}/html/index.html ${NGINX_WWW_ROOT} \
    && mkdir -p -m755 ${NGINX_PREFIX}/scts ${NGINX_PREFIX}/naxsi.d ${NGINX_PREFIX}/conf.d/templates \
    && rm -rf /tmp/build \
    && chown 700 /usr/bin/ct-submit /usr/bin/ct-submit.sh \
    && ln -s ../../usr/lib/nginx/modules /etc/nginx/modules 
COPY files/nginx.conf ${NGINX_PREFIX}/nginx.conf
COPY files/naxsi_core.conf ${NGINX_PREFIX}/conf.d/naxsi_core.conf
COPY files/fastcgi_params ${NGINX_PREFIX}/fastcgi_params
COPY files/naxsi.d/ ${NGINX_PREFIX}/naxsi.d/
COPY files/templates/ ${NGINX_PREFIX}/conf.d/
COPY files/security.conf ${NGINX_PREFIX}/conf.d/security.conf

RUN apk add --no-cache --virtual .curl curl \
    && curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/master/contrib/install.sh | sh -s -- -b /tmp \
    && /tmp/trivy filesystem --skip-files /tmp/trivy --exit-code 1 --no-progress / \
    && apk del .curl \
    && rm /tmp/trivy

EXPOSE 80 443

VOLUME ${NGINX_WWW_ROOT}

USER httpd
COPY files/docker-entrypoint.sh /
ENTRYPOINT [ "/docker-entrypoint.sh" ]
CMD [ "/usr/sbin/nginx", "-g", "daemon off;" ]