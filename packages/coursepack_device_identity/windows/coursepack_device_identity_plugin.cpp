#include "coursepack_device_identity_plugin.h"

#include <windows.h>

#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::wstring ReadRegistryString(HKEY root, const wchar_t* subkey,
                                const wchar_t* value_name) {
  DWORD byte_count = 0;
  const LONG size_status = RegGetValueW(root, subkey, value_name, RRF_RT_REG_SZ,
                                        nullptr, nullptr, &byte_count);
  if (size_status != ERROR_SUCCESS || byte_count == 0) return L"";

  std::vector<wchar_t> buffer(byte_count / sizeof(wchar_t) + 1, L'\0');
  if (RegGetValueW(root, subkey, value_name, RRF_RT_REG_SZ, nullptr,
                   buffer.data(), &byte_count) != ERROR_SUCCESS) {
    return L"";
  }
  return std::wstring(buffer.data());
}

std::string ToUtf8(const std::wstring& value) {
  if (value.empty()) return "";
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) return "";
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::string ReadMachineGuid() {
  return ToUtf8(ReadRegistryString(
      HKEY_LOCAL_MACHINE,
      L"SOFTWARE\\Microsoft\\Cryptography",
      L"MachineGuid"));
}

std::string ReadSystemVolumeSerial() {
  wchar_t windows_directory[MAX_PATH] = {};
  const UINT length = GetWindowsDirectoryW(windows_directory, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return "";
  std::wstring root(windows_directory, 3);  // The system drive root, e.g. C:\\

  DWORD serial = 0;
  if (!GetVolumeInformationW(root.c_str(), nullptr, 0, &serial, nullptr,
                             nullptr, nullptr, 0)) {
    return "";
  }
  std::wstringstream formatted;
  formatted << std::uppercase << std::hex << std::setw(8) << std::setfill(L'0')
            << serial;
  return ToUtf8(formatted.str());
}

std::string ReadProcessorIdentifier() {
  return ToUtf8(ReadRegistryString(
      HKEY_LOCAL_MACHINE,
      L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
      L"Identifier"));
}

std::string ReadComponents() {
  std::vector<std::string> parts;
  const std::string machine_guid = ReadMachineGuid();
  const std::string volume_serial = ReadSystemVolumeSerial();
  const std::string processor_id = ReadProcessorIdentifier();
  if (!machine_guid.empty()) parts.push_back("win:" + machine_guid);
  if (!volume_serial.empty()) parts.push_back("vol:" + volume_serial);
  if (!processor_id.empty()) parts.push_back("cpu:" + processor_id);

  std::ostringstream result;
  for (size_t i = 0; i < parts.size(); ++i) {
    if (i > 0) result << '|';
    result << parts[i];
  }
  return result.str();
}

}  // namespace

CoursePackDeviceIdentityPlugin::CoursePackDeviceIdentityPlugin() = default;
CoursePackDeviceIdentityPlugin::~CoursePackDeviceIdentityPlugin() = default;

void CoursePackDeviceIdentityPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<CoursePackDeviceIdentityPlugin>();
  plugin->channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.coursepack/device_identity",
      &flutter::StandardMethodCodec::GetInstance());
  plugin->channel_->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](
          const auto& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

void CoursePackDeviceIdentityPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "readComponents") {
    result->NotImplemented();
    return;
  }
  const std::string components = ReadComponents();
  if (components.empty()) {
    result->Error("device_identity_unavailable",
                  "Windows did not provide any device identity components.");
    return;
  }
  result->Success(flutter::EncodableValue(components));
}
