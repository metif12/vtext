$ErrorActionPreference = 'Stop'

# Shared build environment for the vtext module.
#   VEXE   - the V compiler to build with: the fork in Projects\v, not the separate
#            vlang/v checkout in C:\Users\MR\v
#   CC     - MinGW-w64 gcc from scoop, needed for every compile
#   VMODULES - directory holding this module, so v can resolve `import vtext`
$env:PATH = "C:\Users\MR\scoop\apps\gcc\current\bin;" + $env:PATH
$env:VMODULES = "C:\Users\MR\Projects"
$env:VEXE = "C:\Users\MR\Projects\v\v.exe"
