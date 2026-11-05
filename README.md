# aio
AIO in zig

A high-performance asynchronous I/O library for Zig, originally extracted from [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle).

## About

This library was initially separated from the [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle) project, a financial transactions database designed for mission-critical safety and performance. The I/O abstraction layer has been extracted to provide a standalone, reusable async I/O library for the Zig ecosystem.

## Requirements
> **DEPRECATED (2026-04-18):** `build.zig.zon` declares `minimum_zig_version = "0.15.0"` and forKernels targets Zig 0.15.2. The 0.16.0-dev reference below predates the 0.15 standardization — use Zig 0.15.2 (matching the rest of forKernels).
zig version: 0.16.0-dev.1451+0a9f666ea

## Usage
```
zig fetch --save https://github.com/zon-dev/aio/archive/refs/heads/main.zip
```