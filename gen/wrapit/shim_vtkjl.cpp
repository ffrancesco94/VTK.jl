// shim_vtkjl.cpp — hand-written companion merged INTO the WrapIt-generated
// module (single library, single JLCXX_MODULE). Provides everything a
// generator cannot express for VTK:
//   * ownership (factories/outputs return owning vtkSmartPointer; getters
//     are take_ref'd; zero-copy views via vtkArrayDispatch),
//   * per-operation diagnostic capture through vtkCommand observers,
//   * macro-generated and convenience accessors (SetFileName, SetInsideOut,
//     SetInputData, EnableCompression, ...),
//   * downcasts and the typed-array factory.
// Type registrations and plain method bindings come from WrapIt.

#include <array>
#include <cstdint>
#include <jlcxx/jlcxx.hpp>
#include <jlcxx/smart_pointers.hpp>
#include <jlcxx/stl.hpp>
#include <mutex>
#include <stdexcept>
#include <string>
#include <tuple>
#include <utility>
#include <vector>
#include <vtkAbstractArray.h>
#include <vtkAlgorithm.h>
#include <vtkArrayDispatch.h>
#include <vtkCGNSReader.h>
#include <vtkCellData.h>
#include <vtkCellDataToPointData.h>
#include <vtkCommand.h>
#include <vtkContourFilter.h>
#include <vtkCutter.h>
#include <vtkDataArray.h>
#include <vtkDataObject.h>
#include <vtkDataReader.h>
#include <vtkDataSet.h>
#include <vtkDataSetReader.h>
#include <vtkDataSetSurfaceFilter.h>
#include <vtkDataSetWriter.h>
#include <vtkDataWriter.h>
#include <vtkDoubleArray.h>
#include <vtkEnSightGoldReader.h>
#include <vtkEnSightReader.h>
#include <vtkFieldData.h>
#include <vtkFloatArray.h>
#include <vtkGenericDataObjectReader.h>
#include <vtkGenericDataObjectWriter.h>
#include <vtkGenericEnSightReader.h>
#include <vtkIdList.h>
#include <vtkImageData.h>
#include <vtkImplicitFunction.h>
#include <vtkInformation.h>
#include <vtkIntArray.h>
#include <vtkMultiBlockDataSet.h>
#include <vtkMultiBlockDataSetAlgorithm.h>
#include <vtkObject.h>
#include <vtkObjectBase.h>
#include <vtkObjectFactory.h>
#include <vtkPlane.h>
#include <vtkPointData.h>
#include <vtkPointDataToCellData.h>
#include <vtkPointSet.h>
#include <vtkPoints.h>
#include <vtkPolyData.h>
#include <vtkPolyDataReader.h>
#include <vtkPolyDataWriter.h>
#include <vtkRectilinearGrid.h>
#include <vtkRectilinearGridReader.h>
#include <vtkRectilinearGridWriter.h>
#include <vtkSmartPointer.h>
#include <vtkStreamingDemandDrivenPipeline.h>
#include <vtkStringArray.h>
#include <vtkStructuredGrid.h>
#include <vtkStructuredGridReader.h>
#include <vtkStructuredGridWriter.h>
#include <vtkTableBasedClipDataSet.h>
#include <vtkUnstructuredGrid.h>
#include <vtkUnstructuredGridReader.h>
#include <vtkUnstructuredGridWriter.h>
#include <vtkWriter.h>
#include <vtkXMLImageDataReader.h>
#include <vtkXMLImageDataWriter.h>
#include <vtkXMLWriterBase.h>
#include <vtkXMLMultiBlockDataReader.h>
#include <vtkXMLMultiBlockDataWriter.h>
#include <vtkXMLPDataObjectReader.h>
#include <vtkXMLPDataReader.h>
#include <vtkXMLPPolyDataReader.h>
#include <vtkXMLPUnstructuredDataReader.h>
#include <vtkXMLPolyDataReader.h>
#include <vtkXMLPolyDataWriter.h>
#include <vtkXMLRectilinearGridReader.h>
#include <vtkXMLRectilinearGridWriter.h>
#include <vtkXMLStructuredGridReader.h>
#include <vtkXMLStructuredGridWriter.h>
#include <vtkXMLUnstructuredGridReader.h>
#include <vtkXMLUnstructuredGridWriter.h>
#include <vtkMatrix3x3.h>

#include "shim_vtkjl.h"

