# The C distributable

Each directory holds the HarfAra library as plain C for one platform,
regenerated and committed by the `c-generated` workflow on every push to
master. A C user with no V toolchain builds from here: the `.c` file plus
the `thirdparty/` headers vendored beside it are the complete sources, and
`harfara.h` / `harfara.def` at the repo root are the API contract (the smoke
test compiles against exactly those headers, so they cannot drift).

One file per platform because V resolves `$if windows/linux/macos` at
translation time: the emitted C is platform-specific and shares nothing
across directories.

## Linux

```sh
cd generated/linux
gcc -shared -fPIC -o libharfara.so harfara.linux.c thirdparty/vlib/builtin/segfault_handler_nix.c -I. -lm
```

`-lm` is what V's own builder adds for the math the engine uses; a raw
`cc` line does not. The extra `.c` is the platform companion (see below).

## macOS

```sh
cd generated/macos
clang -dynamiclib -o libharfara.dylib harfara.macos.c thirdparty/vlib/builtin/segfault_handler_nix.c -I.
install_name_tool -id @rpath/libharfara.dylib libharfara.dylib
```

## Windows

```sh
cd generated/windows
gcc -shared -o harfara.dll harfara.windows.c thirdparty/vlib/builtin/core_windows.c -I. -static-libgcc
dlltool -d ../../harfara.def --dllname harfara.dll -l libharfara.dll.a
```

The extra `.c` on each platform is a companion, not a discovery: the
generated file declares a symbol it never defines, and the companion defines
it — the same split V's own link makes. On Windows it is the SEH thunk
(`core_windows.c` for `v_set_unhandled_exception_filter`); on Linux and
macOS it is `segfault_handler_nix.c` (the non-static
`v_install_segfault_handler`; the vendored header carries only a `static`
copy). The per-platform companion list lives in `c-generated.yml`; a V
upgrade that emits a new undefined symbol fails the link there, not here.

## Regenerating by hand

```sh
v -shared -gc none -cc gcc -o gen.c .
python3 tools/c_bundle.py <vroot> gen.c generated/<os>/harfara.<os>.c generated/<os>/thirdparty [--runtime-c ...]
```

`<vroot>` is the V checkout the compiler came from (the directory with
`vlib/` beside the `v` binary). The script refuses instead of writing a
partial bundle: a missing header, a surviving absolute V-root include, or a
vendored file that differs from the checkout. Only `c_bundle.py` needs to
change when V's runtime layout does; the committed files are its output.
