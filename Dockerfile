ARG DOTNET_VERSION=3.1

FROM node:alpine as web-builder
ARG JELLYFIN_WEB_VERSION=master
RUN apk add curl git zlib zlib-dev autoconf g++ make libpng-dev gifsicle alpine-sdk automake libtool make gcc musl-dev nasm python \
 && curl -L https://github.com/jellyfin/jellyfin-web/archive/${JELLYFIN_WEB_VERSION}.tar.gz | tar zxf - \
 && cd jellyfin-web-* \
 && yarn install \
 && mv dist /dist

FROM mcr.microsoft.com/dotnet/core/sdk:${DOTNET_VERSION} as builder
WORKDIR /repo
COPY . .
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
# because of changes in docker and systemd we need to not build in parallel at the moment
# see https://success.docker.com/article/how-to-reserve-resource-temporarily-unavailable-errors-due-to-tasksmax-setting
RUN dotnet publish Jellyfin.Server --disable-parallel --configuration Release --output="/jellyfin" --self-contained --runtime linux-arm64 "-p:GenerateDocumentationFile=false;DebugSymbols=false;DebugType=none"

FROM debian:buster-slim

# https://askubuntu.com/questions/972516/debian-frontend-environment-variable
ARG DEBIAN_FRONTEND="noninteractive"
# http://stackoverflow.com/questions/48162574/ddg#49462622
ARG APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn
# https://github.com/NVIDIA/nvidia-docker/wiki/Installation-(Native-GPU-Support)
ENV NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

COPY --from=builder /jellyfin /jellyfin
COPY --from=web-builder /dist /jellyfin/jellyfin-web
# Install dependencies:
#   mesa-va-drivers: needed for AMD VAAPI
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y ca-certificates gnupg wget apt-transport-https \
 && wget -O - https://repo.jellyfin.org/jellyfin_team.gpg.key | apt-key add - \
 && echo "deb [arch=$( dpkg --print-architecture )] https://repo.jellyfin.org/$( awk -F'=' '/^ID=/{ print $NF }' /etc/os-release ) $( awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release ) main" | tee /etc/apt/sources.list.d/jellyfin.list \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y \
   mesa-va-drivers \
   jellyfin-ffmpeg \
   openssl \
   locales \
 && apt-get install --no-install-recommends --no-install-suggests -y autoconf automake build-essential cmake debhelper fakeroot git-core libass-dev libfreetype6-dev libsdl2-dev libtool libva-dev libvdpau-dev libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev pkg-config texinfo wget zlib1g-dev \
 && wget http://ftp.debian.org/debian/pool/main/n/nasm/nasm_2.14-1_arm64.deb \
 && dpkg -i nasm_2.14-1_arm64.deb \
 && wget http://ftp.debian.org/debian/pool/main/y/yasm/yasm_1.3.0-2+b1_arm64.deb \
 && dpkg -i yasm_1.3.0-2+b1_arm64.deb \
 && echo "deb http://www.deb-multimedia.org stretch main non-free" >> /etc/apt/sources.list \
 && apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 5C808C2B65558117 \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y libx264-dev libx265-dev libnuma-dev libvpx-dev libfdk-aac-dev libmp3lame-dev libopus-dev

ARG FFMPEG_COMPILE_DIR=/ffmped_dir
ARG FFMPEG_SOURCES=$FFMPEG_COMPILE_DIR/ffmpeg_sources
ARG LIBAOM_SOURCES=$FFMPEG_COMPILE_DIR/libaom_sources
ARG MPP_SOURCES=$FFMPEG_COMPILE_DIR/mpp_sources
ARG FFMPEG_BIN=$FFMPEG_COMPILE_DIR/ffmpeg_bin
ARG LIBAOM_BIN=$FFMPEG_COMPILE_DIR/libaom_bin
ARG FFMPEG_BUILD=$FFMPEG_COMPILE_DIR/ffmpeg_build
ARG LIBAOM_BUILD=$LIBAOM_SOURCES/aom_build
ARG PKG_CONFIG_PATH=$FFMPEG_BUILD/lib/pkgconfig

