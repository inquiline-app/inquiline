/*
 * Copyright (C) 2011 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Inquiline: AOSP's stub HAL (hardware/libhardware/modules/audio/audio_hw.c, android15),
 * changed to play and record through the VM's sound card (virtio-sound, card 0, device 0)
 * with tinyalsa, which QEMU connects to the Mac's own sound through CoreAudio. Without the
 * card, a stream keeps the stub's timing and sends nowhere, as before. Built as
 * audio.primary.redroid.so, which Android picks over audio.primary.default.so.
 */

#define LOG_TAG "audio_hw_inquiline"
//#define LOG_NDEBUG 0

#include <errno.h>
#include <malloc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/system_properties.h>

#include <android/log.h>
#include <tinyalsa/asoundlib.h>
#define ALOGV(...) ((void)0)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#include <hardware/audio.h>
#include <hardware/hardware.h>
#include <system/audio.h>

#define STUB_DEFAULT_SAMPLE_RATE   48000
#define STUB_DEFAULT_AUDIO_FORMAT  AUDIO_FORMAT_PCM_16_BIT

#define STUB_INPUT_BUFFER_MILLISECONDS  20
#define STUB_INPUT_DEFAULT_CHANNEL_MASK AUDIO_CHANNEL_IN_STEREO

/* Playback follows the Android emulator's audio HAL (device/generic/goldfish/hals/audio,
 * device_port_sink.cpp, Apache-2.0): Android writes into a ring of a few buffers, at the pace of
 * the clock, and a thread of its own hands the ring to the card. Android's mixer never waits on
 * the card, so a VM held up for a moment, as while a game loads, doesn't stall it, and the card
 * can hold little. Sizes can be tuned without building again (vendor.inquiline.audio.*). */
#define OUTPUT_BUFFER_MS_DEFAULT  40 /* what Android writes at a time */
#define RING_BUFFERS_DEFAULT       1 /* the ring holds this many of those */
#define CARD_PERIODS_DEFAULT       4 /* the card holds one buffer, in this many periods */

#define CARD 0
#define CARD_DEVICE 0
/* Capture keeps the card's own pacing. */
#define PERIOD_COUNT 10
#define MAX_LEAD_MS 200
#define STUB_OUTPUT_DEFAULT_CHANNEL_MASK AUDIO_CHANNEL_OUT_STEREO

static unsigned audio_property(const char *name, unsigned fallback)
{
    char value[PROP_VALUE_MAX] = "";
    if (__system_property_get(name, value) <= 0) return fallback;
    unsigned long n = strtoul(value, NULL, 10);
    return n > 0 && n < 1000 ? (unsigned)n : fallback;
}

static int64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}

/* The ring and the thread that plays it (goldfish's TinyalsaSink). */
struct sink {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    pthread_t thread;
    bool running;
    struct pcm *pcm;
    struct pcm_config config;
    uint8_t *ring;
    size_t ring_frames, frame_size, period_frames;
    size_t capacity;    /* the ring's room: its buffers and the most the sound may be held back */
    uint32_t rate;
    int64_t start_ns;
    uint64_t received;  /* frames Android wrote */
    uint64_t played;    /* frames handed to the card */
    uint64_t missed;    /* frames the clock passed while nothing was there to play */
};

struct stub_audio_device {
    struct audio_hw_device device;
};

struct stub_stream_out {
    struct audio_stream_out stream;
    struct sink *sink;
    unsigned ring_buffers, card_periods;
    uint64_t frames_before; /* frames played by earlier sinks, as Android counts from the start */
    uint32_t sample_rate;
    audio_channel_mask_t channel_mask;
    audio_format_t format;
    size_t frame_count;
};

struct stub_stream_in {
    struct audio_stream_in stream;
    struct pcm *pcm;
    int64_t last_read_time_us;
    uint32_t sample_rate;
    audio_channel_mask_t channel_mask;
    audio_format_t format;
    size_t frame_count;
};

