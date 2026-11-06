# auto_shim.jl — generate the mechanical part of the merged shim from VTK
# headers: owning `X_new` factories (from `static vtkX* New();`) and
# macro-generated accessors (vtkSetMacro/vtkGetMacro, string macros,
# vtkBooleanMacro, vtkSetVector{,3}Macro, vtkSetClampMacro).
#
# Everything emitted here is derivable from the headers alone. The
# hand-written shim (shim_vtkjl.cpp) keeps ownership policy, zero-copy
# workers, error capture and convenience methods; methods it already
# provides are skipped (dedup by (class, method-name), factories by name).
#
# Used by build.jl; no standalone entry point.

# C++ scalar types we dare to expose directly; others are skipped
# (pointers, enums, class types, ...). Signature type may differ from the
# VTK type (vtkIdType → int64_t, vtkTypeBool → int).
const AUTO_TYPE_MAP = Dict(
    "double" => "double", "float" => "float",
    "int" => "int", "unsigned int" => "unsigned int",
    "long" => "long", "unsigned long" => "unsigned long",
    "long long" => "long long", "unsigned long long" => "unsigned long long",
    "short" => "short", "unsigned short" => "unsigned short",
    "char" => "char", "signed char" => "signed char",
    "unsigned char" => "unsigned char",
    "bool" => "bool", "vtkIdType" => "int64_t", "vtkTypeBool" => "int",
    "size_t" => "uint64_t")

# Signature normalization shared by the auto-shim skip logic and the
# shim-clash audit in build.jl. Integer types are canonicalized to
# fixed-width spellings (LP64), matching what CxxWrap/Julia sees:
# vtkIdType → Int64, vtkTypeBool/int → Int32, size_t → UInt64, etc.
const NORM_INT_TYPES = Dict(
    "int" => "int32_t", "unsigned int" => "uint32_t",
    "long" => "int64_t", "long int" => "int64_t",
    "unsigned long" => "uint64_t", "long unsigned int" => "uint64_t",
    "long long" => "int64_t", "long long int" => "int64_t",
    "unsigned long long" => "uint64_t", "unsigned long long int" => "uint64_t",
    "short" => "int16_t", "unsigned short" => "uint16_t",
    "char" => "int8_t", "signed char" => "int8_t", "unsigned char" => "uint8_t",
    "vtkIdType" => "int64_t", "vtkTypeBool" => "int32_t", "size_t" => "uint64_t")

"""
    norm_cpp_type(p) -> String

Normalize a C++ parameter type so signatures from WrapIt and the shim can be
compared. Top-level `const`, pointers, and references do not affect dispatch,
so they are removed. Integer typedefs are replaced by the fixed-width types
seen by CxxWrap on the supported LP64 platforms. VTK typedefs are also
normalized inside template arguments, without changing names such as
`vtkIdTypeArray`.

This function compares *types*, not complete parameter declarations; use
[`norm_shim_args`](@ref) when the declaration also contains parameter names.

# Examples

```julia
norm_cpp_type("const vtkIdType&")          # "int64_t"
norm_cpp_type("std::vector<vtkIdType>")    # "std::vector<int64_t>"
norm_cpp_type("vtkIdTypeArray*")           # "vtkIdTypeArray"
```
"""
function norm_cpp_type(p)
    p = strip(replace(p, r"^const\s+" => "", "&" => "", "*" => ""))
    haskey(NORM_INT_TYPES, p) && return NORM_INT_TYPES[p]
    # template-argument types: normalize typedefs inside (word-boundaried,
    # so vtkIdTypeArray etc. are untouched)
    return replace(p, r"\bvtkIdType\b" => "int64_t",
                      r"\bvtkTypeBool\b" => "int32_t",
                      r"\bsize_t\b" => "uint64_t")
end

"""
    norm_shim_args(a; strip_names=false) -> Vector{String}

Convert a comma-separated C++ argument list to normalized type names. Whitespace
is canonicalized before each argument is passed to [`norm_cpp_type`](@ref).

Set `strip_names=true` for shim lambda parameters, which include a variable
name after each type. Leave it false for WrapIt's veto comments, which contain
only types: dropping the last token there would incorrectly turn
`unsigned int` into `unsigned`.

An empty argument list returns `String[]`.

# Examples

```julia
norm_shim_args("vtkPlane* o, const double v"; strip_names=true)
# ["vtkPlane", "double"]

norm_shim_args("unsigned int, vtkIdType")
# ["uint32_t", "int64_t"]
```
"""
function norm_shim_args(a; strip_names = false)
    a == "" && return String[]
    args = String[]
    for p in split(a, ',')
        p = replace(strip(p), r"\s+" => " ")
        if strip_names
            tokens = split(p, ' ')
            length(tokens) > 1 && (p = join(tokens[1:end-1], ' '))
        end
        push!(args, norm_cpp_type(p))
    end
    return args
