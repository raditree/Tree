#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// ── Windows 11 RedirectionGuard ("untrusted mount point") ───────────────────
//
// PROCESS_MITIGATION_REDIRECTION_TRUST_POLICY.EnforceRedirectionTrust (0x1) makes
// a process REFUSE to follow reparse points (symlinks / junctions) that were
// created by a non-admin user. It is meant to stop privilege escalation via
// redirection (low-privileged location -> privileged location), so **elevated
// processes carry it by default** — and it is **inherited through the call
// chain** (measured: installer -> Tree.exe -> tree_core.exe -> the shell in the
// integrated terminal -> anything the user runs there, all 0x1; while
// explorer.exe and everything it spawns is 0x0).
//
// Impact on this product (measured on a real machine; full write-up in
// docs/known-issues.md #16): the installer is elevated and launches Tree when it
// finishes, so the whole Tree process tree refuses to follow
// windows/flutter/ephemeral/.plugin_symlinks/* — which is exactly what CMake's
// `add_subdirectory` needs — so `flutter build windows` always fails inside
// Tree's terminal, while the same command succeeds in a terminal the user opened
// themselves (spawned by explorer, clean).
//
// The policy cannot be cleared (`SetProcessMitigationPolicy(id, 0)` returns
// ERROR_ACCESS_DENIED) and there is no creation-time flag to switch it off for a
// child process, so the only clean way out is **to get a clean parent**: ask
// explorer to launch us again (explorer's chain measured 0x0).
constexpr wchar_t kRelaunchFlag[] = L"--tree-clean-relaunch";
constexpr wchar_t kSelfCheckFlag[] = L"--tree-rt-selfcheck";

// ProcessRedirectionTrustPolicy in the PROCESS_MITIGATION_POLICY enum. The local
// SDK (10.0.19041) predates that enum member, hence the raw value; on systems
// without the policy the call fails and we treat it as "not set" (0).
constexpr int kRedirectionTrustPolicyId = 16;

uint32_t RedirectionTrustFlags() {
  uint32_t flags = 0;
  if (!::GetProcessMitigationPolicy(
          ::GetCurrentProcess(),
          static_cast<PROCESS_MITIGATION_POLICY>(kRedirectionTrustPolicyId),
          &flags, sizeof(flags))) {
    return 0;
  }
  return flags;
}

std::wstring ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(size - 1), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], size);
  return wide;
}

bool HasArgument(const std::vector<std::string>& args, const wchar_t* flag) {
  for (const std::string& arg : args) {
    if (ToWide(arg) == flag) return true;
  }
  return false;
}

// Ask explorer to start the very same executable: explorer becomes the parent,
// so the new process gets a clean context (measured 0x0 and able to traverse the
// links, even when requested from an affected process).
//
// Note we must NOT ShellExecute our own exe directly: that process would be
// created by us and would inherit the mitigation again.
bool RelaunchViaShell() {
  wchar_t exe_path[MAX_PATH] = {0};
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) return false;
  std::wstring parameters = L"\"";
  parameters += exe_path;
  parameters += L"\"";
  const HINSTANCE result =
      ::ShellExecuteW(nullptr, L"open", L"explorer.exe", parameters.c_str(),
                      nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(result) > 32;  // > 32 = success
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const uint32_t rt_flags = RedirectionTrustFlags();
  const bool relaunched = HasArgument(command_line_arguments, kRelaunchFlag);

  // Diagnostic / self-check entry point: report state and decision only, never
  // start Flutter. Used by the packaging self-check and by the regression test
  // (test/redirection_guard_test.dart).
  if (HasArgument(command_line_arguments, kSelfCheckFlag)) {
    printf("tree-rt-selfcheck: flags=0x%04X would-relaunch=%d\n",
           static_cast<unsigned>(rt_flags),
           (rt_flags != 0 && !relaunched) ? 1 : 0);
    fflush(stdout);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  if (rt_flags != 0) {
    if (!relaunched) {
      if (RelaunchViaShell()) {
        ::CoUninitialize();
        return EXIT_SUCCESS;  // handed over to the clean instance
      }
      // Could not relaunch: start anyway (never lock the user out) but say so --
      // commands in the terminal that rely on reparse points will fail.
      fprintf(stderr,
              "[tree] RedirectionGuard(0x%04X): could not relaunch cleanly; "
              "terminal commands relying on reparse points (e.g. `flutter build "
              "windows`) will fail -- restart Tree from the Start menu "
              "(docs/known-issues.md #16)\n",
              static_cast<unsigned>(rt_flags));
    } else {
      // Still set after the relaunch (the shell chain itself is affected):
      // same deal, report it instead of staying silent.
      fprintf(stderr,
              "[tree] RedirectionGuard(0x%04X) is still set after relaunch; "
              "terminal commands relying on reparse points will fail "
              "(docs/known-issues.md #16)\n",
              static_cast<unsigned>(rt_flags));
    }
  }

  // Our own flags are a Windows-runner private matter: do not forward them.
  command_line_arguments.erase(
      std::remove_if(command_line_arguments.begin(),
                     command_line_arguments.end(),
                     [](const std::string& arg) {
                       return arg == "--tree-clean-relaunch" ||
                              arg == "--tree-rt-selfcheck";
                     }),
      command_line_arguments.end());

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"flutter_application_tree", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