/* Opens the card's playback or capture side for a stream; NULL when there's no card. */
static struct pcm *open_card(unsigned int flags, uint32_t rate, unsigned int channels,
                             size_t period_frames)
{
    struct pcm_config config = {
        .channels = channels,
        .rate = rate,
        .period_size = period_frames,
        .period_count = PERIOD_COUNT,
        .format = PCM_FORMAT_S16_LE,
        .start_threshold = (flags & PCM_IN) ? 0 : period_frames,
    };
    struct pcm *pcm = pcm_open(CARD, CARD_DEVICE, flags, &config);
    if (!pcm || !pcm_is_ready(pcm)) {
        ALOGE("Sound card: %s", pcm ? pcm_get_error(pcm) : "no memory");
        if (pcm) pcm_close(pcm);
        return NULL;
    }
    return pcm;
}

static void *sink_play(void *arg)
{
    struct sink *sink = arg;
    pthread_mutex_lock(&sink->lock);
    while (sink->running) {
        if (sink->played == sink->received) {
            pthread_cond_wait(&sink->changed, &sink->lock);
            continue;
        }
        size_t at = sink->played % sink->capacity;
        size_t frames = sink->received - sink->played;
        if (frames > sink->period_frames) frames = sink->period_frames;
        if (frames > sink->capacity - at) frames = sink->capacity - at;
        pthread_mutex_unlock(&sink->lock);
        /* The card takes it at the Mac's own pace. A card that has just started can refuse a
         * write once, and then refuses to be prepared again: it's opened anew, as before. */
        if (pcm_writei(sink->pcm, sink->ring + at * sink->frame_size, frames) < 0) {
            ALOGE("Sound card write: %s", pcm_get_error(sink->pcm));
            pcm_close(sink->pcm);
            sink->pcm = pcm_open(CARD, CARD_DEVICE, PCM_OUT, &sink->config);
            if (!sink->pcm || !pcm_is_ready(sink->pcm)) {
                ALOGE("Sound card: %s", sink->pcm ? pcm_get_error(sink->pcm) : "no memory");
                if (sink->pcm) pcm_close(sink->pcm);
                sink->pcm = NULL;
                pthread_mutex_lock(&sink->lock);
                sink->running = false;
                break;
            }
            pcm_writei(sink->pcm, sink->ring + at * sink->frame_size, frames);
        }
        pthread_mutex_lock(&sink->lock);
        sink->played += frames;
        pthread_cond_broadcast(&sink->changed);
    }
    pthread_mutex_unlock(&sink->lock);
    return NULL;
}

static struct sink *sink_open(struct stub_stream_out *out)
{
    struct sink *sink = calloc(1, sizeof(*sink));
    if (!sink) return NULL;
    unsigned channels = audio_channel_count_from_out_mask(out->channel_mask);
    sink->rate = out->sample_rate;
    sink->frame_size = audio_stream_out_frame_size(&out->stream);
    sink->period_frames = out->frame_count / out->card_periods;
    sink->ring_frames = out->frame_count * out->ring_buffers;
    sink->capacity = sink->ring_frames + (size_t)out->sample_rate * MAX_LEAD_MS / 1000;
    struct pcm_config config = {
        .channels = channels,
        .rate = out->sample_rate,
        .period_size = sink->period_frames,
        .period_count = out->card_periods,
        .format = PCM_FORMAT_S16_LE,
        /* goldfish starts the card with all but one period in it. */
        .start_threshold = sink->period_frames * (out->card_periods - 1),
        .stop_threshold = sink->period_frames * out->card_periods,
    };
    sink->config = config;
    sink->pcm = pcm_open(CARD, CARD_DEVICE, PCM_OUT, &config);
    sink->ring = malloc(sink->capacity * sink->frame_size);
    if (!sink->pcm || !pcm_is_ready(sink->pcm) || !sink->ring) {
        ALOGE("Sound card: %s", sink->pcm ? pcm_get_error(sink->pcm) : "no memory");
        if (sink->pcm) pcm_close(sink->pcm);
        free(sink->ring);
        free(sink);
        return NULL;
    }
    pthread_mutex_init(&sink->lock, NULL);
    pthread_cond_init(&sink->changed, NULL);
    sink->running = true;
    sink->start_ns = now_ns();
    if (pthread_create(&sink->thread, NULL, sink_play, sink) != 0) {
        pcm_close(sink->pcm);
        free(sink->ring);
        free(sink);
        return NULL;
    }
    return sink;
}

/* Frames the clock says have been played since the sink started; must hold the lock. */
static uint64_t sink_clock_frames(const struct sink *sink, int64_t now)
{
    return (uint64_t)((now - sink->start_ns) / 1000) * sink->rate / 1000000;
}

