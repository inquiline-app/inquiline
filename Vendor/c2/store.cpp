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
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <set>
#include <thread>

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
         {C2Config::PROFILE_VP9_0, C2Config::PROFILE_VP9_2},
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

        // HDR10's static metadata, as AOSP's HEVC and AV1 decoders take it: it makes Android list
        // the HDR profiles (Codec2InfoBuilder), so apps offer HDR video. The Mac tone-maps the
        // pictures to SDR as it decodes them (engine patch 0111).
        auto hdrDefault = [] {
            auto* info = new C2StreamHdrStaticInfo::output(0u);
            info->mastering = {
                    .red = {.x = 0.708, .y = 0.292},
                    .green = {.x = 0.170, .y = 0.797},
                    .blue = {.x = 0.131, .y = 0.046},
                    .white = {.x = 0.3127, .y = 0.3290},
                    .maxLuminance = 0,
                    .minLuminance = 0,
            };
            info->maxCll = 0;
            info->maxFall = 0;
            return info;
        };
        mHdrStaticInfo.reset(hdrDefault());
        addParameter(
                DefineParam(mHdrStaticInfo, C2_PARAMKEY_HDR_STATIC_INFO)
                .withDefault(hdrDefault())
                .withFields({
                    C2F(mHdrStaticInfo, mastering.red.x).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.red.y).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.green.x).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.green.y).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.blue.x).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.blue.y).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.white.x).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.white.y).inRange(0, 1),
                    C2F(mHdrStaticInfo, mastering.maxLuminance).inRange(0, 65535),
                    C2F(mHdrStaticInfo, mastering.minLuminance).inRange(0, 6.5535),
                    C2F(mHdrStaticInfo, maxCll).inRange(0, 0XFFFF),
                    C2F(mHdrStaticInfo, maxFall).inRange(0, 0XFFFF)
                })
                .withSetter(HdrStaticInfoSetter)
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

    static C2R HdrStaticInfoSetter(bool mayBlock, C2P<C2StreamHdrStaticInfo::output> &me) {
        (void)mayBlock;
        if (me.v.mastering.red.x > 1) me.set().mastering.red.x = 1;
        if (me.v.mastering.red.y > 1) me.set().mastering.red.y = 1;
        if (me.v.mastering.green.x > 1) me.set().mastering.green.x = 1;
        if (me.v.mastering.green.y > 1) me.set().mastering.green.y = 1;
        if (me.v.mastering.blue.x > 1) me.set().mastering.blue.x = 1;
        if (me.v.mastering.blue.y > 1) me.set().mastering.blue.y = 1;
        if (me.v.mastering.white.x > 1) me.set().mastering.white.x = 1;
        if (me.v.mastering.white.y > 1) me.set().mastering.white.y = 1;
        if (me.v.mastering.maxLuminance > 65535.0) me.set().mastering.maxLuminance = 65535.0;
        if (me.v.mastering.minLuminance > 6.5535) me.set().mastering.minLuminance = 6.5535;
        if (me.v.maxCll > 65535.0) me.set().maxCll = 65535.0;
        if (me.v.maxFall > 65535.0) me.set().maxFall = 65535.0;
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
        // HDR video (PQ or HLG) comes out of the Mac tone-mapped to SDR BT.709, and is said so,
        // so Android shows it as it is and doesn't tone-map it again.
        if (me.v.transfer == C2Color::TRANSFER_ST2084 || me.v.transfer == C2Color::TRANSFER_HLG) {
            me.set().primaries = C2Color::PRIMARIES_BT709;
            me.set().transfer = C2Color::TRANSFER_170M;
            me.set().matrix = C2Color::MATRIX_BT709;
            me.set().range = C2Color::RANGE_LIMITED;
        }
        return C2R::Ok();
    }

    std::shared_ptr<C2StreamColorAspectsInfo::output> getColorAspects_l() {
        return mColorAspects;
    }

    /// The colour Android takes from the container, as ITU-T H.273 codes, for the Mac: HDR's
    /// alone matters, which a VP9 stream doesn't say itself.
    void containerColour_l(uint8_t codes[3]) {
        const auto& v = *mDefaultColorAspects;
        codes[0] = v.primaries == C2Color::PRIMARIES_BT2020 ? 9 : v.primaries == C2Color::PRIMARIES_BT709 ? 1 : 2;
        codes[1] = v.transfer == C2Color::TRANSFER_ST2084 ? 16 : v.transfer == C2Color::TRANSFER_HLG ? 18 : 2;
        codes[2] = v.matrix == C2Color::MATRIX_BT2020 ? 9 : v.matrix == C2Color::MATRIX_BT709 ? 1 : 2;
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
    std::shared_ptr<C2StreamHdrStaticInfo::output> mHdrStaticInfo;
    std::shared_ptr<C2StreamPixelFormatInfo::output> mPixelFormat;
};


