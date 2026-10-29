// shim_vtkjl.cpp — hand-written companion merged INTO the WrapIt-generated
// module (single library, single JLCXX_MODULE). Provides everything a
// generator cannot express for VTK:
//   * ownership (factories/outputs return owning vtkSmartPointer; getters
//     are take_ref'd; zero-copy views via vtkArrayDispatch),
//   * the output-window error hook (install_error_window/vtk_last_error),
//   * macro-generated and convenience accessors (SetFileName, SetInsideOut,
//     SetInputData, EnableCompression, ...),
//   * downcasts and the typed-array factory.
// Type registrations and plain method bindings come from WrapIt.

#include <jlcxx/jlcxx.hpp>
#include <jlcxx/smart_pointers.hpp>
#include <jlcxx/stl.hpp>
#include <vtkSmartPointer.h>
#include <vtkObjectBase.h>
#include <vtkObject.h>
#include <vtkObjectFactory.h>
#include <vtkOutputWindow.h>
#include <vtkAbstractArray.h>
#include <vtkDataArray.h>
#include <vtkFloatArray.h>
#include <vtkDoubleArray.h>
#include <vtkIntArray.h>
#include <vtkPoints.h>
#include <vtkFieldData.h>
#include <vtkPointData.h>
#include <vtkCellData.h>
#include <vtkDataObject.h>
#include <vtkDataSet.h>
#include <vtkIdList.h>
#include <vtkPointSet.h>
#include <vtkUnstructuredGrid.h>
#include <vtkPolyData.h>
#include <vtkImageData.h>
#include <vtkRectilinearGrid.h>
#include <vtkStructuredGrid.h>
#include <vtkAlgorithm.h>
#include <vtkImplicitFunction.h>
#include <vtkPlane.h>
#include <vtkXMLUnstructuredGridReader.h>
#include <vtkXMLUnstructuredGridWriter.h>
#include <vtkXMLPolyDataReader.h>
#include <vtkXMLPolyDataWriter.h>
#include <vtkXMLImageDataReader.h>
#include <vtkXMLImageDataWriter.h>
#include <vtkXMLRectilinearGridReader.h>
#include <vtkXMLRectilinearGridWriter.h>
#include <vtkXMLStructuredGridReader.h>
#include <vtkXMLStructuredGridWriter.h>
#include <vtkMultiBlockDataSet.h>
#include <vtkXMLMultiBlockDataReader.h>
#include <vtkXMLMultiBlockDataWriter.h>
#include <vtkTableBasedClipDataSet.h>
#include <vtkCutter.h>
#include <vtkCellDataToPointData.h>
#include <vtkPointDataToCellData.h>
#include <vtkContourFilter.h>
#include <vtkDataSetSurfaceFilter.h>
#include <vtkMultiBlockDataSetAlgorithm.h>
#include <vtkGenericEnSightReader.h>
#include <vtkEnSightReader.h>
#include <vtkEnSightGoldReader.h>
#include <vtkCGNSReader.h>
#include <vtkXMLPDataObjectReader.h>
#include <vtkXMLPDataReader.h>
#include <vtkXMLPUnstructuredDataReader.h>
#include <vtkXMLPPolyDataReader.h>
#include <vtkDataReader.h>
#include <vtkDataWriter.h>
#include <vtkDataSetReader.h>
#include <vtkDataSetWriter.h>
#include <vtkUnstructuredGridReader.h>
#include <vtkUnstructuredGridWriter.h>
#include <vtkPolyDataReader.h>
#include <vtkPolyDataWriter.h>
#include <vtkStructuredGridReader.h>
#include <vtkStructuredGridWriter.h>
#include <vtkRectilinearGridReader.h>
#include <vtkRectilinearGridWriter.h>
#include <vtkGenericDataObjectReader.h>
#include <vtkGenericDataObjectWriter.h>
#include <vtkArrayDispatch.h>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "shim_vtkjl.h"


namespace
{

// Redirect VTK's error/warning output into a buffer that Julia can inspect.
class vtkJuliaOutputWindow : public vtkOutputWindow
{
public:
  static vtkJuliaOutputWindow* New();
  vtkTypeMacro(vtkJuliaOutputWindow, vtkOutputWindow);

