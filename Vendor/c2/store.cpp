// Inquiline's Codec2 store: decoders that hand video to the Mac, which decodes it with its
// own hardware (VideoToolbox). Its components' interfaces are AOSP's software decoders' own
// (frameworks/av/media/codec2/components, Apache 2.0), so apps see what they know.
#include <C2Component.h>
#include <C2Config.h>
#include <C2PlatformSupport.h>
#include <SimpleC2Interface.h>
#include <util/C2InterfaceHelper.h>
#include <media/stagefright/foundation/MediaDefs.h>
#include <codec2/aidl/ComponentStore.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <android-base/logging.h>
#include <SimpleC2Component.h>
#include <system/graphics.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <fstream>
#include <mutex>

namespace android {

namespace {
constexpr size_t kMinInputBufferSize = 2 * 1024 * 1024;

/// A kind of video the Mac decodes, as Android knows it.
struct Kind {
    uint8_t codec;  // as the Mac numbers them
    const char* word;  // as the Mac names them
    const char* name;
    const char* mediaType;
    C2Config::profile_t defaultProfile;
    C2Config::level_t defaultLevel;
    std::vector<C2Config::profile_t> profiles;
    std::vector<C2Config::level_t> levels;
};

const std::vector<Kind>& Kinds() {
    static const std::vector<Kind> kinds = {
        {1, "avc", "c2.inquiline.avc.decoder", MEDIA_MIMETYPE_VIDEO_AVC,
         C2Config::PROFILE_AVC_CONSTRAINED_BASELINE, C2Config::LEVEL_AVC_5_2,
         {C2Config::PROFILE_AVC_CONSTRAINED_BASELINE, C2Config::PROFILE_AVC_BASELINE, C2Config::PROFILE_AVC_MAIN,
          C2Config::PROFILE_AVC_CONSTRAINED_HIGH, C2Config::PROFILE_AVC_PROGRESSIVE_HIGH, C2Config::PROFILE_AVC_HIGH},
         {C2Config::LEVEL_AVC_1, C2Config::LEVEL_AVC_1B, C2Config::LEVEL_AVC_1_1, C2Config::LEVEL_AVC_1_2,
          C2Config::LEVEL_AVC_1_3, C2Config::LEVEL_AVC_2, C2Config::LEVEL_AVC_2_1, C2Config::LEVEL_AVC_2_2,
          C2Config::LEVEL_AVC_3, C2Config::LEVEL_AVC_3_1, C2Config::LEVEL_AVC_3_2, C2Config::LEVEL_AVC_4,
          C2Config::LEVEL_AVC_4_1, C2Config::LEVEL_AVC_4_2, C2Config::LEVEL_AVC_5, C2Config::LEVEL_AVC_5_1,
          C2Config::LEVEL_AVC_5_2}},
        {2, "vp9", "c2.inquiline.vp9.decoder", MEDIA_MIMETYPE_VIDEO_VP9,
         C2Config::PROFILE_VP9_0, C2Config::LEVEL_VP9_5,
         {C2Config::PROFILE_VP9_0},
         {C2Config::LEVEL_VP9_1, C2Config::LEVEL_VP9_1_1, C2Config::LEVEL_VP9_2, C2Config::LEVEL_VP9_2_1,
          C2Config::LEVEL_VP9_3, C2Config::LEVEL_VP9_3_1, C2Config::LEVEL_VP9_4, C2Config::LEVEL_VP9_4_1,
          C2Config::LEVEL_VP9_5, C2Config::LEVEL_VP9_5_1, C2Config::LEVEL_VP9_5_2, C2Config::LEVEL_VP9_6}},
        {3, "av1", "c2.inquiline.av1.decoder", MEDIA_MIMETYPE_VIDEO_AV1,
         C2Config::PROFILE_AV1_0, C2Config::LEVEL_AV1_5,
         {C2Config::PROFILE_AV1_0},
         {C2Config::LEVEL_AV1_2, C2Config::LEVEL_AV1_2_1, C2Config::LEVEL_AV1_2_2, C2Config::LEVEL_AV1_2_3,
          C2Config::LEVEL_AV1_3, C2Config::LEVEL_AV1_3_1, C2Config::LEVEL_AV1_3_2, C2Config::LEVEL_AV1_3_3,
          C2Config::LEVEL_AV1_4, C2Config::LEVEL_AV1_4_1, C2Config::LEVEL_AV1_4_2, C2Config::LEVEL_AV1_4_3,
          C2Config::LEVEL_AV1_5, C2Config::LEVEL_AV1_5_1, C2Config::LEVEL_AV1_5_2, C2Config::LEVEL_AV1_5_3,
          C2Config::LEVEL_AV1_6}},
        {4, "hevc", "c2.inquiline.hevc.decoder", MEDIA_MIMETYPE_VIDEO_HEVC,
         C2Config::PROFILE_HEVC_MAIN, C2Config::LEVEL_HEVC_MAIN_5_1,
         {C2Config::PROFILE_HEVC_MAIN, C2Config::PROFILE_HEVC_MAIN_STILL, C2Config::PROFILE_HEVC_MAIN_10},
         {C2Config::LEVEL_HEVC_MAIN_1, C2Config::LEVEL_HEVC_MAIN_2, C2Config::LEVEL_HEVC_MAIN_2_1,
          C2Config::LEVEL_HEVC_MAIN_3, C2Config::LEVEL_HEVC_MAIN_3_1, C2Config::LEVEL_HEVC_MAIN_4,
          C2Config::LEVEL_HEVC_MAIN_4_1, C2Config::LEVEL_HEVC_MAIN_5, C2Config::LEVEL_HEVC_MAIN_5_1,
          C2Config::LEVEL_HEVC_MAIN_5_2, C2Config::LEVEL_HEVC_HIGH_4, C2Config::LEVEL_HEVC_HIGH_4_1,
          C2Config::LEVEL_HEVC_HIGH_5, C2Config::LEVEL_HEVC_HIGH_5_1, C2Config::LEVEL_HEVC_HIGH_5_2}},
    };
    return kinds;
}

/// Inquiline writes its port, its token and the kinds of video this Mac decodes here as Android
/// starts, for this service alone.
bool ReadKey(unsigned* port, std::string* token, std::string* kinds) {
    std::ifstream file("/data/vendor/inquiline/decoder");
    return file >> *port >> *token >> *kinds && token->size() == 64;
}
constexpr uint32_t kDefaultOutputDelay = 8;
constexpr uint32_t kMaxOutputDelay = 34;
}  // namespace

class VideoIntf : public SimpleInterface<void>::BaseParams {
public:
    VideoIntf(const std::shared_ptr<C2ReflectorHelper> &helper, const Kind& kind)
        : SimpleInterface<void>::BaseParams(
                helper,
                kind.name,
                C2Component::KIND_DECODER,
                C2Component::DOMAIN_VIDEO,
                kind.mediaType) {
        noPrivateBuffers(); // TODO: account for our buffers here
        noInputReferences();
        noOutputReferences();
        noInputLatency();
        noTimeStretch();

        // TODO: Proper support for reorder depth.
        addParameter(
                DefineParam(mActualOutputDelay, C2_PARAMKEY_OUTPUT_DELAY)
                .withDefault(new C2PortActualDelayTuning::output(kDefaultOutputDelay))
                .withFields({C2F(mActualOutputDelay, value).inRange(0, kMaxOutputDelay)})
                .withSetter(Setter<decltype(*mActualOutputDelay)>::StrictValueWithNoDeps)
                .build());

        // TODO: output latency and reordering

        addParameter(
                DefineParam(mAttrib, C2_PARAMKEY_COMPONENT_ATTRIBUTES)
                .withConstValue(new C2ComponentAttributesSetting(C2Component::ATTRIB_IS_TEMPORAL))
                .build());

        // coded and output picture size is the same for this codec
        addParameter(
                DefineParam(mSize, C2_PARAMKEY_PICTURE_SIZE)
                .withDefault(new C2StreamPictureSizeInfo::output(0u, 320, 240))
                .withFields({
                    C2F(mSize, width).inRange(2, 4080, 2),
                    C2F(mSize, height).inRange(2, 4080, 2),
                })
                .withSetter(SizeSetter)
                .build());

        addParameter(
                DefineParam(mMaxSize, C2_PARAMKEY_MAX_PICTURE_SIZE)
                .withDefault(new C2StreamMaxPictureSizeTuning::output(0u, 320, 240))
                .withFields({
                    C2F(mSize, width).inRange(2, 4080, 2),
                    C2F(mSize, height).inRange(2, 4080, 2),
                })
                .withSetter(MaxPictureSizeSetter, mSize)
                .build());

        addParameter(
                DefineParam(mProfileLevel, C2_PARAMKEY_PROFILE_LEVEL)
                .withDefault(new C2StreamProfileLevelInfo::input(0u, kind.defaultProfile, kind.defaultLevel))
                .withFields({
                    C2F(mProfileLevel, profile).oneOf(std::vector<uint32_t>(kind.profiles.begin(), kind.profiles.end())),
                    C2F(mProfileLevel, level).oneOf(std::vector<uint32_t>(kind.levels.begin(), kind.levels.end()))
                })
                .withSetter(ProfileLevelSetter, mSize)
                .build());

        addParameter(
                DefineParam(mMaxInputSize, C2_PARAMKEY_INPUT_MAX_BUFFER_SIZE)
                .withDefault(new C2StreamMaxBufferSizeInfo::input(0u, kMinInputBufferSize))
                .withFields({
                    C2F(mMaxInputSize, value).any(),
                })
                .calculatedAs(MaxInputSizeSetter, mMaxSize)
                .build());

        C2ChromaOffsetStruct locations[1] = { C2ChromaOffsetStruct::ITU_YUV_420_0() };
        std::shared_ptr<C2StreamColorInfo::output> defaultColorInfo =
            C2StreamColorInfo::output::AllocShared(
                    1u, 0u, 8u /* bitDepth */, C2Color::YUV_420);
        memcpy(defaultColorInfo->m.locations, locations, sizeof(locations));

        defaultColorInfo =
            C2StreamColorInfo::output::AllocShared(
                    { C2ChromaOffsetStruct::ITU_YUV_420_0() },
                    0u, 8u /* bitDepth */, C2Color::YUV_420);
        helper->addStructDescriptors<C2ChromaOffsetStruct>();

        addParameter(
                DefineParam(mColorInfo, C2_PARAMKEY_CODED_COLOR_INFO)
                .withConstValue(defaultColorInfo)
                .build());

        addParameter(
                DefineParam(mDefaultColorAspects, C2_PARAMKEY_DEFAULT_COLOR_ASPECTS)
                .withDefault(new C2StreamColorAspectsTuning::output(
                        0u, C2Color::RANGE_UNSPECIFIED, C2Color::PRIMARIES_UNSPECIFIED,
                        C2Color::TRANSFER_UNSPECIFIED, C2Color::MATRIX_UNSPECIFIED))
                .withFields({
                    C2F(mDefaultColorAspects, range).inRange(
                                C2Color::RANGE_UNSPECIFIED,     C2Color::RANGE_OTHER),
                    C2F(mDefaultColorAspects, primaries).inRange(
                                C2Color::PRIMARIES_UNSPECIFIED, C2Color::PRIMARIES_OTHER),
                    C2F(mDefaultColorAspects, transfer).inRange(
                                C2Color::TRANSFER_UNSPECIFIED,  C2Color::TRANSFER_OTHER),
                    C2F(mDefaultColorAspects, matrix).inRange(
                                C2Color::MATRIX_UNSPECIFIED,    C2Color::MATRIX_OTHER)
                })
                .withSetter(DefaultColorAspectsSetter)
                .build());

        addParameter(
                DefineParam(mCodedColorAspects, C2_PARAMKEY_VUI_COLOR_ASPECTS)
                .withDefault(new C2StreamColorAspectsInfo::input(
                        0u, C2Color::RANGE_LIMITED, C2Color::PRIMARIES_UNSPECIFIED,
                        C2Color::TRANSFER_UNSPECIFIED, C2Color::MATRIX_UNSPECIFIED))
                .withFields({
                    C2F(mCodedColorAspects, range).inRange(
                                C2Color::RANGE_UNSPECIFIED,     C2Color::RANGE_OTHER),
                    C2F(mCodedColorAspects, primaries).inRange(
                                C2Color::PRIMARIES_UNSPECIFIED, C2Color::PRIMARIES_OTHER),
                    C2F(mCodedColorAspects, transfer).inRange(
                                C2Color::TRANSFER_UNSPECIFIED,  C2Color::TRANSFER_OTHER),
                    C2F(mCodedColorAspects, matrix).inRange(
                                C2Color::MATRIX_UNSPECIFIED,    C2Color::MATRIX_OTHER)
                })
                .withSetter(CodedColorAspectsSetter)
                .build());

        addParameter(
                DefineParam(mColorAspects, C2_PARAMKEY_COLOR_ASPECTS)
                .withDefault(new C2StreamColorAspectsInfo::output(
                        0u, C2Color::RANGE_UNSPECIFIED, C2Color::PRIMARIES_UNSPECIFIED,
                        C2Color::TRANSFER_UNSPECIFIED, C2Color::MATRIX_UNSPECIFIED))
                .withFields({
                    C2F(mColorAspects, range).inRange(
                                C2Color::RANGE_UNSPECIFIED,     C2Color::RANGE_OTHER),
                    C2F(mColorAspects, primaries).inRange(
                                C2Color::PRIMARIES_UNSPECIFIED, C2Color::PRIMARIES_OTHER),
                    C2F(mColorAspects, transfer).inRange(
                                C2Color::TRANSFER_UNSPECIFIED,  C2Color::TRANSFER_OTHER),
                    C2F(mColorAspects, matrix).inRange(
                                C2Color::MATRIX_UNSPECIFIED,    C2Color::MATRIX_OTHER)
                })
                .withSetter(ColorAspectsSetter, mDefaultColorAspects, mCodedColorAspects)
                .build());

        // TODO: support more formats?
        addParameter(
                DefineParam(mPixelFormat, C2_PARAMKEY_PIXEL_FORMAT)
                .withConstValue(new C2StreamPixelFormatInfo::output(
                                     0u, HAL_PIXEL_FORMAT_YCBCR_420_888))
                .build());
    }
    static C2R SizeSetter(bool mayBlock, const C2P<C2StreamPictureSizeInfo::output> &oldMe,
                          C2P<C2StreamPictureSizeInfo::output> &me) {
        (void)mayBlock;
        C2R res = C2R::Ok();
        if (!me.F(me.v.width).supportsAtAll(me.v.width)) {
            res = res.plus(C2SettingResultBuilder::BadValue(me.F(me.v.width)));
            me.set().width = oldMe.v.width;
        }
        if (!me.F(me.v.height).supportsAtAll(me.v.height)) {
            res = res.plus(C2SettingResultBuilder::BadValue(me.F(me.v.height)));
            me.set().height = oldMe.v.height;
        }
        return res;
    }