/// Talks to Inquiline's engine on the Mac, which decodes the video with the Mac's media engine
/// and copies each picture on the GPU straight into the buffer Android gave for it. Requests go
/// out without waiting, as to a phone's hardware decoder; events come back on their own thread.
/// Little-endian.
///   hello  "IQC1", 32-byte token, u8 codec (1 H.264, 2 VP9, 3 AV1, 4 HEVC); answered with a status byte
///   'D' u64 index, u64 timestamp, u32 flags (1 codec config, 2 end of stream), u32 size, bytes
///   'E' drain, answered with 'X' once every picture held back is told
///   'F' flush, answered with 'L'
///   'P' u64 index, u32 resource, u32 width, u32 height: copy that picture into the resource,
///       answered with 'S' and a status byte, 0 on success
///   'C' u8 primaries, u8 transfer, u8 matrix (ITU-T H.273): the colour the container gives
///   event 'R' u64 index, u32 width, u32 height: a picture to show, in the order pictures are
///       shown (width 0: the input made no picture)
class Mac {
public:
    struct Event {
        enum Kind { Picture, Drained } kind;
        uint64_t index = 0;
        uint32_t width = 0, height = 0;
    };

    ~Mac() { close(); }

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
        return sendAll(hello, sizeof(hello)) && receive(&status, 1) && status == 0;
    }

    /// Starts reading events; pictures and drains go to |onEvent|, on the reading thread.
    void start(std::function<void(const Event&)> onEvent) {
        mOnEvent = std::move(onEvent);
        mReader = std::thread([this] { read(); });
    }

    void close() {
        if (mSocket >= 0) shutdown(mSocket, SHUT_RDWR);
        if (mReader.joinable()) mReader.join();
        if (mSocket >= 0) ::close(mSocket);
        mSocket = -1;
    }

    bool decode(uint64_t index, uint64_t timestamp, uint32_t flags, const uint8_t* data, uint32_t size) {
        uint8_t head[25] = {'D'};
        memcpy(head + 1, &index, 8);
        memcpy(head + 9, &timestamp, 8);
        memcpy(head + 17, &flags, 4);
        memcpy(head + 21, &size, 4);
        std::lock_guard<std::mutex> lock(mSendLock);
        return sendAll(head, sizeof(head)) && (size == 0 || sendAll(data, size));
    }

    bool colour(const uint8_t codes[3]) {
        uint8_t request[4] = {'C', codes[0], codes[1], codes[2]};
        std::lock_guard<std::mutex> lock(mSendLock);
        return sendAll(request, sizeof(request));
    }

    bool drain() {
        uint8_t request = 'E';
        std::lock_guard<std::mutex> lock(mSendLock);
        return sendAll(&request, 1);
    }

    /// Drops every picture not yet shown; pictures told before it returns are of the old stream.
    bool flush() {
        std::unique_lock<std::mutex> lock(mLock);
        const uint64_t flushes = mFlushes;
        {
            uint8_t request = 'F';
            std::lock_guard<std::mutex> sending(mSendLock);
            if (!sendAll(&request, 1)) return false;
        }
        mChanged.wait(lock, [&] { return mFlushes != flushes || mClosed; });
        return !mClosed;
    }

    /// Copies a picture into a buffer's resource; one at a time.
    bool write(uint64_t index, uint32_t resource, uint32_t width, uint32_t height) {
        std::unique_lock<std::mutex> lock(mLock);
        const uint64_t writes = mWrites;
        {
            uint8_t request[21] = {'P'};
            memcpy(request + 1, &index, 8);
            memcpy(request + 9, &resource, 4);
            memcpy(request + 13, &width, 4);
            memcpy(request + 17, &height, 4);
            std::lock_guard<std::mutex> sending(mSendLock);
            if (!sendAll(request, sizeof(request))) return false;
        }
        mChanged.wait(lock, [&] { return mWrites != writes || mClosed; });
        return !mClosed && mWriteStatus == 0;
    }

    /// How many flushes the engine has answered: pictures told before the last belong to a
    /// stream that is gone.
    uint64_t flushes() {
        std::lock_guard<std::mutex> lock(mLock);
        return mFlushes;
    }

