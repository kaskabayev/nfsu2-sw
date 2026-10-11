cmake_minimum_required(VERSION 3.20)
project(nv2a_vk C)

# Vulkan 1.3 renderer for the pushbuffer executor (XBOXRECOMP_VULKAN=ON):
# the Switch's NVK from mesa-switch, linked statically (NVK_SDK), or any
# Vulkan driver on Linux. Shares the shader generators with nv2a_gl, in
# their Vulkan dialect, and compiles them with glslang at run time.
add_library(xbox_nv2a_vk STATIC
    nv2a_vk.c
    ../nv2a_gl/gl_vsh.c
    ../nv2a_gl/gl_psh.c
)
target_include_directories(xbox_nv2a_vk PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

find_package(glslang CONFIG REQUIRED)
target_link_libraries(xbox_nv2a_vk PUBLIC glslang::glslang glslang::glslang-default-resource-limits)

if(NINTENDO_SWITCH)
    set(NVK_SDK "" CACHE PATH "mesa-switch install prefix (holds lib/libvulkan.a, include/vulkan)")
    if(NOT EXISTS "${NVK_SDK}/lib/libvulkan.a")
        message(FATAL_ERROR "NVK_SDK must point at a mesa-switch install (no lib/libvulkan.a in '${NVK_SDK}')")
    endif()
    target_include_directories(xbox_nv2a_vk PUBLIC "${NVK_SDK}/include")
    target_sources(xbox_nv2a_vk PRIVATE switch_elf_stubs.c switch_egl_stubs.c)
    # Static NVK and what it needs; listed twice for archive rescanning.
    target_link_libraries(xbox_nv2a_vk PUBLIC
        "${NVK_SDK}/lib/libvulkan.a" expat z nx
        "${NVK_SDK}/lib/libvulkan.a" expat z nx stdc++ m)
else()
    if(IOS)
        # iOS: MoltenVK static lib + SDL2 static, supplied by the caller.
        find_package(SDL2 REQUIRED)
        target_include_directories(xbox_nv2a_vk PUBLIC "${VULKAN_HEADERS_DIR}")
        find_library(SPIRV_TOOLS_LIB SPIRV-Tools PATHS "${CMAKE_PREFIX_PATH}/lib" "${CMAKE_FIND_ROOT_PATH}")
        find_library(SPIRV_TOOLS_OPT_LIB SPIRV-Tools-opt PATHS "${CMAKE_PREFIX_PATH}/lib" "${CMAKE_FIND_ROOT_PATH}")
        target_link_libraries(xbox_nv2a_vk PUBLIC
            SDL2::SDL2
            "${SPIRV_TOOLS_OPT_LIB}" "${SPIRV_TOOLS_LIB}" c++)
        # MoltenVK ships as an embedded framework; the app bundles it.
        set(MOLTENVK_FRAMEWORK "" CACHE PATH "MoltenVK.framework for iOS")
        if(MOLTENVK_FRAMEWORK)
            target_link_libraries(xbox_nv2a_vk PUBLIC "${MOLTENVK_FRAMEWORK}")
            target_link_options(xbox_nv2a_vk PUBLIC -Wl,-rpath,@executable_path/Frameworks)
        endif()
    else()
    find_package(Vulkan REQUIRED)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SDL2 REQUIRED IMPORTED_TARGET sdl2)
    # The distribution glslang is built with its optimizer (static SPIRV-Tools).
    target_link_libraries(xbox_nv2a_vk PUBLIC Vulkan::Vulkan PkgConfig::SDL2
        SPIRV-Tools-opt SPIRV-Tools stdc++)
    endif()
endif()
if(NOT MSVC)
    target_compile_options(xbox_nv2a_vk PRIVATE -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -O2)
endif()
