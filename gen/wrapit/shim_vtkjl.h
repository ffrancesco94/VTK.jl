#pragma once
// Shared by the generated translation units (JlClasses.cxx) and the
// merged shim: teaches CxxWrap that vtkSmartPointer is a smart pointer.
// Must be visible in EVERY TU that boxes vtkSmartPointer returns (the
// factory selection happens at compile time per translation unit).
#include <jlcxx/jlcxx.hpp>
#include <vtkSmartPointer.h>

namespace jlcxx
{
template <typename T>
struct IsSmartPointerType<vtkSmartPointer<T>> : std::true_type
{
};

// Allow vtkSmartPointer<Derived> to be used where vtkSmartPointer<Base> is
// expected (registers the __cxxwrap_smartptr_construct_from_other methods).
template <typename T>
struct ConstructorPointerType<vtkSmartPointer<T>>
{
  typedef vtkSmartPointer<T> type;
};

// CxxWrap's default smart-pointer finalizer deletes the C++ wrapper directly.
// For VTK that can call UnRegister/vtkGarbageCollector on a GC finalizer
// thread while another thread is executing VTK. Specialize the finalizer to
// transfer the wrapper to a synchronized deferred-deletion queue instead.
void defer_vtk_smart_pointer_deletion(void *pointer,
                                      void (*deleter)(void *));

template <typename T>
struct Finalizer<vtkSmartPointer<T>, SpecializedFinalizer>
{
  static void finalize(vtkSmartPointer<T> *pointer)
  {
    defer_vtk_smart_pointer_deletion(
        static_cast<void *>(pointer), [](void *wrapped) {
          delete static_cast<vtkSmartPointer<T> *>(wrapped);
        });
  }
};
}

void register_shim_methods(jlcxx::Module& mod);
void register_auto_shim_methods(jlcxx::Module& mod);