static int64_t lead_frames(uint32_t rate);

/* Android writes up to the ring's buffers ahead of the clock, and as much more as the picture
 * reaches the Mac's screen later than the sound reaches its speakers (lead_frames): that sound
 * waits in the ring, so it's heard with its picture, as a TV holds its sound back for its
 * picture (lip sync). Video players time pictures by the clock, so they keep in step too. */
static void sink_write(struct sink *sink, const uint8_t *data, size_t frames)
{
    uint64_t lead = (uint64_t)lead_frames(sink->rate);
    pthread_mutex_lock(&sink->lock);
    while (frames > 0 && sink->running) {
        int64_t now = now_ns();
        uint64_t clock = sink_clock_frames(sink, now);
        /* Nothing was there to play: those frames are gone, as on goldfish. */
        if (sink->received + sink->missed < clock) sink->missed = clock - sink->received;
        uint64_t pending = sink->received + sink->missed - clock;
        uint64_t ahead = sink->ring_frames + lead;
        size_t room = pending < ahead ? (size_t)(ahead - pending) : 0;
        size_t space = sink->capacity - (size_t)(sink->received - sink->played);
        if (room == 0 || space == 0) {
            if (space == 0) {
                /* The card is behind the clock: wait for it. */
                pthread_cond_wait(&sink->changed, &sink->lock);
            } else {
                pthread_mutex_unlock(&sink->lock);
                usleep((useconds_t)((uint64_t)1000000 * (frames < sink->period_frames ? frames : sink->period_frames) / sink->rate));
                pthread_mutex_lock(&sink->lock);
            }
            continue;
        }
        size_t n = frames;
        if (n > room) n = room;
        if (n > space) n = space;
        size_t at = sink->received % sink->capacity;
        if (n > sink->capacity - at) n = sink->capacity - at;
        memcpy(sink->ring + at * sink->frame_size, data, n * sink->frame_size);
        sink->received += n;
        data += n * sink->frame_size;
        frames -= n;
        pthread_cond_broadcast(&sink->changed);
    }
    pthread_mutex_unlock(&sink->lock);
}

/* What has been heard: the clock's frames, less what was missed, never more than was written. */
static void sink_position(struct sink *sink, uint64_t *frames, struct timespec *when)
{
    pthread_mutex_lock(&sink->lock);
    int64_t now = now_ns();
    uint64_t clock = sink_clock_frames(sink, now);
    uint64_t heard = clock > sink->missed ? clock - sink->missed : 0;
    if (heard > sink->received) {
        /* Played out: the last frame was heard a while ago. */
        now -= (int64_t)(heard - sink->received) * 1000000000LL / sink->rate;
        heard = sink->received;
    }
    pthread_mutex_unlock(&sink->lock);
    *frames = heard;
    when->tv_sec = now / 1000000000LL;
    when->tv_nsec = now % 1000000000LL;
}

static uint64_t sink_close(struct sink *sink)
{
    uint64_t frames;
    struct timespec when;
    sink_position(sink, &frames, &when);
    pthread_mutex_lock(&sink->lock);
    sink->running = false;
    pthread_cond_broadcast(&sink->changed);
    pthread_mutex_unlock(&sink->lock);
    pthread_join(sink->thread, NULL);
    if (sink->pcm) pcm_close(sink->pcm);
    pthread_mutex_destroy(&sink->lock);
    pthread_cond_destroy(&sink->changed);
    free(sink->ring);
    free(sink);
    return frames;
}

static uint32_t out_get_sample_rate(const struct audio_stream *stream)
{
    const struct stub_stream_out *out = (const struct stub_stream_out *)stream;

    ALOGV("out_get_sample_rate: %u", out->sample_rate);
    return out->sample_rate;
}

static int out_set_sample_rate(struct audio_stream *stream, uint32_t rate)
{
    struct stub_stream_out *out = (struct stub_stream_out *)stream;

    ALOGV("out_set_sample_rate: %d", rate);
    out->sample_rate = rate;
    return 0;
}