private:
    void read() {
        uint8_t kind;
        while (receive(&kind, 1)) {
            if (kind == 'R') {
                uint8_t body[16];
                if (!receive(body, sizeof(body))) break;
                Event event{Event::Picture};
                memcpy(&event.index, body, 8);
                memcpy(&event.width, body + 8, 4);
                memcpy(&event.height, body + 12, 4);
                mOnEvent(event);
            } else if (kind == 'X') {
                mOnEvent(Event{Event::Drained});
            } else if (kind == 'L') {
                std::lock_guard<std::mutex> lock(mLock);
                mFlushes++;
                mChanged.notify_all();
            } else if (kind == 'S') {
                uint8_t status;
                if (!receive(&status, 1)) break;
                std::lock_guard<std::mutex> lock(mLock);
                mWriteStatus = status;
                mWrites++;
                mChanged.notify_all();
            } else {
                break;
            }
        }
        std::lock_guard<std::mutex> lock(mLock);
        mClosed = true;
        mChanged.notify_all();
    }

    bool sendAll(const void* data, size_t size) {
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

    int mSocket = -1;
    std::thread mReader;
    std::function<void(const Event&)> mOnEvent;
    std::mutex mSendLock;
    std::mutex mLock;
    std::condition_variable mChanged;
    uint64_t mFlushes = 0, mWrites = 0;
    uint8_t mWriteStatus = 1;
    bool mClosed = false;
};

/// A gralloc buffer as the VM's GPU knows it: its GEM handle here and the virtio-gpu resource the
/// Mac's GPU knows it by. DRM's and virtio-gpu's ioctls, as minigbm makes them.
class GpuBuffer {
public:
    explicit GpuBuffer(const C2Handle* handle) {
        if (Gpu() < 0 || !handle || handle->numFds < 1) return;
        struct { uint32_t handle, flags; int32_t fd; } prime = {0, 0, handle->data[0]};
        if (ioctl(Gpu(), _IOWR('d', 0x2e, decltype(prime)), &prime) != 0) return;
        mGem = prime.handle;
        struct { uint32_t bo, resource, size, blobMem; } info = {mGem, 0, 0, 0};
        if (ioctl(Gpu(), _IOWR('d', 0x40 + 0x05, decltype(info)), &info) == 0) mResource = info.resource;
    }

    ~GpuBuffer() {
        if (!mGem) return;
        struct { uint32_t handle, pad; } gemClose = {mGem, 0};
        ioctl(Gpu(), _IOW('d', 0x09, decltype(gemClose)), &gemClose);
    }

    uint32_t resource() const { return mResource; }

    /// Waits until the VM's GPU has done what it was asked for this buffer, its making included:
    /// the Mac is told of it by another way, which may come first.
    bool settle() {
        struct { uint32_t handle, flags; } wait = {mGem, 0};
        return mGem && ioctl(Gpu(), _IOWR('d', 0x40 + 0x08, decltype(wait)), &wait) == 0;
    }