end

"""
    parse_generated_sigs(gen_text) -> Vector{NamedTuple}

Extract method signatures from the `// signature to use in the veto list:`
comments in WrapIt's generated C++. Each result has `ret`, `cls`, `name`, and
`args` fields. Argument types remain unnormalized here; normalization happens
when the signatures are indexed or compared.

The auto-shim uses this information to avoid registering a method that WrapIt
already provides. `build.jl` also uses it when auditing clashes with the hand
shim.

# Example

```julia
text = "// signature to use in the veto list: void vtkPlane::SetNormal(double,double,double)"
parse_generated_sigs(text)
# [(ret = "void", cls = "vtkPlane", name = "SetNormal",
#   args = "double,double,double")]
```
"""
parse_generated_sigs(gen_text) =
    [(ret = m.captures[1], cls = m.captures[2], name = m.captures[3],
      args = m.captures[4])
     for m in eachmatch(r"// signature to use in the veto list: (.+?) ([\w:]+)::(\w+)\((.*?)\)\s*$"m,
                        gen_text)]

"""
    generated_sig_index(gen_text) -> Dict{String,Vector{Tuple}}

Index WrapIt's generated methods by method name. Each value contains tuples of
the form `(class, argument_type...)`, with argument types normalized by
[`norm_shim_args`](@ref). Grouping by name lets the emitter cheaply find only
those generated signatures that could clash with a candidate method.

# Example

```julia
text = "// signature to use in the veto list: void vtkPlane::SetNormal(double,double,double)"
generated_sig_index(text)
# Dict("SetNormal" => [("vtkPlane", "double", "double", "double")])
```
"""
function generated_sig_index(gen_text)
    idx = Dict{String,Vector{Tuple}}()
    for s in parse_generated_sigs(gen_text)
        push!(get!(idx, s.name, Tuple[]),
              Tuple(vcat([s.cls], norm_shim_args(s.args))))
    end
    return idx
end

const AUTO_CLASS_RE =
    r"^\s*class\s+(?:[A-Z][A-Z0-9_]*\s+)*(vtk[A-Za-z0-9_]+)\s*(?:final\s*)?:"
const AUTO_NEW_RE = r"^\s*static\s+(vtk[A-Za-z0-9_]+)\s*\*\s*New\s*\(\s*\)\s*;"
const AUTO_MACRO_RE =
    r"^\s*(vtkSetClampMacro|vtkSetVector3Macro|vtkSetVectorMacro|vtkSetFilePathMacro|vtkGetFilePathMacro|vtkSetStringMacro|vtkGetStringMacro|vtkBooleanMacro|vtkSetMacro|vtkGetMacro)\s*\(([^;]+)\)\s*;"

"""
    hand_shim_methods(hand_shim_path) -> Set{Tuple{String,String}}

Read `shim_vtkjl.cpp` and return the `(class, method_name)` pairs it registers.
The class is inferred from the first VTK type in each lambda's argument list.
A registration without a VTK-typed first argument is treated as global and
stored under the empty class name, `""`; this covers factories and helpers.

The emitter skips these registrations so that the automatically generated C++
does not redefine methods owned by the hand shim.

# Example

Given a hand shim containing:

```cpp
mod.method("InsideOutOn", [](vtkPlane* o) { o->InsideOutOn(); });
mod.method("helper", []() { return 42; });
```

`hand_shim_methods(path)` returns a set equivalent to:

```julia
Set([("vtkPlane", "InsideOutOn"), ("", "helper")])
```
"""
function hand_shim_methods(hand_shim_path)
    handled = Set{Tuple{String,String}}()
    for m in eachmatch(r"mod\.method\(\"(\w+)\",\s*\[\]\((.*?)\)", read(hand_shim_path, String))
        name, args = m.captures
        firstarg = strip(split(args, ',')[1])
        cm = match(r"vtk[A-Za-z0-9_]+", firstarg)
        push!(handled, (cm === nothing ? "" : cm.match, name))
    end
    return handled
end

