# Third-Party Notices

Screenlogger includes small vector marks only to identify assistant products a
user may choose to connect. Product names and marks remain the property of their
respective owners. Inclusion does not imply sponsorship or endorsement.

## Simple Icons

The Claude and Cursor vector paths are adapted from Simple Icons at commit
`fadc8239f9a45499f6a30e2dd5c73b84275e1ec7`.

Source: https://github.com/simple-icons/simple-icons

Simple Icons is released under CC0 1.0 Universal. CC0 does not grant trademark
rights. See the upstream legal disclaimer before reusing a mark outside its
identification purpose.

## OpenClaw

The Codex and Grok provider vector paths and the OpenClaw app mark are adapted
from OpenClaw at commit `a8df6e49a7ca456c9f9d9584ed4705368c57ad77`.

Source: https://github.com/openclaw/openclaw

MIT License

Copyright (c) 2026 OpenClaw Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Sparkle

Screenlogger uses Sparkle 2.9.5 for software updates.

Source: https://github.com/sparkle-project/Sparkle

Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesinski.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Sparkle includes the following externally licensed components.

### bsdiff 4.3

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

### sais-lite

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use
of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it freely,
subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but is
   not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

### SUSignatureVerifier.m

Copyright (c) 2011 Mark Hamlin.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## Optional native semantic search

Screenlogger implements the model architecture and image preparation in its own
Swift sources. The isolated `screenlog-semantic-worker` uses
[MLX Swift 0.32.3](https://github.com/ml-explore/mlx-swift) (MIT) and the Tokenizers
product from [swift-transformers 1.3.0](https://github.com/huggingface/swift-transformers)
(Apache-2.0). The standalone CLI and ScreenlogCore do not link these runtimes.
No model wrapper, llama.cpp, Rust runtime, or Xet feature is enabled.

Model files are not included in the app. An explicit download installs only the
text-q8 and, for image search, vision-q8 profiles from
[EmbeddingGemma-2-MLX-Swift](https://huggingface.co/Nurymanau/EmbeddingGemma-2-MLX-Swift/tree/06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd).
The model revision is `06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd`. Google DeepMind
created the Apache-2.0 EmbeddingGemma 2 checkpoint at revision
`914f7f89142e33e77833254d9c9b90c3cef7303b`. The model host supplies data, not code.
All 1,290 stored text and vision tensors were checked against the original
Google checkpoint. The 333 quantized matrices exactly match MLX affine q8
conversion with groups of 64; all other tensors match without conversion.
The omitted tensors belong only to the audio tower and its projection.
No upstream endorsement is implied.

Complete license and notice texts are retained in `Resources/SemanticLicenses`
and shipped unchanged in the app at `Contents/Resources/SemanticLicenses`.
These include the owned encoder reference notice, Apache-2.0, the PyTorch
resize adaptation license, MLX MIT and acknowledgments, and the Metal-cpp license.
The pinned dependency closure also includes:

- [swift-huggingface 0.13.0](https://github.com/huggingface/swift-huggingface), Apache-2.0;
- [swift-jinja 2.5.1](https://github.com/huggingface/swift-jinja), Apache-2.0;
- [Swift Collections 1.7.1](https://github.com/apple/swift-collections), Apache-2.0 with Swift Runtime Library Exception;
- [Swift Numerics 1.1.1](https://github.com/apple/swift-numerics), Apache-2.0 with Swift Runtime Library Exception;
- [Swift Crypto 4.5.2](https://github.com/apple/swift-crypto), Apache-2.0 with Swift Runtime Library Exception and its retained third-party notices;
- [Swift ASN.1 1.7.3](https://github.com/apple/swift-asn1), Apache-2.0 with Swift Runtime Library Exception and its retained notices;
- [EventSource 1.5.1](https://github.com/mattt/EventSource), MIT;
- [yyjson 0.12.0](https://github.com/ibireme/yyjson), MIT.

The consumer dependency lock is
`Screenlog.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
