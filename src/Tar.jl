module Tar

# 2 MiB to take advantage of THP if enabled
const DEFAULT_BUFFER_SIZE = 2 * 1024 * 1024

# TODO: add some version of this method to Base
function Base.skip(io::Union{Base.Process, Base.ProcessChain}, n::Integer)
    n < 0 && throw(ArgumentError("cannot skip backwards when reading from a process"))
    isempty(skip_buffer) && resize!(skip_buffer, DEFAULT_BUFFER_SIZE)
    while n > 0
        n -= readbytes!(io, skip_buffer, min(n, length(skip_buffer)))
    end
    return io
end
const skip_buffer = UInt8[]

include("header.jl")
include("create.jl")
include("extract.jl")

## some API utilities ##

const true_predicate = _ -> true

open_read(f::Function, file::AbstractString) = open(f, file)
open_read(f::Function, file::IO) = f(file)

function open_write(f::Function, file::AbstractString)
    try open(f, file, write=true)
    catch
        rm(file, force=true)
        rethrow()
    end
    return file
end
function open_write(f::Function, file::Nothing)
    file, io = mktemp()
    try f(io)
    catch
        close(io)
        rm(file, force=true)
        rethrow()
    end
    close(io)
    return file
end
function open_write(f::Function, file::IO)
    f(file)
    return file
end

## official API: create, list, extract, rewrite, tree_hash

"""
    create([ predicate, ] dir, [ tarball ]) -> tarball

        predicate :: String --> Bool
        dir       :: AbstractString
        tarball   :: Union{AbstractString, IO}

Create a tar archive ("tarball") of the directory `dir`. The resulting archive
is written to the path `tarball` or if no path is specified, a temporary path is
created and returned by the function call. If `tarball` is an IO object then the
tarball content is written to that handle instead (the handle is left open).

If a `predicate` function is passed, it is called on each system path that is
encountered while recursively searching `dir` and `path` is only included in the
tarball if `predicate(path)` is true. If `predicate(path)` returns false for a
directory, then the directory is excluded entirely: nothing under that directory
will be included in the archive.
"""
function create(
    predicate::Function,
    dir::AbstractString,
    tarball::Union{AbstractString, IO, Nothing} = nothing,
)
    check_create_dir(dir)
    open_write(tarball) do tar
        create_tarball(predicate, tar, dir)
    end
end

function create(
    dir::AbstractString,
    tarball::Union{AbstractString, IO, Nothing} = nothing,
)
    create(true_predicate, dir, tarball)
end

"""
    list(tarball; [ strict = true ]) -> Vector{Header}
    list(callback, tarball; [ strict = true ])

        callback  :: Header --> Bool
        tarball   :: Union{AbstractString, IO}
        strict    :: Bool

List the contents of a tar archive ("tarball") located at the path `tarball`. If
`tarball` is an IO handle, read the tar contents from that stream. Returns a
vector of `Header` structs. See [`Header`](@ref) for details. If a `callback` is
provided then instead of returning a vector of headers, the callback is called
on each `Header`. This can be useful if the number of items in the tarball is
large or if you want examine items prior to an error in the tarball.

By default `list` will error if it encounters any tarball contents which the
`extract` function would refuse to extract. With `strict=false` it will skip
these checks and list all the the contents of the tar file whether `extract`
would extract them or not. Beware that malicious tarballs can do all sorts of
crafty and unexpected things to try to trick you into doing something bad.
"""
function list(
    callback::Function,
    tarball::Union{AbstractString, IO};
    raw::Bool = false,
    strict::Bool = !raw,
)
    raw && strict &&
        error("`raw=true` and `strict=true` options are incompatible")
    read_hdr = raw ? read_standard_header : read_header
    open_read(tarball) do tar
        iterate_headers(callback, tar, read_hdr, strict=strict)
    end
end

function list(
    tarball::Union{AbstractString, IO};
    raw::Bool = false,
    strict::Bool = !raw,
)
    headers = Header[]
    list(tarball, raw=raw, strict=strict) do hdr
        push!(headers, hdr)
    end
    return headers
end

"""
    extract([ predicate, ] tarball, [ dir ]) -> dir

        predicate :: Header --> Bool
        tarball   :: Union{AbstractString, IO}
        dir       :: AbstractString

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
"""
function extract(
    predicate::Function,
    tarball::Union{AbstractString, IO},
    dir::Union{AbstractString, Nothing} = nothing,
)
    check_extract_tarball(tarball)
    check_extract_dir(dir)
    open_read(tarball) do tar
        if dir !== nothing && ispath(dir)
            extract_tarball(predicate, tar, dir)
        else
            if dir === nothing
                dir = mktempdir()
            else
                mkdir(dir)
            end
            try extract_tarball(predicate, tar, dir)
            catch
                chmod(dir, 0o700, recursive=true)
                rm(dir, force=true, recursive=true)
                rethrow()
            end
        end
    end
    return dir::AbstractString
end

function extract(
    tarball::Union{AbstractString, IO},
    dir::Union{AbstractString, Nothing} = nothing,
)
    extract(true_predicate, tarball, dir)
