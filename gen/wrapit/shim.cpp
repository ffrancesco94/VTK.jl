// VTKGen shim: surface that WrapIt cannot generate for VTK.
//
// vtkSetStringMacro/vtkSetMacro-generated accessors (macro-expanded in
// headers; WrapIt 1.8.0 silently truncates output on them, so they are
// vetoed during generation and re-provided here). Ownership of factory
// returns (CxxPtr, borrowed) is a separate concern handled by the same
// take_ref + smart-pointer-traits shim as the hand-written VTK.jl wrapper.
#include <jlcxx/jlcxx.hpp>
#include <vtkAbstractArray.h>
#include <vtkTableBasedClipDataSet.h>
#include <vtkXMLWriterBase.h>
#include <vtkXMLReader.h>

JLCXX_MODULE define_julia_module(jlcxx::Module& mod)
{
  mod.method("shimSetName", [](vtkAbstractArray* a, const char* n) { a->SetName(n); });
  mod.method("shimGetName", [](vtkAbstractArray* a) -> std::string {
    const char* n = a->GetName();
    return n == nullptr ? std::string() : std::string(n);
  });
  mod.method("shimSetFileName", [](vtkXMLWriterBase* w, const char* n) { w->SetFileName(n); });
  mod.method("shimSetReaderFileName", [](vtkXMLReader* r, const char* n) { r->SetFileName(n); });
  mod.method("shimSetInsideOut", [](vtkTableBasedClipDataSet* f, bool v) { f->SetInsideOut(v); });
}
