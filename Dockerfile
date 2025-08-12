FROM node:12-buster AS wwwstage

ARG KASMWEB_RELEASE="46412d23aff1f45dffa83fafb04a683282c8db58"

RUN \
  echo "**** build clientside ****" && \
  export QT_QPA_PLATFORM=offscreen && \
  export QT_QPA_FONTDIR=/usr/share/fonts && \
  mkdir /src && \
  cd /src && \
  wget https://github.com/kasmtech/noVNC/tarball/${KASMWEB_RELEASE} -O - \
    | tar  --strip-components=1 -xz

COPY ./novnc/display.js /src/core/display.js
COPY ./novnc/vnc.html /src/vnc.html
COPY ./novnc/audio.svg /src/app/images/audio.svg
COPY ./novnc/ui.js /src/app/ui.js

RUN \
  cd /src && \
  npm install && \
  npm run-script build

RUN \
  echo "**** organize output ****" && \
  mkdir /build-out && \
  cd /src && \
  rm -rf node_modules/ && \
  cp -R ./* /build-out/ && \
  cd /build-out && \
  rm *.md && \
  rm AUTHORS && \
  cp index.html vnc.html && \
  mkdir Downloads

FROM ghcr.io/linuxserver/baseimage-kasmvnc:alpine320

COPY --from=wwwstage /build-out /usr/local/share/kasmvnc/www

# 1. Install build dependencies, including GTK
RUN apk add --no-cache \
    bash git build-base ninja \
    python3 py3-pip \
    glib-dev pixman-dev alsa-lib-dev \
    pulseaudio-dev sdl2-dev libusb-dev \
    linux-headers bison flex libaio-dev \
    zlib-dev libcap-dev ncurses-dev \
    gtk+3.0-dev cairo-dev gdk-pixbuf-dev pango-dev \
    libx11-dev libxext-dev libxrandr-dev libepoxy-dev mesa-dev \
    musl-dev pkgconfig

# 2. Clone QEMU
WORKDIR /build
RUN git clone --branch v7.0.0 --depth 1 https://github.com/qemu/qemu.git
WORKDIR /build/qemu

#RUN sed -i '/pit_set_gate/s/.*/&\n    fprintf(stderr, "[QEMU PATCH] PC speaker triggered: val=0x%02lx\\n", val);/' \
#    hw/audio/pcspk.c

# Ensure /config/pcspk_audio exists and is writable
RUN mkdir -p /config/pcspk_audio && chmod 777 /config/pcspk_audio
RUN mkdir -p /config/pcspk_audio/static && chmod 777 /config/pcspk_audio/static

# Force audio init in pcspk_realizefn
RUN sed -i '/pcspk_state = s;/i\
    pcspk_audio_init(s);\
    fprintf(stderr, "[PCSPK DEBUG] Forced audio init\\n");' hw/audio/pcspk.c

RUN sed -i '/static PCSpkState \*pcspk_state;/a static FILE *audio_dump_file = NULL;' hw/audio/pcspk.c

# Add fopen + debug logging in pcspk_audio_init
RUN sed -i '/AUD_register_card(s_spk, &s->card);/a \
fprintf(stderr, "[PCSPK DEBUG] Trying to open /config/pcspk_audio/pcspk_out.raw\\n");\
audio_dump_file = fopen("/config/pcspk_audio/pcspk_out.raw", "wb");\
if (!audio_dump_file) { perror("[PCSPK ERROR] fopen failed"); } else { fprintf(stderr, "[PCSPK DEBUG] Opened audio output file successfully\\n"); }' hw/audio/pcspk.c

# Add callback trigger debug log
#RUN sed -i '/pit_get_channel_info(s->pit, 2, &ch);/i \
#fprintf(stderr, "[PCSPK DEBUG] Callback triggered\\n");' hw/audio/pcspk.c

RUN sed -i '/AUD_write(s->voice, &s->sample_buf\[s->play_pos\], n);/a \
        if (audio_dump_file) fwrite(&s->sample_buf[s->play_pos], 1, n, audio_dump_file);' hw/audio/pcspk.c

RUN sed -i '/s->menu_bar = gtk_menu_bar_new();/s/^/\/\/ /' ui/gtk.c && \
    sed -i '/gtk_box_pack_start(GTK_BOX(s->main_box), s->menu_bar, FALSE, TRUE, 0);/s/^/\/\/ /' ui/gtk.c

# You can skip the Kconfig edits entirely—legacy soundhw support is built-in in 7.0.0.
# Then configure and build:

RUN ./configure \
    --target-list=x86_64-softmmu \
    --audio-drv-list=pa,alsa \
    --enable-kvm \
    --enable-linux-aio \
    --enable-gtk \
    --enable-sdl \
    --enable-debug \
    --disable-werror

RUN make -j$(nproc) && \
    make install


# 7. Cleanup build artifacts (optional)
#RUN rm -rf /build

# 8. Verify installed tools (optional debug)
#RUN which qemu-system-x86_64 && \
#    which qemu-img && \
#    qemu-system-x86_64 --version && \
#    qemu-img --version


# Copy your custom image into the container
# COPY temple.img /workspace/disk.img
#COPY TOS_Supplemental1.ISO.C /workspace/TOS_Supplemental1.ISO.C
#COPY TOS_Supplemental2.ISO.C /workspace/TOS_Supplemental2.ISO.C
#COPY TOS_Supplemental3.ISO.C /workspace/TOS_Supplemental3.ISO.C
# RUN chown abc:abc /workspace/disk.img

RUN pip install --break-system-packages --no-cache-dir --upgrade pip && \
    pip install --break-system-packages --no-cache-dir aiohttp

COPY ./listener/pcspk_stream_server.py /config/pcspk_audio/pcspk_stream_server.py
COPY ./listener/listen.html /config/pcspk_audio/static/listen.html
COPY ./listener/worklet-processor.js /config/pcspk_audio/static/worklet-processor.js

# Replace the default window manager startup with QEMU boot
COPY startwm.sh /defaults/startwm.sh

RUN mkdir /workspace
RUN touch /workspace/disk.img
RUN chown abc:abc /workspace/disk.img
RUN chmod +x /defaults/startwm.sh

RUN apk add --no-cache nginx
COPY nginx.conf /workspace/nginx.conf

EXPOSE 9000
CMD ["nginx", "-c", "/workspace/nginx.conf", "-g", "daemon off;"]
