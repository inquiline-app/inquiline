# Shaders through DXIL: design (set aside)

Set aside: the prototype was removed (see Status below for what it found). Kept for reference.

Why: Metal spends 91% of a shader's compile reading the MSL text that MoltenVK writes (0.095 s each, measured on 159 of Asphalt Legends' shaders). Going SPIR-V → DXIL (Mesa's `spirv_to_dxil`) → Metal IR (Apple's Metal Shader Converter, `libmetalirconverter.dylib`) took about 3 s instead of 16 s for the same shaders and pipelines (see `linux-gpu/README.md`). The converter's license lets apps ship the .dylib "for the sole purpose of shader conversion".

Scope of the first version: graphics pipelines with only vertex and fragment shaders. Everything else (tessellation, geometry, compute, pipelines the conversion fails for) keeps MoltenVK's MSL path, chosen per pipeline.

## Conversion (pipeline creation)

- `spirv_to_dxil` per stage, with the pipeline's specialization constants. Vulkan descriptor set N, binding B becomes register space N, register B (CBV for uniform buffers, SRV for sampled images and read-only buffers, UAV for storage, sampler for samplers; a combined image sampler becomes an SRV and a sampler with the same register).
- Push constants: `conf.push_constant_cbv` in a space of their own. Draw data (first vertex, base instance): `conf.runtime_data_cbv`.
- Y flip: MoltenVK's MSL path flips Y in the vertex shader (`flip_vert_y`); here `conf.yz_flip.mode = DXIL_SPIRV_Y_FLIP_UNCONDITIONAL`.
- Metal Shader Converter with a root signature built from the pipeline layout:
  - per descriptor set, one descriptor table for CBV/SRV/UAV and one for samplers, with one range per binding (register = binding, count = descriptor count, offset = the binding's first entry in that set's table);
  - dynamic uniform and storage buffers as root descriptors (their offset changes at bind time);
  - push constants and draw data as root 32-bit constants.
- Vertex inputs: the converter's vertex reflection gives each input's attribute index (from 11, `kIRStageInAttributeStartIndex`); the pipeline's vertex descriptor moves each Vulkan location there. Vertex buffer indices can stay MoltenVK's.
- Stage interface: both stages come from `spirv_to_dxil`, so semantics match (TEXCOORD by location).

## Descriptor sets

Each set gets a second GPU table in the converter's format beside MoltenVK's own argument buffer: 24-byte `IRDescriptorTableEntry`s (GPU address, texture resource ID, metadata), one table for resources and one for samplers, in binding order with arrays expanded. Every write path updates it: `vkUpdateDescriptorSets`, copies, templates, push descriptors.

## Draws

For a DXIL pipeline the encoder skips MoltenVK's MSL bindings for vertex and fragment and instead:
- builds the top-level argument buffer per stage (table GPU addresses, dynamic buffer addresses with their offsets, push constants, draw data) and sets it with `setVertexBytes`/`setFragmentBytes` at index 2 (`kIRArgumentBufferBindPoint`);
- calls `useResource` for everything the bound sets reference, as MoltenVK already does for its argument buffers;
- binds vertex buffers as before.

## Order of work

1. Build: `spirv_to_dxil` as a static library into MoltenVK; link `libmetalirconverter.dylib` and ship it in the app.
2. Pipeline conversion and root signature, with a fallback to MSL on any failure; log how many pipelines take each path.
3. Descriptor set tables.
4. Draw binding.
5. Compare against the MSL path with screenshots: Subway Surfers, Asphalt Legends, Free Fire. Measure first-launch time with an empty Metal cache.

## Status (first prototype)

Built and wired in, but off by default: `MVK_INQUILINE_DXIL=1` in the engine's environment turns it on (`open --env MVK_INQUILINE_DXIL=1 "Inquiline.app"`; `INQUILINE_ENGINE_LOG=<file>` keeps the engine's error output).

- Builds: `Scripts/vm/build-spirv-to-dxil.sh` (Mesa patch `patches/mesa-dxil/0001`), then `build-moltenvk.sh` (`MVKDXIL.h`, pipeline and encoder changes in `patches/moltenvk/0100`).
- Found on the way, now handled: the converter's vertex shaders read draw parameters at buffer 4 and the index type at buffer 5 on every draw; samplers go in the entry's `gpuVA` field, not `textureViewID`; spirv_to_dxil needs a logger; Metal turns down some DXIL pipelines (dual-source blending), which then fall back to MSL.
- Standalone test (GLSL → SPIR-V with glslang → spirv2dxil → metal-shaderconverter, drawn in Metal with the same top-level argument buffer encoding): position, vertex inputs at attribute 11 + location, a uniform buffer, a combined image sampler and push constants all come out right.
- In the app, every pipeline that takes the DXIL path draws nothing: Subway Surfers, Play Store and Asphalt Legends show only their clear color. The binding values look right in a trace (`MVK_INQUILINE_DXIL_TRACE=1`). Not the Y flip (`MVK_INQUILINE_DXIL_NOFLIP=1` changed nothing). Still to check, against the standalone test: the converter library's defaults versus the command-line tool's, the vertex descriptor and stride state MoltenVK binds, and the inter-stage locations (spirv_to_dxil numbers vertex outputs and fragment inputs separately, so a fragment shader reading only some outputs gets the wrong ones).
