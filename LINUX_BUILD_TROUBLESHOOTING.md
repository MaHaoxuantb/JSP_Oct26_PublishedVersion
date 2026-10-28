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
