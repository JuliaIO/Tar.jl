# Tar.jl

[![Build Status](https://travis-ci.org/JuliaLang/Tar.jl.svg?branch=master)](https://travis-ci.org/JuliaLang/Tar.jl)
[![Codecov](https://codecov.io/gh/JuliaLang/Tar.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaLang/Tar.jl)

The `Tar` package can list, extract and create POSIX TAR archives ("tarballs") as specified in [POSIX 1003.1-2001](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html).
It is designed to support using the TAR format as a mechanism for sending trees of files from one system to another, rather than for the historical use case of backing up files for restoration to the same system.
Because of this design goal, `Tar` intentionally ignores much of the metadata included in the TAR format, which does not make sense for the data transfer use case.
The package also does not aim to read or create legacy non-POSIX variants of the TAR format, although it does support reading GNU long name and long link extensions.

## Design & Features

Unlike the `tar` command line tool, which was originally designed to archive data in order to restore it back to the same system or to a replica thereof, the `Tar` package is designed for using the TAR format to transfer trees of files and directories from one system to another.
This design goal means that some metadata fields supported by the TAR format and used by default by historical `tar` tools are not used or supported by `Tar`.
In short, the choice of features and defaults for `Tar` are designed to support transfer of data, rather than backup and restoration.

The TAR format can, for example, record the name and ID of the user that owns each file.
Recording this information makes perfect sense when using tarballs for backup:
the `tar` program should run as root when restoring data, so it can restore the original owner of each file and directory.
On the other hand, this ownership information is of no use when using the TAR format to transfer data from one system to another:
the user names and IDs will not generally be the same on different systems, and the tool should _not_ be run as `root`, so it cannot change the owner of anything it extracts.
For data transfer, ownership metadata should be disregarded and need not be recorded in the first place.

Similarly, it makes little sense, when using tarballs for data transfer, to copy the modification time of each file from the source system.
Those time stamps are unlikely to be relevant on the destination system, and in some cases, clock skew between the systems could mean that time stamps from the source appear to be in the future at the destination.
This can confuse some programs and may even be perceived as an attempted security breach;
most `tar` command line tools print warnings when extracting files with time stamps from the future.
When using the TAR format for data transfer, it is better to ignore time stamps and just let the extracted contents have natural modification times.

The features and defaults of the `Tar` package are guided by the principle that it uses the TAR format for transmitting data, not as a tool for backup and restoration.
If you want to use the TAR format for archival purposes, you are likely better off using a traditional command line tool like [GNU tar](https://www.gnu.org/software/tar/).
If, on the other hand, you want to use the TAR format to transmit data from one system to another, then you've come to the right place.

### File Types

Since `Tar` is designed for transmission of file and directory trees, it supports only the following file types:

* plain files
* directories
* symlinks

The `Tar` package does not support other file types that the TAR format can represent, including: hard links, character devices, block devices, and FIFOs.
If you attempt to create or extract an archive that contains any of these kinds of entries, `Tar` will raise an error.
You can, however, list the contents of a tarball containing other kinds of entries by passing the `strict=false` flag to the `list` function; without this option, `list` raises the same error as `extract` would.

In the future, optional support may be added for using hard links within archives to avoid duplicating identical files.

### Time Stamps

Also in accordance with its design goal as a data transfer tool, the `Tar` package does not record or set modification times upon tarball creation and extraction.
When creating a tarball, it sets the time stamp of each entry to `0`, representing the UNIX epoch (Jan 1st, 1970).
When extracting a tarball, it ignores the time stamps of entries and lets all extracted content have "natural" modification times based on when each file or directory is extracted.

In the future, optional support may be added for recording and restoring time stamps.

### Users & Groups

`Tar` ignores user and group names and IDs when creating and extracting tarballs.
This is due to two facts:

* names and IDs on source and destination systems will generally not match;
* names and IDs can only be changed if `Tar` is run with elevated privileges.

The first fact means that it probably doesn't make sense to try to restore ownership when transferring data, while the second fact means that it's probably not possible.
Accordingly, `Tar` disregards user and group names and IDs when creating and extracting tarballs.
During creation, the ID fields are recorded as `0` and names fields are recorded as the empty string.
When extracting a tarball, the user and group fields are ignored entirely and all extracted content is owned by the current user.

It is unlikely that support will be added for recording or restoring ownership of files or directories since that functionality only makes sense when using the TAR format for backup, a purpose better served by using a command line `tar` tool.

### Permissions

When it comes to permissions, `Tar` records and restores only one significant bit of information:
whether plain files are executable by their owner or not.
No permission information is recorded or restored for directories or symlinks.
This one bit of information is the only one which makes sense across all platforms, so this choice makes `Tar`'s behavior as portable as possible.
(Unfortunately, this is currently broken on Windows since `libuv` does not correctly support querying or changing the user executable "bit"; this is actively being worked on, however, and should be fixed in future versions of Julia.)

Modes are normalized in the following manner for both tarball creation and extraction:

* files that are not executable by the owner are archived/restored with mode `0o644`;
* files that are executable by the owner are archived/restored with mode `0o755`;
* directories and symlinks are always archived/restored with mode `0o755`.

On systems (like Windows) that do not use POSIX modes, whatever permissions mechanism exists (_e.g._ ACLs) should be queried/modified to determine/set whether each file is executable by its owner or not.

In the future, optional support may be added for recording and applying exact permission modes on POSIX systems.

### Reproducibility

The information that `Tar` records about permissions is the same information that `git` considers to be significant when recording and hashing tree contents (admittedly not by coincidence).
As a result, an important and useful consequence of `Tar`'s design is that it has the following properties:

* if you create a tarball from a file tree and extract it, the new tree will have the same `git` tree hash as the original;
* if you `git checkout` a file tree and archive it using `Tar`, the resulting TAR archive file is always the same.

One important caveat to keep in mind is that `git` ignores directories that recursively contain only directories—_i.e._ unless there's a file or a symlink somewhere, `git` will not acknowledge the existence of a subdirectory.
This means that two trees with the same `git` tree hash can produce different tarballs if they differ by subdirectories containing no files or symlinks:
`git` will ignore those subdirectories, while `Tar` will not.
Therefore, they will have the same `git` tree hash, but produce different tarballs.
Two _identical_ file trees will always produce identical tarballs, however, and that tarball should remain stable in future versions of the `Tar` package.

## API & Usage

The public API of `Tar` includes three functions and one type:

* `create` — creates a tarball from an on-disk file tree
* `extract` — extracts a tarball to an on-disk file tree
* `list` — lists the contents of a tarball as a vector of `Header` objects
* `Header` — struct representing metadata that `Tar` considers important in a TAR entry

None of these are exported, however: the recommended usage is to do `import Tar` and then access all of these names fully qualified as `Tar.create`, `Tar.extract` and so on.

<!-- BEGIN: copied from inline doc strings -->

### Tar.create

    create([ predicate, ] dir, [ tarball ]) -> tarball

* `predicate :: Function`
* `dir       :: AbstractString`
* `tarball   :: Union{AbstractString, IO}`

Create a tar archive ("tarball") of the directory `dir`. The resulting archive
is written to the path `tarball` or if no path is specified, a temporary path is
created and returned by the function call. If `tarball` is an IO object then the
tarball content is written to that handle instead (the handle is left open).

If a `predicate` function is passed, it is called on each system path that is
encountered while recursively searching `dir` and `path` is only included in the
tarball if `predicate(path)` is true.

### Tar.extract

    extract(tarball, [ dir ]) -> dir

* `tarball   :: Union{AbstractString, IO}`
* `dir       :: AbstractString`

Extract a tar archive ("tarball") located at the path `tarball` into the
directory `dir`. If `tarball` is an IO object instead of a path, then the
archive contents will be read from that IO stream. The archive is extracted to
`dir` which must either be an existing empty directory or a non-existent path
which can be created as a new directory. If `dir` is not specified, the archive
is extracted into a temporary directory which is returned by `extract`.

### Tar.list

    list(tarball; [ strict = true ]) -> Vector{Header}

* `tarball   :: Union{AbstractString, IO}`
* `strict    :: Bool`

List the contents of a tar archive ("tarball") located at the path `tarball`.
If `tarball` is an IO handle, read the tar contents from that stream. Returns
a vector of `Header` structs. See [`Header`](#TarHeader) for details.

By default `list` will error if it encounters any tarball contents which the
`extract` function would refuse to extract. With `strict=false` it will skip
these checks and list all the the contents of the tar file whether `extract`
would extract them or not. Beware that malicious tarballs can do all sorts of
crafty and unexpected things to try to trick you into doing something bad.

### Tar.Header

The `Header` type is a struct representing the essential metadata for a single
record in a tar file with this definition:

    struct Header
        path :: String # path relative to the root
        type :: Symbol # type indicator (see below)
        mode :: UInt16 # mode/permissions (best viewed in octal)
        size :: Int64  # size of record data in bytes
        link :: String # target path of a symlink
    end

Types are represented with the following symbols: `file`, `hardlink`, `symlink`,
`chardev`, `blockdev`, `directory`, `fifo`, or for unknown types, the typeflag
character as a symbol. Note that [`extract`](#Tarextract) refuses to extract records
types other than `file`, `symlink` and `directory`; [`list`](#Tarlist) will only
list other kinds of records if called with `strict=false`.

<!-- END: copied from inline doc strings -->

### API comparison with command-line tar

It might be helpful to compare the `Tar` API with command-line `tar`.
Unlike `tar -c` the `Tar.create` function does not include any of the path you tell it to bundle in the resulting TAR file:
the location of the data is not part of the data.
Doing `Tar.create(dir, tarball)` is roughly equivalent to running the following `tar` command:
```sh
tar -f $tarball -C $dir -c $(cd $dir; ls -A)
```
In other words, `tar` is told to change into the directory  `dir` before constructing the tarball and then include all the top-level items in that directory without any path prefix.
Note that the above command does not fully emulate the behavior of `Tar.create`:
it does not sort entries in the same order and it still records user and group information, modification times and exact permissions.
Coaxing command-line `tar` programs to omit this non-portable information and use a portable (and `git`-compatible sort order) is non-trivial.

Another difference from command-line `tar`:
non-empty directories are also omitted from the tarballs that `Tar` creates since no metadata is recorded about directories aside from the fact that they exist and the existence of non-empty directories is already implied by the fact that they contain something else.
If, in the future, the ability to record metadata about directories is added, tarballs will record entries for non-empty directories with non-default metadata.

On the extraction side of things, doing `Tar.extract(tarball, dir)` is roughly equivalent to the following commands:
```sh
test -d $dir || mkdir $dir
tar -f $tarball -C $dir -mx
```
Again, `tar` is told to change into the directory `dir` before extracting the tarball and to extract each path relative to that directory.
The `-m` option tells `tar` to ignore the modification times recorded in the tarball and just let files and directories have their natural modification times.

If the current user has elevated privileges, the `tar` command will attempt to change the owner and group of files to what is recorded in the tarball, whereas `Tar.extract` will never do that.
The `tar` command may also try to restore permissions without respecting the current `umask` if the user is an administrator.
Again, `Tar.extract` will never do that—it behaves the same way for any users:
by ignoring any user/group/permission information, aside from whether plain files are executable by their owner or not.
To suppress these behaviors with GNU tar, you can use the `--no-same-owner` and `--no-same-permissions` options;
these options are not broadly supported by other `tar` commands, which may not have options to support these behaviors.