end

"""
    rewrite([ predicate, ], old_tarball, [ new_tarball ]) -> new_tarball

        predicate   :: Header --> Bool
        old_tarball :: Union{AbstractString, IO}
        new_tarball :: Union{AbstractString, IO}

Rewrite `old_tarball` to the standard format that `create` generates, while also
checking that it doesn't contain anything that would cause `extract` to raise an
error. This is functionally equivalent to doing

    Tar.create(Tar.extract(predicate, old_tarball), new_tarball)

However, it never extracts anything to disk and instead uses the `seek` function
to navigate the old tarball's data. If no `new_tarball` argument is passed, the
new tarball is written to a temporary file whose path is returned.

If a `predicate` function is passed, it is called on each `Header` object that
is encountered while extracting `old_tarball` and the entry is skipped unless
`predicate(hdr)` is true. This can be used to selectively rewrite only parts of
an archive, to skip entries that would cause `extract` to throw an error, or to
record what content is encountered during the rewrite process.
"""
function rewrite(
    predicate::Function,
    old_tarball::Union{AbstractString, IO},
    new_tarball::Union{AbstractString, IO, Nothing} = nothing,
)
    old_tarball = check_rewrite_old_tarball(old_tarball)
    open_read(old_tarball) do old_tar
        open_write(new_tarball) do new_tar
            rewrite_tarball(predicate, old_tar, new_tar)
        end
    end
end

function rewrite(
    old_tarball::Union{AbstractString, IO},
    new_tarball::Union{AbstractString, IO, Nothing} = nothing,
)
    rewrite(true_predicate, old_tarball, new_tarball)
end

"""
    tree_hash([ predicate, ] tarball;
              [ algorithm = "git-sha1", ]
              [ skip_empty = false ]) -> hash::String

        predicate  :: Header --> Bool
        tarball    :: Union{AbstractString, IO}
        algorithm  :: AbstractString
        skip_empty :: Bool

Compute a tree hash value for the file tree that the tarball contains. By
default, this uses git's tree hashing algorigthm with the SHA1 secure hash
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

Currently supported values for `algorithm` are `git-sha1` (the default) and
`git-sha256`, which uses the same basic algorithm as `git-sha1` but replaces the
SHA1 hash function with SHA2-256, the hash function that git will transition to
using in the future (due to known attacks on SHA1). Support for other file tree
hashing algorithms may be added in the future.

The `skip_empty` option controls whether directories in the tarball which
recursiviely contain no files or symlinks are included in the hash or ignored.
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
"""
function tree_hash(
    predicate::Function,
    tarball::Union{AbstractString, IO};
    algorithm::AbstractString = "git-sha1",
    skip_empty::Bool = false,
)
    HashType =
        algorithm == "git-sha1"   ? SHA.SHA1_CTX :
        algorithm == "git-sha256" ? SHA.SHA256_CTX :
            error("invalid tree hashing algorithm: $algorithm")

    check_tree_hash_tarball(tarball)
    open_read(tarball) do tar
        git_tree_hash(predicate, tar, HashType, skip_empty)
    end
end

function tree_hash(
    tarball::Union{AbstractString, IO};
    algorithm::AbstractString = "git-sha1",
    skip_empty::Bool = false,
)
    tree_hash(
        true_predicate,
        tarball,
        algorithm = algorithm,
        skip_empty = skip_empty,
    )
end

## error checking utility functions

check_create_dir(dir::AbstractString) =
    isdir(dir) || error("""
    not a directory: $dir
    USAGE: create([predicate,] dir, [tarball])
    """)

check_list_tarball(tarball::AbstractString) =
    isfile(tarball) || error("""
    not a file: $tarball
    USAGE: list(tarball)
    """)

check_extract_tarball(tarball::AbstractString) =
    isfile(tarball) || error("""
    not a file: $tarball
    USAGE: extract([predicate,] tarball, [dir])
    """)

check_extract_tarball(tarball::IO) = nothing

function check_extract_dir(dir::AbstractString)
    st = stat(dir)
    ispath(st) && !isdir(st) &&
        error("""
        not a directory: $dir
        USAGE: extract([predicate,] tarball, [dir])
        """)
    isdir(st) && !isempty(readdir(dir)) &&
        error("""
        directory not empty: $dir
        USAGE: extract([predicate,] tarball, [dir])
        """)
end

check_extract_dir(dir::Nothing) = nothing

check_rewrite_old_tarball(tarball::AbstractString) =
    isfile(tarball) ? tarball : error("""
    not a file: $tarball
    USAGE: rewrite([predicate,] old_tarball, [new_tarball])
    """)

check_rewrite_old_tarball(tarball::IO) =
    applicable(seek, tarball, 0) ? tarball : IOBuffer(read(tarball))

check_tree_hash_tarball(tarball::AbstractString) =
    isfile(tarball) || error("""
    not a file: $tarball
    USAGE: tree_hash([predicate,] tarball)
    """)

check_tree_hash_tarball(tarball::IO) = nothing

end # module
