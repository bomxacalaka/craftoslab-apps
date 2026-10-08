# Third-party notices

The bundled weights were trained on the EMNIST Letters dataset introduced in:

G. Cohen, S. Afshar, J. Tapson, and A. van Schaik, “EMNIST: Extending MNIST to handwritten letters,” 2017. Dataset details and attribution are available from [NIST](https://www.nist.gov/itl/products-and-services/emnist-dataset).

EMNIST is not included in this repository. The training script downloads it through Torchvision.

## llama2.c and stories260K

This app vendors a copy of the sibling [`llama.lua`](../llama.lua/) project under `llama/` (its `llama2.lua` inference port of [karpathy/llama2.c](https://github.com/karpathy/llama2.c), plus the TinyStories `stories260K` checkpoint and 512-token tokenizer) so that it is fully self-contained at runtime. `llama2.c` is MIT licensed; its original terms are preserved in the sibling project's license and notices, which also apply to this vendored copy. Refresh the copy with `tools/update-llama.sh`.