namespace {

struct PendingVTKSmartPointerDeletion {
  void *Pointer;
  void (*Deleter)(void *);
};

std::mutex DeferredDeletionMutex;
std::vector<PendingVTKSmartPointerDeletion> DeferredDeletions;

uint64_t drain_deferred_deletions() {
  std::vector<PendingVTKSmartPointerDeletion> pending;
  {
    std::lock_guard<std::mutex> lock(DeferredDeletionMutex);
    pending.swap(DeferredDeletions);
  }
  for (const auto &entry : pending) {
    entry.Deleter(entry.Pointer);
  }
  return static_cast<uint64_t>(pending.size());
}

uint64_t deferred_deletion_count() {
  std::lock_guard<std::mutex> lock(DeferredDeletionMutex);
  return static_cast<uint64_t>(DeferredDeletions.size());
}

// Diagnostic severity values are mirrored by _VTK_SEVERITIES in
// src/diagnostics.jl. Keep errors at zero so a failed Update can be detected
// without inspecting message contents.
enum ScopedDiagnosticSeverity {
  ScopedDiagnosticError = 0,
  ScopedDiagnosticWarning = 1,
  ScopedDiagnosticText = 2,
  ScopedDiagnosticDebug = 3,
};

// VTK (including 9.7) has Error/Warning/Text events but no DebugEvent. Give
// the deterministic debug channel a private event id rather than mislabeling
// debug messages as text.
constexpr unsigned long ScopedDebugEvent = vtkCommand::UserEvent + 0x56444A;

struct ScopedDiagnostic {
  int severity;
  std::string message;
};

using ScopedDiagnosticResult =
    std::tuple<int, std::vector<int>, std::vector<std::string>>;

// A collector belongs to exactly one scoped operation. VTK may invoke events
// from worker threads, so each collector protects its own records; there is no
// process-global diagnostic state or lock.
class vtkJuliaDiagnosticCollector : public vtkCommand {
public:
  static vtkJuliaDiagnosticCollector *New();

  vtkJuliaDiagnosticCollector() { this->PassiveObserverOn(); }

  void Execute(vtkObject *, unsigned long eventId, void *callData) override {
    int severity;
    switch (eventId) {
    case vtkCommand::ErrorEvent:
      severity = ScopedDiagnosticError;
      break;
    case vtkCommand::WarningEvent:
      severity = ScopedDiagnosticWarning;
      break;
    case vtkCommand::TextEvent:
      severity = ScopedDiagnosticText;
      break;
    case ScopedDebugEvent:
      severity = ScopedDiagnosticDebug;
      break;
    default:
      return;
    }

    const char *text = static_cast<const char *>(callData);
    std::lock_guard<std::mutex> lock(this->Mutex);
    this->Diagnostics.push_back(
        {severity, text == nullptr ? std::string() : std::string(text)});
  }

  std::vector<ScopedDiagnostic> Snapshot() const {
    std::lock_guard<std::mutex> lock(this->Mutex);
    return this->Diagnostics;
  }

private:
  mutable std::mutex Mutex;
  std::vector<ScopedDiagnostic> Diagnostics;
};

vtkStandardNewMacro(vtkJuliaDiagnosticCollector);

// Attach for the lifetime of one native call and remove every observer on all
// exits. Tag-based removal leaves independent/nested observers untouched.
class ScopedDiagnosticCapture {
public:
  explicit ScopedDiagnosticCapture(vtkAlgorithm *algorithm)
      : Algorithm(algorithm) {
    if (algorithm == nullptr) {
      throw std::runtime_error("Scoped diagnostics: null algorithm");
    }
    this->Collector = vtkSmartPointer<vtkJuliaDiagnosticCollector>::New();
    try {
      this->Tags[0] = algorithm->AddObserver(vtkCommand::ErrorEvent,
                                             this->Collector);
      this->Tags[1] = algorithm->AddObserver(vtkCommand::WarningEvent,
                                             this->Collector);
      this->Tags[2] = algorithm->AddObserver(vtkCommand::TextEvent,
                                             this->Collector);
      this->Tags[3] = algorithm->AddObserver(ScopedDebugEvent,
                                             this->Collector);
    } catch (...) {
      this->RemoveObservers();
      throw;
    }
  }

  ~ScopedDiagnosticCapture() { this->RemoveObservers(); }

  ScopedDiagnosticCapture(const ScopedDiagnosticCapture &) = delete;
  ScopedDiagnosticCapture &
  operator=(const ScopedDiagnosticCapture &) = delete;

  bool HasError() const {
    const auto records = this->Collector->Snapshot();
    for (const auto &record : records) {
      if (record.severity == ScopedDiagnosticError) {
        return true;
      }
    }
    return false;
  }

  ScopedDiagnosticResult Result(int status) const {
    const auto records = this->Collector->Snapshot();
    std::vector<int> severities;
    std::vector<std::string> messages;
    severities.reserve(records.size());
    messages.reserve(records.size());
    for (const auto &record : records) {
      severities.push_back(record.severity);
      messages.push_back(record.message);
    }
    return std::make_tuple(status, std::move(severities), std::move(messages));
  }

private:
  void RemoveObservers() noexcept {
    if (this->Algorithm != nullptr) {
      for (const unsigned long tag : this->Tags) {
        if (tag != 0) {
          this->Algorithm->RemoveObserver(tag);
        }
      }
    }
    this->Tags = {{0, 0, 0, 0}};
  }