    /// Brings what the Mac's GPU wrote into the buffer's memory in the VM, for an app that reads
    /// the picture there, as gralloc does when a buffer the GPU renders to is locked for reading.
    bool readBack(uint32_t width, uint32_t height) {
        struct { uint32_t x, y, z, w, h, d; } box = {0, 0, 0, width, height, 1};
        struct { uint32_t bo; decltype(box) box; uint32_t level, offset, stride, layerStride; } transfer =
            {mGem, box, 0, 0, 0, 0};
        if (ioctl(Gpu(), _IOWR('d', 0x40 + 0x06, decltype(transfer)), &transfer) != 0) return false;
        return settle();
    }

private:
    static int Gpu() {
        static int gpu = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
        return gpu;
    }

    uint32_t mGem = 0, mResource = 0;
};

/// A decoder as a phone's hardware one works (Android's v4l2_codec2): process() hands each input
/// to the Mac and returns at once; pictures come back as events, and an output thread puts each
/// into a buffer of Android's, which may wait for the app to give one back, without holding up
/// the inputs behind it.
class Decoder : public SimpleC2Component {
public:
    Decoder(const char* name, c2_node_id_t id, uint8_t codec, const std::shared_ptr<VideoIntf>& intf)
        : SimpleC2Component(std::make_shared<SimpleInterface<VideoIntf>>(name, id, intf)),
          mIntf(intf), mCodec(codec) {}

    ~Decoder() override { stopThreads(); }

    bool connect() {
        mMac = std::make_unique<Mac>();
        return mMac->connect(mCodec);
    }

protected:
    c2_status_t onInit() override {
        if (!mMac) return C2_CORRUPTED;
        mMac->start([this](const Mac::Event& event) { arrive(event); });
        mOutput = std::thread([this] { output(); });
        return C2_OK;
    }

    c2_status_t onStop() override { return flushMac(); }

    void onReset() override {
        flushMac();
        std::lock_guard<std::mutex> lock(mLock);
        mEosIndex.reset();
        mFailed = false;
    }

    void onRelease() override { stopThreads(); }

    c2_status_t onFlush_sm() override {
        c2_status_t status = flushMac();
        std::lock_guard<std::mutex> lock(mLock);
        mEosIndex.reset();
        return status;
    }

    void process(const std::unique_ptr<C2Work>& work, const std::shared_ptr<C2BlockPool>& pool) override {
        work->result = C2_OK;
        work->workletsProcessed = 0u;
        work->worklets.front()->output.flags = work->input.flags;
        const uint64_t index = work->input.ordinal.frameIndex.peeku();
        {
            // Every work before this one is among the pending ones now: their pictures may go.
            std::lock_guard<std::mutex> lock(mLock);
            mPool = pool;
            mStarted = index;
            mStartedAny = true;
            // The end's picture, if it has one, waits for this work rather than the pending ones.
            if (work->input.flags & C2FrameData::FLAG_END_OF_STREAM) mEosIndex = index;
            mChanged.notify_all();
            if (mFailed) {
                work->result = C2_CORRUPTED;
                work->workletsProcessed = 1u;
                return;
            }
        }
        const bool eos = work->input.flags & C2FrameData::FLAG_END_OF_STREAM;
        const bool config = work->input.flags & C2FrameData::FLAG_CODEC_CONFIG;
        C2ReadView view = mDummyReadView;
        if (!work->input.buffers.empty()) {
            view = work->input.buffers[0]->data().linearBlocks().front().map().get();
            if (view.error()) return fail(work);
        }
        if (view.capacity() > 0) {
            uint8_t codes[3];
            {
                auto lock = mIntf->lock();
                mIntf->containerColour_l(codes);
            }
            if (memcmp(codes, mSentColour, 3) != 0) {
                if (!mMac->colour(codes)) return fail(work);
                memcpy(mSentColour, codes, 3);
            }
            uint32_t flags = (config ? 1 : 0) | (eos ? 2 : 0);
            if (!mMac->decode(index, work->input.ordinal.timestamp.peeku(), flags, view.data(),
                              view.capacity())) {
                return fail(work);
            }
        }
        if (eos) {
            // The end: every picture held back comes first, as a phone's decoder drains; this
            // work's own picture, if any, comes with it.
            std::unique_lock<std::mutex> lock(mLock);
            const uint64_t drains = mDrains;
            lock.unlock();
            if (!mMac->drain()) return fail(work);
            lock.lock();
            mChanged.wait(lock, [&] { return mDrains != drains || mStopping; });
            auto buffer = std::move(mEosBuffer);
            auto change = std::move(mEosChange);
            mEosIndex.reset();
            lock.unlock();
            fillEmpty(work);
            if (buffer) work->worklets.front()->output.buffers.push_back(buffer);
            if (change) work->worklets.front()->output.configUpdate.push_back(C2Param::Copy(*change));
        } else if (config || view.capacity() == 0) {
            // No picture comes of it.
            fillEmpty(work);
        }
        work->input.buffers.clear();
    }

