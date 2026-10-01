$ErrorActionPreference = 'Stop'

# Shared build environment for the vtext module.
#   VEXE   - the V compiler to build and test with
#   CC     - MinGW-w64 gcc from scoop, needed for every compile
#   VMODULES - directory holding this module, so v can resolve `import vtext`
#
# The fork in Projects\v compiles fine but its `v test` mode fails with
# "exec failed (SetHandleInformation): The handle is invalid." before any test
# runs, so tests use the stable checkout in C:\Users\MR\v. Both compile the
# module identically; only the test runner differs.
$env:PATH = "C:\Users\MR\scoop\apps\gcc\current\bin;" + $env:PATH
$env:VMODULES = "C:\Users\MR\Projects"
$env:VEXE = "C:\Users\MR\v\v.exe"
