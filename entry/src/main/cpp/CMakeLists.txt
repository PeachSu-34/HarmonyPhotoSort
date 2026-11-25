cmake_minimum_required(VERSION 3.16)
project(PhotoSortOrt LANGUAGES CXX)

add_library(photosort_ort SHARED TextEmbedding.cpp)
target_compile_features(photosort_ort PRIVATE cxx_std_17)
target_include_directories(photosort_ort PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/onnxruntime/include")
target_link_libraries(photosort_ort PRIVATE libace_napi.z.so dl)
