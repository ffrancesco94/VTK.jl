using VTK

# --- fill in these ---
input_file  = "pod_final_7.vtu"
output_file = "output.vtu"
field_name  = "Velocity"   # must exist in cell data
# ---------------------

ug = VTK.read_vtu(input_file)

# Check the field exists in cell data
VTK.HasArray(VTK.cell_data(ug), field_name) ||
    error("Cell data array '$field_name' not found")

# cell_to_point processes ALL cell arrays; no per-field selection available
result = VTK.cell_to_point(ug)

VTK.write_vtu(result, output_file)