static size_t out_get_buffer_size(const struct audio_stream *stream)
{
    const struct stub_stream_out *out = (const struct stub_stream_out *)stream;
    size_t buffer_size = out->frame_count *
                         audio_stream_out_frame_size(&out->stream);

    ALOGV("out_get_buffer_size: %zu", buffer_size);
    return buffer_size;
}

static audio_channel_mask_t out_get_channels(const struct audio_stream *stream)
{
    const struct stub_stream_out *out = (const struct stub_stream_out *)stream;

    ALOGV("out_get_channels: %x", out->channel_mask);
    return out->channel_mask;
}

static audio_format_t out_get_format(const struct audio_stream *stream)
{
    const struct stub_stream_out *out = (const struct stub_stream_out *)stream;

    ALOGV("out_get_format: %d", out->format);
    return out->format;
}

static int out_set_format(struct audio_stream *stream, audio_format_t format)
{
    struct stub_stream_out *out = (struct stub_stream_out *)stream;

    ALOGV("out_set_format: %d", format);
    out->format = format;
    return 0;
}

static int out_standby(struct audio_stream *stream)
{
    ALOGV("out_standby");
    struct stub_stream_out *out = (struct stub_stream_out *)stream;
    if (out->sink) {
        out->frames_before += sink_close(out->sink);
        out->sink = NULL;
    }
    return 0;
}

static int out_dump(const struct audio_stream *stream, int fd)
{
    ALOGV("out_dump");
    return 0;
}

static int out_set_parameters(struct audio_stream *stream, const char *kvpairs)
{
    ALOGV("out_set_parameters");
    return 0;
}

static char * out_get_parameters(const struct audio_stream *stream, const char *keys)
{
    ALOGV("out_get_parameters");
    return strdup("");
}

static uint32_t out_get_latency(const struct audio_stream_out *stream)
{
    const struct stub_stream_out *out = (const struct stub_stream_out *)stream;
    /* The ring and the card, as goldfish reports it. */
    return (uint32_t)(out->frame_count * (out->ring_buffers + 1) * 1000 / out->sample_rate);
}

static int out_set_volume(struct audio_stream_out *stream, float left,
                          float right)
{
    ALOGV("out_set_volume: Left:%f Right:%f", left, right);
    return 0;
}

static ssize_t out_write(struct audio_stream_out *stream, const void* buffer,
                         size_t bytes)
{
    struct stub_stream_out *out = (struct stub_stream_out *)stream;
    if (!out->sink) out->sink = sink_open(out);
    size_t frames = bytes / audio_stream_out_frame_size(stream);
    if (out->sink) {
        sink_write(out->sink, buffer, frames);
    } else {
        /* No card: the sound is dropped at the pace it would have played. */
        usleep((useconds_t)((uint64_t)1000000 * frames / out->sample_rate));
    }
    return bytes;
}

/* How far the Mac shows a picture after it plays the sound that goes with it, in ms, as
 * Inquiline measures it (the picture's way to the Mac's screen, less the sound's to its
 * speakers): the sound is held back that much (sink_write), as goldfish tells Android the
 * host's sound latency (ro.hardware.audio.tinyalsa.host_latency_ms). Read again each second. */
static int64_t lead_frames(uint32_t rate)
{
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static int64_t read_ns, lead_ms;
    pthread_mutex_lock(&lock);
    int64_t now = now_ns();
    if (now - read_ns > 1000000000LL) {
        read_ns = now;
        unsigned ms = audio_property("vendor.inquiline.audio.lead_ms", 0);
        lead_ms = ms > MAX_LEAD_MS ? MAX_LEAD_MS : ms;
    }
    int64_t frames = lead_ms * rate / 1000;
    pthread_mutex_unlock(&lock);
    return frames;
}

static int out_get_presentation_position(const struct audio_stream_out *stream,
                                         uint64_t *frames, struct timespec *timestamp)
{
    const struct stub_stream_out *out = (const struct stub_stream_out *)stream;
    if (!out->sink) return -ENODATA;
    sink_position(out->sink, frames, timestamp);
    /* Never past what was written: a player takes that for sound it never gave. */
    pthread_mutex_lock(&out->sink->lock);
    uint64_t written = out->sink->received;
    pthread_mutex_unlock(&out->sink->lock);
    if (*frames > written) *frames = written;
    *frames += out->frames_before;
    return 0;
}