    static C2R MaxPictureSizeSetter(bool mayBlock, C2P<C2StreamMaxPictureSizeTuning::output> &me,
                                    const C2P<C2StreamPictureSizeInfo::output> &size) {
        (void)mayBlock;
        // TODO: get max width/height from the size's field helpers vs. hardcoding
        me.set().width = c2_min(c2_max(me.v.width, size.v.width), 4080u);
        me.set().height = c2_min(c2_max(me.v.height, size.v.height), 4080u);
        return C2R::Ok();
    }

    static C2R MaxInputSizeSetter(bool mayBlock, C2P<C2StreamMaxBufferSizeInfo::input> &me,
                                  const C2P<C2StreamMaxPictureSizeTuning::output> &maxSize) {
        (void)mayBlock;
        // assume compression ratio of 2
        me.set().value = c2_max((((maxSize.v.width + 15) / 16)
                * ((maxSize.v.height + 15) / 16) * 192), kMinInputBufferSize);
        return C2R::Ok();
    }

    static C2R ProfileLevelSetter(bool mayBlock, C2P<C2StreamProfileLevelInfo::input> &me,
                                  const C2P<C2StreamPictureSizeInfo::output> &size) {
        (void)mayBlock;
        (void)size;
        (void)me;  // TODO: validate
        return C2R::Ok();
    }

