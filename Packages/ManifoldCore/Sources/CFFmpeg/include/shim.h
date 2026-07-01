// Umbrella shim for the vendored static libav. Mirrors the spike's bridge.h —
// the exact surface proven to link + bridge into Swift. Headers resolve via the
// ThirdParty/ffmpeg/include search path set in Package.swift; the static archives
// are linked into the app binary (see project.yml). Stage 2a: link + callable
// proof only, no decode yet.
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/channel_layout.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