static int out_get_render_position(const struct audio_stream_out *stream,
                                   uint32_t *dsp_frames)
{
    *dsp_frames = 0;
    ALOGV("out_get_render_position: dsp_frames: %p", dsp_frames);
    return -EINVAL;
}

static int out_add_audio_effect(const struct audio_stream *stream, effect_handle_t effect)
{
    ALOGV("out_add_audio_effect: %p", effect);
    return 0;
}

static int out_remove_audio_effect(const struct audio_stream *stream, effect_handle_t effect)
{
    ALOGV("out_remove_audio_effect: %p", effect);
    return 0;
}

static int out_get_next_write_timestamp(const struct audio_stream_out *stream,
                                        int64_t *timestamp)
{
    *timestamp = 0;
    ALOGV("out_get_next_write_timestamp: %ld", (long int)(*timestamp));
    return -EINVAL;
}

/** audio_stream_in implementation **/
static uint32_t in_get_sample_rate(const struct audio_stream *stream)
{
    const struct stub_stream_in *in = (const struct stub_stream_in *)stream;

    ALOGV("in_get_sample_rate: %u", in->sample_rate);
    return in->sample_rate;
}

static int in_set_sample_rate(struct audio_stream *stream, uint32_t rate)
{
    struct stub_stream_in *in = (struct stub_stream_in *)stream;

    ALOGV("in_set_sample_rate: %u", rate);
    in->sample_rate = rate;
    return 0;
}

static size_t in_get_buffer_size(const struct audio_stream *stream)
{
    const struct stub_stream_in *in = (const struct stub_stream_in *)stream;
    size_t buffer_size = in->frame_count *
                         audio_stream_in_frame_size(&in->stream);

    ALOGV("in_get_buffer_size: %zu", buffer_size);
    return buffer_size;
}

static audio_channel_mask_t in_get_channels(const struct audio_stream *stream)
{
    const struct stub_stream_in *in = (const struct stub_stream_in *)stream;

    ALOGV("in_get_channels: %x", in->channel_mask);
    return in->channel_mask;
}

static audio_format_t in_get_format(const struct audio_stream *stream)
{
    const struct stub_stream_in *in = (const struct stub_stream_in *)stream;

    ALOGV("in_get_format: %d", in->format);
    return in->format;
}

static int in_set_format(struct audio_stream *stream, audio_format_t format)
{
    struct stub_stream_in *in = (struct stub_stream_in *)stream;

    ALOGV("in_set_format: %d", format);
    in->format = format;
    return 0;
}

static int in_standby(struct audio_stream *stream)
{
    struct stub_stream_in *in = (struct stub_stream_in *)stream;
    in->last_read_time_us = 0;
    if (in->pcm) {
        pcm_close(in->pcm);
        in->pcm = NULL;
    }
    return 0;
}

static int in_dump(const struct audio_stream *stream, int fd)
{
    return 0;
}

static int in_set_parameters(struct audio_stream *stream, const char *kvpairs)
{
    return 0;
}

static char * in_get_parameters(const struct audio_stream *stream,
                                const char *keys)
{
    return strdup("");
}

static int in_set_gain(struct audio_stream_in *stream, float gain)
{
    return 0;
}

static ssize_t in_read(struct audio_stream_in *stream, void* buffer,
                       size_t bytes)
{
    ALOGV("in_read: bytes %zu", bytes);

    struct stub_stream_in *in = (struct stub_stream_in *)stream;
    if (!in->pcm) {
        in->pcm = open_card(PCM_IN, in->sample_rate,
                            audio_channel_count_from_in_mask(in->channel_mask), in->frame_count);
    }
    if (in->pcm) {
        // The Mac's microphone, which macOS asks the user about the first time.
        unsigned int frames = bytes / audio_stream_in_frame_size(stream);
        if (pcm_readi(in->pcm, buffer, frames) >= 0) return bytes;
        ALOGE("Sound card read: %s", pcm_get_error(in->pcm));
        pcm_close(in->pcm);
        in->pcm = NULL;
    }

    /* XXX: fake timing for audio input */
    struct timespec t = { .tv_sec = 0, .tv_nsec = 0 };
    clock_gettime(CLOCK_MONOTONIC, &t);
    const int64_t now = (t.tv_sec * 1000000000LL + t.tv_nsec) / 1000;

    // we do a full sleep when exiting standby.
    const bool standby = in->last_read_time_us == 0;
    const int64_t elapsed_time_since_last_read = standby ?
            0 : now - in->last_read_time_us;
    int64_t sleep_time = bytes * 1000000LL / audio_stream_in_frame_size(stream) /
            in_get_sample_rate(&stream->common) - elapsed_time_since_last_read;
    if (sleep_time > 0) {
        usleep(sleep_time);
    } else {
        sleep_time = 0;
    }
    in->last_read_time_us = now + sleep_time;
    // last_read_time_us is an approximation of when the (simulated) alsa
    // buffer is drained by the read, and is empty.
    //
    // On the subsequent in_read(), we measure the elapsed time spent in
    // the recording thread. This is subtracted from the sleep estimate based on frames,
    // thereby accounting for fill in the alsa buffer during the interim.
    memset(buffer, 0, bytes);
    return bytes;
}