    static C2R DefaultColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsTuning::output> &me) {
        (void)mayBlock;
        if (me.v.range > C2Color::RANGE_OTHER) {
                me.set().range = C2Color::RANGE_OTHER;
        }
        if (me.v.primaries > C2Color::PRIMARIES_OTHER) {
                me.set().primaries = C2Color::PRIMARIES_OTHER;
        }
        if (me.v.transfer > C2Color::TRANSFER_OTHER) {
                me.set().transfer = C2Color::TRANSFER_OTHER;
        }
        if (me.v.matrix > C2Color::MATRIX_OTHER) {
                me.set().matrix = C2Color::MATRIX_OTHER;
        }
        return C2R::Ok();
    }

    static C2R CodedColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsInfo::input> &me) {
        (void)mayBlock;
        if (me.v.range > C2Color::RANGE_OTHER) {
                me.set().range = C2Color::RANGE_OTHER;
        }
        if (me.v.primaries > C2Color::PRIMARIES_OTHER) {
                me.set().primaries = C2Color::PRIMARIES_OTHER;
        }
        if (me.v.transfer > C2Color::TRANSFER_OTHER) {
                me.set().transfer = C2Color::TRANSFER_OTHER;
        }
        if (me.v.matrix > C2Color::MATRIX_OTHER) {
                me.set().matrix = C2Color::MATRIX_OTHER;
        }
        return C2R::Ok();
    }

    static C2R ColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsInfo::output> &me,
                                  const C2P<C2StreamColorAspectsTuning::output> &def,
                                  const C2P<C2StreamColorAspectsInfo::input> &coded) {
        (void)mayBlock;
        // take default values for all unspecified fields, and coded values for specified ones
        me.set().range = coded.v.range == RANGE_UNSPECIFIED ? def.v.range : coded.v.range;
        me.set().primaries = coded.v.primaries == PRIMARIES_UNSPECIFIED
                ? def.v.primaries : coded.v.primaries;
        me.set().transfer = coded.v.transfer == TRANSFER_UNSPECIFIED
                ? def.v.transfer : coded.v.transfer;
        me.set().matrix = coded.v.matrix == MATRIX_UNSPECIFIED ? def.v.matrix : coded.v.matrix;
        return C2R::Ok();
    }

    std::shared_ptr<C2StreamColorAspectsInfo::output> getColorAspects_l() {
        return mColorAspects;
    }

