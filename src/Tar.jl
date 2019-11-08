module Tar

# TODO: add some version of this method to Base
function Base.skip(io::Union{Base.Process, Base.ProcessChain}, n::Integer)
    n < 0 && throw(ArgumentError("cannot skip backwards when reading from a process"))
    for _ = 1:n
        read(io, UInt8)
    end
end

include("header.jl")
include("create.jl")
include("extract.jl")

## official API: create, list, extract

"""
    create([ predicate, ] dir, [ tarball, ]) -> tarball

        predicate :: Function
        dir       :: AbstractString
        tarball   :: Union{AbstractString, IO}

Create a tar archive ("tarball") of the directory `dir`. The resulting archive
is written to the path `tarball` or if no path is specified, a temporary path is
created and returned by the function call. If `tarball` is an IO object then the
tarball content is written to that handle instead (the handle is left open).

If a `predicate` function is passed, it is called on each system path that is
encountered while recursively searching `dir` and `path` is only included in the
tarball if `predicate(path)` is true.
"""
function create(predicate::Function, dir::AbstractString, tarball::AbstractString)
    create_dir_check(dir)
    open(tarball, write=true) do out
        write_tarball(predicate, out, dir)
    end
    return tarball
end

function create(predicate::Function, dir::AbstractString, tarball::IO)
    create_dir_check(dir)
    write_tarball(predicate, dir, out)
    return tarball
end

function create(predicate::Function, dir::AbstractString)
    create_dir_check(dir)
    tarball, out = mktemp()
    write_tarball(predicate, out, dir)
    close(out)
    return tarball
end

create(dir::AbstractString, tarball::Union{AbstractString, IO}) =
    create(p->true, dir, tarball)
create(dir::AbstractString) = create(p->true, dir)

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
function list(tarball::AbstractString; strict::Bool=true)
    list_tarball_check(tarball)
    open(tarball) do io
        list_tarball(io, strict=strict)
    end
end

list(tarball::IO; strict::Bool=true) = list_tarball(tarball, strict=strict)

"""
    extract(tarball, [ dir, ]; [ force=false ]) -> dir

        tarball   :: Union{AbstractString, IO}
        dir       :: AbstractString
        force     :: Bool

Extract a tar archive ("tarball") located at the path `tarball` into the
directory `dir`. If `tarball` is an IO object instead of a path, then the
archive contents will be read from that IO stream. The archive is extracted to
`dir` which must either be an existing writeable directory or a path which can
be created as a directory with `mkdir`. By default, `extract` will refuse to
extract into a non-empty directory, but the `force=true` option allows this. If
`dir` is not specified, the archive is extracted into a temporary directory
which is returned by the `extract` function call.
"""
function extract(tarball::AbstractString, dir::AbstractString=mktempdir(); force::Bool=false)
    extract_tarball_check(tarball)
    extract_dir_check(dir, force=force)
    open(tarball) do io
        extract_tarball(io, dir)
    end
    return dir
end

function extract(tarball::IO, dir::AbstractString = mktempdir(); force::Bool=false)
    extract_dir_check(dir, force=force)
    extract_tarball(tarball, dir)
    return dir
end

## error checking utility functions

create_dir_check(dir::AbstractString) = isdir(dir) ||
        error("not a directory: $dir\nUSAGE: create([predicate,] dir, [tarball])")

list_tarball_check(tarball::AbstractString) = isfile(tarball) ||
    error("not a file: $tarball\nUSAGE: list(tarball)")

extract_tarball_check(tarball::AbstractString) = isfile(tarball) ||
    error("not a file: $tarball\nUSAGE: extract(tarball, [dir])")

function extract_dir_check(dir::AbstractString; force::Bool=false)
    st = stat(dir)
    if !isdir(st)
        ispath(st) &&
            error("not a directory: $dir\nUSAGE: extract(tarball, [dir])")
        mkdir(dir)
    else
        force || isempty(readdir(dir)) ||
            error("directory not empty: $dir\n USAGE: extract(tarball, [dir])")
    end
end

end # module
