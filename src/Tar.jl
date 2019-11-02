module Tar

include("write.jl")
include("read.jl")

"""
    create([ predicate, ] dir, [ tarball, ]) -> tarball

        predicate :: Function
        dir       :: AbstractString
        tarball   :: AbstractString

Create a tar archive ("tarball") of the directory `dir`. The resulting archive
is written to the path `tarball` or if no path is specified, a temporary path
which is returned by the `create` function call. If a `predicate` function is
passed, it is called on each system path that is encountered while recursively
searching `dir` and if `predicate(path)` returns `false` the path is excluded
from the archive.
"""

function create(predicate::Function, dir::AbstractString, tarball::AbstractString)
    isdir(dir) ||
        error("not a directory: $dir\nUSAGE: create([predicate,] dir, [tarball])")
    open(tarball, write=true) do out
        write_tar(predicate, out, dir)
    end
    return tarball
end

function create(predicate::Function, dir::AbstractString)
    isdir(dir) ||
        error("not a directory: $dir\nUSAGE: create([predicate,] dir, [tarball])")
    tarball, out = mktemp()
    write_tar(predicate, out, dir)
    close(out)
    return tarball
end

create(dir::AbstractString, tarball::AbstractString) = create(p->true, dir, tarball)
create(dir::AbstractString) = create(p->true, dir)

"""
    extract(tarball, [ dir, ]) -> dir

        tarball   :: AbstractString
        dir       :: AbstractString

Extract a tar archive ("tarball") located at the path `tarball` into the
directory `dir`. The archive is extracted to `dir` which must either be an
existing writeable directory or which can be created. If `dir` is not specified,
the archive is extracted into a temporary directory, which is returned by the
`extract` function call.
"""

function extract(tarball::AbstractString, dir::AbstractString = mktempdir())
    isfile(tarball) ||
        error("not a file: $tarball\nUSAGE: extract(tarball, [dir])")
    ispath(dir) && !isdir(dir) &&
        error("not a directory: $dir\nUSAGE: extract(tarball, [dir])")
    isdir(dir) || mkdir(dir)
    # core call to extract tarball into dir here
    return dir
end

end # module