static uint32_t in_get_input_frames_lost(struct audio_stream_in *stream)
{
    return 0;
}

static int in_add_audio_effect(const struct audio_stream *stream, effect_handle_t effect)
{
    return 0;
}

static int in_remove_audio_effect(const struct audio_stream *stream, effect_handle_t effect)
{
    return 0;
}

static size_t samples_per_milliseconds(size_t milliseconds,
                                       uint32_t sample_rate,
                                       size_t channel_count)
{
    return milliseconds * sample_rate * channel_count / 1000;
}

static int adev_open_output_stream(struct audio_hw_device *dev,
                                   audio_io_handle_t handle,
                                   audio_devices_t devices,
                                   audio_output_flags_t flags,
                                   struct audio_config *config,
                                   struct audio_stream_out **stream_out,
                                   const char *address __unused)
{
    ALOGV("adev_open_output_stream...");

    *stream_out = NULL;
    struct stub_stream_out *out =
            (struct stub_stream_out *)calloc(1, sizeof(struct stub_stream_out));
    if (!out)
        return -ENOMEM;

    out->stream.common.get_sample_rate = out_get_sample_rate;
    out->stream.common.set_sample_rate = out_set_sample_rate;
    out->stream.common.get_buffer_size = out_get_buffer_size;
    out->stream.common.get_channels = out_get_channels;
    out->stream.common.get_format = out_get_format;
    out->stream.common.set_format = out_set_format;
    out->stream.common.standby = out_standby;
    out->stream.common.dump = out_dump;
    out->stream.common.set_parameters = out_set_parameters;
    out->stream.common.get_parameters = out_get_parameters;
    out->stream.common.add_audio_effect = out_add_audio_effect;
    out->stream.common.remove_audio_effect = out_remove_audio_effect;
    out->stream.get_latency = out_get_latency;
    out->stream.set_volume = out_set_volume;
    out->stream.write = out_write;
    out->stream.get_render_position = out_get_render_position;
    out->stream.get_next_write_timestamp = out_get_next_write_timestamp;
    out->stream.get_presentation_position = out_get_presentation_position;
    out->sample_rate = config->sample_rate;
    if (out->sample_rate == 0)
        out->sample_rate = STUB_DEFAULT_SAMPLE_RATE;
    out->channel_mask = config->channel_mask;
    if (out->channel_mask == AUDIO_CHANNEL_NONE)
        out->channel_mask = STUB_OUTPUT_DEFAULT_CHANNEL_MASK;
    out->format = config->format;
    if (out->format == AUDIO_FORMAT_DEFAULT)
        out->format = STUB_DEFAULT_AUDIO_FORMAT;
    if (out->format != AUDIO_FORMAT_PCM_16_BIT) {
        // The card plays 16-bit PCM; Android asks again with what's offered here.
        config->format = AUDIO_FORMAT_PCM_16_BIT;
        free(out);
        return -EINVAL;
    }
    unsigned buffer_ms = audio_property("vendor.inquiline.audio.buffer_ms", OUTPUT_BUFFER_MS_DEFAULT);
    out->ring_buffers = audio_property("vendor.inquiline.audio.ring_buffers", RING_BUFFERS_DEFAULT);
    out->card_periods = audio_property("vendor.inquiline.audio.card_periods", CARD_PERIODS_DEFAULT);
    if (out->card_periods < 2) out->card_periods = 2;
    /* Whole periods of 16 frames, as goldfish aligns them. */
    out->frame_count = (samples_per_milliseconds(buffer_ms, out->sample_rate, 1)
                        / (16 * out->card_periods)) * 16 * out->card_periods;

    ALOGV("adev_open_output_stream: sample_rate: %u, channels: %x, format: %d,"
          " frames: %zu", out->sample_rate, out->channel_mask, out->format,
          out->frame_count);
    *stream_out = &out->stream;
    return 0;
}

