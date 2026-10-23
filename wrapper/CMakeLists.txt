cmake_minimum_required(VERSION 3.21)
project(vtk_julia LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED VTK_JLL_DIR)
  message(FATAL_ERROR "VTK_JLL_DIR must point at the VTK_jll artifact directory")
endif()

find_package(JlCxx REQUIRED)
get_target_property(_jlcxx_lib JlCxx::cxxwrap_julia LOCATION)
get_filename_component(_jlcxx_libdir "${_jlcxx_lib}" DIRECTORY)

set(VTK_VERSION "9.7")
set(VTK_INCLUDE_DIR "${VTK_JLL_DIR}/include/vtk-${VTK_VERSION}")

set(VTK_LIBRARIES
  vtkCommonCore-${VTK_VERSION}
  vtkCommonDataModel-${VTK_VERSION}
  vtkCommonExecutionModel-${VTK_VERSION}
  vtkFiltersCore-${VTK_VERSION}
  vtkFiltersExtraction-${VTK_VERSION}
  vtkFiltersGeneral-${VTK_VERSION}
  vtkIOXML-${VTK_VERSION}
  vtkIOCore-${VTK_VERSION}
)

add_library(vtk_julia SHARED src/vtk_julia.cpp)
target_include_directories(vtk_julia PRIVATE "${VTK_INCLUDE_DIR}")
target_link_directories(vtk_julia PRIVATE "${VTK_JLL_DIR}/lib")
target_link_libraries(vtk_julia PRIVATE JlCxx::cxxwrap_julia ${VTK_LIBRARIES})

set_target_properties(vtk_julia PROPERTIES
  BUILD_RPATH "${VTK_JLL_DIR}/lib;${_jlcxx_libdir}"
)
