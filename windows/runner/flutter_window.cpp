#include "flutter_window.h"

#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

// 读取剪贴板中的图片字节。优先取 PNG 格式（常见截图工具会带出，体积小），
// 否则取 CF_DIB 拼接成 BMP。返回 true 表示至少有一种格式成功。
bool ReadClipboardImageBytes(std::vector<uint8_t>& png_out,
                             std::vector<uint8_t>& bmp_out) {
  if (!OpenClipboard(nullptr)) {
    return false;
  }
  bool found = false;

  // 优先 PNG：Win+Shift+S 等截图在剪贴板注册了 "PNG" 格式。
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
    HANDLE handle = GetClipboardData(png_format);
    if (handle != nullptr) {
      const BYTE* p = static_cast<const BYTE*>(GlobalLock(handle));
      const SIZE_T size = GlobalSize(handle);
      if (p != nullptr && size > 0) {
        png_out.assign(p, p + size);
        found = true;
      }
      if (p != nullptr) {
        GlobalUnlock(handle);
      }
    }
  }

  // 否则取 CF_DIB（DIB 数据 = BITMAPINFO 头 + 像素位），补一个文件头转成 BMP。
  if (!found && IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE handle = GetClipboardData(CF_DIB);
    if (handle != nullptr) {
      const BYTE* p = static_cast<const BYTE*>(GlobalLock(handle));
      const SIZE_T size = GlobalSize(handle);
      if (p != nullptr && size >= sizeof(BITMAPINFOHEADER)) {
        const auto* bih =
            reinterpret_cast<const BITMAPINFOHEADER*>(p);
        if (bih->biSize >= sizeof(BITMAPINFOHEADER)) {
          BITMAPFILEHEADER fh = {};
          fh.bfType = 0x4D42;  // 'BM'
          fh.bfOffBits = sizeof(BITMAPFILEHEADER) + bih->biSize;
          fh.bfSize = sizeof(BITMAPFILEHEADER) + static_cast<DWORD>(size);
          const BYTE* fh_bytes = reinterpret_cast<const BYTE*>(&fh);
          bmp_out.assign(fh_bytes, fh_bytes + sizeof(BITMAPFILEHEADER));
          bmp_out.insert(bmp_out.end(), p, p + size);
          found = true;
        }
      }
      if (p != nullptr) {
        GlobalUnlock(handle);
      }
    }
  }

  CloseClipboard();
  return found;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterClipboardImageChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterClipboardImageChannel() {
  clipboard_image_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "tree/clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_image_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() != "readImage") {
          result->NotImplemented();
          return;
        }
        std::vector<uint8_t> png;
        std::vector<uint8_t> bmp;
        if (!ReadClipboardImageBytes(png, bmp)) {
          // 剪贴板无图片，返回 null
          result->Success(flutter::EncodableValue());
          return;
        }
        const std::string format = png.empty() ? "bmp" : "png";
        const std::vector<uint8_t>& bytes = png.empty() ? bmp : png;
        flutter::EncodableMap map;
        map[flutter::EncodableValue("format")] =
            flutter::EncodableValue(format);
        map[flutter::EncodableValue("bytes")] =
            flutter::EncodableValue(bytes);
        result->Success(flutter::EncodableValue(map));
      });
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
