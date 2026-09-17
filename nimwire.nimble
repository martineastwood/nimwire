version       = "0.1.0"
author        = "martin"
description   = "MCP server framework for Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "nimcrypto >= 0.6.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off --threads:on --mm:atomicArc tests/all_tests.nim"

task fuzz, "Build the stdin parser/security fuzz harness":
  exec "nim c --hints:off tests/fuzz_parser.nim"