"""
    scan_vtk_header(path) -> Vector{NamedTuple}

Scan one VTK header for classes and the declarations that the auto-shim knows
how to reproduce. Each class record contains:

- `name`: the C++ class name, such as `"vtkPlane"`;
- `template`: whether a `template` declaration precedes the class;
- `has_new`: whether the class publicly declares `static vtkX* New();`;
- `macros`: `(macro_name, argument_string)` pairs in source order.

Only public members are collected, matching the protected/private filtering of
libclang-based generators. Template classes are recorded but skipped later,
because this simple textual emitter does not attempt C++ template binding.

# Example

For a header containing:

```cpp
class VTK_EXPORT vtkPlane : public vtkImplicitFunction
{
public:
  static vtkPlane* New();
  vtkSetMacro(InsideOut, int);
};
```

the result is equivalent to:

```julia
[(name = "vtkPlane", template = false, has_new = true,
  macros = [("vtkSetMacro", "InsideOut, int")])]
```
"""
function scan_vtk_header(path)
    classes = NamedTuple[]
    name, template, has_new = "", false, false
    macros = Tuple{String,String}[]
    access = :private  # C++ class default; VTK bodies start with public:
    prev_nonempty = ""
    function finish!()
        isempty(name) || push!(classes, (name = name, template = template,
                                         has_new = has_new, macros = copy(macros)))
        name, template, has_new = "", false, false
        access = :private
        empty!(macros)
    end
    for line in eachline(path)
        m = match(AUTO_CLASS_RE, line)
        if m !== nothing
            finish!()
            name, template = m.captures[1], occursin("template", prev_nonempty)
        elseif !isempty(name) && occursin(r"^\};", line)
            finish!()
        elseif !isempty(name)
            am = match(r"^\s*(public|protected|private)\s*:", line)
            if am !== nothing
                access = Symbol(am.captures[1])
            elseif access == :public
                mn = match(AUTO_NEW_RE, line)
                mn !== nothing && mn.captures[1] == name && (has_new = true)
                mm = match(AUTO_MACRO_RE, line)
                mm !== nothing && push!(macros, (mm.captures[1], strip(mm.captures[2])))
            end
        end
        isempty(strip(line)) || (prev_nonempty = line)
    end
    finish!()
    return classes
end

"""
    split_macro_args(s) -> Vector{String}

Split a VTK accessor macro's arguments and remove surrounding whitespace. The
supported macros have simple comma-separated arguments of the form
`Name, Type` or `Name, Type, N`, so no C++ parser is needed here.

# Examples

```julia
split_macro_args("InsideOut, int")       # ["InsideOut", "int"]
split_macro_args("Origin, double, 3")    # ["Origin", "double", "3"]
```
"""
split_macro_args(s) = strip.(split(s, ','))

