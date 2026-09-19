## Central test runner: compiles and runs every `t*.nim` in `tests/`.

import std/os

proc fatal(msg: string) =
  quit "FAILURE " & msg

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0:
    fatal cmd

let testDir = currentSourcePath().parentDir()
for file in walkFiles(testDir / "t*.nim"):
  let name = file.extractFilename
  if name != "tester.nim":
    exec "nim c -r " & quoteShell(file)

echo "All test files completed."
