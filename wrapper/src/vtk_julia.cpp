// VTK.jl — CxxWrap binding module for a CFD-oriented subset of VTK.
//
// Phase 0 scope: vtkDataArray family (with zero-copy access), core data model
// (unstructured grid / polydata / image data), XML I/O, and the basic
// manipulation filters (clip, cut, c2p/p2c, contour, surface extraction).
//
// Ownership model: factories and outputs return vtkSmartPointer<T>, registered
// with CxxWrap as a smart pointer, so Julia finalizers release references
// correctly. Borrowed raw pointers (e.g. field data access) are never owned by
// Julia; keep the parent dataset alive.

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
#include <vtkPointSet.h>
#include <vtkUnstructuredGrid.h>
#include <vtkPolyData.h>
#include <vtkImageData.h>
#include <vtkAlgorithm.h>
#include <vtkImplicitFunction.h>
#include <vtkPlane.h>
#include <vtkXMLUnstructuredGridReader.h>
#include <vtkXMLUnstructuredGridWriter.h>
#include <vtkXMLPolyDataReader.h>
#include <vtkXMLPolyDataWriter.h>
#include <vtkTableBasedClipDataSet.h>
#include <vtkCutter.h>
#include <vtkCellDataToPointData.h>
#include <vtkPointDataToCellData.h>
#include <vtkContourFilter.h>
#include <vtkDataSetSurfaceFilter.h>
#include <vtkArrayDispatch.h>

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

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

template <>
struct SuperType<vtkObject> { typedef vtkObjectBase type; };
template <>
struct SuperType<vtkDataObject> { typedef vtkObject type; };
template <>
struct SuperType<vtkDataSet> { typedef vtkDataObject type; };
template <>
struct SuperType<vtkPointSet> { typedef vtkDataSet type; };
template <>
struct SuperType<vtkUnstructuredGrid> { typedef vtkPointSet type; };
template <>
struct SuperType<vtkPolyData> { typedef vtkPointSet type; };
template <>
struct SuperType<vtkImageData> { typedef vtkDataSet type; };
template <>
struct SuperType<vtkAbstractArray> { typedef vtkObject type; };
template <>
struct SuperType<vtkDataArray> { typedef vtkAbstractArray type; };
template <>
struct SuperType<vtkFloatArray> { typedef vtkDataArray type; };
template <>
struct SuperType<vtkDoubleArray> { typedef vtkDataArray type; };
template <>
struct SuperType<vtkIntArray> { typedef vtkDataArray type; };
template <>
struct SuperType<vtkFieldData> { typedef vtkObject type; };
template <>
struct SuperType<vtkPointData> { typedef vtkFieldData type; };
template <>
struct SuperType<vtkCellData> { typedef vtkFieldData type; };
template <>
struct SuperType<vtkPoints> { typedef vtkObject type; };
template <>
struct SuperType<vtkAlgorithm> { typedef vtkObject type; };
template <>
struct SuperType<vtkImplicitFunction> { typedef vtkObject type; };
template <>
struct SuperType<vtkPlane> { typedef vtkImplicitFunction type; };
template <>
struct SuperType<vtkXMLUnstructuredGridReader> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkXMLUnstructuredGridWriter> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkXMLPolyDataReader> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkXMLPolyDataWriter> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkTableBasedClipDataSet> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkCutter> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkCellDataToPointData> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkPointDataToCellData> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkContourFilter> { typedef vtkAlgorithm type; };
template <>
struct SuperType<vtkDataSetSurfaceFilter> { typedef vtkAlgorithm type; };
} // namespace jlcxx

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


// Zero-copy view of an AOS vtkDataArray as a flat Julia vector.
// The flat layout is component-fastest (ncomponents * ntuples), which is
// exactly column-major for an (ncomponents, ntuples) matrix.
struct ZeroCopyDataWorker
{
  template <typename ArrayT>
  void operator()(ArrayT* arr, jl_value_t*& out)
  {
    using V = std::remove_const_t<typename ArrayT::ValueType>;
    const jlcxx::cxxint_t n =
      static_cast<jlcxx::cxxint_t>(arr->GetNumberOfComponents() * arr->GetNumberOfTuples());
    V* ptr = static_cast<V*>(arr->GetVoidPointer(0));
    out = reinterpret_cast<jl_value_t*>(jlcxx::make_julia_array(ptr, n).wrapped());
  }
};

