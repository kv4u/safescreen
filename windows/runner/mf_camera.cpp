#include "mf_camera.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shlwapi.h>
#include <wrl/client.h>

#include <memory>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

std::string Utf8FromWide(const wchar_t* wide, int wide_len) {
  if (wide == nullptr || wide_len <= 0) return std::string();
  int size = ::WideCharToMultiByte(CP_UTF8, 0, wide, wide_len, nullptr, 0,
                                   nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string out(static_cast<size_t>(size), 0);
  ::WideCharToMultiByte(CP_UTF8, 0, wide, wide_len, &out[0], size, nullptr,
                        nullptr);
  return out;
}

// Owns the Media Foundation reader for one camera.
//
// Everything runs on the platform thread. ReadSample blocks until a frame is
// available, which for a running camera is roughly one frame interval. The
// first read after Start is slower because the sensor is still waking up, so
// Start performs one discarded read and absorbs that delay there rather than
// letting the first grab() appear to hang.
class MfCamera {
 public:
  ~MfCamera() { Stop(); }

  // Opens the first camera whose friendly name contains |preferred_name|, or
  // simply the first camera when that is empty.
  bool Start(const std::string& preferred_name, std::string* device_out,
             int* width_out, int* height_out, std::string* error_out) {
    Stop();

    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    if (FAILED(hr)) {
      *error_out = "MFStartup failed";
      return false;
    }
    mf_started_ = true;

    ComPtr<IMFAttributes> config;
    hr = MFCreateAttributes(&config, 1);
    if (FAILED(hr)) {
      *error_out = "MFCreateAttributes failed";
      return false;
    }
    config->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);

    IMFActivate** devices = nullptr;
    UINT32 count = 0;
    hr = MFEnumDeviceSources(config.Get(), &devices, &count);
    if (FAILED(hr) || count == 0) {
      if (devices != nullptr) CoTaskMemFree(devices);
      *error_out = "no video capture devices";
      return false;
    }

    UINT32 chosen = 0;
    std::string chosen_name;
    for (UINT32 i = 0; i < count; i++) {
      wchar_t* name = nullptr;
      UINT32 name_len = 0;
      if (SUCCEEDED(devices[i]->GetAllocatedString(
              MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &name_len))) {
        std::string utf8 = Utf8FromWide(name, static_cast<int>(name_len));
        CoTaskMemFree(name);
        if (i == 0) chosen_name = utf8;
        if (!preferred_name.empty() &&
            utf8.find(preferred_name) != std::string::npos) {
          chosen = i;
          chosen_name = utf8;
          break;
        }
      }
    }

    ComPtr<IMFMediaSource> source;
    hr = devices[chosen]->ActivateObject(IID_PPV_ARGS(&source));
    for (UINT32 i = 0; i < count; i++) devices[i]->Release();
    CoTaskMemFree(devices);
    if (FAILED(hr)) {
      *error_out = "could not activate camera";
      return false;
    }

    ComPtr<IMFAttributes> reader_attrs;
    hr = MFCreateAttributes(&reader_attrs, 1);
    if (SUCCEEDED(hr)) {
      // Lets the reader insert a converter, so RGB32 can be requested whether
      // the sensor speaks NV12, YUY2 or MJPG.
      reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }

    hr = MFCreateSourceReaderFromMediaSource(source.Get(), reader_attrs.Get(),
                                             &reader_);
    if (FAILED(hr)) {
      *error_out = "could not create source reader";
      return false;
    }

    ComPtr<IMFMediaType> rgb;
    hr = MFCreateMediaType(&rgb);
    if (FAILED(hr)) {
      *error_out = "MFCreateMediaType failed";
      return false;
    }
    rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    hr = reader_->SetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
        rgb.Get());
    if (FAILED(hr)) {
      *error_out = "camera would not provide RGB32";
      return false;
    }

    ComPtr<IMFMediaType> current;
    hr = reader_->GetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &current);
    if (FAILED(hr)) {
      *error_out = "could not read negotiated media type";
      return false;
    }

    UINT32 w = 0;
    UINT32 h = 0;
    MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h);
    if (w == 0 || h == 0) {
      *error_out = "camera reported a zero frame size";
      return false;
    }
    width_ = static_cast<int>(w);
    height_ = static_cast<int>(h);

    UINT32 raw_stride = 0;
    if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &raw_stride))) {
      stride_ = static_cast<int>(static_cast<INT32>(raw_stride));
    } else {
      stride_ = width_ * 4;
    }

    // Absorb sensor warm-up here rather than in the first grab().
    std::vector<uint8_t> discard;
    int dw = 0;
    int dh = 0;
    int ds = 0;
    Grab(&discard, &dw, &dh, &ds);

    *device_out = chosen_name;
    *width_out = width_;
    *height_out = height_;
    return true;
  }

  // Reads one frame. Returns false when no usable frame arrived.
  bool Grab(std::vector<uint8_t>* out, int* width, int* height, int* stride) {
    if (!reader_) return false;

    DWORD stream_flags = 0;
    ComPtr<IMFSample> sample;
    HRESULT hr = reader_->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
        &stream_flags, nullptr, &sample);
    if (FAILED(hr) || sample == nullptr) return false;

    ComPtr<IMFMediaBuffer> buffer;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return false;

    BYTE* data = nullptr;
    DWORD max_len = 0;
    DWORD current_len = 0;
    hr = buffer->Lock(&data, &max_len, &current_len);
    if (FAILED(hr)) return false;

    out->assign(data, data + current_len);
    buffer->Unlock();

    *width = width_;
    *height = height_;
    *stride = stride_;
    return true;
  }

  void Stop() {
    reader_.Reset();
    if (mf_started_) {
      MFShutdown();
      mf_started_ = false;
    }
    width_ = 0;
    height_ = 0;
    stride_ = 0;
  }

 private:
  ComPtr<IMFSourceReader> reader_;
  bool mf_started_ = false;
  int width_ = 0;
  int height_ = 0;
  int stride_ = 0;
};