"""
    auto_shim_class_methods!(out, cls, handled, emitted, skipped,
                             gen_sigs, n_skipped_gen) -> Int

Append C++ `mod.method(...)` registrations for one scanned class to `out` and
return the number appended. Template classes are ignored. Depending on the
macros found by [`scan_vtk_header`](@ref), this emits:

- an owning `X_new` factory returning `vtkSmartPointer<vtkX>`;
- scalar setters/getters, including casts for VTK integer typedefs;
- null-safe string setters/getters using `std::string` at the Julia boundary;
- `On`/`Off` methods for `vtkBooleanMacro`;
- fixed-size vector setters with one scalar argument per component.

The mutable arguments coordinate generation across all classes:

- `handled` contains hand-shim `(class, method)` pairs to leave alone;
- `emitted` prevents duplicate auto-shim registrations by class and name;
- `gen_sigs` is the WrapIt index from [`generated_sig_index`](@ref), used to
  skip registrations that WrapIt already provides;
- `skipped` accumulates counts for unsupported `(class, macro, type)` triples;
- `n_skipped_gen` is a `Ref{Int}` counting methods omitted because WrapIt
  already generated them.

String getters deliberately bypass the WrapIt duplicate check. Their
`std::string` version replaces WrapIt's `const char*` version through the clash
audit in `build.jl`, giving Julia safe string ownership and handling null C
strings.

# Example

```julia
cls = (name = "vtkPlane", template = false, has_new = true,
       macros = [("vtkSetMacro", "InsideOut, int")])
out = String[]
handled = Set{Tuple{String,String}}()
emitted = Set{Tuple{String,String}}()
skipped = Dict{Tuple{String,String,String},Int}()
gen_sigs = Dict{String,Vector{Tuple}}()
n_skipped_gen = Ref(0)

auto_shim_class_methods!(out, cls, handled, emitted, skipped,
                         gen_sigs, n_skipped_gen)  # 2
```

`out` now contains registrations for `Plane_new` and `SetInsideOut`. The
function only emits C++ source; `generate_auto_shim!` writes the complete file.
"""
function auto_shim_class_methods!(out, cls, handled, emitted, skipped, gen_sigs, n_skipped_gen)
    cls.template && return 0
    n = 0
    function emit!(methodname, code, argtypes = String[]; allow_clash = false)
        (cls.name, methodname) in handled && return
        ("", methodname) in handled && return
        key = (cls.name, methodname)
        key in emitted && return
        if !allow_clash
            full = Tuple(vcat([cls.name], norm_cpp_type.(argtypes)))
            if any(g -> length(full) <= length(g) && full == g[1:length(full)],
                   get(gen_sigs, methodname, Tuple[]))
                n_skipped_gen[] += 1  # WrapIt already emits this method
                return
            end
        end
        push!(emitted, key)
        push!(out, code)
        n += 1
    end
    sig(t) = AUTO_TYPE_MAP[t]
    castto(t, v) = sig(t) == t ? v : "static_cast<$t>($v)"
    castfrom(t, v) = sig(t) == t ? v : "static_cast<$(sig(t))>($v)"
    scalar_setter(name, t) =
        emit!("Set$name", "  mod.method(\"Set$name\", []($(cls.name)* o, $(sig(t)) v) { o->Set$name($(castto(t, "v"))); });",
              [sig(t)])
    scalar_getter(name, t) =
        emit!("Get$name", "  mod.method(\"Get$name\", []($(cls.name)* o) { return $(castfrom(t, "o->Get$name()")); });")
    string_setter(name) =
        emit!("Set$name", "  mod.method(\"Set$name\", []($(cls.name)* o, const std::string& v) { o->Set$name(v.c_str()); });",
              ["std::string"])
    string_getter(name) =
        emit!("Get$name", "  mod.method(\"Get$name\", []($(cls.name)* o) { const char* s = o->Get$name(); return s == nullptr ? std::string() : std::string(s); });";
              allow_clash = true)
    if cls.has_new
        short = replace(cls.name, r"^vtk" => "")
        emit!("$(short)_new",
              "  mod.method(\"$(short)_new\", []() { return vtkSmartPointer<$(cls.name)>::New(); });")
    end
    for (mac, argstr) in cls.macros
        args = split_macro_args(argstr)
        if mac == "vtkSetMacro" || mac == "vtkGetMacro" || mac == "vtkSetClampMacro"
            length(args) == 2 || continue
            name, t = args[1], replace(args[2], r"\s+" => " ")
            if !haskey(AUTO_TYPE_MAP, t)
                skipped[(cls.name, mac, t)] = get(skipped, (cls.name, mac, t), 0) + 1
                continue
            end
            mac == "vtkGetMacro" ? scalar_getter(name, t) : scalar_setter(name, t)
        elseif mac == "vtkSetStringMacro" || mac == "vtkSetFilePathMacro"
            length(args) == 1 && string_setter(args[1])
        elseif mac == "vtkGetStringMacro" || mac == "vtkGetFilePathMacro"
            length(args) == 1 && string_getter(args[1])
        elseif mac == "vtkBooleanMacro"
            length(args) == 2 || continue
            name, t = args[1], replace(args[2], r"\s+" => " ")
            if !haskey(AUTO_TYPE_MAP, t)
                skipped[(cls.name, mac, t)] = get(skipped, (cls.name, mac, t), 0) + 1
                continue
            end
            scalar_setter(name, t)
            scalar_getter(name, t)
            emit!("$(name)On", "  mod.method(\"$(name)On\", []($(cls.name)* o) { o->$(name)On(); });")
            emit!("$(name)Off", "  mod.method(\"$(name)Off\", []($(cls.name)* o) { o->$(name)Off(); });")
        elseif mac == "vtkSetVector3Macro" || mac == "vtkSetVectorMacro"
            ncomp = mac == "vtkSetVector3Macro" ? 3 :
                (length(args) == 3 && all(isdigit, args[3]) ? parse(Int, args[3]) : 0)
            (ncomp in 1:8 && length(args) >= 2) || continue
            name, t = args[1], replace(args[2], r"\s+" => " ")
            if !haskey(AUTO_TYPE_MAP, t)
                skipped[(cls.name, mac, t)] = get(skipped, (cls.name, mac, t), 0) + 1
                continue
            end
            decl = join(["$(sig(t)) v$i" for i in 1:ncomp], ", ")
            call = join([castto(t, "v$i") for i in 1:ncomp], ", ")
            emit!("Set$name", "  mod.method(\"Set$name\", []($(cls.name)* o, $decl) { o->Set$name($call); });",
                  fill(sig(t), ncomp))
        end
    end
    return n
