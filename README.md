# Tar

[![Build Status](https://travis-ci.org/JuliaLang/Tar.jl.svg?branch=master)](https://travis-ci.org/JuliaLang/Tar.jl)
[![Codecov](https://codecov.io/gh/JuliaLang/Tar.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaLang/Tar.jl)

The `Tar` package can list, extract and create POSIX TAR archives ("tarballs") as specified in [POSIX 1003.1-2001](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html).
It does not aim to read other historical variants of the TAR format and it intentionally ignores much of the metadata included in the TAR format.

## Design

This package has one primary design goal:

* __If you create archives of trees with the same git tree hash, their archives will be identical.__

When you extract that tarball, it will produce a tree with the same git tree hash.
To this end, `Tar` only supports creation and extraction of tarballs containing regular files, symlinks and directories—the kinds of content that git tracks.
It also ignores the owner, group, modification time, device and inode of all contents during tarball creation and extraction, since git does not consider this metadata significant when computing tree hashes.
All of these ignored metadata fields are set to zero or empty (depending on whether the field is a string or an integer) when tar files are created.
When creating a tarball, permission modes are recorded only to the extent that git considers them significant:

* a file with no executable bits set is archived with mode `0o644`
* a file with any executable bits set is archived with mode `0o755`
* directories and symlinks are always archived with mode `0o755`

When extracting a tarball, the mode recorded in the archive is applied to the extracted files, symlinks and directories, even if they are modes other than `0o644` or `0o755`.
Upon extraction, all files, symlinks and directorues are owned by the current user and group, and the modification time is not altered from the actual time of extraction.

## Usage

The public API of `Tar` includes three functions:

* `Tar.create([ predicate, ] dir, [ tarball, ]) -> tarball`
  - `predicate :: Function`
  - `dir       :: AbstractString`
  - `tarball   :: Union{AbstractString, IO}`

* `Tar.list(tarball; [ strict = true ]) -> Vector{Header}`
  - `tarball   :: Union{AbstractString, IO}`
  - `strict    :: Bool`

* `Tar.extract(tarball, [ dir, ]; [ force=false ]) -> dir`
  - `tarball   :: Union{AbstractString, IO}`
  - `dir       :: AbstractString`
  - `force     :: Bool`

Use `?` in the REPL for more detail on how these API functions work.
