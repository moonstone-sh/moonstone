cmake_minimum_required(VERSION 3.10)
project(mock-cmake-lib C)

# Find Lua headers (provided by Moonstone via -DLUA_INCLUDE_DIR)
include_directories(${LUA_INCLUDE_DIR})

add_library(mock_cmake SHARED src/mock_cmake.c)
set_target_properties(mock_cmake PROPERTIES PREFIX "")

install(TARGETS mock_cmake DESTINATION .)
