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

// 宽字符 → UTF-8：Dart 侧把 std::string 当 UTF-8 解码，路径里的中文必须转换，
// 否则前端拿到的是乱码路径。
std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int wide_length = static_cast<int>(wide.size());
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), wide_length,
                                       nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), wide_length, utf8.data(), size,
                      nullptr, nullptr);
  return utf8;
}

// 读取剪贴板中的**文件列表**（CF_HDROP）。资源管理器里多选文件复制时只有这种
// 形式能拿到全部路径（剪贴板位图一次只允许一张），所以 Dart 侧优先用它。
// 返回 true 表示至少取到一个路径；剪贴板无文件时返回 false（不是错误）。
bool ReadClipboardFilePaths(std::vector<std::string>& paths_out) {
  if (!OpenClipboard(nullptr)) {
    return false;
  }
  bool found = false;
  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE handle = GetClipboardData(CF_HDROP);
    if (handle != nullptr) {
      // HDROP 句柄只在剪贴板打开期间有效，DragQueryFileW 必须在这段区间内调用
      HDROP drop = static_cast<HDROP>(handle);
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < count; ++i) {
        const UINT length = DragQueryFileW(drop, i, nullptr, 0);
        if (length == 0) {
          continue;
        }
        std::wstring path(static_cast<size_t>(length) + 1, L'\0');
        if (DragQueryFileW(drop, i, path.data(), length + 1) == 0) {
          continue;
        }
        path.resize(length);
        const std::string utf8 = WideToUtf8(path);
        if (utf8.empty()) {
          continue;
        }
        paths_out.push_back(utf8);
        found = true;
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
  RegisterClipboardChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterClipboardChannel() {
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "tree/clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        // 文件列表（可多个）：资源管理器多选文件复制只在这里拿得到
        if (call.method_name() == "readFiles") {
          std::vector<std::string> paths;
          if (!ReadClipboardFilePaths(paths)) {
            // 剪贴板无文件：返回 null，Dart 侧继续按位图/文本处理
            result->Success(flutter::EncodableValue());
            return;
          }
          flutter::EncodableList list;
          list.reserve(paths.size());
          for (const std::string& path : paths) {
            list.push_back(flutter::EncodableValue(path));
          }
          result->Success(flutter::EncodableValue(list));
          return;
        }
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
