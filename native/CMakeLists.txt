cmake_minimum_required(VERSION 3.24)

project(remvibe_archive_native LANGUAGES C CXX)

include(FetchContent)

set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)
if(MSVC)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static dependencies" FORCE)
set(ZLIB_BUILD_EXAMPLES OFF CACHE BOOL "Do not build zlib examples" FORCE)
set(NLOHMANN_JSON_BUILD_TESTS OFF CACHE BOOL "Do not build JSON tests" FORCE)

if(NOT TARGET zlibstatic)
  FetchContent_Declare(
    zlib
    GIT_REPOSITORY https://github.com/madler/zlib.git
    GIT_TAG 51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf
    GIT_SHALLOW FALSE
  )
  FetchContent_MakeAvailable(zlib)
endif()

if(NOT TARGET nlohmann_json::nlohmann_json)
  FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG 9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03
    GIT_SHALLOW FALSE
  )
  FetchContent_MakeAvailable(nlohmann_json)
endif()

add_library(remvibe_archive_native STATIC
  src/nta_v2_reader.cpp
)
add_library(remvibe::archive_native ALIAS remvibe_archive_native)

target_compile_features(remvibe_archive_native PUBLIC cxx_std_17)
target_include_directories(remvibe_archive_native
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(remvibe_archive_native
  PRIVATE
    zlibstatic
    nlohmann_json::nlohmann_json
)

if(MSVC)
  target_compile_options(remvibe_archive_native PRIVATE /W4 /permissive- /EHsc)
else()
  target_compile_options(remvibe_archive_native PRIVATE -Wall -Wextra -Wpedantic)
endif()
