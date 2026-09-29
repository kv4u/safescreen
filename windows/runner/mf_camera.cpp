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

#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
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
// Used only from the capture thread (see CaptureWorker below). ReadSample
// blocks until a frame is available, roughly one frame interval for a running
// camera. The first read after Start is slower because the sensor is still
// waking up, so Start performs one discarded read and absorbs that delay there
// rather than letting the first grab() appear to hang.
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

// ---------------------------------------------------------------------------
// Threading
//
// ReadSample blocks until the sensor delivers the next frame -- roughly one
// frame interval, several times a second. Doing that on the platform thread
// froze the UI for that long on every grab. So a dedicated capture thread owns
// Media Foundation outright: it creates the reader, reads from it and shuts it
// down, in its own multithreaded COM apartment.
//
// Flutter replies, however, must be sent on the platform thread. The capture
// thread therefore never touches a MethodResult: it queues the finished reply
// and posts kMfCameraDoneMessage to the runner window, whose message handler
// (on the platform thread) calls HandleMfCameraMessage to deliver it.
//
// Frames are exactly as fresh as before -- each grab still reads the next frame
// from the sensor -- and nothing runs between grabs, so this costs no more CPU.
// It only stops the UI thread waiting for the camera.
// ---------------------------------------------------------------------------

using MethodResultPtr =
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

struct Job {
  enum class Kind { kStart, kGrab, kStop, kQuit };
  Kind kind = Kind::kQuit;
  std::string preferred_name;
  MethodResultPtr result;
};

struct Reply {
  MethodResultPtr result;
  bool ok = true;
  flutter::EncodableValue value;
  std::string error_code;
  std::string error_message;

  static Reply Success(flutter::EncodableValue v) {
    Reply r;
    r.value = std::move(v);
    return r;
  }
  static Reply Failure(std::string code, std::string message) {
    Reply r;
    r.ok = false;
    r.error_code = std::move(code);
    r.error_message = std::move(message);
    return r;
  }
};

class CaptureWorker {
 public:
  explicit CaptureWorker(HWND window) : window_(window) {
    thread_ = std::thread([this] { Run(); });
  }

  ~CaptureWorker() { Shutdown(); }

  CaptureWorker(const CaptureWorker&) = delete;
  CaptureWorker& operator=(const CaptureWorker&) = delete;

  void Post(Job job) {
    {
      std::lock_guard<std::mutex> lock(mu_);
      jobs_.push_back(std::move(job));
    }
    cv_.notify_one();
  }

  // Platform thread only: hands finished replies back to Dart.
  void DeliverReplies() {
    std::deque<Reply> ready;
    {
      std::lock_guard<std::mutex> lock(mu_);
      ready.swap(replies_);
    }
    for (Reply& r : ready) {
      if (!r.result) continue;
      if (r.ok) {
        r.result->Success(r.value);
      } else {
        r.result->Error(r.error_code, r.error_message);
      }
    }
  }

  // Stops the camera and joins the thread. Replies not yet delivered are
  // dropped: the engine they would go to is being torn down.
  void Shutdown() {
    if (!thread_.joinable()) return;
    Post(Job{});  // kQuit
    thread_.join();
    std::lock_guard<std::mutex> lock(mu_);
    replies_.clear();
    jobs_.clear();
  }

 private:
  void Run() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MfCamera camera;
    bool started = false;

    for (;;) {
      Job job;
      {
        std::unique_lock<std::mutex> lock(mu_);
        cv_.wait(lock, [this] { return !jobs_.empty(); });
        job = std::move(jobs_.front());
        jobs_.pop_front();
      }
      if (job.kind == Job::Kind::kQuit) break;

      Reply reply = Handle(&camera, &started, job);
      reply.result = std::move(job.result);
      {
        std::lock_guard<std::mutex> lock(mu_);
        replies_.push_back(std::move(reply));
      }
      ::PostMessage(window_, kMfCameraDoneMessage, 0, 0);
    }

    camera.Stop();
    if (SUCCEEDED(co)) CoUninitialize();
  }

  static Reply Handle(MfCamera* camera, bool* started, const Job& job) {
    switch (job.kind) {
      case Job::Kind::kStart: {
        std::string device;
        std::string error;
        int w = 0;
        int h = 0;
        if (!camera->Start(job.preferred_name, &device, &w, &h, &error)) {
          camera->Stop();
          *started = false;
          return Reply::Failure("start_failed", error);
        }
        *started = true;
        flutter::EncodableMap out;
        out[flutter::EncodableValue("device")] = flutter::EncodableValue(device);
        out[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
        out[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
        return Reply::Success(flutter::EncodableValue(out));
      }

      case Job::Kind::kGrab: {
        if (!*started) {
          return Reply::Failure("not_started", "camera is not running");
        }
        std::vector<uint8_t> bytes;
        int w = 0;
        int h = 0;
        int s = 0;
        if (!camera->Grab(&bytes, &w, &h, &s)) {
          // Null means "no frame this time", which the Dart side treats as a
          // detector blind spot and therefore protects the screen.
          return Reply::Success(flutter::EncodableValue());
        }
        flutter::EncodableMap out;
        out[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
        out[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
        out[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
        out[flutter::EncodableValue("stride")] = flutter::EncodableValue(s);
        return Reply::Success(flutter::EncodableValue(out));
      }

      case Job::Kind::kStop:
        camera->Stop();
        *started = false;
        return Reply::Success(flutter::EncodableValue());

      case Job::Kind::kQuit:
        break;
    }
    return Reply::Success(flutter::EncodableValue());
  }

  HWND window_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<Job> jobs_;
  std::deque<Reply> replies_;
  // Declared last so every member above exists before the thread starts.
  std::thread thread_;
};

std::unique_ptr<CaptureWorker> g_worker;

// The channel must outlive RegisterMfCameraChannel for the handler to keep
// receiving messages, so it is retained until ShutdownMfCamera.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

void RegisterMfCameraChannel(flutter::BinaryMessenger* messenger,
                             HWND window) {
  g_worker = std::make_unique<CaptureWorker>(window);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "safescreen/camera",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         MethodResultPtr result) {
        if (!g_worker) {
          result->Error("shut_down", "capture has been shut down");
          return;
        }
        const std::string& method = call.method_name();
        Job job;
        job.result = std::move(result);

        if (method == "start") {
          job.kind = Job::Kind::kStart;
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("deviceName"));
            if (it != args->end()) {
              const auto* s = std::get_if<std::string>(&it->second);
              if (s != nullptr) job.preferred_name = *s;
            }
          }
        } else if (method == "grab") {
          job.kind = Job::Kind::kGrab;
        } else if (method == "stop") {
          job.kind = Job::Kind::kStop;
        } else {
          job.result->NotImplemented();
          return;
        }
        g_worker->Post(std::move(job));
      });
}

bool HandleMfCameraMessage(UINT message) {
  if (message != kMfCameraDoneMessage) return false;
  if (g_worker) g_worker->DeliverReplies();
  return true;
}

void ShutdownMfCamera() {
  g_channel.reset();
  g_worker.reset();
}
