# BareFront shaders

BareFront uses a mixture of BareFront-owned shaders and third-party shaders.

## BareFront-owned

- `barecrt/` — BareCRT presentation shaders.
- `c64/BareFront_C64_Bezel.fx` — BareFront C64 bezel/compositing shader.

## Third-party

### CRT-Lite

`crt-lite/CRT_Lite.fx`

Author: Firedragon761138
Licence: BSD 2-Clause License

See:

`crt-lite/LICENSE`

### CRT-Lottes

`crt-lottes/CRT_Lottes.fx` and related files

Original CRT shader: Timothy Lottes
ReShade port: Lucas Melo (luluco250)

The original shader identifies itself as public domain.
The ReShade port is distributed under the MIT License.

See:

`crt-lottes/LICENSE`

### ReShade compatibility header

The bundled `ReShade.fxh` compatibility headers identify themselves as:

`SPDX-License-Identifier: CC0-1.0`

Upstream attribution is retained in the BareCRT copy.

BareFront does not claim ownership of these third-party components.