private:
    std::shared_ptr<C2StreamProfileLevelInfo::input> mProfileLevel;
    std::shared_ptr<C2StreamPictureSizeInfo::output> mSize;
    std::shared_ptr<C2StreamMaxPictureSizeTuning::output> mMaxSize;
    std::shared_ptr<C2StreamMaxBufferSizeInfo::input> mMaxInputSize;
    std::shared_ptr<C2StreamColorInfo::output> mColorInfo;
    std::shared_ptr<C2StreamColorAspectsInfo::input> mCodedColorAspects;
    std::shared_ptr<C2StreamColorAspectsTuning::output> mDefaultColorAspects;
    std::shared_ptr<C2StreamColorAspectsInfo::output> mColorAspects;
    std::shared_ptr<C2StreamPixelFormatInfo::output> mPixelFormat;
};


/// Talks to Inquiline on the Mac, which decodes the video with VideoToolbox and writes each
/// picture straight into the GPU buffer of the picture Android gave for it. Little-endian.
///   hello  "IQC1", 32-byte token, u8 codec (1 H.264, 2 VP9, 3 AV1, 4 HEVC)
///   'D' u64 index, u64 timestamp, u32 flags (1 codec config, 2 end of stream), u32 size, bytes
///   'E' drain: every picture still held
///   'F' flush: drop them
///       each answered with u32 count, then per picture u64 index, u32 width, u32 height
///       (width 0: the input made no picture)
///   'P' u64 index, u32 resource, u32 width, u32 height: write that picture into the resource
///       (YV12, as Android lays it out), answered with a status byte, 0 on success
class Mac {
public:
    struct Picture { uint64_t index; uint32_t width, height; };

