cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "coursepack_device_identity")
project(${PROJECT_NAME} LANGUAGES CXX)

add_library(${PROJECT_NAME} SHARED
  "coursepack_device_identity_plugin.cpp"
  "include/coursepack_device_identity/coursepack_device_identity_plugin.h"
)
apply_standard_settings(${PROJECT_NAME})
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PROJECT_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PROJECT_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PROJECT_NAME} PRIVATE flutter flutter_wrapper_plugin advapi32)