static void adev_close_output_stream(struct audio_hw_device *dev,
                                     struct audio_stream_out *stream)
{
    ALOGV("adev_close_output_stream...");
    out_standby(&stream->common);
    free(stream);
}

static int adev_set_parameters(struct audio_hw_device *dev, const char *kvpairs)
{
    ALOGV("adev_set_parameters");
    return -ENOSYS;
}

static char * adev_get_parameters(const struct audio_hw_device *dev,
                                  const char *keys)
{
    ALOGV("adev_get_parameters");
    return strdup("");
}

static int adev_init_check(const struct audio_hw_device *dev)
{
    ALOGV("adev_init_check");
    return 0;
}

static int adev_set_voice_volume(struct audio_hw_device *dev, float volume)
{
    ALOGV("adev_set_voice_volume: %f", volume);
    return -ENOSYS;
}

static int adev_set_master_volume(struct audio_hw_device *dev, float volume)
{
    ALOGV("adev_set_master_volume: %f", volume);
    return -ENOSYS;
}

static int adev_get_master_volume(struct audio_hw_device *dev, float *volume)
{
    ALOGV("adev_get_master_volume: %f", *volume);
    return -ENOSYS;
}

static int adev_set_master_mute(struct audio_hw_device *dev, bool muted)
{
    ALOGV("adev_set_master_mute: %d", muted);
    return -ENOSYS;
}

static int adev_get_master_mute(struct audio_hw_device *dev, bool *muted)
{
    ALOGV("adev_get_master_mute: %d", *muted);
    return -ENOSYS;
}

static int adev_set_mode(struct audio_hw_device *dev, audio_mode_t mode)
{
    ALOGV("adev_set_mode: %d", mode);
    return 0;
}

static int adev_set_mic_mute(struct audio_hw_device *dev, bool state)
{
    ALOGV("adev_set_mic_mute: %d",state);
    return -ENOSYS;
}

static int adev_get_mic_mute(const struct audio_hw_device *dev, bool *state)
{
    ALOGV("adev_get_mic_mute");
    return -ENOSYS;
}

static size_t adev_get_input_buffer_size(const struct audio_hw_device *dev,
                                         const struct audio_config *config)
{
    size_t buffer_size = samples_per_milliseconds(
                             STUB_INPUT_BUFFER_MILLISECONDS,
                             config->sample_rate,
                             audio_channel_count_from_in_mask(
                                 config->channel_mask));

    if (!audio_has_proportional_frames(config->format)) {
        // Since the audio data is not proportional choose an arbitrary size for
        // the buffer.
        buffer_size *= 4;
    } else {
        buffer_size *= audio_bytes_per_sample(config->format);
    }
    ALOGV("adev_get_input_buffer_size: %zu", buffer_size);
    return buffer_size;
}