RUN mkdir -p $FFMPEG_COMPILE_DIR $FFMPEG_SOURCES $LIBAOM_SOURCES $MPP_SOURCES $FFMPEG_BIN $LIBAOM_BIN $FFMPEG_BUILD $LIBAOM_BUILD $PKG_CONFIG_PATH \
 && cd ${LIBAOM_SOURCES} \
 && if [ ! -d aom ]; then git clone --depth 1 https://aomedia.googlesource.com/aom ; fi \
 && cd aom \
 && git pull \
 && cd ${LIBAOM_SOURCES}/aom_build \
 && PATH="${LIBAOM_BIN}:$PATH" cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="${LIBAOM_BUILD}" -DENABLE_SHARED=off -DENABLE_NASM=on ../aom \
 && cd ${LIBAOM_SOURCES}/aom_build \
 && PATH="${LIBAOM_BIN}:$PATH" make -j4 \
 && cd ${LIBAOM_SOURCES}/aom_build \
 && make install \
 && chmod 755 ${LIBAOM_BUILD}/aom.pc && cp ${LIBAOM_BUILD}/aom.pc ${PKG_CONFIG_PATH}
 
RUN cd ${MPP_SOURCES} \
 && if [ ! -d mpp ]; then git clone --single-branch --branch develop https://github.com/Caesar-github/mpp.git ; fi \
 && cd mpp \
 && git pull \
 && cmake -DRKPLATFORM=ON -DHAVE_DRM=ON \
 && cd ${MPP_SOURCES}/mpp \
 && make -j4 \
 && make install \
 && cd .. \
 && chmod 755 ${MPP_SOURCES}/mpp/rockchip_mpp.pc ${MPP_SOURCES}/mpp/rockchip_vpu.pc && cp ${MPP_SOURCES}/mpp/rockchip_mpp.pc ${MPP_SOURCES}/mpp/rockchip_vpu.pc ${PKG_CONFIG_PATH}

ARG ffmpeg_source_dir="ffmpeg-rockchip"

RUN cd ${FFMPEG_SOURCES} \
 && if [ ! -d ${ffmpeg_source_dir} ]; then git clone --single-branch --branch rockchip-encode https://github.com/jaja123456789/rockchip-ffmpeg.git ${ffmpeg_source_dir} ; fi \
 && cd ${ffmpeg_source_dir} \
 && git pull \
 && cp ${PKG_CONFIG_PATH}/* ${FFMPEG_SOURCES}/${ffmpeg_source_dir} \
 && cp ${PKG_CONFIG_PATH}/* ${FFMPEG_BIN} \
 && chmod +x configure \
 && chmod 755 configure 

RUN cd ${FFMPEG_SOURCES}/${ffmpeg_source_dir} && PATH="${FFMPEG_BIN}:$PATH" ./configure \
  --prefix="${FFMPEG_BUILD}" \
  --pkg-config-flags="--static" \
  --extra-cflags="-I${FFMPEG_BUILD}/include" \
  --extra-ldflags="-L${FFMPEG_BUILD}/lib" \
  --extra-libs="-lpthread -lm" \
  --bindir="${FFMPEG_BIN}" \
  --disable-v4l2-m2m \
  --enable-gpl \
  --enable-libaom \
  --enable-libass \
  --enable-libfdk-aac \
  --enable-libfreetype \
  --enable-libmp3lame \
  --enable-libopus \
  --enable-libvorbis \
  --enable-libvpx \
  --enable-libx264 \
  --enable-rkmpp \
  --enable-version3 \
  --enable-libdrm \
  --enable-libx265 \
  --enable-nonfree

RUN cd ${FFMPEG_SOURCES}/${ffmpeg_source_dir} \
 && PATH="${FFMPEG_BIN}:$PATH" make -j4

RUN cp ${FFMPEG_SOURCES}/${ffmpeg_source_dir}/ffmpeg ${FFMPEG_SOURCES}/${ffmpeg_source_dir}/ffprobe /usr/local/bin \
 && apt-get remove gnupg wget apt-transport-https -y \
 && apt-get clean autoclean -y \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /cache /config /media \
 && chmod 777 /cache /config /media \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV LC_ALL en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en

EXPOSE 8096
VOLUME /cache /config /media
ENTRYPOINT umount /sys/firmware
ENTRYPOINT ["./jellyfin/jellyfin", \
    "--datadir", "/config", \
    "--cachedir", "/cache", \
    "--ffmpeg", "/usr/local/bin/ffmpeg"]
