# Linux build error: `<memory>` file not found

The Orange Pi build fails while compiling `swift-nio-ssl` because the compiler cannot find `<memory>`, a C++ standard library header. This usually means the Linux C++ development packages are missing.

On the Orange Pi, run these commands as root:

```bash
apt-get update
apt-get install build-essential g++ libsqlite3-dev pkg-config

swift build -c release
swift test -c release
```

Swift uses GCC's `libstdc++` on Ubuntu and Debian. See the [Swift documentation](https://www.swift.org/documentation/cxx-interop/status/).

If the same error persists, collect the output of:

```bash
cat /etc/os-release
swift --version
clang++ -v -E -x c++ /dev/null
g++ --version
```

This output helps identify whether Clang is selecting a GCC installation whose matching C++ headers are missing.

## Dependencies already installed, but the error persists

The follow-up output shows Ubuntu 22.04 (Jammy) ARM64 with `g++` 11 already installed. Installing the default build packages did not resolve the error. One possible cause is Clang selecting a newer, incomplete GCC installation instead of GCC 11; this has not yet been confirmed on the Orange Pi.

Ensure GCC 11's C++ headers are installed, then explicitly select its installation for the C++ compilation:

```bash
apt-get install g++-11 libstdc++-11-dev

ls /usr/include/c++/11/memory
ls -d /usr/lib/gcc/aarch64-linux-gnu/11

swift build -c release -Xcxx --gcc-install-dir=/usr/lib/gcc/aarch64-linux-gnu/11
swift test -c release -Xcxx --gcc-install-dir=/usr/lib/gcc/aarch64-linux-gnu/11
```

Proceed with the build commands only if both `ls` commands succeed. Keep the same `-Xcxx` option on subsequent builds and tests while using this workaround.

Clang documents `--gcc-install-dir` as selecting a specific GCC installation. Its automatic detection normally selects the largest GCC version it finds. See [Clang's toolchain setup guidance](https://clang.llvm.org/get_started.html).

If this still fails, collect diagnostics using the Clang bundled beside Swift, since a system `clang++` may be a different compiler:

```bash
swift --version
command -v swift
g++ -v
ls /usr/lib/gcc/aarch64-linux-gnu/
ls /usr/include/c++/
swift_toolchain_bin="$(dirname "$(readlink -f "$(command -v swift)")")"
printf '#include <memory>\n' | "$swift_toolchain_bin/clang++" -v -E -x c++ - >/dev/null
printf '#include <memory>\n' | "$swift_toolchain_bin/clang++" --gcc-install-dir=/usr/lib/gcc/aarch64-linux-gnu/11 -v -E -x c++ - >/dev/null
```

The compiler diagnostics remain visible on standard error. Compare the selected GCC installation and include search paths in the two Clang runs.

## Headers resolved, but linking fails with `cannot find -lstdc++`

The next Orange Pi output confirms that selecting GCC 11 resolved the header compilation error. The release build now reaches linking, where `ld.gold` cannot find `libstdc++`. The undefined C++ symbols listed after that error are consistent with the missing library. The pasted test output ends during compilation, so the test outcome is not yet known.

The `-Xcxx` option applies to C++ compilation; also provide GCC 11's library directory to the linker:

```bash
ls -l /usr/lib/gcc/aarch64-linux-gnu/11/libstdc++.so
readlink -e /usr/lib/gcc/aarch64-linux-gnu/11/libstdc++.so

swift build -c release \
  -Xcxx --gcc-install-dir=/usr/lib/gcc/aarch64-linux-gnu/11 \
  -Xlinker -L/usr/lib/gcc/aarch64-linux-gnu/11

swift test -c release \
  -Xcxx --gcc-install-dir=/usr/lib/gcc/aarch64-linux-gnu/11 \
  -Xlinker -L/usr/lib/gcc/aarch64-linux-gnu/11
```

Run the build and test commands if both library checks succeed. The linker `-L` option adds a directory to the library search path; see the [GNU linker documentation](https://sourceware.org/binutils/docs/ld/Options.html).

If the library is missing or its symlink does not resolve, repair the development package and runtime, then retry:

```bash
apt-get install --reinstall libstdc++-11-dev libstdc++6
```

If linking still fails, capture the verbose invocation using the same options:

```bash
swift build -c release -v \
  -Xcxx --gcc-install-dir=/usr/lib/gcc/aarch64-linux-gnu/11 \
  -Xlinker -L/usr/lib/gcc/aarch64-linux-gnu/11
```
