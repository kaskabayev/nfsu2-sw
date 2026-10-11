# Xbox Input → XInput Compatibility Layer

add_library(xbox_input STATIC
    xinput_device.c
)
if(NINTENDO_SWITCH)
    # The Switch's controllers, read through libnx and mapped by position.
    target_sources(xbox_input PRIVATE xinput_nx.c)
elseif(IOS)
    # The touchscreen as the gamepad for port 0 when no controller is
    # attached (xinput_ios.c also self-guards on NFSU2_IOS, so it would
    # compile empty anywhere else).
    target_sources(xbox_input PRIVATE xinput_ios.c)
endif()

target_include_directories(xbox_input PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

if(WIN32)
    target_link_libraries(xbox_input PUBLIC platform xinput)
else()
    find_package(SDL2 REQUIRED)
    target_link_libraries(xbox_input PUBLIC platform SDL2::SDL2)
endif()

if(MSVC)
    target_compile_options(xbox_input PRIVATE /W4 /O2)
else()
    target_compile_options(xbox_input PRIVATE -Wall -Wextra -O2)
endif()