jl_value_t* zero_copy_data(vtkDataArray* da)
{
  if (da->GetNumberOfTuples() == 0)
  {
    throw std::runtime_error("zero_copy_data: empty array");
  }
  if (da->GetArrayType() != vtkArrayTypes::VTK_AOS_DATA_ARRAY)
  {
    throw std::runtime_error("zero_copy_data: array is not AOS (use component API)");
  }
  jl_value_t* out = nullptr;
  if (!vtkArrayDispatch::Dispatch::Execute(da, ZeroCopyDataWorker{}, out))
  {
    throw std::runtime_error("zero_copy_data: array type not supported by dispatch");
  }
  return out;
}

} // namespace

JLCXX_MODULE define_julia_module(jlcxx::Module& mod)
{
  using namespace jlcxx;

  // ---- type hierarchy (true VTK inheritance, used for smart-pointer casts) ----
  mod.add_type<vtkObjectBase>("vtkObjectBase");
  mod.add_type<vtkObject>("vtkObject", julia_base_type<vtkObjectBase>());
  mod.add_type<vtkDataObject>("vtkDataObject", julia_base_type<vtkObject>());
  mod.add_type<vtkDataSet>("vtkDataSet", julia_base_type<vtkDataObject>());
  mod.add_type<vtkPointSet>("vtkPointSet", julia_base_type<vtkDataSet>());
  mod.add_type<vtkUnstructuredGrid>("vtkUnstructuredGrid", julia_base_type<vtkPointSet>());
  mod.add_type<vtkPolyData>("vtkPolyData", julia_base_type<vtkPointSet>());
  mod.add_type<vtkImageData>("vtkImageData", julia_base_type<vtkDataSet>());
  mod.add_type<vtkAbstractArray>("vtkAbstractArray", julia_base_type<vtkObject>());
  mod.add_type<vtkDataArray>("vtkDataArray", julia_base_type<vtkAbstractArray>());
  // Concrete array types: their real superclass is vtkAOSDataArrayTemplate<T>,
  // which derives from vtkDataArray, so registering them under vtkDataArray
  // is a valid up-cast (this mirrors VTK's __VTK_WRAP__ fake-superclass trick).
  mod.add_type<vtkFloatArray>("vtkFloatArray", julia_base_type<vtkDataArray>());
  mod.add_type<vtkDoubleArray>("vtkDoubleArray", julia_base_type<vtkDataArray>());
  mod.add_type<vtkIntArray>("vtkIntArray", julia_base_type<vtkDataArray>());
  mod.add_type<vtkFieldData>("vtkFieldData", julia_base_type<vtkObject>());
  mod.add_type<vtkPointData>("vtkPointData", julia_base_type<vtkFieldData>());
  mod.add_type<vtkCellData>("vtkCellData", julia_base_type<vtkFieldData>());
  mod.add_type<vtkPoints>("vtkPoints", julia_base_type<vtkObject>());
  mod.add_type<vtkAlgorithm>("vtkAlgorithm", julia_base_type<vtkObject>());
  mod.add_type<vtkImplicitFunction>("vtkImplicitFunction", julia_base_type<vtkObject>());
  mod.add_type<vtkPlane>("vtkPlane", julia_base_type<vtkImplicitFunction>());
  mod.add_type<vtkXMLUnstructuredGridReader>("vtkXMLUnstructuredGridReader",
    julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkXMLUnstructuredGridWriter>("vtkXMLUnstructuredGridWriter",
    julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkXMLPolyDataReader>("vtkXMLPolyDataReader", julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkXMLPolyDataWriter>("vtkXMLPolyDataWriter", julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkTableBasedClipDataSet>("vtkTableBasedClipDataSet", julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkCutter>("vtkCutter", julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkCellDataToPointData>("vtkCellDataToPointData", julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkPointDataToCellData>("vtkPointDataToCellData", julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkContourFilter>("vtkContourFilter", julia_base_type<vtkAlgorithm>());
  mod.add_type<vtkDataSetSurfaceFilter>("vtkDataSetSurfaceFilter", julia_base_type<vtkAlgorithm>());

  // ---- smart pointer: the owning handle type for all factories/outputs ----
  // Registers the parametric type; concrete instantiations
  // (vtkSmartPointer{T}) are created lazily on first use.
  jlcxx::add_smart_pointer<vtkSmartPointer>(mod, "vtkSmartPointer");

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
  mod.method("Update", [](vtkAlgorithm* a) { a->Update(); });

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
  mod.method("GetOutput", [](vtkXMLUnstructuredGridReader* r) {
    return take_ref(r->GetOutput());
  });
  mod.method("GetOutput", [](vtkXMLPolyDataReader* r) {
    return take_ref(r->GetOutput());
  });

  // ---- XML writers ----
  mod.method("XMLUnstructuredGridWriter_new", []() {
    return vtkSmartPointer<vtkXMLUnstructuredGridWriter>::New();
  });
  mod.method("XMLPolyDataWriter_new", []() { return vtkSmartPointer<vtkXMLPolyDataWriter>::New(); });
  mod.method("SetInputData",
    [](vtkXMLUnstructuredGridWriter* w, vtkUnstructuredGrid* d) {
      w->SetInputData(d);
    });
  mod.method("SetInputData",
    [](vtkXMLPolyDataWriter* w, vtkPolyData* d) {
      w->SetInputData(d);
    });
  mod.method("Write", [](vtkXMLUnstructuredGridWriter* w) { return w->Write(); });
  mod.method("Write", [](vtkXMLPolyDataWriter* w) { return w->Write(); });
  // zlib-compressed appended output (interoperable with ReadVTK.jl)
  mod.method("EnableCompression",
    [](vtkXMLUnstructuredGridWriter* w) { w->SetCompressorTypeToZLib(); });
  mod.method("SetRawAppendedData",
    [](vtkXMLUnstructuredGridWriter* w) { w->SetEncodeAppendedData(0); });
  mod.method("EnableCompression",
    [](vtkXMLPolyDataWriter* w) { w->SetCompressorTypeToZLib(); });

  // ---- filters ----
  mod.method("TableBasedClipDataSet_new", []() {
    return vtkSmartPointer<vtkTableBasedClipDataSet>::New();
  });
  mod.method("SetInputData",
    [](vtkTableBasedClipDataSet* f, vtkDataSet* d) {
      f->SetInputData(d);
    });
  mod.method("SetClipFunction",
    [](vtkTableBasedClipDataSet* f, vtkImplicitFunction* fn) {
      f->SetClipFunction(fn);
    });
  mod.method("SetInsideOut", [](vtkTableBasedClipDataSet* f, bool b) {
    f->SetInsideOut(b);
  });
  mod.method("GetOutput", [](vtkTableBasedClipDataSet* f) {
    return take_ref(f->GetOutput());
  });

  mod.method("Cutter_new", []() { return vtkSmartPointer<vtkCutter>::New(); });
  mod.method("SetInputData", [](vtkCutter* f, vtkDataSet* d) {
    f->SetInputData(d);
  });
  mod.method("SetCutFunction", [](vtkCutter* f, vtkImplicitFunction* fn) {
    f->SetCutFunction(fn);
  });
  mod.method("GetOutput", [](vtkCutter* f) { return take_ref(f->GetOutput()); });

  mod.method("CellDataToPointData_new", []() {
    return vtkSmartPointer<vtkCellDataToPointData>::New();
  });
  mod.method("SetInputData",
    [](vtkCellDataToPointData* f, vtkDataSet* d) {
      f->SetInputData(d);
    });
  mod.method("GetOutput", [](vtkCellDataToPointData* f) {
    return take_ref<vtkDataSet>(f->GetOutput());
  });

  mod.method("PointDataToCellData_new", []() {
    return vtkSmartPointer<vtkPointDataToCellData>::New();
  });
  mod.method("SetInputData",
    [](vtkPointDataToCellData* f, vtkDataSet* d) {
      f->SetInputData(d);
    });
  mod.method("GetOutput", [](vtkPointDataToCellData* f) {
    return take_ref<vtkDataSet>(f->GetOutput());
  });

  mod.method("ContourFilter_new", []() { return vtkSmartPointer<vtkContourFilter>::New(); });
  mod.method("SetInputData", [](vtkContourFilter* f, vtkDataSet* d) {
    f->SetInputData(d);
  });
  mod.method("SetContourValue", [](vtkContourFilter* f, int64_t i, double v) {
    f->SetValue(static_cast<int>(i), v);
  });
  mod.method("GetOutput", [](vtkContourFilter* f) { return take_ref(f->GetOutput()); });

  mod.method("DataSetSurfaceFilter_new", []() {
    return vtkSmartPointer<vtkDataSetSurfaceFilter>::New();
  });
  mod.method("SetInputData",
    [](vtkDataSetSurfaceFilter* f, vtkDataSet* d) {
      f->SetInputData(d);
    });
  mod.method("GetOutput", [](vtkDataSetSurfaceFilter* f) {
    return take_ref(f->GetOutput());
  });

  // ---- downcasts (throws if the object has the wrong dynamic type) ----
  mod.method("downcast_unstructuredgrid", [](vtkDataObject* o) {
    return take_ref(vtkUnstructuredGrid::SafeDownCast(o));
  });
  mod.method("downcast_polydata", [](vtkDataObject* o) {
    return take_ref(vtkPolyData::SafeDownCast(o));
  });
  mod.method("downcast_imagedata", [](vtkDataObject* o) {
    return take_ref(vtkImageData::SafeDownCast(o));
  });
}
