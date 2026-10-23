// The engine's door into Google's Draco decoder: plain C, so Swift can call it without C++ interop.
//
// A decoded mesh is opaque. Ask it for its sizes, then copy out the triangles and each attribute the
// glTF file names by its Draco unique id, as floats — Draco dequantizes and, for a normalized
// attribute, normalizes on the way.
#ifndef DUDRACO_H
#define DUDRACO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DUDracoMesh DUDracoMesh;

/// Decodes a Draco-compressed mesh. Returns NULL when the data is not a valid Draco mesh.
DUDracoMesh *_Nullable du_draco_decode(const void *_Nonnull data, size_t length);
void du_draco_free(DUDracoMesh *_Nullable mesh);

uint32_t du_draco_point_count(const DUDracoMesh *_Nonnull mesh);
uint32_t du_draco_face_count(const DUDracoMesh *_Nonnull mesh);

/// Copies `3 × face count` indices. Always succeeds for a decoded mesh.
void du_draco_indices(const DUDracoMesh *_Nonnull mesh, uint32_t *_Nonnull out);

/// Components per value of the attribute with this unique id, or 0 when the mesh has none.
int32_t du_draco_attribute_components(const DUDracoMesh *_Nonnull mesh, uint32_t unique_id);

/// Copies `point count × components` floats. Returns 0 when the attribute is missing or unconvertible.
int32_t du_draco_attribute_floats(const DUDracoMesh *_Nonnull mesh, uint32_t unique_id, float *_Nonnull out);

#ifdef __cplusplus
}
#endif

#endif
