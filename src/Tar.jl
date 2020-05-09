module Tar

# TODO: add some version of this method to Base
function Base.skip(io::Union{Base.Process, Base.ProcessChain}, n::Integer)
    n < 0 && throw(ArgumentError("cannot skip backwards when reading from a process"))
    for _ = 1:n
        read(io, UInt8)
    end
end

# 2 MiB to take advantage of THP if enabled
const DEFAULT_BUFFER_SIZE = 2 * 1024 * 1024

include("header.jl")
include("create.jl")
include("extract.jl")

const true_predicate = _ -> true

## official API: create, list, extract

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
function create(predicate::Function, dir::AbstractString, tarball::AbstractString)
    create_dir_check(dir)
    try open(tarball, write=true) do out
            write_tarball(predicate, out, dir)
        end
    catch
        rm(tarball, force=true)
        rethrow()
    end
    return tarball
end

function create(predicate::Function, dir::AbstractString, tarball::IO)
    create_dir_check(dir)
    write_tarball(predicate, tarball, dir)
    return tarball
end

function create(predicate::Function, dir::AbstractString)
    create_dir_check(dir)
    tarball, out = mktemp()
    try write_tarball(predicate, out, dir)
    catch
        close(out)
        rm(tarball, force=true)
        rethrow()
    end
    close(out)
    return tarball
end

create(dir::AbstractString, tarball::Union{AbstractString, IO}) =
    create(true_predicate, dir, tarball)
create(dir::AbstractString) =
    create(true_predicate, dir)

"""
    list(tarball; [ strict = true ]) -> Vector{Header}

        tarball   :: Union{AbstractString, IO}
        strict    :: Bool

List the contents of a tar archive ("tarball") located at the path `tarball`.
If `tarball` is an IO handle, read the tar contents from that stream. Returns
a vector of `Header` structs. See [`Header`](@ref) for details.

By default `list` will error if it encounters any tarball contents which the
`extract` function would refuse to extract. With `strict=false` it will skip
these checks and list all the the contents of the tar file whether `extract`
would extract them or not. Beware that malicious tarballs can do all sorts of
crafty and unexpected things to try to trick you into doing something bad.
"""
function list(tarball::AbstractString; raw::Bool=false, strict::Bool=!raw)
    list_tarball_check(tarball)
    open(tarball) do io
        list_tarball(io, raw=raw, strict=strict)
    end
end

list(tarball::IO; raw::Bool=false, strict::Bool=!raw) =
    list_tarball(tarball, raw=raw, strict=strict)

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
    dir::AbstractString,
)
    extract_tarball_check(tarball)
    extract_dir_check(dir)
    if ispath(dir)
        extract_tarball(predicate, tarball, dir)
    else
        mkdir(dir)
        extract_tarball_with_cleanup(predicate, tarball, dir)
    end
    return dir
end

function extract(predicate::Function, tarball::Union{AbstractString, IO})
    extract_tarball_check(tarball)
    dir = mktempdir()
    extract_tarball_with_cleanup(predicate, tarball, dir)
    return dir
end

extract(tarball::Union{AbstractString, IO}, dir::AbstractString) =
    extract(true_predicate, tarball, dir)
extract(tarball::Union{AbstractString, IO}) =
    extract(true_predicate, tarball)

function extract_tarball_with_cleanup(
    predicate::Function,
    tarball::Union{AbstractString, IO},
    dir::AbstractString,
)
    try extract_tarball(predicate, tarball, dir)
    catch
        rm(dir, force=true, recursive=true)
        rethrow()
    end
end

## error checking utility functions

create_dir_check(dir::AbstractString) = isdir(dir) ||
    error("""
    not a directory: $dir
    USAGE: create([predicate,] dir, [tarball])
    """)

list_tarball_check(tarball::AbstractString) = isfile(tarball) ||
    error("""
    not a file: $tarball
    USAGE: list(tarball)
    """)

extract_tarball_check(tarball::AbstractString) = isfile(tarball) ||
    error("""
    not a file: $tarball
    USAGE: extract([predicate,] tarball, [dir])
    """)

extract_tarball_check(tarball::IO) = nothing

function extract_dir_check(dir::AbstractString)
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

end # module