static int adev_open_input_stream(struct audio_hw_device *dev,
                                  audio_io_handle_t handle,
                                  audio_devices_t devices,
                                  struct audio_config *config,
                                  struct audio_stream_in **stream_in,
                                  audio_input_flags_t flags __unused,
                                  const char *address __unused,
                                  audio_source_t source __unused)
{
    ALOGV("adev_open_input_stream...");

    *stream_in = NULL;
    struct stub_stream_in *in = (struct stub_stream_in *)calloc(1, sizeof(struct stub_stream_in));
    if (!in)
        return -ENOMEM;

    in->stream.common.get_sample_rate = in_get_sample_rate;
    in->stream.common.set_sample_rate = in_set_sample_rate;
    in->stream.common.get_buffer_size = in_get_buffer_size;
    in->stream.common.get_channels = in_get_channels;
    in->stream.common.get_format = in_get_format;
    in->stream.common.set_format = in_set_format;
    in->stream.common.standby = in_standby;
    in->stream.common.dump = in_dump;
    in->stream.common.set_parameters = in_set_parameters;
    in->stream.common.get_parameters = in_get_parameters;
    in->stream.common.add_audio_effect = in_add_audio_effect;
    in->stream.common.remove_audio_effect = in_remove_audio_effect;
    in->stream.set_gain = in_set_gain;
    in->stream.read = in_read;
    in->stream.get_input_frames_lost = in_get_input_frames_lost;
    in->sample_rate = config->sample_rate;
    if (in->sample_rate == 0)
        in->sample_rate = STUB_DEFAULT_SAMPLE_RATE;
    in->channel_mask = config->channel_mask;
    if (in->channel_mask == AUDIO_CHANNEL_NONE)
        in->channel_mask = STUB_INPUT_DEFAULT_CHANNEL_MASK;
    in->format = config->format;
    if (in->format == AUDIO_FORMAT_DEFAULT)
        in->format = STUB_DEFAULT_AUDIO_FORMAT;
    if (in->format != AUDIO_FORMAT_PCM_16_BIT) {
        config->format = AUDIO_FORMAT_PCM_16_BIT;
        free(in);
        return -EINVAL;
    }
    in->frame_count = samples_per_milliseconds(
                          STUB_INPUT_BUFFER_MILLISECONDS, in->sample_rate, 1);

    ALOGV("adev_open_input_stream: sample_rate: %u, channels: %x, format: %d,"
          "frames: %zu", in->sample_rate, in->channel_mask, in->format,
          in->frame_count);
    *stream_in = &in->stream;
    return 0;
}

static void adev_close_input_stream(struct audio_hw_device *dev,
                                   struct audio_stream_in *in)
{
    ALOGV("adev_close_input_stream...");
    in_standby(&in->common);
    free(in);
}

static int adev_dump(const audio_hw_device_t *device, int fd)
{
    ALOGV("adev_dump");
    return 0;
}

static int adev_close(hw_device_t *device)
{
    ALOGV("adev_close");
    free(device);
    return 0;
}

static int adev_open(const hw_module_t* module, const char* name,
                     hw_device_t** device)
{
    ALOGV("adev_open: %s", name);

    struct stub_audio_device *adev;

    if (strcmp(name, AUDIO_HARDWARE_INTERFACE) != 0)
        return -EINVAL;

    adev = calloc(1, sizeof(struct stub_audio_device));
    if (!adev)
        return -ENOMEM;

    adev->device.common.tag = HARDWARE_DEVICE_TAG;
    adev->device.common.version = AUDIO_DEVICE_API_VERSION_2_0;
    adev->device.common.module = (struct hw_module_t *) module;
    adev->device.common.close = adev_close;

    adev->device.init_check = adev_init_check;
    adev->device.set_voice_volume = adev_set_voice_volume;
    adev->device.set_master_volume = adev_set_master_volume;
    adev->device.get_master_volume = adev_get_master_volume;
    adev->device.set_master_mute = adev_set_master_mute;
    adev->device.get_master_mute = adev_get_master_mute;
    adev->device.set_mode = adev_set_mode;
    adev->device.set_mic_mute = adev_set_mic_mute;
    adev->device.get_mic_mute = adev_get_mic_mute;
    adev->device.set_parameters = adev_set_parameters;
    adev->device.get_parameters = adev_get_parameters;
    adev->device.get_input_buffer_size = adev_get_input_buffer_size;
    adev->device.open_output_stream = adev_open_output_stream;
    adev->device.close_output_stream = adev_close_output_stream;
    adev->device.open_input_stream = adev_open_input_stream;
    adev->device.close_input_stream = adev_close_input_stream;
    adev->device.dump = adev_dump;

    *device = &adev->device.common;

    return 0;
}

static struct hw_module_methods_t hal_module_methods = {
    .open = adev_open,
};

struct audio_module HAL_MODULE_INFO_SYM = {
    .common = {
        .tag = HARDWARE_MODULE_TAG,
        .module_api_version = AUDIO_MODULE_API_VERSION_0_1,
        .hal_api_version = HARDWARE_HAL_API_VERSION,
        .id = AUDIO_HARDWARE_MODULE_ID,
        .name = "Default audio HW HAL",
        .author = "The Android Open Source Project",
        .methods = &hal_module_methods,
    },
};
