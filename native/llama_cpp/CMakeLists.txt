cmake_minimum_required(VERSION 3.18.1)

project(llama_wrapper)

set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/src)

# Basic llama.cpp build
add_subdirectory(${LLAMA_DIR} EXCLUDE_FROM_ALL)

# Our wrapper
add_library(llama_wrapper SHARED
    llama_wrapper.cpp
)

target_include_directories(llama_wrapper PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${LLAMA_DIR}/include
    ${LLAMA_DIR}/ggml/include
)

target_link_libraries(llama_wrapper
    llama
)

if (ANDROID)
    target_link_libraries(llama_wrapper log)
endif()

# iOS Specifics
if (APPLE AND NOT ANDROID)
    set_target_properties(llama_wrapper PROPERTIES
        FRAMEWORK TRUE
        MACOSX_FRAMEWORK_IDENTIFIER com.example.llama_wrapper
        PUBLIC_HEADER llama_wrapper.h
    )
endif()