std::unique_ptr<MfCamera> g_camera;

// The channel must outlive RegisterMfCameraChannel for the handler to keep
// receiving messages, so it is retained for the life of the process.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

void RegisterMfCameraChannel(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "safescreen/camera",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();

        if (method == "start") {
          std::string preferred;
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("deviceName"));
            if (it != args->end()) {
              const auto* s = std::get_if<std::string>(&it->second);
              if (s != nullptr) preferred = *s;
            }
          }

          if (!g_camera) g_camera = std::make_unique<MfCamera>();
          std::string device;
          std::string error;
          int w = 0;
          int h = 0;
          if (!g_camera->Start(preferred, &device, &w, &h, &error)) {
            g_camera.reset();
            result->Error("start_failed", error);
            return;
          }
          flutter::EncodableMap out;
          out[flutter::EncodableValue("device")] =
              flutter::EncodableValue(device);
          out[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          out[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          result->Success(flutter::EncodableValue(out));
          return;
        }

        if (method == "grab") {
          if (!g_camera) {
            result->Error("not_started", "camera is not running");
            return;
          }
          std::vector<uint8_t> bytes;
          int w = 0;
          int h = 0;
          int s = 0;
          if (!g_camera->Grab(&bytes, &w, &h, &s)) {
            // Null means "no frame this time", which the Dart side treats as a
            // detector blind spot and therefore protects the screen.
            result->Success(flutter::EncodableValue());
            return;
          }
          flutter::EncodableMap out;
          out[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          out[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          out[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          out[flutter::EncodableValue("stride")] = flutter::EncodableValue(s);
          result->Success(flutter::EncodableValue(out));
          return;
        }

        if (method == "stop") {
          if (g_camera) {
            g_camera->Stop();
            g_camera.reset();
          }
          result->Success(flutter::EncodableValue());
          return;
        }

        result->NotImplemented();
      });
}