    c2_status_t drain(uint32_t mode, const std::shared_ptr<C2BlockPool>& pool) override {
        if (mode == NO_DRAIN) return C2_OK;
        if (mode == DRAIN_CHAIN) return C2_OMITTED;
        std::unique_lock<std::mutex> lock(mLock);
        mPool = pool;
        const uint64_t drains = mDrains;
        lock.unlock();
        if (!mMac->drain()) return C2_CORRUPTED;
        lock.lock();
        mChanged.wait(lock, [&] { return mDrains != drains || mStopping; });
        return C2_OK;
    }

private:
    struct Item {
        Mac::Event event;
        uint64_t flushes;  // of the stream it belongs to
    };

    /// On the Mac connection's reading thread: an event joins the output thread's queue.
    void arrive(const Mac::Event& event) {
        uint64_t flushes = mMac->flushes();
        std::lock_guard<std::mutex> lock(mLock);
        mQueue.push_back({event, flushes});
        mChanged.notify_all();
    }

    void output() {
        while (true) {
            std::unique_lock<std::mutex> lock(mLock);
            mChanged.wait(lock, [&] { return mStopping || !mQueue.empty(); });
            if (mStopping) return;
            Item item = mQueue.front();
            mQueue.pop_front();
            if (item.flushes != mMac->flushes()) continue;  // a stream flushed away
            if (item.event.kind == Mac::Event::Drained) {
                mDrains++;
                mChanged.notify_all();
                continue;
            }
            // A work is among the pending ones once a later one has started: Android's codec
            // framework files it just after process() returns.
            const uint64_t index = item.event.index;
            mChanged.wait(lock, [&] {
                return mStopping || (mStartedAny && mStarted > index) || (mEosIndex && *mEosIndex >= index) ||
                       item.flushes != mMac->flushes();
            });
            if (mStopping) return;
            if (item.flushes != mMac->flushes()) continue;
            const bool isEos = mEosIndex && *mEosIndex == index;
            auto pool = mPool;
            lock.unlock();
            std::shared_ptr<C2Buffer> buffer;
            std::shared_ptr<C2Param> change;
            picture(item.event, pool, &buffer, &change);
            if (isEos) {
                // The end's own work is being processed: it takes its picture itself.
                std::lock_guard<std::mutex> relock(mLock);
                mEosBuffer = buffer;
                mEosChange = change;
                continue;
            }
            finish(index, [buffer, change](const std::unique_ptr<C2Work>& work) {
                work->worklets.front()->output.flags = (C2FrameData::flags_t)0;
                work->worklets.front()->output.buffers.clear();
                if (buffer) work->worklets.front()->output.buffers.push_back(buffer);
                if (change) work->worklets.front()->output.configUpdate.push_back(C2Param::Copy(*change));
                work->worklets.front()->output.ordinal = work->input.ordinal;
                work->workletsProcessed = 1u;
            });
        }
    }