  void DisplayText(const char* text) override { this->Append(text); }
  void DisplayErrorText(const char* text) override { this->Append(text); }
  void DisplayWarningText(const char* text) override { this->Append(text); }
  void DisplayGenericWarningText(const char* text) override { this->Append(text); }
  void DisplayDebugText(const char* text) override { this->Append(text); }

  static std::string GetAndReset()
  {
    std::string result = vtkJuliaOutputWindow::LastMessage;
    vtkJuliaOutputWindow::LastMessage.clear();
    return result;
  }

private:
  static void Append(const char* text)
  {
    if (text != nullptr)
    {
      vtkJuliaOutputWindow::LastMessage += text;
      vtkJuliaOutputWindow::LastMessage += "\n";
    }
  }
  static std::string LastMessage;
};

std::string vtkJuliaOutputWindow::LastMessage;
vtkStandardNewMacro(vtkJuliaOutputWindow);

// Borrow a raw VTK pointer into a smart pointer without upsetting the
// reference count: Register first, then Take (Take does not Register).
template <typename T>
vtkSmartPointer<T> take_ref(T* raw)
{
  if (raw == nullptr)
  {
    throw std::runtime_error("take_ref: null pointer");
  }
  raw->Register(nullptr);
  return vtkSmartPointer<T>::Take(raw);
}


// Zero-copy views of an AOS vtkDataArray as Julia arrays. The flat layout is
// component-fastest (ncomponents * ntuples), which is exactly column-major
// for an (ncomponents, ntuples) matrix. The arrays are created directly at
// the target dimensionality so they are plain Array objects (not the
// immutable wrapper types that Julia's reshape/reinterpret produce).
struct ZeroCopyDataWorker
{
  template <typename ArrayT>
  void operator()(ArrayT* arr, jl_value_t*& out)
  {
    using V = std::remove_const_t<typename ArrayT::ValueType>;
    const jlcxx::cxxint_t n =
      static_cast<jlcxx::cxxint_t>(arr->GetNumberOfComponents() * arr->GetNumberOfTuples());
    V* ptr = static_cast<V*>(arr->GetVoidPointer(0));
    // Ensure the Julia Array{V,1} wrapper type exists (no-op if registered).
    jlcxx::create_if_not_exists<jlcxx::ArrayRef<V, 1>>();
    out = reinterpret_cast<jl_value_t*>(jlcxx::make_julia_array(ptr, n).wrapped());
  }
};

struct ZeroCopyMatrixWorker
{
  template <typename ArrayT>
  void operator()(ArrayT* arr, jl_value_t*& out)
  {
    using V = std::remove_const_t<typename ArrayT::ValueType>;
    const jlcxx::cxxint_t ncomp = static_cast<jlcxx::cxxint_t>(arr->GetNumberOfComponents());
    const jlcxx::cxxint_t nt = static_cast<jlcxx::cxxint_t>(arr->GetNumberOfTuples());
    V* ptr = static_cast<V*>(arr->GetVoidPointer(0));
    // CxxWrap pre-registers Array{V,1} for numbers but not higher
    // dimensions; create the Array{V,2} wrapper type before use.
    jlcxx::create_if_not_exists<jlcxx::ArrayRef<V, 2>>();
    out = reinterpret_cast<jl_value_t*>(jlcxx::make_julia_array(ptr, ncomp, nt).wrapped());
  }
};

template <typename WorkerT>
jl_value_t* zero_copy_impl(vtkDataArray* da, WorkerT worker)
{
  if (da->GetNumberOfTuples() == 0)
  {
    throw std::runtime_error("zero_copy: empty array");
  }
  if (da->GetArrayType() != vtkArrayTypes::VTK_AOS_DATA_ARRAY)
  {
    throw std::runtime_error("zero_copy: array is not AOS (use component API)");
  }
  jl_value_t* out = nullptr;
  if (!vtkArrayDispatch::Dispatch::Execute(da, worker, out))
  {
    throw std::runtime_error("zero_copy: array type not supported by dispatch");
  }
  return out;
}

jl_value_t* zero_copy_data(vtkDataArray* da)
{
  return zero_copy_impl(da, ZeroCopyDataWorker{});
}

jl_value_t* zero_copy_matrix(vtkDataArray* da)
{
  return zero_copy_impl(da, ZeroCopyMatrixWorker{});
}

} // namespace

// Force-register the smart-pointer methods (dereference, casts) for a

