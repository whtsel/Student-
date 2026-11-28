#ifndef FLUTTER_PLUGIN_COURSEPACK_DEVICE_IDENTITY_PLUGIN_H_
#define FLUTTER_PLUGIN_COURSEPACK_DEVICE_IDENTITY_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#if defined(FLUTTER_PLUGIN_IMPL)
#define COURSEPACK_DEVICE_IDENTITY_PLUGIN_EXPORT __declspec(dllexport)
#else
#define COURSEPACK_DEVICE_IDENTITY_PLUGIN_EXPORT __declspec(dllimport)
#endif

COURSEPACK_DEVICE_IDENTITY_PLUGIN_EXPORT
void CoursePackDeviceIdentityPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

class CoursePackDeviceIdentityPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  CoursePackDeviceIdentityPlugin();
  ~CoursePackDeviceIdentityPlugin() override;

  CoursePackDeviceIdentityPlugin(const CoursePackDeviceIdentityPlugin&) = delete;
  CoursePackDeviceIdentityPlugin& operator=(const CoursePackDeviceIdentityPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // FLUTTER_PLUGIN_COURSEPACK_DEVICE_IDENTITY_PLUGIN_H_