    ~Mac() { if (mSocket >= 0) close(mSocket); }

    bool connect(uint8_t codec) {
        unsigned port = 0;
        std::string token, kinds;
        if (!ReadKey(&port, &token, &kinds)) return false;
        mSocket = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (mSocket < 0) return false;
        int on = 1;
        setsockopt(mSocket, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        inet_pton(AF_INET, "10.0.2.2", &address.sin_addr);
        if (::connect(mSocket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) return false;
        uint8_t hello[37] = {'I', 'Q', 'C', '1'};
        for (int i = 0; i < 32; i++) hello[4 + i] = std::stoi(token.substr(2 * i, 2), nullptr, 16);
        hello[36] = codec;
        uint8_t status = 1;
        return send(hello, sizeof(hello)) && receive(&status, 1) && status == 0;
    }

    bool decode(uint64_t index, uint64_t timestamp, uint32_t flags, const uint8_t* data, uint32_t size,
                std::vector<Picture>* pictures) {
        uint8_t head[25] = {'D'};
        memcpy(head + 1, &index, 8);
        memcpy(head + 9, &timestamp, 8);
        memcpy(head + 17, &flags, 4);
        memcpy(head + 21, &size, 4);
        return send(head, sizeof(head)) && (size == 0 || send(data, size)) && receivePictures(pictures);
    }

    bool drain(std::vector<Picture>* pictures) {
        uint8_t request = 'E';
        return send(&request, 1) && receivePictures(pictures);
    }

    bool flush() {
        uint8_t request = 'F';
        std::vector<Picture> dropped;
        return send(&request, 1) && receivePictures(&dropped);
    }

    bool write(uint64_t index, uint32_t resource, uint32_t width, uint32_t height) {
        uint8_t request[21] = {'P'};
        memcpy(request + 1, &index, 8);
        memcpy(request + 9, &resource, 4);
        memcpy(request + 13, &width, 4);
        memcpy(request + 17, &height, 4);
        uint8_t status = 1;
        return send(request, sizeof(request)) && receive(&status, 1) && status == 0;
    }

private:
    bool send(const void* data, size_t size) {
        auto* bytes = static_cast<const uint8_t*>(data);
        while (size > 0) {
            ssize_t sent = ::send(mSocket, bytes, size, MSG_NOSIGNAL);
            if (sent <= 0) return false;
            bytes += sent;
            size -= sent;
        }
        return true;
    }

    bool receive(void* data, size_t size) {
        auto* bytes = static_cast<uint8_t*>(data);
        while (size > 0) {
            ssize_t got = recv(mSocket, bytes, size, 0);
            if (got <= 0) return false;
            bytes += got;
            size -= got;
        }
        return true;
    }

    bool receivePictures(std::vector<Picture>* pictures) {
        uint32_t count;
        if (!receive(&count, 4) || count > 64) return false;
        pictures->resize(count);
        for (auto& picture : *pictures) {
            uint8_t entry[16];
            if (!receive(entry, sizeof(entry))) return false;
            memcpy(&picture.index, entry, 8);
            memcpy(&picture.width, entry + 8, 4);
            memcpy(&picture.height, entry + 12, 4);
        }
        return true;
    }

    int mSocket = -1;
};

/// gralloc's BufferUsage::VIDEO_DECODER, which Codec2's usage names lack.
constexpr uint64_t kVideoDecoderUsage = 1ull << 22;

/// The virtio-gpu resource behind a gralloc buffer: the one the Mac's GPU knows it by.
uint32_t ResourceOf(const C2Handle* handle) {
    static int gpu = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (gpu < 0 || !handle || handle->numFds < 1) return 0;
    struct { uint32_t handle, flags; int32_t fd; } prime = {0, 0, handle->data[0]};
    if (ioctl(gpu, _IOWR('d', 0x2e, decltype(prime)), &prime) != 0) return 0;
    struct { uint32_t bo, resource, size, blobMem; } info = {prime.handle, 0, 0, 0};
    int failed = ioctl(gpu, _IOWR('d', 0x40 + 0x05, decltype(info)), &info);
    struct { uint32_t handle, pad; } gemClose = {prime.handle, 0};
    ioctl(gpu, _IOW('d', 0x09, decltype(gemClose)), &gemClose);
    return failed ? 0 : info.resource;
}

class Decoder : public SimpleC2Component {
public:
    Decoder(const char* name, c2_node_id_t id, uint8_t codec, const std::shared_ptr<VideoIntf>& intf)
        : SimpleC2Component(std::make_shared<SimpleInterface<VideoIntf>>(name, id, intf)),
          mIntf(intf), mCodec(codec) {}

    bool connect() {
        mMac = std::make_unique<Mac>();
        return mMac->connect(mCodec);
    }

protected:
    c2_status_t onInit() override { return mMac ? C2_OK : C2_CORRUPTED; }
    c2_status_t onStop() override { return flushMac(); }
    void onReset() override { flushMac(); mSignalledEos = mFailed = false; }
    void onRelease() override { mMac.reset(); }
    c2_status_t onFlush_sm() override { mSignalledEos = false; return flushMac(); }

    void process(const std::unique_ptr<C2Work>& work, const std::shared_ptr<C2BlockPool>& pool) override {
        work->result = C2_OK;
        work->workletsProcessed = 0u;
        work->worklets.front()->output.flags = work->input.flags;
        if (mFailed || mSignalledEos) {
            work->result = C2_BAD_VALUE;
            return;
        }
        const bool eos = work->input.flags & C2FrameData::FLAG_END_OF_STREAM;
        const bool config = work->input.flags & C2FrameData::FLAG_CODEC_CONFIG;
        const uint64_t index = work->input.ordinal.frameIndex.peeku();
        C2ReadView view = mDummyReadView;
        if (!work->input.buffers.empty()) {
            view = work->input.buffers[0]->data().linearBlocks().front().map().get();
            if (view.error()) return fail(work);
        }
        std::vector<Mac::Picture> pictures;
        if (view.capacity() > 0) {
            uint32_t flags = (config ? 1 : 0) | (eos ? 2 : 0);
            if (!mMac->decode(index, work->input.ordinal.timestamp.peeku(), flags, view.data(),
                              view.capacity(), &pictures)) {
                return fail(work);
            }
        }
        bool done = config || view.capacity() == 0;
        for (const auto& picture : pictures) {
            if (!deliver(picture, pool, work, eos)) return fail(work);
            if (picture.index == index) done = true;
        }
        if (eos) {
            if (!mMac->drain(&pictures)) return fail(work);
            for (const auto& picture : pictures) {
                if (!deliver(picture, pool, work, true)) return fail(work);
            }
            mSignalledEos = true;
            done = true;
        }
        if (done && work->workletsProcessed == 0u) fillEmpty(work);
        work->input.buffers.clear();
    }

    c2_status_t drain(uint32_t mode, const std::shared_ptr<C2BlockPool>& pool) override {
        if (mode == NO_DRAIN) return C2_OK;
        if (mode == DRAIN_CHAIN) return C2_OMITTED;
        std::vector<Mac::Picture> pictures;
        if (!mMac->drain(&pictures)) return C2_CORRUPTED;
        std::unique_ptr<C2Work> none;
        for (const auto& picture : pictures) {
            if (!deliver(picture, pool, none, false)) return C2_CORRUPTED;
        }
        return C2_OK;
    }

private:
    static void fillEmpty(const std::unique_ptr<C2Work>& work) {
        work->worklets.front()->output.flags =
                (C2FrameData::flags_t)(work->input.flags & C2FrameData::FLAG_END_OF_STREAM);
        work->worklets.front()->output.buffers.clear();
        work->worklets.front()->output.ordinal = work->input.ordinal;
        work->workletsProcessed = 1u;
    }

    void fail(const std::unique_ptr<C2Work>& work) {
        mFailed = true;
        work->workletsProcessed = 1u;
        work->result = C2_CORRUPTED;
    }

    c2_status_t flushMac() {
        return !mMac || mMac->flush() ? C2_OK : C2_CORRUPTED;
    }

    /// One picture the Mac decoded, into a buffer of Android's, to the work its input came in.
    bool deliver(const Mac::Picture& picture, const std::shared_ptr<C2BlockPool>& pool,
                 const std::unique_ptr<C2Work>& current, bool eos) {
        std::shared_ptr<C2Buffer> buffer;
        std::unique_ptr<C2Param> sizeChange;
        if (picture.width > 0) {
            if (picture.width != mWidth || picture.height != mHeight) {
                C2StreamPictureSizeInfo::output size(0u, picture.width, picture.height);
                std::vector<std::unique_ptr<C2SettingResult>> failures;
                if (mIntf->config({&size}, C2_MAY_BLOCK, &failures) != C2_OK) return false;
                mWidth = picture.width;
                mHeight = picture.height;
                sizeChange = C2Param::Copy(size);
            }
            std::shared_ptr<C2GraphicBlock> block;
            // Written by the video decoder (gralloc's VIDEO_DECODER), as a phone's hardware
            // decoder's buffers are: an app that reads a picture into memory, not to a Surface,
            // then gets it from the GPU.
            C2MemoryUsage usage = {C2MemoryUsage::CPU_READ, C2MemoryUsage::CPU_WRITE | kVideoDecoderUsage};
            if (pool->fetchGraphicBlock(mWidth, mHeight, HAL_PIXEL_FORMAT_YV12, usage, &block) != C2_OK) {
                return false;
            }
            uint32_t resource = ResourceOf(block->handle());
            if (!resource || !mMac->write(picture.index, resource, block->width(), block->height())) {
                LOG(ERROR) << "Inquiline's decoder couldn't write a picture (resource " << resource << ", "
                           << block->width() << "x" << block->height() << ")";
                return false;
            }
            buffer = createGraphicBuffer(std::move(block), C2Rect(mWidth, mHeight));
            auto lock = mIntf->lock();
            buffer->setInfo(mIntf->getColorAspects_l());
        }
        std::shared_ptr<C2Param> change(sizeChange.release());
        auto fill = [buffer, change](const std::unique_ptr<C2Work>& work) {
            work->worklets.front()->output.flags = (C2FrameData::flags_t)0;
            work->worklets.front()->output.buffers.clear();
            if (buffer) work->worklets.front()->output.buffers.push_back(buffer);
            if (change) work->worklets.front()->output.configUpdate.push_back(C2Param::Copy(*change));
            work->worklets.front()->output.ordinal = work->input.ordinal;
            work->workletsProcessed = 1u;
        };
        if (current && current->input.ordinal.frameIndex.peeku() == picture.index) {
            if (eos) {
                // The end of the stream goes on its own, after this picture.
                if (buffer) {
                    C2WorkOrdinalStruct ordinal = current->input.ordinal;
                    cloneAndSend(picture.index, current, [buffer, change, ordinal](const std::unique_ptr<C2Work>& work) {
                        work->worklets.front()->output.flags = C2FrameData::FLAG_INCOMPLETE;
                        work->worklets.front()->output.buffers.clear();
                        work->worklets.front()->output.buffers.push_back(buffer);
                        if (change) work->worklets.front()->output.configUpdate.push_back(C2Param::Copy(*change));
                        work->worklets.front()->output.ordinal = ordinal;
                        work->workletsProcessed = 1u;
                        work->result = C2_OK;
                    });
                }
            } else {
                fill(current);
            }
        } else {
            finish(picture.index, fill);
        }
        return true;
    }

    std::shared_ptr<VideoIntf> mIntf;
    std::unique_ptr<Mac> mMac;
    const uint8_t mCodec;
    uint32_t mWidth = 0, mHeight = 0;
    bool mSignalledEos = false, mFailed = false;
};

/// The store: its components' names and interfaces, as Android lists codecs.
class Store : public C2ComponentStore {
public:
    Store() : mReflector(std::make_shared<C2ReflectorHelper>()) {}

    C2String getName() const override { return "inquiline"; }

    c2_status_t createComponent(C2String name, std::shared_ptr<C2Component>* const component) override {
        component->reset();
        const Kind* kind = find(name);
        if (!kind) return C2_NOT_FOUND;
        static std::atomic<c2_node_id_t> nextId;
        auto decoder = std::make_shared<Decoder>(kind->name, nextId++, kind->codec,
                                                 std::make_shared<VideoIntf>(mReflector, *kind));
        // Without Inquiline on the other end, Android takes its software decoder instead.
        if (!decoder->connect()) return C2_NO_MEMORY;
        *component = decoder;
        return C2_OK;
    }

    c2_status_t createInterface(C2String name, std::shared_ptr<C2ComponentInterface>* const interface) override {
        const Kind* kind = find(name);
        if (!kind) return C2_NOT_FOUND;
        *interface = std::shared_ptr<C2ComponentInterface>(new SimpleInterface<VideoIntf>(
                kind->name, 0, std::make_shared<VideoIntf>(mReflector, *kind)));
        return C2_OK;
    }

    /// The kinds this Mac decodes in its hardware.
    std::vector<std::shared_ptr<const C2Component::Traits>> listComponents() override {
        std::vector<std::shared_ptr<const C2Component::Traits>> list;
        unsigned port;
        std::string token, kinds;
        if (!ReadKey(&port, &token, &kinds)) return list;
        for (const auto& kind : Kinds()) {
            if (("," + kinds + ",").find(std::string(",") + kind.word + ",") == std::string::npos) continue;
            auto traits = std::make_shared<C2Component::Traits>();
            traits->name = kind.name;
            traits->domain = C2Component::DOMAIN_VIDEO;
            traits->kind = C2Component::KIND_DECODER;
            traits->mediaType = kind.mediaType;
            traits->rank = 0x100;
            traits->owner = "inquiline";
            list.push_back(traits);
        }
        return list;
    }

    c2_status_t copyBuffer(std::shared_ptr<C2GraphicBuffer>, std::shared_ptr<C2GraphicBuffer>) override {
        return C2_OMITTED;
    }
    c2_status_t query_sm(const std::vector<C2Param*>&, const std::vector<C2Param::Index>&,
                         std::vector<std::unique_ptr<C2Param>>* const) const override { return C2_OK; }
    c2_status_t config_sm(const std::vector<C2Param*>&, std::vector<std::unique_ptr<C2SettingResult>>* const) override {
        return C2_OK;
    }
    std::shared_ptr<C2ParamReflector> getParamReflector() const override { return mReflector; }
    c2_status_t querySupportedParams_nb(std::vector<std::shared_ptr<C2ParamDescriptor>>* const) const override { return C2_OK; }
    c2_status_t querySupportedValues_sm(std::vector<C2FieldSupportedValuesQuery>&) const override { return C2_OK; }

private:
    static const Kind* find(const C2String& name) {
        for (const auto& kind : Kinds()) if (name == kind.name) return &kind;
        return nullptr;
    }

    std::shared_ptr<C2ReflectorHelper> mReflector;
};

}  // namespace android

int main() {
    android::base::InitLogging(nullptr, android::base::LogdLogger(android::base::SYSTEM));
    ABinderProcess_setThreadPoolMaxThreadCount(8);
    ABinderProcess_startThreadPool();
    using namespace ::aidl::android::hardware::media::c2;
    auto store = ::ndk::SharedRefBase::make<utils::ComponentStore>(std::make_shared<android::Store>());
    const std::string instance = std::string(IComponentStore::descriptor) + "/default";
    if (AServiceManager_addService(store->asBinder().get(), instance.c_str()) != EX_NONE) {
        LOG(ERROR) << "Inquiline's codecs couldn't register";
        return 1;
    }
    LOG(INFO) << "Inquiline's codecs are ready";
    ABinderProcess_joinThreadPool();
    return 0;
}
