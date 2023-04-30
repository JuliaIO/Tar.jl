# Tar.jl

[![Build Status](https://github.com/JuliaIO/Tar.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaIO/Tar.jl/actions/workflows/ci.yml)
[![Codecov](https://codecov.io/gh/JuliaIO/Tar.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaIO/Tar.jl)

The `Tar` package can list, extract and create POSIX TAR archives ("tarballs")
as specified in [POSIX
1003.1-2001](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html).
It is designed to support using the TAR format as a mechanism for sending trees
of files from one system to another, rather than for the historical use case of
backing up files for restoration to the same system. Because of this design
goal, `Tar` intentionally ignores much of the metadata included in the TAR
format, which does not make sense for the data transfer use case. The package
also does not aim to read or create legacy non-POSIX variants of the TAR format,
although it does support reading GNU long name and long link extensions.

## API & Usage

The public API of `Tar` includes five functions and one type:

* `create` — creates a tarball from an on-disk file tree
* `extract` — extracts a tarball to an on-disk file tree
* `list` — lists the contents of a tarball as a vector of `Header` objects
* `rewrite` — rewrite a tarball to the standard format `create` produces
* `tree_hash` — compute a tree hash of the content of a tarball (default: git
  SHA1)
* `Header` — struct representing metadata that `Tar` considers important in a
  TAR entry

None of these are exported, however: the recommended usage is to do `import Tar`
and then access all of these names fully qualified as `Tar.create`,
`Tar.extract` and so on.

<!-- BEGIN: copied from inline doc strings -->

### Tar.create

```jl
create([ predicate, ] dir, [ tarball ]; [ skeleton ]) -> tarball
```
* `predicate :: String --> Bool`
* `dir       :: AbstractString`
* `tarball   :: Union{AbstractString, AbstractCmd, IO}`
* `skeleton  :: Union{AbstractString, AbstractCmd, IO}`

Create a tar archive ("tarball") of the directory `dir`. The resulting archive
is written to the path `tarball` or if no path is specified, a temporary path is
created and returned by the function call. If `tarball` is an IO object then the
tarball content is written to that handle instead (the handle is left open).

If a `predicate` function is passed, it is called on each system path that is
encountered while recursively searching `dir` and `path` is only included in the
tarball if `predicate(path)` is true. If `predicate(path)` returns false for a
directory, then the directory is excluded entirely: nothing under that directory
will be included in the archive.

If the `skeleton` keyword is passed then the file or IO handle given is used as
a "skeleton" to generate the tarball. You create a skeleton file by passing the
`skeleton` keyword to the `extract` command. If `create` is called with that
skeleton file and the extracted files haven't changed, an identical tarball is
recreated. The `skeleton` and `predicate` arguments cannot be used together.

### Tar.extract

```jl
extract(
    [ predicate, ] tarball, [ dir ];
    [ skeleton = <none>, ]
    [ copy_symlinks = <auto>, ]
    [ set_permissions = true, ]
) -> dir
```
* `predicate       :: Header --> Bool`
* `tarball         :: Union{AbstractString, AbstractCmd, IO}`
* `dir             :: AbstractString`
* `skeleton        :: Union{AbstractString, AbstractCmd, IO}`
* `copy_symlinks   :: Bool`
* `set_permissions :: Bool`

Extract a tar archive ("tarball") located at the path `tarball` into the
directory `dir`. If `tarball` is an IO object instead of a path, then the
archive contents will be read from that IO stream. The archive is extracted to
`dir` which must either be an existing empty directory or a non-existent path
which can be created as a new directory. If `dir` is not specified, the archive
is extracted into a temporary directory which is returned by `extract`.

If a `predicate` function is passed, it is called on each `Header` object that
is encountered while extracting `tarball` and the entry is only extracted if the
`predicate(hdr)` is true. This can be used to selectively extract only parts of
an archive, to skip entries that cause `extract` to throw an error, or to record
what is extracted during the extraction process.

Before it is passed to the predicate function, the `Header` object is somewhat
modified from the raw header in the tarball: the `path` field is normalized to
remove `.` entries and replace multiple consecutive slashes with a single slash.
If the entry has type `:hardlink`, the link target path is normalized the same
way so that it will match the path of the target entry; the size field is set to
the size of the target path (which must be an already-seen file).

If the `skeleton` keyword is passed then a "skeleton" of the extracted tarball
is written to the file or IO handle given. This skeleton file can be used to
recreate an identical tarball by passing the `skeleton` keyword to the `create`
function. The `skeleton` and `predicate` arguments cannot be used together.

If `copy_symlinks` is `true` then instead of extracting symbolic links as such,
they will be extracted as copies of what they link to if they are internal to
the tarball and if it is possible to do so. Non-internal symlinks, such as a
link to `/etc/passwd` will not be copied. Symlinks which are in any way cyclic
will also not be copied and will instead be skipped. By default, `extract` will
detect whether symlinks can be created in `dir` or not and will automatically
copy symlinks if they cannot be created.

If `set_permissions` is `false`, no permissions are set on the extracted files.

### Tar.list

```jl
list(tarball; [ strict = true ]) -> Vector{Header}
list(callback, tarball; [ strict = true ])
```
* `callback  :: Header, [ <data> ] --> Any`
* `tarball   :: Union{AbstractString, AbstractCmd, IO}`
* `strict    :: Bool`

List the contents of a tar archive ("tarball") located at the path `tarball`. If
`tarball` is an IO handle, read the tar contents from that stream. Returns a
vector of `Header` structs. See [`Header`](@ref) for details.

If a `callback` is provided then instead of returning a vector of headers, the
callback is called on each `Header`. This can be useful if the number of items
in the tarball is large or if you want examine items prior to an error in the
tarball. If the `callback` function can accept a second argument of either type
`Vector{UInt8}` or `Vector{Pair{Symbol, String}}` then it will be called with a
representation of the raw header data either as a single byte vector or as a
vector of pairs mapping field names to the raw data for that field (if these
fields are concatenated together, the result is the raw data of the header).

By default `list` will error if it encounters any tarball contents which the
`extract` function would refuse to extract. With `strict=false` it will skip
these checks and list all the the contents of the tar file whether `extract`
would extract them or not. Beware that malicious tarballs can do all sorts of
crafty and unexpected things to try to trick you into doing something bad.

If the `tarball` argument is a skeleton file (see `extract` and `create`) then
`list` will detect that from the file header and appropriately list or iterate
the headers of the skeleton file.

### Tar.rewrite

```jl
rewrite([ predicate, ], old_tarball, [ new_tarball ]) -> new_tarball
```
* `predicate   :: Header --> Bool`
* `old_tarball :: Union{AbstractString, AbstractCmd, IO}`
* `new_tarball :: Union{AbstractString, AbstractCmd, IO}`

Rewrite `old_tarball` to the standard format that `create` generates, while also
checking that it doesn't contain anything that would cause `extract` to raise an
error. This is functionally equivalent to doing
```jl
Tar.create(Tar.extract(predicate, old_tarball), new_tarball)
```
However, it never extracts anything to disk and instead uses the `seek` function
to navigate the old tarball's data. If no `new_tarball` argument is passed, the
new tarball is written to a temporary file whose path is returned.

If a `predicate` function is passed, it is called on each `Header` object that
is encountered while extracting `old_tarball` and the entry is skipped unless
`predicate(hdr)` is true. This can be used to selectively rewrite only parts of
an archive, to skip entries that would cause `extract` to throw an error, or to
record what content is encountered during the rewrite process.

Before it is passed to the predicate function, the `Header` object is somewhat
modified from the raw header in the tarball: the `path` field is normalized to
remove `.` entries and replace multiple consecutive slashes with a single slash.
If the entry has type `:hardlink`, the link target path is normalized the same
way so that it will match the path of the target entry; the size field is set to
the size of the target path (which must be an already-seen file).

### Tar.tree_hash

```jl
tree_hash([ predicate, ] tarball;
          [ algorithm = "git-sha1", ]
          [ skip_empty = false ]) -> hash::String
```
* `predicate  :: Header --> Bool`
* `tarball    :: Union{AbstractString, AbstractCmd, IO}`
* `algorithm  :: AbstractString`
* `skip_empty :: Bool`

Compute a tree hash value for the file tree that the tarball contains. By
default, this uses git's tree hashing algorithm with the SHA1 secure hash
function (like current versions of git). This means that for any tarball whose
file tree git can represent—i.e. one with only files, symlinks and non-empty
directories—the hash value computed by this function will be the same as the
hash value git would compute for that file tree. Note that tarballs can
represent file trees with empty directories, which git cannot store, and this
function can generate hashes for those, which will, by default (see `skip_empty`
below for how to change this behavior), differ from the hash of a tarball which
omits those empty directories. In short, the hash function agrees with git on
all trees which git can represent, but extends (in a consistent way) the domain
of hashable trees to other trees which git cannot represent.

If a `predicate` function is passed, it is called on each `Header` object that
is encountered while processing `tarball` and an entry is only hashed if
`predicate(hdr)` is true. This can be used to selectively hash only parts of an
archive, to skip entries that cause `extract` to throw an error, or to record
what is extracted during the hashing process.

Before it is passed to the predicate function, the `Header` object is somewhat
modified from the raw header in the tarball: the `path` field is normalized to
remove `.` entries and replace multiple consecutive slashes with a single slash.
If the entry has type `:hardlink`, the link target path is normalized the same
way so that it will match the path of the target entry; the size field is set to
the size of the target path (which must be an already-seen file).

Currently supported values for `algorithm` are `git-sha1` (the default) and
`git-sha256`, which uses the same basic algorithm as `git-sha1` but replaces the
SHA1 hash function with SHA2-256, the hash function that git will transition to
using in the future (due to known attacks on SHA1). Support for other file tree
hashing algorithms may be added in the future.

The `skip_empty` option controls whether directories in the tarball which
recursively contain no files or symlinks are included in the hash or ignored.
In general, if you are hashing the content of a tarball or a file tree, you care
about all directories, not just non-empty ones, so including these in the
computed hash is the default. So why does this function even provide the option
to skip empty directories? Because git refuses to store empty directories and
will ignore them if you try to add them to a repo. So if you compute a reference
tree hash by by adding files to a git repo and then asking git for the tree
hash, the hash value that you get will match the hash value computed by
`tree_hash` with `skip_empty=true`. In other words, this option allows
`tree_hash` to emulate how git would hash a tree with empty directories. If you
are hashing trees that may contain empty directories (i.e. do not come from a
git repo), however, it is recommended that you hash them using a tool (such as
this one) that does not ignore empty directories.

### Tar.Header

The `Header` type is a struct representing the essential metadata for a single
record in a tar file with this definition:
```jl
struct Header
    path :: String # path relative to the root
    type :: Symbol # type indicator (see below)
    mode :: UInt16 # mode/permissions (best viewed in octal)
    size :: Int64  # size of record data in bytes
    link :: String # target path of a symlink
end
```
Types are represented with the following symbols: `file`, `hardlink`, `symlink`,
`chardev`, `blockdev`, `directory`, `fifo`, or for unknown types, the typeflag
character as a symbol. Note that [`extract`](#Tarextract) refuses to extract
records types other than `file`, `symlink` and `directory`; [`list`](#Tarlist)
will only list other kinds of records if called with `strict=false`.

<!-- END: copied from inline doc strings -->

### Compression

It is typical to compress tarballs when saving or transferring them. In the UNIX
tradition of doing one thing and doing it well, the `Tar` package does not do
any kind of compression and instead makes it easy to compose its API with
external compression tools. The simplest way to read a compressed archive is to
use a command-line tool to decompress it. For example:
```jl
Tar.list(`gzcat $tarball`)
Tar.extract(`gzcat $tarball`)
```
This will spawn the `gzcat $tarball` command, read the uncompressed tarball data
from the output of that process, and then close the process. Creating a tarball
with the `gzip` command is nearly as easy:
```jl
Tar.create(dir, pipeline(`gzip -9`, tarball))
```
This assumes that `dir` is the directory you want to archive and `tarball` is
the path you want to create as a compressed archive.

If you want to compress or decompress a tarball in the same process, you can
use various
[TranscodingStreams](https://github.com/JuliaIO/TranscodingStreams.jl)
packages:
```jl
using CodecZlib

tar_gz = open(tarball, write=true)
tar = GzipCompressorStream(tar_gz)
Tar.create(dir, tar)
close(tar)
```
This assumes that `dir` is the directory you want to archive and `tarball` is
the path you want to create as a compressed archive. You can decompress
in-process in a similar manner:
```jl
using CodecZlib

tar_gz = open(tarball)
tar = GzipDecompressorStream(tar_gz)
dir = Tar.extract(tar)
close(tar)
```
This assumes that `tarball` is the path of the compressed archive you want to
extract.

### API comparison with command-line tar

It might be helpful to compare the `Tar` API with command-line `tar`. Unlike
`tar -c` the `Tar.create` function does not include any of the path you tell it
to bundle in the resulting TAR file: the location of the data is not part of the
data. Doing `Tar.create(dir, tarball)` is roughly equivalent to running the
following `tar` command:
```sh
tar -f $tarball -C $dir -c $(cd $dir; ls -A)
```
In other words, `tar` is told to change into the directory  `dir` before
constructing the tarball and then include all the top-level items in that
directory without any path prefix. Note that the above command does not fully
emulate the behavior of `Tar.create`: it does not sort entries in the same order
and it still records user and group information, modification times and exact
permissions. Coaxing command-line `tar` programs to omit this non-portable
information and use a portable (and `git`-compatible sort order) is non-trivial.

On the extraction side of things, doing `Tar.extract(tarball, dir)` is roughly
equivalent to the following commands:
```sh
test -d $dir || mkdir $dir
tar -f $tarball -C $dir -mx
```
Again, `tar` is told to change into the directory `dir` before extracting the
tarball and to extract each path relative to that directory. The `-m` option
tells `tar` to ignore the modification times recorded in the tarball and just
let files and directories have their natural modification times.

If the current user has elevated privileges, the `tar` command will attempt to
change the owner and group of files to what is recorded in the tarball, whereas
`Tar.extract` will never do that. The `tar` command may also try to restore
permissions without respecting the current `umask` if the user is an
administrator. Again, `Tar.extract` will never do that—it behaves the same way
for any users: by ignoring any user/group/permission information, aside from
whether plain files are executable by their owner or not. To suppress these
behaviors with GNU tar, you can use the `--no-same-owner` and
`--no-same-permissions` options; these options are not broadly supported by
other `tar` commands, which may not have options to support these behaviors.

## Design & Features

Unlike the `tar` command line tool, which was originally designed to archive
data in order to restore it back to the same system or to a replica thereof, the
`Tar` package is designed for using the TAR format to transfer trees of files
and directories from one system to another. This design goal means that some
metadata fields supported by the TAR format and used by default by historical
`tar` tools are not used or supported by `Tar`. In short, the choice of features
and defaults for `Tar` are designed to support transfer of data, rather than
backup and restoration.

The TAR format can, for example, record the name and ID of the user that owns
each file. Recording this information makes perfect sense when using tarballs
for backup: the `tar` program should run as root when restoring data, so it can
restore the original owner of each file and directory. On the other hand, this
ownership information is of no use when using the TAR format to transfer data
from one system to another: the user names and IDs will not generally be the
same on different systems, and the tool should _not_ be run as `root`, so it
cannot change the owner of anything it extracts. For data transfer, ownership
metadata should be disregarded and need not be recorded in the first place.

Similarly, it makes little sense, when using tarballs for data transfer, to copy
the modification time of each file from the source system. Those time stamps are
unlikely to be relevant on the destination system, and in some cases, clock skew
between the systems could mean that time stamps from the source appear to be in
the future at the destination. This can confuse some programs and may even be
perceived as an attempted security breach; most `tar` command line tools print
warnings when extracting files with time stamps from the future. When using the
TAR format for data transfer, it is better to ignore time stamps and just let
the extracted contents have natural modification times.

The features and defaults of the `Tar` package are guided by the principle that
it uses the TAR format for transmitting data, not as a tool for backup and
restoration. If you want to use the TAR format for archival purposes, you are
likely better off using a traditional command line tool like [GNU
tar](https://www.gnu.org/software/tar/). If, on the other hand, you want to use
the TAR format to transmit data from one system to another, then you've come to
the right place.

### File Types

Since `Tar` is designed for transmission of file and directory trees, it
supports only the following file types:

* plain files
* directories
* symlinks
* hardlinks (extracted as copies)

The `Tar` package does not support other file types that the TAR format can
represent, including: character devices, block devices, and FIFOs. If you
attempt to create or extract an archive that contains any of these kinds of
entries, `Tar` will raise an error. You can, however, list the contents of a
tarball containing other kinds of entries by passing the `strict=false` flag to
the `list` function; without this option, `list` raises the same error as
`extract` would.

### Time Stamps

Also in accordance with its design goal as a data transfer tool, the `Tar`
package does not record or set modification times upon tarball creation and
extraction. When creating a tarball, it sets the time stamp of each entry to
`0`, representing the UNIX epoch (Jan 1st, 1970). When extracting a tarball, it
ignores the time stamps of entries and lets all extracted content have "natural"
modification times based on when each file or directory is extracted.

In the future, optional support may be added for recording and restoring time
stamps.

### Users & Groups

`Tar` ignores user and group names and IDs when creating and extracting
tarballs. This is due to two facts:

* names and IDs on source and destination systems will generally not match;
* names and IDs can only be changed if `Tar` is run with elevated privileges.

The first fact means that it probably doesn't make sense to try to restore
ownership when transferring data, while the second fact means that it's probably
not possible. Accordingly, `Tar` disregards user and group names and IDs when
creating and extracting tarballs. During creation, the ID fields are recorded as
`0` and names fields are recorded as the empty string. When extracting a
tarball, the user and group fields are ignored entirely and all extracted
content is owned by the current user.

It is unlikely that support will be added for recording or restoring ownership
of files or directories since that functionality only makes sense when using the
TAR format for backup, a purpose better served by using a command line `tar`
tool.

### Permissions

When it comes to permissions, `Tar` records and restores only one significant
bit of information: whether plain files are executable by their owner or not. No
permission information is recorded or restored for directories or symlinks. This
one bit of information is supported on most file systems and platforms, and is
(not by coincidence) the only information that `git` records. This choice makes
`Tar`'s behavior as portable as possible and means that it is safe to extract
and use the contents of tarballs even if they were generated with unsafe
permission combinations such as `0o777`, i.e. world writable and executable.
Modes are normalized in the following manner for both creation and extraction:

* files not executable by owner are archived/restored with mode `0o644`;
* files executable by owner are archived/restored with mode `0o755`;
* directories and symlinks are archived with mode `0o755`;
* directories and symlinks are restored with default modes.

When extracting tarball contents, `Tar` respects the system
[umask](https://en.wikipedia.org/wiki/Umask) (or similar administrative
permission limits on non-POSIX systems), so the exact permissions of extracted
tree contents may be *less* permissive than the above but should never be more
permissive. If you observe `Tar` extracting any tarball contents with more
permissive modes than this, please file an issue.

When using Julia versions prior to 1.6 on Windows, support for querying and
setting the executable bit is broken, so all files are created as executable.
Julia versions 1.6 and greater can correctly read and write executable
permissions using Windows ACLs, so tarballs created and extracted on Windows
should have appropriate permissions.

In the future, optional support may be added for recording or restoring exact
permission modes to the extent that such permissions are supported on those
systems. On non-POSIX systems, permissions will necessarily be an approximation
of POSIX mode strings as supported by those systems.

### Reproducibility

The information that `Tar` records about permissions is the same information
that `git` considers to be significant when recording and hashing tree contents
(admittedly not by coincidence). As a result, an important and useful
consequence of `Tar`'s design is that it has the following properties:

* if you create a tarball from a file tree and extract it, the new tree will
  have the same `git` tree hash as the original;
* if you `git checkout` a file tree and archive it using `Tar`, the resulting
  TAR archive file is always the same.

One important caveat to keep in mind is that `git` ignores directories that
recursively contain only directories—_i.e._ unless there's a file or a symlink
somewhere, `git` will not acknowledge the existence of a subdirectory. This
means that two trees with the same `git` tree hash can produce different
tarballs if they differ by subdirectories containing no files or symlinks: `git`
will ignore those subdirectories, while `Tar` will not. Therefore, they will
have the same `git` tree hash, but produce different tarballs. Two _identical_
file trees will always produce identical tarballs, however, and that tarball
should remain stable in future versions of the `Tar` package.

**Note:** the canonical tarball format was [changed] slightly in the 1.10
release of the package. Since that release, the canonical format _includes_ all
directories in the canonical tarball format, whereas previously non-empty
directories were omitted since their existence is implied by their contents. The
absence of explicit directory entries in tarballs confused some external
tooling, so it was deemed worth a small format change to avoid such problems.

[changed]: https://github.com/JuliaIO/Tar.jl/pull/106

The `tree_hash` function can be used to compute a git-style tree hash of the
contents of a tarball (without needing to extract it). Moreover, two tarballs
created by the `Tar` package will have the same hash if and only if they contain
the same file tree, which is true if and only if they are identical tarballs.
You can, however, hash tarballs not created by `Tar` this way to see if they
represent the same file tree, and you can use the `skip_empty=true` option to
`tree_hash` to compute the hash that `git` would assign the tree, ignoring empty
directories.