  vtkAlgorithm *Algorithm = nullptr;
  vtkSmartPointer<vtkJuliaDiagnosticCollector> Collector;
  std::array<unsigned long, 4> Tags = {{0, 0, 0, 0}};
};

unsigned long diagnostic_event(std::string severity) {
  if (!severity.empty() && severity.front() == ':') {
    severity.erase(severity.begin());
  }
  if (severity == "error") {
    return vtkCommand::ErrorEvent;
  }
  if (severity == "warning") {
    return vtkCommand::WarningEvent;
  }
  if (severity == "text") {
    return vtkCommand::TextEvent;
  }
  if (severity == "debug") {
    return ScopedDebugEvent;
  }
  throw std::invalid_argument(
      "EmitDiagnostic: severity must be error, warning, text, or debug");
}

int write_algorithm(vtkAlgorithm *algorithm) {
  if (auto *writer = dynamic_cast<vtkXMLWriterBase *>(algorithm)) {
    return writer->Write();
  }
  if (auto *writer = dynamic_cast<vtkWriter *>(algorithm)) {
    return writer->Write();
  }
  throw std::runtime_error("ScopedWrite: algorithm does not support Write");
}

// Borrow a raw VTK pointer into a smart pointer without upsetting the
// reference count: Register first, then Take (Take does not Register).
template <typename T> vtkSmartPointer<T> take_ref(T *raw) {
  if (raw == nullptr) {
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
struct ZeroCopyDataWorker {
  template <typename ArrayT> void operator()(ArrayT *arr, jl_value_t *&out) {
    using V = std::remove_const_t<typename ArrayT::ValueType>;
    const jlcxx::cxxint_t n = static_cast<jlcxx::cxxint_t>(
        arr->GetNumberOfComponents() * arr->GetNumberOfTuples());
    V *ptr = static_cast<V *>(arr->GetVoidPointer(0));
    // Ensure the Julia Array{V,1} wrapper type exists (no-op if registered).
    jlcxx::create_if_not_exists<jlcxx::ArrayRef<V, 1>>();
    out = reinterpret_cast<jl_value_t *>(
        jlcxx::make_julia_array(ptr, n).wrapped());
  }
};

struct ZeroCopyMatrixWorker {
  template <typename ArrayT> void operator()(ArrayT *arr, jl_value_t *&out) {
    using V = std::remove_const_t<typename ArrayT::ValueType>;
    const jlcxx::cxxint_t ncomp =
        static_cast<jlcxx::cxxint_t>(arr->GetNumberOfComponents());
    const jlcxx::cxxint_t nt =
        static_cast<jlcxx::cxxint_t>(arr->GetNumberOfTuples());
    V *ptr = static_cast<V *>(arr->GetVoidPointer(0));
    // CxxWrap pre-registers Array{V,1} for numbers but not higher
    // dimensions; create the Array{V,2} wrapper type before use.
    jlcxx::create_if_not_exists<jlcxx::ArrayRef<V, 2>>();
    out = reinterpret_cast<jl_value_t *>(
        jlcxx::make_julia_array(ptr, ncomp, nt).wrapped());
  }
};

template <typename WorkerT>
jl_value_t *zero_copy_impl(vtkDataArray *da, WorkerT worker) {
  if (da->GetNumberOfTuples() == 0) {
    throw std::runtime_error("zero_copy: empty array");
  }
  if (da->GetArrayType() != vtkArrayTypes::VTK_AOS_DATA_ARRAY) {
    throw std::runtime_error("zero_copy: array is not AOS (use component API)");
  }
  jl_value_t *out = nullptr;
  if (!vtkArrayDispatch::Dispatch::Execute(da, worker, out)) {
    throw std::runtime_error("zero_copy: array type not supported by dispatch");
  }
  return out;
}

jl_value_t *zero_copy_data(vtkDataArray *da) {
  return zero_copy_impl(da, ZeroCopyDataWorker{});
}

jl_value_t *zero_copy_matrix(vtkDataArray *da) {
  return zero_copy_impl(da, ZeroCopyMatrixWorker{});
}

// Concrete unregistered subclass used to verify hierarchy-aware downcasting.
class vtkJuliaDerivedPolyData : public vtkPolyData {
public:
  static vtkJuliaDerivedPolyData *New();
  vtkTypeMacro(vtkJuliaDerivedPolyData, vtkPolyData);
};
vtkStandardNewMacro(vtkJuliaDerivedPolyData);

} // namespace

namespace jlcxx {
void defer_vtk_smart_pointer_deletion(void *pointer,
                                      void (*deleter)(void *)) {
  if (pointer == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(DeferredDeletionMutex);
  DeferredDeletions.push_back({pointer, deleter});
}
} // namespace jlcxx

// Force-register the smart-pointer methods (dereference, casts) for a

void register_shim_methods(jlcxx::Module &mod) {
  using namespace jlcxx;

  // ---- type hierarchy (true VTK inheritance, used for smart-pointer casts)
  // ---- Concrete array types: their real superclass is
  // vtkAOSDataArrayTemplate<T>, which derives from vtkDataArray, so registering
  // them under vtkDataArray is a valid up-cast (this mirrors VTK's __VTK_WRAP__
  // fake-superclass trick).

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
  mod.method("upcast_dataarray", [](const vtkSmartPointer<vtkDoubleArray> &p) {
    return vtkSmartPointer<vtkDataArray>(p);
  });
  mod.method("upcast_dataarray", [](const vtkSmartPointer<vtkFloatArray> &p) {
    return vtkSmartPointer<vtkDataArray>(p);
  });
  mod.method("upcast_dataarray", [](const vtkSmartPointer<vtkIntArray> &p) {
    return vtkSmartPointer<vtkDataArray>(p);
  });
  mod.method("DrainVTKDeletions", []() { return drain_deferred_deletions(); });
  mod.method("PendingVTKDeletionCount",
             []() { return deferred_deletion_count(); });

  // ---- scoped diagnostic capture ----
  // The raw Update/Write bindings below intentionally remain unchanged.
  mod.method("ScopedUpdate", [](vtkAlgorithm *a) {
    ScopedDiagnosticCapture capture(a);
    // Update historically returns void (and some VTK versions now return a
    // status). The scoped API uses a uniform sentinel: any captured error is
    // failure, otherwise the operation completed successfully.
    a->Update();
    return capture.Result(capture.HasError() ? 0 : 1);
  });
  mod.method("ScopedUpdateInformation", [](vtkAlgorithm *a) {
    ScopedDiagnosticCapture capture(a);
    const int status = a->UpdateInformation() ? 1 : 0;
    return capture.Result(status);
  });
  mod.method("ScopedUpdateTimeStep", [](vtkAlgorithm *a, double time) {
    ScopedDiagnosticCapture capture(a);
    const int status = a->UpdateTimeStep(time);
    return capture.Result(status);
  });
  mod.method("ScopedWrite", [](vtkAlgorithm *a) {
    ScopedDiagnosticCapture capture(a);
    const int status = write_algorithm(a);
    return capture.Result(status);
  });
  // Deterministic event source for tests. The std::string payload stays alive
  // until InvokeEvent has returned, including all synchronous observers.
  mod.method("EmitDiagnostic", [](vtkAlgorithm *a, const std::string &severity,
                                  const std::string &message) {
    if (a == nullptr) {
      throw std::runtime_error("EmitDiagnostic: null algorithm");
    }
    std::string payload(message);
    a->InvokeEvent(diagnostic_event(severity), payload.data());
  });
  mod.method("EmitScopedDiagnosticForTesting",
             [](vtkAlgorithm *a, const std::string &severity,
                const std::string &message) {
               ScopedDiagnosticCapture capture(a);
               std::string payload(message);
               a->InvokeEvent(diagnostic_event(severity), payload.data());
               return capture.Result(capture.HasError() ? 0 : 1);
             });

  // ---- vtkDataArray ----
  // All parameters take vtkSmartPointer by value so that Julia's smart-pointer
  // conversion machinery (including up-casts) applies at call sites.
  mod.method("GetNumberOfTuples", [](vtkDataArray *a) {
    return static_cast<int64_t>(a->GetNumberOfTuples());
  });
  mod.method("GetNumberOfComponents",
             [](vtkDataArray *a) { return a->GetNumberOfComponents(); });
  mod.method("GetComponent", [](vtkDataArray *a, int64_t i, int c) {
    return a->GetComponent(static_cast<vtkIdType>(i), c);
  });
  mod.method("SetComponent", [](vtkDataArray *a, int64_t i, int c, double v) {
    a->SetComponent(static_cast<vtkIdType>(i), c, v);
  });
  mod.method("SetNumberOfTuples", [](vtkDataArray *a, int64_t n) {
    a->SetNumberOfTuples(static_cast<vtkIdType>(n));
  });
  mod.method("SetArrayName", [](vtkDataArray *a, const std::string &name) {
    a->SetName(name.c_str());
  });
  mod.method("GetArrayName", [](vtkDataArray *a) -> std::string {
    const char *name = a->GetName();
    return name == nullptr ? std::string() : std::string(name);
  });
  mod.method("zero_copy_data",
             [](vtkDataArray *a) { return zero_copy_data(a); });
  mod.method("zero_copy_matrix",
             [](vtkDataArray *a) { return zero_copy_matrix(a); });

  mod.method("GetArrayRangeValues", [](vtkDataArray *array, int64_t component, bool finite) {
          std::vector<double> values(2);
          if (finite) {
            array->GetFiniteRange(values.data(), static_cast<int>(component));
          } else {
            array->GetRange(values.data(), static_cast<int>(component));
          }
          return values;
          });

  // Deep copy stuff
  mod.method("TakeRefDataObject", [](vtkDataObject *object) {
    if (object == nullptr) {
      throw std::runtime_error("TakeRefDataObject: null pointer");
    }
    return take_ref<vtkDataObject>(object);
  });
  mod.method("DeepCopyDataObject", [](vtkDataObject *source) {
    auto destination = take_ref(source->NewInstance());
    destination->DeepCopy(source);
    return destination;
  });
  mod.method("GenericDataObjectForTesting", []() {
    return vtkSmartPointer<vtkDataObject>::New();
  });
  mod.method("DerivedPolyDataForTesting", []() {
    auto object = vtkSmartPointer<vtkJuliaDerivedPolyData>::New();
    return vtkSmartPointer<vtkDataObject>(object);
  });
  mod.method("NullDataObjectForTesting", []() -> vtkDataObject * {
    return nullptr;
  });

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
  mod.method("SetNumberOfPoints", [](vtkPoints *p, int64_t n) {
    p->SetNumberOfPoints(static_cast<vtkIdType>(n));
  });
  mod.method("SetPoint",
             [](vtkPoints *p, int64_t i, double x, double y, double z) {
               p->SetPoint(static_cast<vtkIdType>(i), x, y, z);
             });
  mod.method("GetPoint", [](vtkPoints *p, int64_t i) {
    std::array<double, 3> pt;
    p->GetPoint(static_cast<vtkIdType>(i), pt.data());
    return std::make_tuple(pt[0], pt[1], pt[2]);
  });
  mod.method("GetPointData",
             [](vtkPoints *p) { return take_ref<vtkDataArray>(p->GetData()); });

  // ---- field data ----
  mod.method("GetPointData", [](vtkDataSet *d) {
    return take_ref<vtkPointData>(d->GetPointData());
  });
  mod.method("GetCellData", [](vtkDataSet *d) {
    return take_ref<vtkCellData>(d->GetCellData());
  });
  mod.method("GetNumberOfArrays",
             [](vtkFieldData *f) { return f->GetNumberOfArrays(); });
  mod.method("GetArrayNameOf", [](vtkFieldData *f, int i) -> std::string {
    const char *name = f->GetArrayName(i);
    return name == nullptr ? std::string() : std::string(name);
  });
  mod.method("GetArray", [](vtkFieldData *f, const std::string &name) {
    return take_ref<vtkDataArray>(
        vtkDataArray::SafeDownCast(f->GetAbstractArray(name.c_str())));
  });
  mod.method("HasArray", [](vtkFieldData *f, const std::string &name) {
    return f->GetAbstractArray(name.c_str()) != nullptr;
  });
  mod.method("AddStringArrayForTesting", [](vtkFieldData *f,
                                             const std::string &name) {
    vtkNew<vtkStringArray> array;
    array->SetName(name.c_str());
    array->InsertNextValue("nonnumeric");
    f->AddArray(array);
  });
  mod.method("GetFieldDataOwned", [](vtkDataObject *object) {
          return take_ref<vtkFieldData>(object->GetFieldData());
  });
  // Generic typed array factory over the VTK scalar type ids (see vtkType.h).
  mod.method("CreateDataArray", [](int dataType, int64_t ncomp) {
    vtkAbstractArray *raw = vtkAbstractArray::CreateArray(dataType);
    auto *da = vtkDataArray::SafeDownCast(raw);
    if (da == nullptr) {
      if (raw != nullptr) {
        raw->Delete();
      }
      throw std::runtime_error("CreateDataArray: unsupported data type id");
    }
    da->SetNumberOfComponents(static_cast<int>(ncomp));
    return take_ref(da);
  });
  mod.method("GetDataType",
             [](vtkAbstractArray *a) { return a->GetDataType(); });
  mod.method("AddArray",
             [](vtkFieldData *f, vtkDataArray *a) { return f->AddArray(a); });
  mod.method("SetActiveScalars", [](vtkPointData *f, const std::string &name) {
    return f->SetActiveScalars(name.c_str());
  });
  mod.method("SetActiveScalars", [](vtkCellData *f, const std::string &name) {
    return f->SetActiveScalars(name.c_str());
  });

  // ---- vtkUnstructuredGrid ----
  mod.method("UnstructuredGrid_new",
             []() { return vtkSmartPointer<vtkUnstructuredGrid>::New(); });
  mod.method("GetNumberOfPoints", [](vtkPointSet *g) {
    return static_cast<int64_t>(g->GetNumberOfPoints());
  });
  mod.method("GetNumberOfCells", [](vtkDataSet *g) {
    return static_cast<int64_t>(g->GetNumberOfCells());
  });
  mod.method("GetPoints", [](vtkPointSet *g) {
    return take_ref<vtkPoints>(g->GetPoints());
  });
  mod.method("SetPoints",
             [](vtkPointSet *g, vtkPoints *p) { g->SetPoints(p); });
  mod.method("Allocate", [](vtkUnstructuredGrid *g, int64_t n) {
    g->Allocate(static_cast<vtkIdType>(n));
  });
  // VTK cell type ids, e.g. VTK_HEXAHEDRON = 12
  mod.method("InsertNextCell", [](vtkUnstructuredGrid *g, int64_t cellType,
                                  const std::vector<int64_t> &pointIds) {
    std::vector<vtkIdType> ids(pointIds.begin(), pointIds.end());
    return static_cast<int64_t>(
        g->InsertNextCell(static_cast<int>(cellType),
                          static_cast<vtkIdType>(ids.size()), ids.data()));
  });
  // Cell queries (vtkDataSet API): type id and 0-based point ids of cell i.
  mod.method("GetCellTypeId", [](vtkDataSet *g, int64_t i) {
    return static_cast<int64_t>(g->GetCellType(static_cast<vtkIdType>(i)));
  });
  mod.method("GetCellPointIds", [](vtkDataSet *g, int64_t i) {
    vtkNew<vtkIdList> ids;
    g->GetCellPoints(static_cast<vtkIdType>(i), ids);
    std::vector<int64_t> out(static_cast<size_t>(ids->GetNumberOfIds()));
    for (int j = 0; j < ids->GetNumberOfIds(); ++j) {
      out[static_cast<size_t>(j)] = static_cast<int64_t>(ids->GetId(j));
    }
    return out;
  });
  mod.method("GetPointCoordinates", [](vtkPointSet *g, int64_t i) {
    std::array<double, 3> pt;
    g->GetPoint(static_cast<vtkIdType>(i), pt.data());
    return std::make_tuple(pt[0], pt[1], pt[2]);
  });

  // ---- implicit functions ----
  mod.method("Plane_new", []() { return vtkSmartPointer<vtkPlane>::New(); });
  mod.method("SetOrigin", [](vtkPlane *p, double x, double y, double z) {
    p->SetOrigin(x, y, z);
  });
  mod.method("SetNormal", [](vtkPlane *p, double x, double y, double z) {
    p->SetNormal(x, y, z);
  });

  // ---- generic algorithm plumbing ----
  // One generic SetInputData/GetOutput for every algorithm (readers,
  // writers, filters): no per-class plumbing needed. Outputs are owning
  // vtkDataObject smart pointers; downcast in the Julian layer.
  mod.method("Update", [](vtkAlgorithm *a) { a->Update(); });
  mod.method("SetInputData", [](vtkAlgorithm *a, vtkDataObject *d) {
    a->SetInputDataObject(0, d);
  });
  mod.method("GetOutput", [](vtkAlgorithm *a) {
    return take_ref(a->GetOutputDataObject(0));
  });

  // ---- XML readers ----
  mod.method("XMLUnstructuredGridReader_new", []() {
    return vtkSmartPointer<vtkXMLUnstructuredGridReader>::New();
  });
  mod.method("XMLPolyDataReader_new",
             []() { return vtkSmartPointer<vtkXMLPolyDataReader>::New(); });
  mod.method("SetFileName",
             [](vtkXMLUnstructuredGridReader *r, const std::string &name) {
               r->SetFileName(name.c_str());
             });
  mod.method("SetFileName",
             [](vtkXMLPolyDataReader *r, const std::string &name) {
               r->SetFileName(name.c_str());
             });
  mod.method("SetFileName",
             [](vtkXMLUnstructuredGridWriter *w, const std::string &name) {
               w->SetFileName(name.c_str());
             });
  mod.method("SetFileName",
             [](vtkXMLPolyDataWriter *w, const std::string &name) {
               w->SetFileName(name.c_str());
             });
  mod.method("SetFileName",
             [](vtkXMLImageDataWriter *w, const std::string &name) {
               w->SetFileName(name.c_str());
             });
  mod.method("SetFileName",
             [](vtkXMLRectilinearGridWriter *w, const std::string &name) {
               w->SetFileName(name.c_str());
             });
  mod.method("SetFileName",
             [](vtkXMLStructuredGridWriter *w, const std::string &name) {
               w->SetFileName(name.c_str());
             });

  // ---- CFD readers: EnSight Gold + CGNS ----
  mod.method("EnSightGoldReader_new",
             []() { return vtkSmartPointer<vtkEnSightGoldReader>::New(); });
  mod.method("GenericEnSightReader_new",
             []() { return vtkSmartPointer<vtkGenericEnSightReader>::New(); });
  mod.method("SetCaseFileName",
             [](vtkGenericEnSightReader *r, const std::string &name) {
               r->SetCaseFileName(name.c_str());
             });
  mod.method("CGNSReader_new",
             []() { return vtkSmartPointer<vtkCGNSReader>::New(); });
  mod.method("SetFileName", [](vtkCGNSReader *r, const std::string &name) {
    r->SetFileName(name.c_str());
  });

  // ---- parallel XML readers ----
  mod.method("XMLPPolyDataReader_new",
             []() { return vtkSmartPointer<vtkXMLPPolyDataReader>::New(); });

  // ---- legacy VTK I/O (.vtk format) ----
  mod.method("DataSetReader_new",
             []() { return vtkSmartPointer<vtkDataSetReader>::New(); });
  mod.method("GenericDataObjectReader_new", []() {
    return vtkSmartPointer<vtkGenericDataObjectReader>::New();
  });
  mod.method("UnstructuredGridReader_new", []() {
    return vtkSmartPointer<vtkUnstructuredGridReader>::New();
  });
  mod.method("PolyDataReader_new",
             []() { return vtkSmartPointer<vtkPolyDataReader>::New(); });
  mod.method("StructuredGridReader_new",
             []() { return vtkSmartPointer<vtkStructuredGridReader>::New(); });
  mod.method("RectilinearGridReader_new",
             []() { return vtkSmartPointer<vtkRectilinearGridReader>::New(); });
  mod.method("SetFileName", [](vtkDataReader *r, const std::string &name) {
    r->SetFileName(name.c_str());
  });
  mod.method("SetFileName", [](vtkDataWriter *w, const std::string &name) {
    w->SetFileName(name.c_str());
  });
  mod.method("DataSetWriter_new",
             []() { return vtkSmartPointer<vtkDataSetWriter>::New(); });
  mod.method("GenericDataObjectWriter_new", []() {
    return vtkSmartPointer<vtkGenericDataObjectWriter>::New();
  });
  mod.method("UnstructuredGridWriter_new", []() {
    return vtkSmartPointer<vtkUnstructuredGridWriter>::New();
  });
  mod.method("PolyDataWriter_new",
             []() { return vtkSmartPointer<vtkPolyDataWriter>::New(); });
  mod.method("StructuredGridWriter_new",
             []() { return vtkSmartPointer<vtkStructuredGridWriter>::New(); });
  mod.method("RectilinearGridWriter_new",
             []() { return vtkSmartPointer<vtkRectilinearGridWriter>::New(); });
  mod.method("Write", [](vtkDataWriter *w) { return w->Write(); });

  // ---- Temporal readers ----
  mod.method("GetTimeSteps", [](vtkAlgorithm *a) {
    auto *info = a->GetOutputInformation(0);
    auto *key = vtkStreamingDemandDrivenPipeline::TIME_STEPS();

    std::vector<double> times;

    if (info != nullptr && info->Has(key)) {
      const int n = info->Length(key);

      if (n > 0) {
        const double *values = info->Get(key);
        times.assign(values, values + n);
      }
    }

    return times;
  });

  // ---- XML writers ----
  mod.method("XMLUnstructuredGridWriter_new", []() {
    return vtkSmartPointer<vtkXMLUnstructuredGridWriter>::New();
  });
  mod.method("XMLPolyDataWriter_new",
             []() { return vtkSmartPointer<vtkXMLPolyDataWriter>::New(); });
  mod.method("Write",
             [](vtkXMLUnstructuredGridWriter *w) { return w->Write(); });
  mod.method("Write", [](vtkXMLPolyDataWriter *w) { return w->Write(); });
  mod.method("Write", [](vtkXMLImageDataWriter *w) { return w->Write(); });
  mod.method("Write",
             [](vtkXMLRectilinearGridWriter *w) { return w->Write(); });
  mod.method("Write", [](vtkXMLStructuredGridWriter *w) { return w->Write(); });
  // zlib-compressed appended output (interoperable with ReadVTK.jl)
  mod.method("EnableCompression", [](vtkXMLUnstructuredGridWriter *w) {
    w->SetCompressorTypeToZLib();
  });
  mod.method("SetRawAppendedData", [](vtkXMLUnstructuredGridWriter *w) {
    w->SetEncodeAppendedData(0);
  });
  mod.method("EnableCompression",
             [](vtkXMLPolyDataWriter *w) { w->SetCompressorTypeToZLib(); });
  mod.method("EnableCompression",
             [](vtkXMLImageDataWriter *w) { w->SetCompressorTypeToZLib(); });
  mod.method("EnableCompression", [](vtkXMLRectilinearGridWriter *w) {
    w->SetCompressorTypeToZLib();
  });
  mod.method("EnableCompression", [](vtkXMLStructuredGridWriter *w) {
    w->SetCompressorTypeToZLib();
  });
  mod.method("EnableCompression", [](vtkXMLMultiBlockDataWriter *w) {
    w->SetCompressorTypeToZLib();
  });

  // ---- multiblock container ----
  mod.method("MultiBlockDataSet_new",
             []() { return vtkSmartPointer<vtkMultiBlockDataSet>::New(); });
  // Blocks are borrowed views owned by the dataset; take_ref so Julia may
  // keep them while the parent stays alive.
  mod.method("GetNumberOfBlocks", [](vtkMultiBlockDataSet *m) {
    return static_cast<int64_t>(m->GetNumberOfBlocks());
  });
  // Named GetBlockByIndex (not GetBlock): WrapIt also generates GetBlock on
  // this class; CxxWrap would reject the double registration.
  mod.method("GetBlockByIndex", [](vtkMultiBlockDataSet *m, int64_t i) {
    return take_ref<vtkDataObject>(m->GetBlock(static_cast<unsigned int>(i)));
  });
  // Named SetBlockByIndex (not SetBlock): WrapIt also generates SetBlock on
  // this class; CxxWrap would reject the double registration.
  mod.method("SetBlockByIndex",
             [](vtkMultiBlockDataSet *m, int64_t i, vtkDataObject *b) {
               m->SetBlock(static_cast<unsigned int>(i), b);
             });
  // NOTE: SetNumberOfBlocks is generated by WrapIt (macro); not bound here.
  mod.method("XMLMultiBlockDataReader_new", []() {
    return vtkSmartPointer<vtkXMLMultiBlockDataReader>::New();
  });
  mod.method("SetFileName",
             [](vtkXMLMultiBlockDataReader *r, const std::string &name) {
               r->SetFileName(name.c_str());
             });
  mod.method("XMLMultiBlockDataWriter_new", []() {
    return vtkSmartPointer<vtkXMLMultiBlockDataWriter>::New();
  });
  mod.method("Write", [](vtkXMLMultiBlockDataWriter *w) { return w->Write(); });
  mod.method("SetFileName",
             [](vtkXMLMultiBlockDataWriter *w, const std::string &name) {
               w->SetFileName(name.c_str());
             });

  // ---- filters ----
  mod.method("TableBasedClipDataSet_new",
             []() { return vtkSmartPointer<vtkTableBasedClipDataSet>::New(); });
  mod.method("SetClipFunction",
             [](vtkTableBasedClipDataSet *f, vtkImplicitFunction *fn) {
               f->SetClipFunction(fn);
             });
  mod.method("SetInsideOut",
             [](vtkTableBasedClipDataSet *f, bool b) { f->SetInsideOut(b); });

  mod.method("Cutter_new", []() { return vtkSmartPointer<vtkCutter>::New(); });
  mod.method("SetCutFunction", [](vtkCutter *f, vtkImplicitFunction *fn) {
    f->SetCutFunction(fn);
  });

  mod.method("CellDataToPointData_new",
             []() { return vtkSmartPointer<vtkCellDataToPointData>::New(); });

  mod.method("PointDataToCellData_new",
             []() { return vtkSmartPointer<vtkPointDataToCellData>::New(); });

  mod.method("ContourFilter_new",
             []() { return vtkSmartPointer<vtkContourFilter>::New(); });
  mod.method("SetContourValue", [](vtkContourFilter *f, int64_t i, double v) {
    f->SetValue(static_cast<int>(i), v);
  });

  mod.method("DataSetSurfaceFilter_new",
             []() { return vtkSmartPointer<vtkDataSetSurfaceFilter>::New(); });

  // ---- downcasts (throws if the object has the wrong dynamic type) ----
  // One generic binding per registered grid type; the Julia side builds its
  // DOWNCAST_REGISTRY mechanically from `add_type<...>("vtkX")` in the
  // generated JlClasses.cxx, so adding a grid type needs no new C++ here.
  mod.method("downcast_unstructuredgrid", [](vtkDataObject *o) {
    return take_ref(vtkUnstructuredGrid::SafeDownCast(o));
  });
  mod.method("downcast_polydata", [](vtkDataObject *o) {
    return take_ref(vtkPolyData::SafeDownCast(o));
  });
  mod.method("downcast_imagedata", [](vtkDataObject *o) {
    return take_ref(vtkImageData::SafeDownCast(o));
  });
  mod.method("downcast_rectilineargrid", [](vtkDataObject *o) {
    return take_ref(vtkRectilinearGrid::SafeDownCast(o));
  });
  mod.method("downcast_structuredgrid", [](vtkDataObject *o) {
    return take_ref(vtkStructuredGrid::SafeDownCast(o));
  });
  mod.method("downcast_multiblock", [](vtkDataObject *o) {
    return take_ref(vtkMultiBlockDataSet::SafeDownCast(o));
  });
  // Dynamic class name, e.g. "vtkPolyData" — drives the generic downcast
  // in the Julian layer.
  mod.method("GetClassName", [](vtkObjectBase *o) -> std::string {
    const char *name = o->GetClassName();
    return name == nullptr ? std::string() : std::string(name);
  });
  // --- DataSetAttributes bindings ---- 
  mod.method("HasAttributeArray", [](vtkDataSetAttributes* attributes, int64_t attribute) {
          return attributes->GetArray(static_cast<int>(attribute)) != nullptr;
          });
  mod.method("GetAttributeArrayOwned", [](vtkDataSetAttributes* attributes, int64_t attribute){
          return take_ref<vtkDataArray>(attributes->GetArray(static_cast<int>(attribute)));
          });
  // ---- Stuff related to extents ---- 
  mod.method("GetBoundsValues", [](vtkDataSet* dataset) {
          std::vector<double> values(6);
          dataset->GetBounds(values.data());
          return values;
          });
  mod.method("GetDimensionsValues", [](vtkStructuredGrid* grid) {
          std::vector<int> values(3);
          grid->GetDimensions(values.data());
          return values;
          });
  mod.method("GetExtentValues", [](vtkStructuredGrid* grid) {
          std::vector<int> values(6);
          grid->GetExtent(values.data());
          return values;
          });
  mod.method("GetOriginValues", [](vtkImageData* image) {
          std::vector<double> values(3);
          image->GetSpacing(values.data());
          return values;
          });
  mod.method("GetDirectionValues", [](vtkImageData* image) {
          double *data = image->GetDirectionMatrix()->GetData();
          return std::vector<double>(data, data+9);
          });
}