    /// One picture the Mac decoded, in a buffer of Android's; none when the input made none.
    void picture(const Mac::Event& picture, const std::shared_ptr<C2BlockPool>& pool,
                 std::shared_ptr<C2Buffer>* outBuffer, std::shared_ptr<C2Param>* outChange) {
        std::shared_ptr<C2Buffer>& buffer = *outBuffer;
        std::shared_ptr<C2Param>& change = *outChange;
        if (picture.width > 0 && pool) {
            if (picture.width != mWidth || picture.height != mHeight) {
                C2StreamPictureSizeInfo::output size(0u, picture.width, picture.height);
                std::vector<std::unique_ptr<C2SettingResult>> failures;
                if (mIntf->config({&size}, C2_MAY_BLOCK, &failures) == C2_OK) {
                    mWidth = picture.width;
                    mHeight = picture.height;
                    change = C2Param::Copy(size);
                }
            }
            std::shared_ptr<C2GraphicBlock> block;
            C2MemoryUsage usage = {C2MemoryUsage::CPU_READ, C2MemoryUsage::CPU_WRITE};
            if (pool->fetchGraphicBlock(mWidth, mHeight, HAL_PIXEL_FORMAT_YV12, usage, &block) == C2_OK) {
                GpuBuffer gpu(block->handle());
                uint32_t resource = gpu.resource();
                // Without a Surface the app reads the picture from memory: its buffers are made as
                // it asks, so the Mac waits for them, and the picture is brought into memory.
                const bool inMemory = pool->getAllocatorId() == C2PlatformAllocatorStore::GRALLOC;
                // A buffer seen for the first time may still be being made: the Mac waits for it.
                const bool fresh = mKnown.insert(resource).second;
                bool written = resource && (!(inMemory || fresh) || gpu.settle()) &&
                               mMac->write(picture.index, resource, block->width(), block->height()) &&
                               (!inMemory || gpu.readBack(block->width(), block->height()));
                if (written) {
                    buffer = createGraphicBuffer(std::move(block), C2Rect(mWidth, mHeight));
                    auto lock = mIntf->lock();
                    buffer->setInfo(mIntf->getColorAspects_l());
                } else {
                    LOG(ERROR) << "Inquiline's decoder couldn't write a picture (resource " << resource << ")";
                }
            }
        }
    }

    static void fillEmpty(const std::unique_ptr<C2Work>& work) {
        work->worklets.front()->output.flags =
                (C2FrameData::flags_t)(work->input.flags & C2FrameData::FLAG_END_OF_STREAM);
        work->worklets.front()->output.buffers.clear();
        work->worklets.front()->output.ordinal = work->input.ordinal;
        work->workletsProcessed = 1u;
    }

    void fail(const std::unique_ptr<C2Work>& work) {
        std::lock_guard<std::mutex> lock(mLock);
        mFailed = true;
        work->workletsProcessed = 1u;
        work->result = C2_CORRUPTED;
    }

    c2_status_t flushMac() {
        return !mMac || mMac->flush() ? C2_OK : C2_CORRUPTED;
    }

    void stopThreads() {
        {
            std::lock_guard<std::mutex> lock(mLock);
            mStopping = true;
            mChanged.notify_all();
        }
        if (mMac) mMac->close();
        if (mOutput.joinable()) mOutput.join();
    }

    std::shared_ptr<VideoIntf> mIntf;
    std::unique_ptr<Mac> mMac;
    const uint8_t mCodec;
    std::thread mOutput;
    /// The colour last told to the Mac; it starts unknown (2, 2, 2), as the Mac does.
    uint8_t mSentColour[3] = {2, 2, 2};
    // Guards what process(), the output thread and the Mac's events share.
    std::mutex mLock;
    std::condition_variable mChanged;
    std::deque<Item> mQueue;
    std::shared_ptr<C2BlockPool> mPool;
    uint64_t mStarted = 0, mDrains = 0;
    bool mStartedAny = false, mStopping = false, mFailed = false;
    std::optional<uint64_t> mEosIndex;
    std::shared_ptr<C2Buffer> mEosBuffer;
    std::shared_ptr<C2Param> mEosChange;
    uint32_t mWidth = 0, mHeight = 0;
    std::set<uint32_t> mKnown;  // resources already written to (output thread only)
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