end

"""
    generate_auto_shim!(driver_dir, build_dir, include_dir) -> nothing

Generate `build_dir/cxx/shim_auto.cpp` from the headers listed in
`driver_dir/VTK.wit.in`. This is the top-level auto-shim entry point called by
`build.jl` after WrapIt has generated its C++ and before the merged library is
compiled.

The generation pipeline is:

1. Read the input header list from `VTK.wit.in`.
2. Read `build_dir/cxx/JlClasses.cxx` to discover which VTK classes WrapIt
   actually registered and which method signatures it generated.
3. Read `driver_dir/shim_vtkjl.cpp` to avoid duplicating hand-written methods.
4. Scan each available header under `include_dir` and emit mechanical bindings
   for registered classes only.
5. Write the includes and `register_auto_shim_methods` function to
   `shim_auto.cpp`, then report emitted and skipped method counts.

Missing header files and classes not registered by WrapIt are ignored.
Unsupported macro argument types are reported rather than emitted as invalid
C++. The generated file is replaced on every build and should not be edited.

# Example

Called from the WrapIt driver as:

```julia
generate_auto_shim!(driver_dir, build_dir, vtk_include_dir())
```

From a repository checkout, the directories are typically `gen/wrapit` and
`gen/wrapit/build`; `vtk_include_dir()` supplies the include path from the VTK
artifact. `JlClasses.cxx` must already exist in `build_dir/cxx`.
"""
function generate_auto_shim!(driver_dir, build_dir, include_dir)
    template = read(joinpath(driver_dir, "VTK.wit.in"), String)
    m = match(r"input\s*=\s*\[(.*?)\]"s, template)
    m === nothing && error("no input list in VTK.wit.in")
    headers = [m.captures[1] for m in eachmatch(r"\"([^\"]+\.h)\"", m.captures[1])]
    registered = Set(m.captures[1] for m in eachmatch(
        r"add_type<(vtk[A-Za-z0-9_]+)>",
        read(joinpath(build_dir, "cxx", "JlClasses.cxx"), String)))
    handled = hand_shim_methods(joinpath(driver_dir, "shim_vtkjl.cpp"))
    gen_sigs = generated_sig_index(
        read(joinpath(build_dir, "cxx", "JlClasses.cxx"), String))
    n_skipped_gen = Ref(0)
    emitted = Set{Tuple{String,String}}()
    skipped = Dict{Tuple{String,String,String},Int}()
    out = String[]
    n_methods, n_classes = 0, 0
    for h in headers
        path = joinpath(include_dir, h)
        isfile(path) || continue
        for cls in scan_vtk_header(path)
            cls.name in registered || continue
            n = auto_shim_class_methods!(out, cls, handled, emitted, skipped,
                                         gen_sigs, n_skipped_gen)
            n > 0 && (n_methods += n; n_classes += 1)
        end
    end
    code = """
// AUTO-GENERATED by gen/wrapit/auto_shim.jl from VTK headers — do not edit.
// Mechanical shim: owning `X_new` factories and macro-generated accessors.
// Regenerated on every build; the hand-written shim owns everything else.
#include <jlcxx/jlcxx.hpp>
#include <jlcxx/smart_pointers.hpp>
#include <jlcxx/stl.hpp>
#include <vtkSmartPointer.h>
#include <string>
#include <cstdint>
#include "shim_vtkjl.h"
$(join(["#include <$h>" for h in headers], "\n"))

void register_auto_shim_methods(jlcxx::Module& mod)
{
$(join(out, "\n"))
}
"""
    write(joinpath(build_dir, "cxx", "shim_auto.cpp"), code)
    println("auto-shim: $n_methods methods for $n_classes classes",
            " ($(n_skipped_gen[]) already generated by WrapIt, skipped)",
            isempty(skipped) ? "" : " (skipped $(length(skipped)) unsupported macro/type combos)")
    if !isempty(skipped)
        for ((cls, mac, t), count) in sort(collect(skipped))
            println("  skipped: $cls $mac($t) ×$count")
        end
    end
    return nothing
end
