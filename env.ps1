$ErrorActionPreference = 'Stop'

# Shared build environment for the vtext module.
#   VEXE   - the V compiler built with gcc
#   CC     - MinGW-w64 gcc from scoop, needed for every compile
#   VMOD   - directory holding this module, so v can resolve `import vtext`
$env:PATH = "C:\Users\MR\scoop\apps\gcc\current\bin;" + $env:PATH
$env:VMODULES = "C:\Users\MR\Projects"
$env:VEXE = "C:\Users\MR\v\v.exe"