void register_shim_methods(jlcxx::Module& mod)
{
  using namespace jlcxx;

  // ---- type hierarchy (true VTK inheritance, used for smart-pointer casts) ----
  // Concrete array types: their real superclass is vtkAOSDataArrayTemplate<T>,
  // which derives from vtkDataArray, so registering them under vtkDataArray
  // is a valid up-cast (this mirrors VTK's __VTK_WRAP__ fake-superclass trick).

  // ---- smart pointer: the owning handle type for all factories/outputs ----
  // Registers the parametric type; concrete instantiations
  // (vtkSmartPointer{T}) are created lazily on first use.
  jlcxx::add_smart_pointer<vtkSmartPointer>(mod, "vtkSmartPointer");
  // The AOS leaf smart-pointer types reach module load with their Julia
  // types pre-registered but WITHOUT __cxxwrap_smartptr_cast_to_base
  // up-casts (CxxWrap's lazy cast registration is skipped once the type
  // exists). Provide explicit C++-side up-casts for the Julian layer's
  // SmartPointer{vtkDataArray} conversions. (const& args: by-value custom
  // smart-pointer args are undispatchable from Julia — see STATUS.md §4.2.)
  mod.method("upcast_dataarray",
    [](const vtkSmartPointer<vtkDoubleArray>& p) { return vtkSmartPointer<vtkDataArray>(p); });
  mod.method("upcast_dataarray",
    [](const vtkSmartPointer<vtkFloatArray>& p) { return vtkSmartPointer<vtkDataArray>(p); });
  mod.method("upcast_dataarray",
    [](const vtkSmartPointer<vtkIntArray>& p) { return vtkSmartPointer<vtkDataArray>(p); });

  // ---- error capture ----
  mod.method("install_error_window",
    []() { vtkOutputWindow::SetInstance(vtkJuliaOutputWindow::New()); });
  mod.method("vtk_last_error", []() { return vtkJuliaOutputWindow::GetAndReset(); });

  // ---- vtkDataArray ----
  // All parameters take vtkSmartPointer by value so that Julia's smart-pointer
  // conversion machinery (including up-casts) applies at call sites.
  mod.method("GetNumberOfTuples",
    [](vtkDataArray* a) { return static_cast<int64_t>(a->GetNumberOfTuples()); });
  mod.method("GetNumberOfComponents",
    [](vtkDataArray* a) { return a->GetNumberOfComponents(); });
  mod.method("GetComponent", [](vtkDataArray* a, int64_t i, int c) {
    return a->GetComponent(static_cast<vtkIdType>(i), c);
  });
  mod.method("SetComponent", [](vtkDataArray* a, int64_t i, int c, double v) {
    a->SetComponent(static_cast<vtkIdType>(i), c, v);
  });
  mod.method("SetNumberOfTuples", [](vtkDataArray* a, int64_t n) {
    a->SetNumberOfTuples(static_cast<vtkIdType>(n));
  });
  mod.method("SetArrayName", [](vtkDataArray* a, const std::string& name) {
    a->SetName(name.c_str());
  });
  mod.method("GetArrayName", [](vtkDataArray* a) -> std::string {
    const char* name = a->GetName();
    return name == nullptr ? std::string() : std::string(name);
  });
  mod.method("zero_copy_data", [](vtkDataArray* a) { return zero_copy_data(a); });
  mod.method("zero_copy_matrix", [](vtkDataArray* a) { return zero_copy_matrix(a); });

  // array factories
  mod.method("FloatArray_new", [](int64_t ncomp) {
    auto a = vtkSmartPointer<vtkFloatArray>::New();
    a->SetNumberOfComponents(static_cast<int>(ncomp));
    return a;
  });
  mod.method("DoubleArray_new", [](int64_t ncomp) {
    auto a = vtkSmartPointer<vtkDoubleArray>::New();
    a->SetNumberOfComponents(static_cast<int>(ncomp));
    return a;
  });
  mod.method("IntArray_new", [](int64_t ncomp) {
    auto a = vtkSmartPointer<vtkIntArray>::New();
    a->SetNumberOfComponents(static_cast<int>(ncomp));
    return a;
  });

  // ---- vtkPoints ----
  mod.method("Points_new", []() { return vtkSmartPointer<vtkPoints>::New(); });
  mod.method("SetNumberOfPoints", [](vtkPoints* p, int64_t n) {
    p->SetNumberOfPoints(static_cast<vtkIdType>(n));
  });
  mod.method("SetPoint", [](vtkPoints* p, int64_t i, double x, double y, double z) {
    p->SetPoint(static_cast<vtkIdType>(i), x, y, z);
  });
  mod.method("GetPoint", [](vtkPoints* p, int64_t i) {
    std::array<double, 3> pt;
    p->GetPoint(static_cast<vtkIdType>(i), pt.data());
    return std::make_tuple(pt[0], pt[1], pt[2]);
  });
  mod.method("GetPointData", [](vtkPoints* p) {
    return take_ref<vtkDataArray>(p->GetData());
  });

  // ---- field data ----
  mod.method("GetPointData", [](vtkDataSet* d) {
    return take_ref<vtkPointData>(d->GetPointData());
  });
  mod.method("GetCellData", [](vtkDataSet* d) {
    return take_ref<vtkCellData>(d->GetCellData());
  });
  mod.method("GetNumberOfArrays", [](vtkFieldData* f) { return f->GetNumberOfArrays(); });
  mod.method("GetArrayNameOf", [](vtkFieldData* f, int i) -> std::string {
    const char* name = f->GetArrayName(i);
    return name == nullptr ? std::string() : std::string(name);
  });
  mod.method("GetArray", [](vtkFieldData* f, const std::string& name) {
    return take_ref<vtkDataArray>(vtkDataArray::SafeDownCast(f->GetAbstractArray(name.c_str())));
  });
  mod.method("HasArray", [](vtkFieldData* f, const std::string& name) {
    return f->GetAbstractArray(name.c_str()) != nullptr;
  });
  // Generic typed array factory over the VTK scalar type ids (see vtkType.h).
  mod.method("CreateDataArray", [](int dataType, int64_t ncomp) {
    vtkAbstractArray* raw = vtkAbstractArray::CreateArray(dataType);
    auto* da = vtkDataArray::SafeDownCast(raw);
    if (da == nullptr)
    {
      if (raw != nullptr)
      {
        raw->Delete();
      }
      throw std::runtime_error("CreateDataArray: unsupported data type id");
    }
    da->SetNumberOfComponents(static_cast<int>(ncomp));
    return take_ref(da);
  });
  mod.method("GetDataType", [](vtkAbstractArray* a) { return a->GetDataType(); });
  mod.method("AddArray", [](vtkFieldData* f, vtkDataArray* a) {
    return f->AddArray(a);
  });
  mod.method("SetActiveScalars", [](vtkPointData* f, const std::string& name) {
    return f->SetActiveScalars(name.c_str());
  });
  mod.method("SetActiveScalars", [](vtkCellData* f, const std::string& name) {
    return f->SetActiveScalars(name.c_str());
  });

  // ---- vtkUnstructuredGrid ----
  mod.method("UnstructuredGrid_new", []() { return vtkSmartPointer<vtkUnstructuredGrid>::New(); });
  mod.method("GetNumberOfPoints", [](vtkPointSet* g) {
    return static_cast<int64_t>(g->GetNumberOfPoints());
  });
  mod.method("GetNumberOfCells", [](vtkDataSet* g) {
    return static_cast<int64_t>(g->GetNumberOfCells());
  });
  mod.method("GetPoints", [](vtkPointSet* g) {
    return take_ref<vtkPoints>(g->GetPoints());
  });
  mod.method("SetPoints", [](vtkPointSet* g, vtkPoints* p) {
    g->SetPoints(p);
  });
  mod.method("Allocate", [](vtkUnstructuredGrid* g, int64_t n) {
    g->Allocate(static_cast<vtkIdType>(n));
  });
  // VTK cell type ids, e.g. VTK_HEXAHEDRON = 12
  mod.method("InsertNextCell", [](vtkUnstructuredGrid* g, int64_t cellType,
                                   const std::vector<int64_t>& pointIds) {
    std::vector<vtkIdType> ids(pointIds.begin(), pointIds.end());
    return static_cast<int64_t>(g->InsertNextCell(static_cast<int>(cellType),
      static_cast<vtkIdType>(ids.size()), ids.data()));
  });
  // Cell queries (vtkDataSet API): type id and 0-based point ids of cell i.
  mod.method("GetCellTypeId", [](vtkDataSet* g, int64_t i) {
    return static_cast<int64_t>(g->GetCellType(static_cast<vtkIdType>(i)));
  });
  mod.method("GetCellPointIds", [](vtkDataSet* g, int64_t i) {
    vtkNew<vtkIdList> ids;
    g->GetCellPoints(static_cast<vtkIdType>(i), ids);
    std::vector<int64_t> out(static_cast<size_t>(ids->GetNumberOfIds()));
    for (int j = 0; j < ids->GetNumberOfIds(); ++j)
    {
      out[static_cast<size_t>(j)] = static_cast<int64_t>(ids->GetId(j));
    }
    return out;
  });
  mod.method("GetPointCoordinates", [](vtkPointSet* g, int64_t i) {
    std::array<double, 3> pt;
    g->GetPoint(static_cast<vtkIdType>(i), pt.data());
    return std::make_tuple(pt[0], pt[1], pt[2]);
  });

  // ---- implicit functions ----
  mod.method("Plane_new", []() { return vtkSmartPointer<vtkPlane>::New(); });
  mod.method("SetOrigin", [](vtkPlane* p, double x, double y, double z) {
    p->SetOrigin(x, y, z);
  });
  mod.method("SetNormal", [](vtkPlane* p, double x, double y, double z) {
    p->SetNormal(x, y, z);
  });

  // ---- generic algorithm plumbing ----
  // One generic SetInputData/GetOutput for every algorithm (readers,
  // writers, filters): no per-class plumbing needed. Outputs are owning
  // vtkDataObject smart pointers; downcast in the Julian layer.
  mod.method("Update", [](vtkAlgorithm* a) { a->Update(); });
  mod.method("SetInputData", [](vtkAlgorithm* a, vtkDataObject* d) {
    a->SetInputDataObject(0, d);
  });
  mod.method("GetOutput", [](vtkAlgorithm* a) {
    return take_ref(a->GetOutputDataObject(0));
  });

  // ---- XML readers ----
  mod.method("XMLUnstructuredGridReader_new", []() {
    return vtkSmartPointer<vtkXMLUnstructuredGridReader>::New();
  });
  mod.method("XMLPolyDataReader_new", []() { return vtkSmartPointer<vtkXMLPolyDataReader>::New(); });
  mod.method("SetFileName",
    [](vtkXMLUnstructuredGridReader* r, const std::string& name) {
      r->SetFileName(name.c_str());
    });
  mod.method("SetFileName",
    [](vtkXMLPolyDataReader* r, const std::string& name) {
      r->SetFileName(name.c_str());
    });
  mod.method("SetFileName",
    [](vtkXMLUnstructuredGridWriter* w, const std::string& name) {
      w->SetFileName(name.c_str());
    });
  mod.method("SetFileName",
    [](vtkXMLPolyDataWriter* w, const std::string& name) {
      w->SetFileName(name.c_str());
    });
  mod.method("SetFileName",
    [](vtkXMLImageDataWriter* w, const std::string& name) {
      w->SetFileName(name.c_str());
    });
  mod.method("SetFileName",
    [](vtkXMLRectilinearGridWriter* w, const std::string& name) {
      w->SetFileName(name.c_str());
    });
  mod.method("SetFileName",
    [](vtkXMLStructuredGridWriter* w, const std::string& name) {
      w->SetFileName(name.c_str());
    });

  // ---- CFD readers: EnSight Gold + CGNS ----
  mod.method("EnSightGoldReader_new", []() {
    return vtkSmartPointer<vtkEnSightGoldReader>::New();
  });
  mod.method("SetCaseFileName",
    [](vtkGenericEnSightReader* r, const std::string& name) {
      r->SetCaseFileName(name.c_str());
    });
  mod.method("CGNSReader_new", []() {
    return vtkSmartPointer<vtkCGNSReader>::New();
  });
  mod.method("SetFileName",
    [](vtkCGNSReader* r, const std::string& name) {
      r->SetFileName(name.c_str());
    });

  // ---- parallel XML readers ----
  mod.method("XMLPPolyDataReader_new", []() {
    return vtkSmartPointer<vtkXMLPPolyDataReader>::New();
  });

  // ---- legacy VTK I/O (.vtk format) ----
  mod.method("DataSetReader_new", []() {
    return vtkSmartPointer<vtkDataSetReader>::New();
  });
  mod.method("GenericDataObjectReader_new", []() {
    return vtkSmartPointer<vtkGenericDataObjectReader>::New();
  });
  mod.method("UnstructuredGridReader_new", []() {
    return vtkSmartPointer<vtkUnstructuredGridReader>::New();
  });
  mod.method("PolyDataReader_new", []() {
    return vtkSmartPointer<vtkPolyDataReader>::New();
  });
  mod.method("StructuredGridReader_new", []() {
    return vtkSmartPointer<vtkStructuredGridReader>::New();
  });
  mod.method("RectilinearGridReader_new", []() {
    return vtkSmartPointer<vtkRectilinearGridReader>::New();
  });
  mod.method("SetFileName",
    [](vtkDataReader* r, const std::string& name) {
      r->SetFileName(name.c_str());
    });
  mod.method("SetFileName",
    [](vtkDataWriter* w, const std::string& name) {
      w->SetFileName(name.c_str());
    });
  mod.method("DataSetWriter_new", []() {
    return vtkSmartPointer<vtkDataSetWriter>::New();
  });
  mod.method("GenericDataObjectWriter_new", []() {
    return vtkSmartPointer<vtkGenericDataObjectWriter>::New();
  });
  mod.method("UnstructuredGridWriter_new", []() {
    return vtkSmartPointer<vtkUnstructuredGridWriter>::New();
  });
  mod.method("PolyDataWriter_new", []() {
    return vtkSmartPointer<vtkPolyDataWriter>::New();
  });
  mod.method("StructuredGridWriter_new", []() {
    return vtkSmartPointer<vtkStructuredGridWriter>::New();
  });
  mod.method("RectilinearGridWriter_new", []() {
    return vtkSmartPointer<vtkRectilinearGridWriter>::New();
  });
  mod.method("Write", [](vtkDataWriter* w) { return w->Write(); });

  // ---- XML writers ----
  mod.method("XMLUnstructuredGridWriter_new", []() {
    return vtkSmartPointer<vtkXMLUnstructuredGridWriter>::New();
  });
  mod.method("XMLPolyDataWriter_new", []() { return vtkSmartPointer<vtkXMLPolyDataWriter>::New(); });
  mod.method("Write", [](vtkXMLUnstructuredGridWriter* w) { return w->Write(); });
  mod.method("Write", [](vtkXMLPolyDataWriter* w) { return w->Write(); });
  mod.method("Write", [](vtkXMLImageDataWriter* w) { return w->Write(); });
  mod.method("Write", [](vtkXMLRectilinearGridWriter* w) { return w->Write(); });
  mod.method("Write", [](vtkXMLStructuredGridWriter* w) { return w->Write(); });
  // zlib-compressed appended output (interoperable with ReadVTK.jl)
  mod.method("EnableCompression",
    [](vtkXMLUnstructuredGridWriter* w) { w->SetCompressorTypeToZLib(); });
  mod.method("SetRawAppendedData",
    [](vtkXMLUnstructuredGridWriter* w) { w->SetEncodeAppendedData(0); });
  mod.method("EnableCompression",
    [](vtkXMLPolyDataWriter* w) { w->SetCompressorTypeToZLib(); });
  mod.method("EnableCompression",
    [](vtkXMLImageDataWriter* w) { w->SetCompressorTypeToZLib(); });
  mod.method("EnableCompression",
    [](vtkXMLRectilinearGridWriter* w) { w->SetCompressorTypeToZLib(); });
  mod.method("EnableCompression",
    [](vtkXMLStructuredGridWriter* w) { w->SetCompressorTypeToZLib(); });
  mod.method("EnableCompression",
    [](vtkXMLMultiBlockDataWriter* w) { w->SetCompressorTypeToZLib(); });

  // ---- multiblock container ----
  mod.method("MultiBlockDataSet_new", []() {
    return vtkSmartPointer<vtkMultiBlockDataSet>::New();
  });
  // Blocks are borrowed views owned by the dataset; take_ref so Julia may
  // keep them while the parent stays alive.
  mod.method("GetNumberOfBlocks", [](vtkMultiBlockDataSet* m) {
    return static_cast<int64_t>(m->GetNumberOfBlocks());
  });
  // Named GetBlockByIndex (not GetBlock): WrapIt also generates GetBlock on
  // this class; CxxWrap would reject the double registration.
  mod.method("GetBlockByIndex", [](vtkMultiBlockDataSet* m, int64_t i) {
    return take_ref<vtkDataObject>(m->GetBlock(static_cast<unsigned int>(i)));
  });
  // Named SetBlockByIndex (not SetBlock): WrapIt also generates SetBlock on
  // this class; CxxWrap would reject the double registration.
  mod.method("SetBlockByIndex", [](vtkMultiBlockDataSet* m, int64_t i, vtkDataObject* b) {
    m->SetBlock(static_cast<unsigned int>(i), b);
  });
  // NOTE: SetNumberOfBlocks is generated by WrapIt (macro); not bound here.
  mod.method("XMLMultiBlockDataReader_new", []() {
    return vtkSmartPointer<vtkXMLMultiBlockDataReader>::New();
  });
  mod.method("SetFileName",
    [](vtkXMLMultiBlockDataReader* r, const std::string& name) {
      r->SetFileName(name.c_str());
    });
  mod.method("XMLMultiBlockDataWriter_new", []() {
    return vtkSmartPointer<vtkXMLMultiBlockDataWriter>::New();
  });
  mod.method("Write", [](vtkXMLMultiBlockDataWriter* w) { return w->Write(); });
  mod.method("SetFileName",
    [](vtkXMLMultiBlockDataWriter* w, const std::string& name) {
      w->SetFileName(name.c_str());
    });

  // ---- filters ----
  mod.method("TableBasedClipDataSet_new", []() {
    return vtkSmartPointer<vtkTableBasedClipDataSet>::New();
  });
  mod.method("SetClipFunction",
    [](vtkTableBasedClipDataSet* f, vtkImplicitFunction* fn) {
      f->SetClipFunction(fn);
    });
  mod.method("SetInsideOut", [](vtkTableBasedClipDataSet* f, bool b) {
    f->SetInsideOut(b);
  });

  mod.method("Cutter_new", []() { return vtkSmartPointer<vtkCutter>::New(); });
  mod.method("SetCutFunction", [](vtkCutter* f, vtkImplicitFunction* fn) {
    f->SetCutFunction(fn);
  });

  mod.method("CellDataToPointData_new", []() {
    return vtkSmartPointer<vtkCellDataToPointData>::New();
  });

  mod.method("PointDataToCellData_new", []() {
    return vtkSmartPointer<vtkPointDataToCellData>::New();
  });

  mod.method("ContourFilter_new", []() { return vtkSmartPointer<vtkContourFilter>::New(); });
  mod.method("SetContourValue", [](vtkContourFilter* f, int64_t i, double v) {
    f->SetValue(static_cast<int>(i), v);
  });

  mod.method("DataSetSurfaceFilter_new", []() {
    return vtkSmartPointer<vtkDataSetSurfaceFilter>::New();
  });

  // ---- downcasts (throws if the object has the wrong dynamic type) ----
  // One generic binding per registered grid type; the Julia side builds its
  // DOWNCAST_REGISTRY mechanically from `add_type<...>("vtkX")` in the
  // generated JlClasses.cxx, so adding a grid type needs no new C++ here.
  mod.method("downcast_unstructuredgrid", [](vtkDataObject* o) {
    return take_ref(vtkUnstructuredGrid::SafeDownCast(o));
  });
  mod.method("downcast_polydata", [](vtkDataObject* o) {
    return take_ref(vtkPolyData::SafeDownCast(o));
  });
  mod.method("downcast_imagedata", [](vtkDataObject* o) {
    return take_ref(vtkImageData::SafeDownCast(o));
  });
  mod.method("downcast_rectilineargrid", [](vtkDataObject* o) {
    return take_ref(vtkRectilinearGrid::SafeDownCast(o));
  });
  mod.method("downcast_structuredgrid", [](vtkDataObject* o) {
    return take_ref(vtkStructuredGrid::SafeDownCast(o));
  });
  mod.method("downcast_multiblock", [](vtkDataObject* o) {
    return take_ref(vtkMultiBlockDataSet::SafeDownCast(o));
  });
  // Dynamic class name, e.g. "vtkPolyData" — drives the generic downcast
  // in the Julian layer.
  mod.method("GetClassName", [](vtkObjectBase* o) -> std::string {
    const char* name = o->GetClassName();
    return name == nullptr ? std::string() : std::string(name);
  });
}
